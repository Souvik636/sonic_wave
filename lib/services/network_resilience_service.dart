import 'dart:async';

import 'package:flutter/foundation.dart';

import 'diagnostic_log_service.dart';
import 'youtube_service.dart';
import 'ytdlp_runtime.dart';

/// Centralized, highly agile Self-Healing & Resilience Supervisor.
///
/// Wraps network and playback operations in an auto-healing loop that
/// automatically recovers from app backgrounding, dead sockets, network switches,
/// carrier IP shifts, and YouTube PO-token blocks.
class NetworkResilienceService {
  static final NetworkResilienceService _instance =
      NetworkResilienceService._internal();
  factory NetworkResilienceService() => _instance;
  NetworkResilienceService._internal();

  /// Execute an asynchronous network/resolution operation with automatic
  /// multi-stage healing and retry ladder.
  Future<T> runWithAutoHeal<T>(
    Future<T> Function() operation, {
    required String name,
    int maxAttempts = 3,
    bool Function(T result)? isValid,
  }) async {
    dynamic lastError;

    for (int attempt = 1; attempt <= maxAttempts; attempt++) {
      try {
        final result = await operation();
        if (isValid != null && !isValid(result)) {
          throw Exception('Operation $name returned invalid/empty result');
        }
        if (attempt > 1) {
          debugPrint('[Resilience] $name succeeded on attempt #$attempt after self-healing');
          DiagnosticLogService().log(
            DiagnosticLogService.autoRecovery,
            {'operation': name, 'attempt': attempt, 'status': 'success'},
          );
        }
        return result;
      } catch (e) {
        lastError = e;
        debugPrint('[Resilience] $name failed on attempt #$attempt/$maxAttempts: $e');

        DiagnosticLogService().log(
          DiagnosticLogService.autoRecovery,
          {
            'operation': name,
            'attempt': attempt,
            'maxAttempts': maxAttempts,
            'error': e.toString(),
          },
        );

        if (attempt < maxAttempts) {
          await _applyHealingProtocol(attempt, e);
          // Small backoff before retrying
          await Future.delayed(Duration(milliseconds: 150 * attempt));
        }
      }
    }

    throw lastError ?? Exception('$name failed after $maxAttempts self-healing attempts');
  }

  /// Apply progressive multi-level self-healing protocols based on attempt number and error type.
  Future<void> _applyHealingProtocol(int attempt, dynamic error) async {
    final errStr = error.toString().toLowerCase();

    debugPrint('[Resilience] Applying Level $attempt Self-Healing Protocol for error: $errStr');

    // Level 1: Purge stale stream cache
    YouTubeService.clearStreamCacheOnResume();

    // Level 2: Refresh HTTP socket pools for YouTube Explode
    YouTubeService.refreshExplodeClient();

    // Level 3: If process or JNI error, force re-initialize native yt-dlp binary
    if (attempt >= 2 ||
        errStr.contains('process') ||
        errStr.contains('nullpointer') ||
        errStr.contains('broken pipe') ||
        errStr.contains('uninitialized') ||
        errStr.contains('socket') ||
        errStr.contains('connection reset')) {
      await YtDlpRuntime.forceReinitialize();
    }
  }
}
