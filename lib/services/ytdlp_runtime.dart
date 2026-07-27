import 'dart:async';
import 'dart:io';

import 'package:extractor/extractor.dart';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'ytdlp_downloader.dart';

/// Single-flight guard + binary auto-update for YoutubeDLFlutter (yt-dlp).
///
/// Two reliability problems this centralizes (both learned from JunkFood02/Seal):
///
/// 1. **Double-init race** — youtubedl-android's init runs on the main thread
///    and is NOT reentrant. App startup fires initialize() without awaiting;
///    if a song plays before that finishes, a second initialize() used to hang
///    the native side. Every caller now shares ONE in-flight init future.
///
/// 2. **Stale binary** — the bundled yt-dlp goes out of date within weeks and
///    YouTube extraction silently breaks (signature / nsig changes). Seal fixes
///    this by updating the yt-dlp binary. [maybeUpdate] does the same: once
///    per [_updateInterval], in the background, after init succeeds.
///
/// FFmpeg is enabled here because it is required by every post-processing flag
/// the download path uses: `-x`, `--audio-format`, `--embed-thumbnail`,
/// `--embed-metadata`. It costs nothing to switch on — the ffmpeg AAR is
/// already packaged in the APK (android/app/build.gradle.kts keeps
/// `**/libffmpeg.zip.so`); `enableFFmpeg: false` only skipped unpacking it at
/// runtime, so the ~65MB shipped unused. Cover art embedding works because
/// mutagen is bundled inside the library's Python payload.
///
/// aria2c stays off: it is excluded from packaging, so `--concurrent-fragments`
/// is the throughput lever instead.
class YtDlpRuntime {
  YtDlpRuntime._();

  static Future<bool>? _inFlight;
  static Future<void>? _updateInFlight;
  static bool _updateCheckedThisRun = false;

  static const String _lastUpdateKey = 'ytdlp_last_update_ms';
  static const Duration _updateInterval = Duration(days: 3);

  /// Returns true when yt-dlp is ready. Safe to call anywhere, concurrently —
  /// parallel callers share the same init future.
  static Future<bool> ensureInitialized() {
    final existing = _inFlight;
    if (existing != null) return existing;
    final future = _doInit();
    _inFlight = future;
    return future;
  }

  static Future<bool> _doInit() async {
    try {
      if (await YoutubeDLFlutter.instance.isInitialized()) {
        _scheduleUpdateCheck();
        return true;
      }
      final result = await YoutubeDLFlutter.instance
          .initialize(enableFFmpeg: true, enableAria2c: false)
          .timeout(const Duration(seconds: 45));
      debugPrint(
          '[yt-dlp] Initialization: ${result.success} ${result.errorMessage ?? ""}');
      if (!result.success) {
        // Allow a later call to retry a failed init (transient IO/storage).
        _inFlight = null;
        return false;
      }
      _scheduleUpdateCheck();
      // Clean orphaned staging files from a previous crash/kill — fire and
      // forget so init isn't delayed.
      _cleanStagingDir();
      return true;
    } catch (e) {
      debugPrint('[yt-dlp] Initialization failed: $e');
      _inFlight = null;
      return false;
    }
  }

  /// Fire-and-forget: once per run, if enough time has passed, update the
  /// yt-dlp binary in the background so YouTube extraction keeps working.
  static void _scheduleUpdateCheck() {
    if (_updateCheckedThisRun) return;
    _updateCheckedThisRun = true;
    // Don't await — playback must never wait on a network binary update.
    maybeUpdate();
  }

  /// Update the bundled yt-dlp binary if it hasn't been updated within
  /// [_updateInterval]. Single-flight and non-blocking. Returns when the
  /// attempt (or the decision to skip) completes; callers usually ignore it.
  static Future<void> maybeUpdate({bool force = false}) {
    final existing = _updateInFlight;
    if (existing != null) return existing;
    final future = _doUpdate(force: force);
    _updateInFlight = future;
    return future;
  }

  static Future<void> _doUpdate({required bool force}) async {
    try {
      if (!await YoutubeDLFlutter.instance.isInitialized()) return;

      final prefs = await SharedPreferences.getInstance();
      final lastMs = prefs.getInt(_lastUpdateKey) ?? 0;
      final elapsed = DateTime.now().millisecondsSinceEpoch - lastMs;
      if (!force && lastMs != 0 && elapsed < _updateInterval.inMilliseconds) {
        return; // updated recently — skip
      }

      debugPrint('[yt-dlp] Checking for binary update...');
      final result = await YoutubeDLFlutter.instance
          .updateYoutubeDL()
          .timeout(const Duration(seconds: 60));
      debugPrint(
          '[yt-dlp] Update: ${result.status} ${result.version ?? ""} ${result.errorMessage ?? ""}');

      // Record the attempt time regardless of up-to-date vs updated, so we
      // don't hammer the network on every launch. On hard error we still
      // record it (the throttle applies to errors too — a broken update
      // endpoint shouldn't retry every cold start).
      await prefs.setInt(
          _lastUpdateKey, DateTime.now().millisecondsSinceEpoch);
    } catch (e) {
      debugPrint('[yt-dlp] Update check failed: $e');
    } finally {
      _updateInFlight = null;
    }
  }

  /// Remove orphaned files (partial downloads from a crash/kill) from the
  /// yt-dlp staging directory. Runs once on cold init, fire-and-forget.
  static Future<void> _cleanStagingDir() async {
    try {
      final dir = await YtDlpDownloader.stagingDir();
      if (!await dir.exists()) return;
      int removed = 0;
      await for (final entity in dir.list()) {
        if (entity is File) {
          try {
            await entity.delete();
            removed++;
          } catch (_) {}
        }
      }
      if (removed > 0) {
        debugPrint('[yt-dlp] Cleaned $removed orphaned staging file(s)');
      }
    } catch (e) {
      debugPrint('[yt-dlp] Staging cleanup failed: $e');
    }
  }
}
