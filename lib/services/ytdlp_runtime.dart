import 'dart:async';
import 'dart:io';

import 'package:extractor/extractor.dart';
import 'package:flutter/widgets.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'diagnostic_log_service.dart';
import 'youtube_service.dart';
import 'ytdlp_downloader.dart';

class _YtDlpLifecycleObserver with WidgetsBindingObserver {
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    DiagnosticLogService().log(DiagnosticLogService.appLifecycle, {
      'state': state.name,
    });
    if (state == AppLifecycleState.resumed) {
      debugPrint(
        '[yt-dlp] App resumed from background — checking native process health',
      );
      YtDlpRuntime.onAppResumed();
    } else if (state == AppLifecycleState.paused) {
      debugPrint('[yt-dlp] App paused/backgrounded');
    }
  }
}

/// Single-flight guard + binary auto-update for YoutubeDLFlutter (yt-dlp).
class YtDlpRuntime {
  YtDlpRuntime._();

  static Future<bool>? _inFlight;
  static Future<void>? _updateInFlight;
  static bool _updateCheckedThisRun = false;
  static bool _ready = false;
  static bool _observerRegistered = false;

  /// Register app lifecycle listener for Android Doze mode & background process recovery.
  static void initLifecycleObserver() {
    if (_observerRegistered) return;
    _observerRegistered = true;
    WidgetsBinding.instance.addObserver(_YtDlpLifecycleObserver());
  }

  /// Handle Android App Resume from background.
  static void onAppResumed() async {
    _consecutiveFailures = 0;
    YouTubeService.clearStreamCacheOnResume();

    try {
      final isInit = await YoutubeDLFlutter.instance.isInitialized().timeout(
        const Duration(seconds: 3),
      );
      if (!isInit) {
        debugPrint(
          '[yt-dlp] Native process died in background — force re-initializing',
        );
        forceReinitialize();
      } else {
        _ready = true;
      }
    } catch (e) {
      debugPrint(
        '[yt-dlp] Native process error on resume ($e) — force re-initializing',
      );
      forceReinitialize();
    }
  }

  /// Force a fresh native initialization sequence.
  static Future<bool> forceReinitialize() async {
    _ready = false;
    _inFlight = null;
    return ensureInitialized();
  }

  /// Whether the runtime is warm RIGHT NOW, without awaiting anything.
  ///
  /// The streaming path needs this: awaiting [ensureInitialized] on a cold start
  /// meant the very first song could sit behind the binary + FFmpeg unpack
  /// before yt-dlp even began extracting. Streaming checks this instead and
  /// simply skips yt-dlp when it is false — Explode/Invidious/Piped cover song
  /// #1, and yt-dlp joins the race from song #2 onward. Downloads still call
  /// [ensureInitialized] and wait, because for them yt-dlp is not optional.
  static bool get isReady => _ready;

  /// Consecutive extraction failures since the last success.
  static int _consecutiveFailures = 0;

  /// Failures in a row before the runtime is treated as broken.
  /// Set to 5 so transient mobile network timeouts do not trip unhealthy resets.
  static const int _unhealthyThreshold = 5;

  /// Report that yt-dlp produced a usable result. Resets the failure streak.
  static void markHealthy() {
    if (_consecutiveFailures > 0) {
      DiagnosticLogService().log(DiagnosticLogService.ytdlpRuntime, {
        'detail': 'healthy',
        'streak_cleared': _consecutiveFailures,
      });
    }
    _consecutiveFailures = 0;
  }

  /// Report that a yt-dlp extraction produced nothing.
  /// After [_unhealthyThreshold] consecutive failures the runtime resets so
  /// the next call re-runs initialize() and heals automatically.
  static void markExtractionFailed() {
    _consecutiveFailures++;
    DiagnosticLogService().log(DiagnosticLogService.ytdlpRuntime, {
      'detail': 'extraction_failed',
      'consecutive': _consecutiveFailures,
      'threshold': _unhealthyThreshold,
    });
    if (_consecutiveFailures < _unhealthyThreshold) return;
    debugPrint(
      '[yt-dlp] $_consecutiveFailures consecutive failures '
      '— resetting runtime for self-recovery',
    );
    DiagnosticLogService().log(DiagnosticLogService.ytdlpRuntime, {
      'detail': 'unhealthy_reset',
      'consecutive': _consecutiveFailures,
    });
    _consecutiveFailures = 0;
    _inFlight = null;
    unawaited(_recover());
  }

  /// Rebuild the runtime after it was marked unhealthy.
  static Future<void> _recover() async {
    try {
      final ok = await ensureInitialized();
      debugPrint('[yt-dlp] Recovery re-initialization: ');
      DiagnosticLogService().log(DiagnosticLogService.ytdlpRuntime, {
        'detail': 'recover',
        'ok': ok,
      });
    } catch (e) {
      debugPrint('[yt-dlp] Recovery re-initialization failed: ');
      DiagnosticLogService().log(DiagnosticLogService.ytdlpRuntime, {
        'detail': 'recover_failed',
        'error': e.toString(),
      });
    }
  }

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
    final sw = Stopwatch()..start();
    try {
      if (await YoutubeDLFlutter.instance.isInitialized()) {
        _ready = true;
        sw.stop();
        DiagnosticLogService().log(DiagnosticLogService.ytdlpRuntime, {
          'detail': 'already_initialized',
          'elapsed_ms': sw.elapsedMilliseconds,
        });
        _scheduleUpdateCheck();
        return true;
      }
      final result = await YoutubeDLFlutter.instance
          .initialize(enableFFmpeg: true, enableAria2c: false)
          .timeout(const Duration(seconds: 25));
      sw.stop();
      debugPrint(
        '[yt-dlp] Initialization: ${result.success} ${result.errorMessage ?? ""}',
      );
      DiagnosticLogService().log(DiagnosticLogService.ytdlpRuntime, {
        'detail': 'init',
        'ok': result.success,
        'elapsed_ms': sw.elapsedMilliseconds,
        if (result.errorMessage != null) 'error': result.errorMessage,
      });
      if (!result.success) {
        _inFlight = null;
        return false;
      }
      _ready = true;
      _scheduleUpdateCheck();
      _cleanStagingDir();
      return true;
    } catch (e) {
      sw.stop();
      debugPrint('[yt-dlp] Initialization failed: $e');
      DiagnosticLogService().log(DiagnosticLogService.ytdlpRuntime, {
        'detail': 'init_exception',
        'elapsed_ms': sw.elapsedMilliseconds,
        'error': e.toString(),
      });
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
      final sw = Stopwatch()..start();
      final result = await YoutubeDLFlutter.instance.updateYoutubeDL().timeout(
        const Duration(seconds: 60),
      );
      sw.stop();
      debugPrint(
        '[yt-dlp] Update: ${result.status} ${result.version ?? ""} ${result.errorMessage ?? ""}',
      );
      DiagnosticLogService().log(DiagnosticLogService.ytdlpRuntime, {
        'detail': 'update',
        'status': result.status.toString(),
        'version': result.version,
        'elapsed_ms': sw.elapsedMilliseconds,
        if (result.errorMessage != null) 'error': result.errorMessage,
      });

      // Record the attempt time regardless of up-to-date vs updated, so we
      // don't hammer the network on every launch. On hard error we still
      // record it (the throttle applies to errors too — a broken update
      // endpoint shouldn't retry every cold start).
      await prefs.setInt(_lastUpdateKey, DateTime.now().millisecondsSinceEpoch);
    } catch (e) {
      debugPrint('[yt-dlp] Update check failed: $e');
      DiagnosticLogService().log(DiagnosticLogService.ytdlpRuntime, {
        'detail': 'update_exception',
        'error': e.toString(),
      });
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
