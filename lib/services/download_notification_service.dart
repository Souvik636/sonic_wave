import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:permission_handler/permission_handler.dart';

/// Drives the Android download notification, and with it the foreground service
/// that keeps a download alive.
///
/// This exists for the shared-link flow. A link shared from another app is the
/// one download the user is most likely to fire off and walk away from — they
/// were in YouTube, not in SonicWave, and they have no reason to sit and watch a
/// progress bar. Without a foreground service Android is free to reclaim the
/// process the moment the app is backgrounded, so the download dies silently and
/// the file never appears. The notification is the visible half of that; the
/// service is the half that actually finishes the job.
///
/// Deliberately fail-soft throughout: the notification is feedback, never the
/// mechanism. A denied permission, a missing plugin (unit tests) or a non-Android
/// platform must all leave the download itself untouched.
class DownloadNotificationService {
  DownloadNotificationService._();

  static const MethodChannel _channel =
      MethodChannel('com.sonicwave.sonic_wave/downloads');

  /// Invoked by the native side when the user taps Cancel on the notification.
  /// Wired by PlayerProvider so the tap reaches the real cancel path.
  static ValueChanged<String>? onCancelRequested;

  static bool _handlerInstalled = false;
  static bool _permissionAsked = false;
  static bool _permissionGranted = false;

  /// Last percent pushed to the native side, so [update] can drop the rest.
  static int _lastPercent = -1;

  /// True only where the native service exists.
  static bool get _supported => !kIsWeb && Platform.isAndroid;

  static void _installHandler() {
    if (_handlerInstalled) return;
    _handlerInstalled = true;
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'onDownloadCancelRequested') {
        final videoId = call.arguments as String?;
        if (videoId != null && videoId.isNotEmpty) {
          onCancelRequested?.call(videoId);
        }
      }
      return null;
    });
  }

  /// Ask for POST_NOTIFICATIONS or check if already granted.
  static Future<bool> ensurePermission() async {
    if (!_supported) return false;
    try {
      final status = await Permission.notification.status;
      if (status.isGranted) {
        _permissionGranted = true;
        return true;
      }
      if (!_permissionAsked) {
        _permissionAsked = true;
        final res = await Permission.notification.request();
        _permissionGranted = res.isGranted;
        return _permissionGranted;
      }
    } catch (e) {
      debugPrint('[DownloadNotification] Permission check error: $e');
    }
    return _permissionGranted;
  }

  /// Start the foreground service for [videoId] and show an indeterminate
  /// notification. [title] is the song where known, otherwise something honest
  /// like "Reading video details".
  static Future<void> start({
    required String videoId,
    required String title,
    String? subtitle,
  }) async {
    if (!_supported) return;
    _installHandler();
    _lastPercent = -1;
    await ensurePermission();
    await _invoke('start', {
      'videoId': videoId,
      'title': title,
      'subtitle': subtitle ?? '',
    });
  }

  /// Update the progress bar.
  ///
  /// Only whole-percent changes cross the channel.
  static Future<void> update({
    required String videoId,
    required double progress,
    required String title,
    String? subtitle,
  }) async {
    if (!_supported) return;
    final percent = (progress.clamp(0.0, 1.0) * 100).round();
    if (percent == _lastPercent) return;
    _lastPercent = percent;
    await _invoke('update', {
      'videoId': videoId,
      'title': title,
      'subtitle': subtitle ?? '',
      'percent': percent,
    });
  }

  /// Swap to a terminal notification and let the service stop.
  static Future<void> complete({
    required String videoId,
    required String title,
  }) async {
    if (!_supported) return;
    _lastPercent = -1;
    await _invoke('complete', {'videoId': videoId, 'title': title});
  }

  static Future<void> fail({
    required String videoId,
    required String title,
    String? reason,
  }) async {
    if (!_supported) return;
    _lastPercent = -1;
    await _invoke('fail', {
      'videoId': videoId,
      'title': title,
      'reason': reason ?? '',
    });
  }

  /// Tear everything down with no trace — used when the user cancels, where a
  /// leftover notification would claim a download is still running.
  static Future<void> stop() async {
    if (!_supported) return;
    _lastPercent = -1;
    await _invoke('stop', const {});
  }

  static Future<void> _invoke(String method, Map<String, Object?> args) async {
    try {
      await _channel.invokeMethod<void>(method, args);
    } catch (e) {
      // MissingPluginException in tests, or a service the OS refused to start.
      debugPrint('[DownloadNotification] $method failed: $e');
    }
  }

  /// Test seam: forget the remembered permission answer and percent gate.
  @visibleForTesting
  static void resetForTest() {
    _permissionAsked = false;
    _permissionGranted = false;
    _lastPercent = -1;
  }

  /// Test seam: the percent gate, so it can be asserted without a platform.
  @visibleForTesting
  static bool shouldPushPercent(double progress) {
    final percent = (progress.clamp(0.0, 1.0) * 100).round();
    if (percent == _lastPercent) return false;
    _lastPercent = percent;
    return true;
  }
}
