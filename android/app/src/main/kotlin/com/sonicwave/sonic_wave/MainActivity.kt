package com.sonicwave.sonic_wave

import android.content.Intent
import android.media.MediaScannerConnection
import android.net.Uri
import android.os.Bundle
import android.provider.OpenableColumns
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import com.ryanheise.audioservice.AudioServiceActivity
import java.io.File
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicInteger

class MainActivity : AudioServiceActivity() {
    private val CHANNEL = "com.sonicwave.sonic_wave/intent"
    private val MEDIA_CHANNEL = "com.sonicwave.sonic_wave/media"
    private var methodChannel: MethodChannel? = null
    private var mediaChannel: MethodChannel? = null
    private var initialUri: String? = null
    private var initialSharedText: String? = null

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        handleIntent(intent)
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        // The activity is singleTask, so it is reused for every subsequent
        // share. Without this, getIntent() would keep returning the intent that
        // originally created it — and a later recreation (process death,
        // unhandled config change) would replay that stale share.
        setIntent(intent)
        handleIntent(intent)
        intent.data?.toString()?.let { uri ->
            methodChannel?.invokeMethod("onFileOpened", uri)
        }
        // The app was already running, so Dart is USUALLY listening: deliver the
        // shared text now rather than parking it for a getInitialSharedText poll
        // that has already happened. handleIntent() above has already parked it,
        // so it is only cleared once Dart confirms it took it — the handler is
        // installed by PlayerProvider, which does not exist while the app is
        // still on the splash screen, and a share dropped there is a share the
        // user has to redo.
        sharedTextOf(intent)?.let { text ->
            methodChannel?.invokeMethod("onTextShared", text, object : MethodChannel.Result {
                override fun success(result: Any?) {
                    initialSharedText = null
                }

                override fun error(code: String, message: String?, details: Any?) {}

                override fun notImplemented() {}
            })
        }
    }

    private fun handleIntent(intent: Intent?) {
        if (intent == null) return
        if (intent.action == Intent.ACTION_VIEW && intent.data != null) {
            initialUri = intent.data.toString()
        }
        sharedTextOf(intent)?.let { initialSharedText = it }
    }

    /// The plain text of an ACTION_SEND intent, or null when this is not one.
    private fun sharedTextOf(intent: Intent?): String? {
        if (intent?.action != Intent.ACTION_SEND) return null
        if (intent.type?.startsWith("text/") != true) return null
        return intent.getStringExtra(Intent.EXTRA_TEXT)?.takeIf { it.isNotBlank() }
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        methodChannel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL)
        methodChannel?.setMethodCallHandler { call, result ->
            when (call.method) {
                "getInitialFileUri" -> {
                    result.success(initialUri)
                    initialUri = null
                }
                // Text shared into a COLD-STARTED app. Cleared on read so a
                // later engine restart cannot re-trigger the same download.
                "getInitialSharedText" -> {
                    result.success(initialSharedText)
                    initialSharedText = null
                }
                // Copy a content:// URI to a real file in the app cache and
                // return its absolute path + display name. content URIs carry
                // only a transient read grant and can't be opened by dart:io,
                // so materializing them is what lets the Dart side read tags
                // (title/artist/cover art) and replay the file later.
                "resolveContentUri" -> {
                    val rawUri = call.arguments as? String
                    if (rawUri == null) {
                        result.success(null)
                        return@setMethodCallHandler
                    }
                    Thread {
                        val resolved: HashMap<String, String>? = try {
                            val uri = Uri.parse(rawUri)
                            var displayName: String? = null
                            try {
                                contentResolver.query(uri, null, null, null, null)?.use { c ->
                                    val idx = c.getColumnIndex(OpenableColumns.DISPLAY_NAME)
                                    if (idx >= 0 && c.moveToFirst()) {
                                        displayName = c.getString(idx)
                                    }
                                }
                            } catch (_: Exception) {}
                            val safeName = (displayName ?: uri.lastPathSegment ?: "opened_audio")
                                .substringAfterLast('/')
                                .replace(Regex("[\\\\/:*?\"<>|]"), "_")
                            val outDir = File(cacheDir, "opened_audio").apply { mkdirs() }
                            val outFile = File(outDir, safeName)
                            contentResolver.openInputStream(uri)?.use { input ->
                                outFile.outputStream().use { output -> input.copyTo(output) }
                            } ?: throw IllegalStateException("openInputStream returned null")
                            hashMapOf("path" to outFile.absolutePath, "name" to safeName)
                        } catch (e: Exception) {
                            null
                        }
                        runOnUiThread { result.success(resolved) }
                    }.start()
                }
                else -> result.notImplemented()
            }
        }

        mediaChannel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, MEDIA_CHANNEL)
        mediaChannel?.setMethodCallHandler { call, result ->
            when (call.method) {
                // Index (or, for a path that no longer exists, de-index) files
                // in MediaStore so other music apps and file managers see the
                // app's downloads without waiting for a reboot-time scan.
                "scanFiles" -> {
                    @Suppress("UNCHECKED_CAST")
                    val paths = (call.arguments as? List<String>)?.toTypedArray()
                    if (paths == null || paths.isEmpty()) {
                        result.success(0)
                        return@setMethodCallHandler
                    }
                    // The scanner calls back once per path, on a binder thread
                    // and in no particular order. Reply after the last one so
                    // the Dart side knows the database is really current — and
                    // guard the reply, since a MethodChannel result may only be
                    // submitted once.
                    val remaining = AtomicInteger(paths.size)
                    val replied = AtomicBoolean(false)
                    MediaScannerConnection.scanFile(applicationContext, paths, null) { _, _ ->
                        if (remaining.decrementAndGet() <= 0 && replied.compareAndSet(false, true)) {
                            runOnUiThread { result.success(paths.size) }
                        }
                    }
                }
                else -> result.notImplemented()
            }
        }

        val installerChannel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "com.sonicwave.sonic_wave/installer")
        installerChannel.setMethodCallHandler { call, result ->
            if (call.method == "installApk") {
                val filePath = call.argument<String>("filePath")
                if (filePath == null) {
                    result.error("INVALID_PATH", "APK file path was null", null)
                    return@setMethodCallHandler
                }
                try {
                    val apkFile = java.io.File(filePath)
                    val apkUri: Uri = androidx.core.content.FileProvider.getUriForFile(
                        applicationContext,
                        "${applicationContext.packageName}.fileprovider",
                        apkFile
                    )
                    val intent = Intent(Intent.ACTION_VIEW).apply {
                        setDataAndType(apkUri, "application/vnd.android.package-archive")
                        flags = Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_GRANT_READ_URI_PERMISSION
                    }
                    applicationContext.startActivity(intent)
                    result.success(true)
                } catch (e: Exception) {
                    result.error("INSTALL_FAILED", e.message, null)
                }
            } else {
                result.notImplemented()
            }
        }
    }
}
