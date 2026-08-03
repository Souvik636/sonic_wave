package com.sonicwave.sonic_wave

import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.pm.PackageInfo
import android.content.pm.PackageInstaller
import android.content.pm.PackageManager
import android.os.Build
import androidx.core.content.ContextCompat
import java.io.File
import java.security.MessageDigest
import java.util.concurrent.atomic.AtomicBoolean
import java.util.zip.ZipFile

/**
 * Installs a downloaded APK and, crucially, reports WHY the OS refused when it
 * refuses.
 *
 * The previous implementation fired an ACTION_VIEW intent at the system package
 * installer and immediately returned success. Everything the OS then decided —
 * signature mismatch, ABI mismatch, downgrade, no "install unknown apps" grant —
 * was invisible to the app, so a failed update surfaced only as Android's own
 * "Install not completed" with no explanation and nothing actionable.
 *
 * Two changes fix that:
 *  - [inspect] compares the downloaded APK against the installed app BEFORE the
 *    installer is launched, so the common failures can be explained in advance.
 *  - [install] uses a [PackageInstaller] session with a status callback, so the
 *    OS's actual verdict comes back to Dart instead of being swallowed.
 */
object ApkInstaller {

    private const val ACTION_STATUS = "com.sonicwave.sonic_wave.APK_INSTALL_STATUS"

    // ---------------------------------------------------------------- preflight

    /**
     * Everything the caller needs to decide whether this APK can replace the
     * running install, and to say something useful when it cannot.
     */
    fun inspect(context: Context, apk: File): HashMap<String, Any?> {
        val pm = context.packageManager
        val result = HashMap<String, Any?>()

        result["exists"] = apk.exists()
        result["fileSize"] = if (apk.exists()) apk.length() else 0L
        result["canRequestInstall"] = canRequestInstall(context)

        val archive = archiveInfo(context, apk)
        if (archive == null) {
            // getPackageArchiveInfo returns null for a file the parser cannot
            // read at all — a truncated or corrupted download, most often.
            result["parsable"] = false
            return result
        }
        result["parsable"] = true
        result["packageName"] = archive.packageName
        result["versionName"] = archive.versionName
        result["versionCode"] = versionCodeOf(archive)

        val installed = try {
            pm.getPackageInfo(context.packageName, signatureFlags())
        } catch (e: PackageManager.NameNotFoundException) {
            null
        }
        result["installedPackageName"] = context.packageName
        result["installedVersionName"] = installed?.versionName
        result["installedVersionCode"] = versionCodeOf(installed)

        result["packageMatches"] = archive.packageName == context.packageName

        // The one that actually bit us: Android will not replace an app with a
        // build signed by a different key, no matter how new it is.
        val newSigners = signerSha256(archive)
        val oldSigners = signerSha256(installed)
        result["signatureMatches"] =
            newSigners.isEmpty() || oldSigners.isEmpty() || newSigners.intersect(oldSigners).isNotEmpty()
        result["signaturesKnown"] = newSigners.isNotEmpty() && oldSigners.isNotEmpty()

        result["abiCompatible"] = abiCompatible(apk)
        result["deviceAbis"] = Build.SUPPORTED_ABIS.toList()

        return result
    }

    fun canRequestInstall(context: Context): Boolean =
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            context.packageManager.canRequestPackageInstalls()
        } else {
            true
        }

    private fun signatureFlags(): Int =
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
            PackageManager.GET_SIGNING_CERTIFICATES
        } else {
            @Suppress("DEPRECATION")
            PackageManager.GET_SIGNATURES
        }

    private fun archiveInfo(context: Context, apk: File): PackageInfo? = try {
        context.packageManager.getPackageArchiveInfo(apk.absolutePath, signatureFlags())
    } catch (e: Exception) {
        null
    }

    private fun versionCodeOf(info: PackageInfo?): Long = when {
        info == null -> -1L
        Build.VERSION.SDK_INT >= Build.VERSION_CODES.P -> info.longVersionCode
        else -> @Suppress("DEPRECATION") info.versionCode.toLong()
    }

    /** SHA-256 of each signing certificate, hex encoded. */
    private fun signerSha256(info: PackageInfo?): Set<String> {
        if (info == null) return emptySet()
        val signatures = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
            val signingInfo = info.signingInfo ?: return emptySet()
            if (signingInfo.hasMultipleSigners()) {
                signingInfo.apkContentsSigners
            } else {
                signingInfo.signingCertificateHistory
            }
        } else {
            @Suppress("DEPRECATION")
            info.signatures
        } ?: return emptySet()

        val digest = MessageDigest.getInstance("SHA-256")
        return signatures.mapNotNull { signature ->
            signature?.toByteArray()?.let { bytes ->
                digest.digest(bytes).joinToString("") { "%02x".format(it) }
            }
        }.toSet()
    }

    /**
     * True when the device can run the APK's native libraries. A release built
     * with `--target-platform=android-arm64` carries only arm64-v8a payloads and
     * fails on anything else with INSTALL_FAILED_NO_MATCHING_ABIS — which, once
     * again, the user only ever sees as "Install not completed".
     */
    private fun abiCompatible(apk: File): Boolean = try {
        ZipFile(apk).use { zip ->
            val apkAbis = zip.entries().asSequence()
                .mapNotNull { entry ->
                    val name = entry.name
                    if (!name.startsWith("lib/")) return@mapNotNull null
                    val end = name.indexOf('/', 4)
                    if (end <= 4) null else name.substring(4, end)
                }
                .toSet()
            // No native code at all means nothing to be incompatible with.
            apkAbis.isEmpty() || Build.SUPPORTED_ABIS.any { it in apkAbis }
        }
    } catch (e: Exception) {
        // A parse failure here should not block an install the OS might accept.
        true
    }

    // ------------------------------------------------------------------ install

    /**
     * Stream [apk] into a PackageInstaller session and commit it.
     *
     * [onResult] fires exactly once, with the OS's verdict. Note that a
     * successful self-update kills this process, so STATUS_SUCCESS frequently
     * never arrives — absence of a result is not failure.
     */
    fun install(
        context: Context,
        apk: File,
        onResult: (success: Boolean, code: String?, message: String?) -> Unit,
    ) {
        val appContext = context.applicationContext
        val replied = AtomicBoolean(false)
        var receiver: BroadcastReceiver? = null

        fun finish(success: Boolean, code: String?, message: String?) {
            if (!replied.compareAndSet(false, true)) return
            receiver?.let {
                try {
                    appContext.unregisterReceiver(it)
                } catch (_: Exception) {
                }
            }
            onResult(success, code, message)
        }

        receiver = object : BroadcastReceiver() {
            override fun onReceive(ctx: Context, intent: Intent) {
                when (val status = intent.getIntExtra(PackageInstaller.EXTRA_STATUS, Int.MIN_VALUE)) {
                    PackageInstaller.STATUS_PENDING_USER_ACTION -> {
                        // The system confirmation sheet. Not terminal — the real
                        // status arrives after the user accepts or declines.
                        @Suppress("DEPRECATION")
                        val confirm = intent.getParcelableExtra<Intent>(Intent.EXTRA_INTENT)
                        if (confirm == null) {
                            finish(false, "NO_CONFIRM_INTENT", "Android did not supply an install confirmation screen.")
                        } else {
                            confirm.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                            try {
                                appContext.startActivity(confirm)
                            } catch (e: Exception) {
                                finish(false, "CONFIRM_LAUNCH_FAILED", e.message)
                            }
                        }
                    }
                    PackageInstaller.STATUS_SUCCESS -> finish(true, null, null)
                    else -> finish(
                        false,
                        statusName(status),
                        intent.getStringExtra(PackageInstaller.EXTRA_STATUS_MESSAGE),
                    )
                }
            }
        }

        ContextCompat.registerReceiver(
            appContext,
            receiver,
            IntentFilter(ACTION_STATUS),
            ContextCompat.RECEIVER_NOT_EXPORTED,
        )

        try {
            val installer = appContext.packageManager.packageInstaller
            val params = PackageInstaller.SessionParams(PackageInstaller.SessionParams.MODE_FULL_INSTALL)
            params.setAppPackageName(appContext.packageName)

            val sessionId = installer.createSession(params)
            installer.openSession(sessionId).use { session ->
                session.openWrite("sonicwave_update", 0, apk.length()).use { out ->
                    apk.inputStream().use { input -> input.copyTo(out) }
                    session.fsync(out)
                }

                var flags = PendingIntent.FLAG_UPDATE_CURRENT
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                    // The installer fills in the status extras, so the
                    // PendingIntent has to stay mutable.
                    flags = flags or PendingIntent.FLAG_MUTABLE
                }
                val statusIntent = Intent(ACTION_STATUS).setPackage(appContext.packageName)
                val pending = PendingIntent.getBroadcast(appContext, sessionId, statusIntent, flags)
                session.commit(pending.intentSender)
            }
        } catch (e: Exception) {
            finish(false, "SESSION_ERROR", e.message)
        }
    }

    private fun statusName(status: Int): String = when (status) {
        PackageInstaller.STATUS_FAILURE -> "FAILURE"
        PackageInstaller.STATUS_FAILURE_ABORTED -> "ABORTED"
        PackageInstaller.STATUS_FAILURE_BLOCKED -> "BLOCKED"
        PackageInstaller.STATUS_FAILURE_CONFLICT -> "CONFLICT"
        PackageInstaller.STATUS_FAILURE_INCOMPATIBLE -> "INCOMPATIBLE"
        PackageInstaller.STATUS_FAILURE_INVALID -> "INVALID"
        PackageInstaller.STATUS_FAILURE_STORAGE -> "STORAGE"
        else -> "UNKNOWN_$status"
    }
}
