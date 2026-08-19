package com.sonicwave.sonic_wave

import android.bluetooth.BluetoothClass
import android.bluetooth.BluetoothDevice
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.media.AudioDeviceInfo
import android.media.AudioDeviceCallback
import android.media.AudioManager
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
    private val DISPLAY_CHANNEL = "com.sonicwave.sonic_wave/display"
    private val WEARABLE_CHANNEL = "com.sonicwave.sonic_wave/wearable"
    private var methodChannel: MethodChannel? = null
    private var mediaChannel: MethodChannel? = null
    private var downloadChannel: MethodChannel? = null
    private var displayChannel: MethodChannel? = null
    private var wearableChannel: MethodChannel? = null
    private var wearableReceiver: BroadcastReceiver? = null
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

        displayChannel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, DISPLAY_CHANNEL)
        displayChannel?.setMethodCallHandler { call, result ->
            when (call.method) {
                "enableHighRefreshRate" -> {
                    try {
                        if (android.os.Build.VERSION.SDK_INT >= android.os.Build.VERSION_CODES.M) {
                            runOnUiThread {
                                val currentWindow = window
                                val display = if (android.os.Build.VERSION.SDK_INT >= android.os.Build.VERSION_CODES.R) {
                                    display
                                } else {
                                    @Suppress("DEPRECATION")
                                    currentWindow.windowManager.defaultDisplay
                                }
                                val modes = display?.supportedModes ?: emptyArray()
                                var bestMode: android.view.Display.Mode? = null
                                for (mode in modes) {
                                    if (bestMode == null || mode.refreshRate > bestMode.refreshRate) {
                                        bestMode = mode
                                    }
                                }
                                if (bestMode != null && bestMode.refreshRate > 60f) {
                                    val params = currentWindow.attributes
                                    params.preferredDisplayModeId = bestMode.modeId
                                    currentWindow.attributes = params
                                }
                            }
                        }
                        result.success(true)
                    } catch (e: Exception) {
                        result.success(false)
                    }
                }
                "getSupportedRefreshRates" -> {
                    try {
                        val rates = mutableListOf<Double>()
                        if (android.os.Build.VERSION.SDK_INT >= android.os.Build.VERSION_CODES.M) {
                            val display = if (android.os.Build.VERSION.SDK_INT >= android.os.Build.VERSION_CODES.R) {
                                display
                            } else {
                                @Suppress("DEPRECATION")
                                window.windowManager.defaultDisplay
                            }
                            val modes = display?.supportedModes ?: emptyArray()
                            for (mode in modes) {
                                rates.add(mode.refreshRate.toDouble())
                            }
                        }
                        result.success(rates.distinct())
                    } catch (e: Exception) {
                        result.success(listOf(60.0))
                    }
                }
                else -> result.notImplemented()
            }
        }

        wearableChannel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, WEARABLE_CHANNEL)
        wearableChannel?.setMethodCallHandler { call, result ->
            when (call.method) {
                "checkConnectedDevices" -> {
                    checkCurrentConnectedDevices()
                    result.success(true)
                }
                else -> result.notImplemented()
            }
        }
        registerWearableReceiver()
        registerAudioDeviceCallback()
        checkCurrentConnectedDevices()
    }

    private var audioDeviceCallback: AudioDeviceCallback? = null

    private fun registerAudioDeviceCallback() {
        if (android.os.Build.VERSION.SDK_INT >= android.os.Build.VERSION_CODES.M) {
            try {
                val audioManager = getSystemService(Context.AUDIO_SERVICE) as? AudioManager ?: return
                if (audioDeviceCallback == null) {
                    audioDeviceCallback = object : AudioDeviceCallback() {
                        override fun onAudioDevicesAdded(addedDevices: Array<out AudioDeviceInfo>?) {
                            super.onAudioDevicesAdded(addedDevices)
                            checkCurrentConnectedDevices()
                        }

                        override fun onAudioDevicesRemoved(removedDevices: Array<out AudioDeviceInfo>?) {
                            super.onAudioDevicesRemoved(removedDevices)
                            checkCurrentConnectedDevices()
                        }
                    }
                    audioManager.registerAudioDeviceCallback(audioDeviceCallback, null)
                }
            } catch (e: Exception) {
                android.util.Log.e("MainActivity", "Error registering audio device callback: $e")
            }
        }
    }

    private fun checkCurrentConnectedDevices() {
        try {
            val audioManager = getSystemService(Context.AUDIO_SERVICE) as? AudioManager ?: return
            if (android.os.Build.VERSION.SDK_INT >= android.os.Build.VERSION_CODES.M) {
                val devices = audioManager.getDevices(AudioManager.GET_DEVICES_OUTPUTS)
                var foundDevice: AudioDeviceInfo? = null
                for (dev in devices) {
                    val t = dev.type
                    if (t == AudioDeviceInfo.TYPE_BLUETOOTH_A2DP ||
                        t == AudioDeviceInfo.TYPE_BLUETOOTH_SCO ||
                        t == AudioDeviceInfo.TYPE_HEARING_AID ||
                        (android.os.Build.VERSION.SDK_INT >= android.os.Build.VERSION_CODES.S && t == AudioDeviceInfo.TYPE_BLE_HEADSET) ||
                        (android.os.Build.VERSION.SDK_INT >= android.os.Build.VERSION_CODES.S && t == AudioDeviceInfo.TYPE_BLE_SPEAKER) ||
                        t == AudioDeviceInfo.TYPE_WIRED_HEADSET ||
                        t == AudioDeviceInfo.TYPE_WIRED_HEADPHONES ||
                        t == AudioDeviceInfo.TYPE_USB_HEADSET) {
                        foundDevice = dev
                        break
                    }
                }

                if (foundDevice != null) {
                    val rawName = foundDevice.productName?.toString() ?: ""
                    val name = if (rawName.isBlank()) "Wireless Audio Accessory" else rawName
                    val category = classifyAudioDeviceName(name, foundDevice.type)
                    val addr = if (android.os.Build.VERSION.SDK_INT >= android.os.Build.VERSION_CODES.P) {
                        foundDevice.address ?: ""
                    } else ""
                    runOnUiThread {
                        wearableChannel?.invokeMethod("onDeviceConnected", mapOf(
                            "name" to name,
                            "type" to category,
                            "address" to addr
                        ))
                    }
                    return
                }
            }
        } catch (e: Exception) {
            android.util.Log.e("MainActivity", "Error checking audio devices: $e")
        }
    }

    private fun classifyAudioDeviceName(name: String, deviceClass: Int = 0): String {
        val lower = name.lowercase()
        return when {
            lower.contains("watch") || lower.contains("band") || lower.contains("gear") || lower.contains("fit") -> "watch"
            lower.contains("neckband") || lower.contains("neck") || lower.contains("rockerz") || lower.contains("bullets") ||
            lower.contains("wireless") || lower.contains("buds") || lower.contains("ear") || lower.contains("headset") ||
            lower.contains("headphone") || lower.contains("airpod") || lower.contains("boat") || lower.contains("boult") ||
            lower.contains("noise") || lower.contains("sony") || lower.contains("jbl") || lower.contains("realme") ||
            lower.contains("oneplus") || lower.contains("oppo") || lower.contains("vivo") || lower.contains("samsung") ||
            lower.contains("infinity") || lower.contains("zebronics") || lower.contains("portronics") -> "headset"
            lower.contains("car") || lower.contains("auto") -> "car"
            lower.contains("speaker") || lower.contains("soundbar") -> "speaker"
            else -> "headset"
        }
    }

    private fun registerWearableReceiver() {
        if (wearableReceiver != null) return
        wearableReceiver = object : BroadcastReceiver() {
            override fun onReceive(context: Context?, intent: Intent?) {
                val action = intent?.action ?: return
                when (action) {
                    BluetoothDevice.ACTION_ACL_CONNECTED,
                    "android.bluetooth.a2dp.profile.action.CONNECTION_STATE_CHANGED",
                    "android.bluetooth.headset.profile.action.CONNECTION_STATE_CHANGED" -> {
                        checkCurrentConnectedDevices()
                    }
                    BluetoothDevice.ACTION_ACL_DISCONNECTED,
                    AudioManager.ACTION_AUDIO_BECOMING_NOISY -> {
                        val device: BluetoothDevice? = if (android.os.Build.VERSION.SDK_INT >= android.os.Build.VERSION_CODES.TIRAMISU) {
                            intent.getParcelableExtra(BluetoothDevice.EXTRA_DEVICE, BluetoothDevice::class.java)
                        } else {
                            @Suppress("DEPRECATION")
                            intent.getParcelableExtra(BluetoothDevice.EXTRA_DEVICE)
                        }
                        val name = try { device?.name ?: "Audio Device" } catch (e: SecurityException) { "Audio Device" }
                        runOnUiThread {
                            wearableChannel?.invokeMethod("onDeviceDisconnected", mapOf(
                                "name" to name
                            ))
                        }
                    }
                }
            }
        }
        val filter = IntentFilter().apply {
            addAction(BluetoothDevice.ACTION_ACL_CONNECTED)
            addAction(BluetoothDevice.ACTION_ACL_DISCONNECTED)
            addAction(AudioManager.ACTION_AUDIO_BECOMING_NOISY)
            addAction(AudioManager.ACTION_HEADSET_PLUG)
            addAction("android.bluetooth.a2dp.profile.action.CONNECTION_STATE_CHANGED")
            addAction("android.bluetooth.headset.profile.action.CONNECTION_STATE_CHANGED")
        }
        try {
            registerReceiver(wearableReceiver, filter)
        } catch (e: Exception) {}
    }

    override fun onResume() {
        super.onResume()
        checkCurrentConnectedDevices()
    }

    override fun cleanUpFlutterEngine(flutterEngine: FlutterEngine) {
        // A Cancel tap can arrive after the engine is gone. Dropping the
        // reference is what lets the service detect that and just stop itself
        // instead of invoking a channel whose executor no longer exists.
        DownloadForegroundService.channel = null
        downloadChannel?.setMethodCallHandler(null)
        downloadChannel = null
        displayChannel?.setMethodCallHandler(null)
        displayChannel = null
        wearableChannel?.setMethodCallHandler(null)
        wearableChannel = null
        try {
            if (android.os.Build.VERSION.SDK_INT >= android.os.Build.VERSION_CODES.M && audioDeviceCallback != null) {
                val audioManager = getSystemService(Context.AUDIO_SERVICE) as? AudioManager
                audioManager?.unregisterAudioDeviceCallback(audioDeviceCallback)
                audioDeviceCallback = null
            }
            wearableReceiver?.let { unregisterReceiver(it) }
            wearableReceiver = null
        } catch (e: Exception) {}
        super.cleanUpFlutterEngine(flutterEngine)
    }

    override fun onDestroy() {
        try {
            if (android.os.Build.VERSION.SDK_INT >= android.os.Build.VERSION_CODES.M && audioDeviceCallback != null) {
                val audioManager = getSystemService(Context.AUDIO_SERVICE) as? AudioManager
                audioManager?.unregisterAudioDeviceCallback(audioDeviceCallback)
                audioDeviceCallback = null
            }
            wearableReceiver?.let { unregisterReceiver(it) }
            wearableReceiver = null
        } catch (e: Exception) {}
        super.onDestroy()
    }
}
