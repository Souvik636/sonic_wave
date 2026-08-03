import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

class InstallerExecutionException implements Exception {
  final String message;
  const InstallerExecutionException(this.message);

  @override
  String toString() => 'InstallerExecutionException: $message';
}

/// What the OS can tell us about a downloaded APK relative to the running app.
///
/// This exists because "Install not completed" is the only thing Android says
/// out loud, and it says it for at least four unrelated reasons. Checking them
/// up front is the difference between a dead end and an instruction.
@immutable
class ApkPreflight {
  /// False when the package parser could not read the file at all — almost
  /// always a truncated or corrupted download.
  final bool parsable;

  /// The APK's own identity.
  final String? packageName;
  final String? versionName;
  final int versionCode;

  /// The currently installed app, for comparison.
  final String? installedVersionName;
  final int installedVersionCode;

  /// False when the APK would install as a different app entirely.
  final bool packageMatches;

  /// False when the APK is signed with a different key than the installed app.
  /// Android refuses that outright and cannot be talked into it.
  final bool signatureMatches;

  /// False when neither certificate could be read, in which case
  /// [signatureMatches] is optimistic rather than verified.
  final bool signaturesKnown;

  /// False when the APK carries no native library for this device's ABI.
  final bool abiCompatible;

  /// Whether the user has granted "install unknown apps" to SonicWave.
  final bool canRequestInstall;

  final List<String> deviceAbis;

  const ApkPreflight({
    required this.parsable,
    required this.packageName,
    required this.versionName,
    required this.versionCode,
    required this.installedVersionName,
    required this.installedVersionCode,
    required this.packageMatches,
    required this.signatureMatches,
    required this.signaturesKnown,
    required this.abiCompatible,
    required this.canRequestInstall,
    required this.deviceAbis,
  });

  factory ApkPreflight.fromMap(Map<dynamic, dynamic> map) {
    return ApkPreflight(
      parsable: map['parsable'] as bool? ?? false,
      packageName: map['packageName'] as String?,
      versionName: map['versionName'] as String?,
      versionCode: (map['versionCode'] as num?)?.toInt() ?? -1,
      installedVersionName: map['installedVersionName'] as String?,
      installedVersionCode: (map['installedVersionCode'] as num?)?.toInt() ?? -1,
      packageMatches: map['packageMatches'] as bool? ?? true,
      signatureMatches: map['signatureMatches'] as bool? ?? true,
      signaturesKnown: map['signaturesKnown'] as bool? ?? false,
      abiCompatible: map['abiCompatible'] as bool? ?? true,
      canRequestInstall: map['canRequestInstall'] as bool? ?? true,
      deviceAbis:
          (map['deviceAbis'] as List?)?.map((e) => e.toString()).toList() ?? const [],
    );
  }

  /// True when nothing known would stop the install.
  bool get isInstallable =>
      parsable && packageMatches && signatureMatches && abiCompatible;

  /// A user-facing explanation of the blocking problem, or null when there
  /// isn't one. Deliberately concrete: each of these has a different fix.
  String? get blockingReason {
    if (!parsable) {
      return 'The downloaded file is not a readable Android package. '
          'It was most likely corrupted in transit — download it again.';
    }
    if (!packageMatches) {
      return 'This APK installs "$packageName", not this app. '
          'It cannot be applied as an update.';
    }
    if (!signatureMatches) {
      return 'This update is signed with a different key than your installed '
          'copy of SonicWave, so Android will not install it over the top. '
          'Uninstall SonicWave first, then install this update — note that '
          'uninstalling removes downloaded songs and settings.';
    }
    if (!abiCompatible) {
      final abis = deviceAbis.isEmpty ? 'this device' : deviceAbis.join(', ');
      return 'This build has no native code for $abis. '
          'Download the APK that matches your device architecture.';
    }
    return null;
  }
}

class AndroidInstallerRunner {
  static const MethodChannel _channel = MethodChannel('com.sonicwave.sonic_wave/installer');

  /// Inspect [apkFile] against the running install. Returns null off Android,
  /// or when the native side could not read the file.
  static Future<ApkPreflight?> inspect(File apkFile) async {
    if (!Platform.isAndroid) return null;
    try {
      final raw = await _channel.invokeMethod<Map<dynamic, dynamic>>(
        'inspectApk',
        {'filePath': apkFile.path},
      );
      if (raw == null) return null;
      final preflight = ApkPreflight.fromMap(raw);
      debugPrint('[AndroidInstaller] Preflight: '
          'parsable=${preflight.parsable} '
          'pkg=${preflight.packageName} '
          'v=${preflight.versionName}(${preflight.versionCode}) '
          'installed=${preflight.installedVersionName}(${preflight.installedVersionCode}) '
          'sigMatch=${preflight.signatureMatches} '
          'sigKnown=${preflight.signaturesKnown} '
          'abiOk=${preflight.abiCompatible} '
          'canInstall=${preflight.canRequestInstall}');
      return preflight;
    } catch (e) {
      debugPrint('[AndroidInstaller] Preflight failed: $e');
      return null;
    }
  }

  /// Whether the user has granted "install unknown apps" to this app.
  static Future<bool> canInstallPackages() async {
    if (!Platform.isAndroid) return true;
    try {
      return await _channel.invokeMethod<bool>('canInstallPackages') ?? true;
    } catch (e) {
      debugPrint('[AndroidInstaller] Permission check failed: $e');
      return true;
    }
  }

  /// Open the per-app "Install unknown apps" settings screen.
  static Future<void> openInstallPermissionSettings() async {
    if (!Platform.isAndroid) return;
    try {
      await _channel.invokeMethod<bool>('openInstallPermissionSettings');
    } catch (e) {
      debugPrint('[AndroidInstaller] Could not open install settings: $e');
    }
  }

  /// Install the APK, waiting for the OS's actual verdict.
  ///
  /// Throws [InstallerExecutionException] carrying the real reason when Android
  /// rejects the package. A successful self-update kills this process, so the
  /// success path frequently never returns — that is expected.
  static Future<bool> installApk(File apkFile) async {
    if (!await apkFile.exists()) {
      throw InstallerExecutionException('APK binary file not found at path: ${apkFile.path}');
    }

    debugPrint('[AndroidInstaller] Committing PackageInstaller session for: ${apkFile.path}');

    if (!Platform.isAndroid) {
      // Fallback simulation for non-Android / test execution
      debugPrint('[AndroidInstaller] Mocking APK install trigger on non-Android platform.');
      return true;
    }

    try {
      final success = await _channel.invokeMethod<bool>('installApk', {
        'filePath': apkFile.path,
      });
      return success ?? true;
    } on PlatformException catch (e) {
      debugPrint('[AndroidInstaller] Install rejected: ${e.code} ${e.message}');
      throw InstallerExecutionException(_explain(e.code, e.message));
    } catch (e) {
      debugPrint('[AndroidInstaller] Error launching APK installer: $e');
      throw InstallerExecutionException('APK installation trigger failed: $e');
    }
  }

  /// Turn a PackageInstaller status into something a user can act on.
  static String _explain(String code, String? message) {
    final detail = (message == null || message.trim().isEmpty) ? '' : ' ($message)';
    switch (code) {
      case 'CONFLICT':
        return 'Android refused the update because it conflicts with the '
            'installed copy — usually a different signing key or an older '
            'version number. Uninstall SonicWave and install this APK fresh.$detail';
      case 'INCOMPATIBLE':
        return 'This build is not compatible with your device (Android version '
            'or CPU architecture).$detail';
      case 'INVALID':
        return 'Android could not read this package. The download was probably '
            'corrupted — try again.$detail';
      case 'BLOCKED':
        return 'The install was blocked, most likely by Play Protect or a device '
            'policy. Allow it and retry.$detail';
      case 'ABORTED':
        return 'Installation was cancelled.$detail';
      case 'STORAGE':
        return 'Not enough free storage to install the update.$detail';
      case 'SESSION_ERROR':
        return 'Could not start the installation session.$detail';
      default:
        return 'Installation failed$detail';
    }
  }
}
