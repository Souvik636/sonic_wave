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
    private val DOWNLOAD_CHANNEL = "com.sonicwave.sonic_wave/downloads"
    private var methodChannel: MethodChannel? = null
    private var mediaChannel: MethodChannel? = null
    private var downloadChannel: MethodChannel? = null
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
                    val remaining = AtomicInteger(paths.size)
                    val replied = AtomicBoolean(false)
                    MediaScannerConnection.scanFile(applicationContext, paths, null) { _, _ ->
                        if (remaining.decrementAndGet() <= 0 && replied.compareAndSet(false, true)) {
                            runOnUiThread { result.success(paths.size) }
                        }
                    }
                }
                // Native metadata reader fallback using Android's
                // MediaMetadataRetriever, which correctly handles all ID3v2
                // text encoding variants (Latin-1, UTF-16 LE/BE with BOM,
                // UTF-8). This is what other Android players use, which is
                // why they display correct titles while the Dart-only parser
                // can produce CJK mojibake from mis-encoded tags.
                "readNativeMetadata" -> {
                    val filePath = call.argument<String>("path")
                    if (filePath == null) {
                        result.success(null)
                        return@setMethodCallHandler
                    }
                    Thread {
                        val meta: HashMap<String, Any?>? = try {
                            val retriever = android.media.MediaMetadataRetriever()
                            retriever.setDataSource(filePath)
                            val title = retriever.extractMetadata(
                                android.media.MediaMetadataRetriever.METADATA_KEY_TITLE
                            )
                            val artist = retriever.extractMetadata(
                                android.media.MediaMetadataRetriever.METADATA_KEY_ARTIST
                            )
                            val album = retriever.extractMetadata(
                                android.media.MediaMetadataRetriever.METADATA_KEY_ALBUM
                            )
                            val durationStr = retriever.extractMetadata(
                                android.media.MediaMetadataRetriever.METADATA_KEY_DURATION
                            )
                            val art = retriever.embeddedPicture
                            retriever.release()

                            // Write embedded art to a temp file if present
                            var artPath: String? = null
                            if (art != null && art.isNotEmpty()) {
                                val hash = filePath.hashCode().toUInt().toString(16)
                                val artFile = File(cacheDir, "native_art_${hash}.jpg")
                                if (!artFile.exists() || artFile.length() != art.size.toLong()) {
                                    artFile.writeBytes(art)
                                }
                                artPath = artFile.absolutePath
                            }

                            hashMapOf(
                                "title" to title,
                                "artist" to artist,
                                "album" to album,
                                "durationMs" to (durationStr?.toLongOrNull() ?: 0L),
                                "artPath" to artPath,
                            )
                        } catch (e: Exception) {
                            null
                        }
                        runOnUiThread { result.success(meta) }
                    }.start()
                }
                else -> result.notImplemented()
            }
        }

        // Progress notification + the foreground service that keeps a download
        // alive once the app is backgrounded. Driven from Dart by
        // DownloadNotificationService; the Cancel action comes back the other
        // way, through DownloadForegroundService.channel.
        downloadChannel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, DOWNLOAD_CHANNEL)
        DownloadForegroundService.channel = downloadChannel
        downloadChannel?.setMethodCallHandler { call, result ->
            try {
                when (call.method) {
                    "start" -> {
                        DownloadForegroundService.start(
                            applicationContext,
                            call.argument<String>("videoId").orEmpty(),
                            call.argument<String>("title").orEmpty(),
                            call.argument<String>("subtitle").orEmpty(),
                        )
                        result.success(true)
                    }
                    "update" -> {
                        DownloadForegroundService.send(
                            applicationContext,
                            DownloadForegroundService.ACTION_UPDATE,
                        ) {
                            putExtra(DownloadForegroundService.EXTRA_VIDEO_ID, call.argument<String>("videoId").orEmpty())
                            putExtra(DownloadForegroundService.EXTRA_TITLE, call.argument<String>("title").orEmpty())
                            putExtra(DownloadForegroundService.EXTRA_SUBTITLE, call.argument<String>("subtitle").orEmpty())
                            putExtra(DownloadForegroundService.EXTRA_PERCENT, call.argument<Int>("percent") ?: -1)
                        }
                        result.success(true)
                    }
                    "complete" -> {
                        DownloadForegroundService.send(
                            applicationContext,
                            DownloadForegroundService.ACTION_COMPLETE,
                        ) {
                            putExtra(DownloadForegroundService.EXTRA_VIDEO_ID, call.argument<String>("videoId").orEmpty())
                            putExtra(DownloadForegroundService.EXTRA_TITLE, call.argument<String>("title").orEmpty())
                        }
                        result.success(true)
                    }
                    "fail" -> {
                        DownloadForegroundService.send(
                            applicationContext,
                            DownloadForegroundService.ACTION_FAIL,
                        ) {
                            putExtra(DownloadForegroundService.EXTRA_VIDEO_ID, call.argument<String>("videoId").orEmpty())
                            putExtra(DownloadForegroundService.EXTRA_TITLE, call.argument<String>("title").orEmpty())
                            putExtra(DownloadForegroundService.EXTRA_REASON, call.argument<String>("reason").orEmpty())
                        }
                        result.success(true)
                    }
                    "stop" -> {
                        DownloadForegroundService.send(
                            applicationContext,
                            DownloadForegroundService.ACTION_STOP,
                        )
                        result.success(true)
                    }
                    else -> result.notImplemented()
                }
            } catch (e: Exception) {
                // The notification is feedback, never the mechanism — a service
                // the OS refused to start must not fail the download in Dart.
                result.success(false)
            }
        }

        val installerChannel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "com.sonicwave.sonic_wave/installer")
        installerChannel.setMethodCallHandler { call, result ->
            when (call.method) {
                // Compare the downloaded APK against the running install before
                // the installer is ever launched, so a mismatch can be explained
                // instead of surfacing as a bare "Install not completed".
                "inspectApk" -> {
                    val filePath = call.argument<String>("filePath")
                    if (filePath == null) {
                        result.error("INVALID_PATH", "APK file path was null", null)
                        return@setMethodCallHandler
                    }
                    Thread {
                        val info = try {
                            ApkInstaller.inspect(applicationContext, File(filePath))
                        } catch (e: Exception) {
                            null
                        }
                        runOnUiThread {
                            if (info == null) {
                                result.error("INSPECT_FAILED", "Could not read the downloaded APK.", null)
                            } else {
                                result.success(info)
                            }
                        }
                    }.start()
                }

                "canInstallPackages" -> result.success(ApkInstaller.canRequestInstall(applicationContext))

                // Send the user to the per-app "Install unknown apps" toggle.
                // REQUEST_INSTALL_PACKAGES in the manifest only makes the app
                // eligible to ask; without this grant the installer aborts.
                "openInstallPermissionSettings" -> {
                    try {
                        val intent = if (android.os.Build.VERSION.SDK_INT >= android.os.Build.VERSION_CODES.O) {
                            Intent(
                                android.provider.Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES,
                                Uri.parse("package:$packageName"),
                            )
                        } else {
                            Intent(android.provider.Settings.ACTION_SECURITY_SETTINGS)
                        }
                        intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                        applicationContext.startActivity(intent)
                        result.success(true)
                    } catch (e: Exception) {
                        result.error("SETTINGS_FAILED", e.message, null)
                    }
                }

                "installApk" -> {
                    val filePath = call.argument<String>("filePath")
                    if (filePath == null) {
                        result.error("INVALID_PATH", "APK file path was null", null)
                        return@setMethodCallHandler
                    }
                    val apkFile = File(filePath)
                    if (!apkFile.exists()) {
                        result.error("INVALID_PATH", "APK file no longer exists at $filePath", null)
                        return@setMethodCallHandler
                    }
                    // A MethodChannel result may only be submitted once, and the
                    // status callback can in principle fire more than that.
                    val replied = AtomicBoolean(false)
                    ApkInstaller.install(applicationContext, apkFile) { success, code, message ->
                        if (!replied.compareAndSet(false, true)) return@install
                        runOnUiThread {
                            if (success) {
                                result.success(true)
                            } else {
                                result.error(code ?: "INSTALL_FAILED", message, null)
                            }
                        }
                    }
                }

                else -> result.notImplemented()
            }
        }
    }

    override fun cleanUpFlutterEngine(flutterEngine: FlutterEngine) {
        // A Cancel tap can arrive after the engine is gone. Dropping the
        // reference is what lets the service detect that and just stop itself
        // instead of invoking a channel whose executor no longer exists.
        DownloadForegroundService.channel = null
        downloadChannel?.setMethodCallHandler(null)
        downloadChannel = null
        super.cleanUpFlutterEngine(flutterEngine)
    }
}
