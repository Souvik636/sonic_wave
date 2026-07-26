import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

class InstallerExecutionException implements Exception {
  final String message;
  const InstallerExecutionException(this.message);

  @override
  String toString() => 'InstallerExecutionException: $message';
}

class AndroidInstallerRunner {
  static const MethodChannel _channel = MethodChannel('com.sonicwave.sonic_wave/installer');

  /// Launch native Android Package Installer for the downloaded APK file.
  static Future<bool> installApk(File apkFile) async {
    if (!await apkFile.exists()) {
      throw InstallerExecutionException('APK binary file not found at path: ${apkFile.path}');
    }

    debugPrint('[AndroidInstaller] Triggering native PackageInstaller for: ${apkFile.path}');

    try {
      if (Platform.isAndroid) {
        final success = await _channel.invokeMethod<bool>('installApk', {
          'filePath': apkFile.path,
        });
        return success ?? true;
      } else {
        // Fallback simulation for non-Android / test execution
        debugPrint('[AndroidInstaller] Mocking APK install trigger on non-Android platform.');
        return true;
      }
    } on PlatformException catch (e) {
      debugPrint('[AndroidInstaller] PlatformChannel error launching APK installer: ${e.message}');
      throw InstallerExecutionException('Failed to launch Android PackageInstaller: ${e.message}');
    } catch (e) {
      debugPrint('[AndroidInstaller] Error launching APK installer: $e');
      throw InstallerExecutionException('APK installation trigger failed: $e');
    }
  }
}
