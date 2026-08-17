import 'dart:async';
import 'dart:io';

/// Append-only structured diagnostic log for every significant pipeline event.
class DiagnosticLogService {
  static final DiagnosticLogService _instance =
      DiagnosticLogService._internal();
  factory DiagnosticLogService() => _instance;
  DiagnosticLogService._internal();

  static const String _logFileName = 'sonicwave_diagnostic.log';

  bool _initialised = false;

  /// Always returns null as log file creation is disabled.
  String? get logFilePath => null;

  // ──────────────────────────────────────────────────────────────────────────
  // Initialisation
  // ──────────────────────────────────────────────────────────────────────────

  Future<void> init() async {
    if (_initialised) return;
    _initialised = true;
    // Clean up any legacy diagnostic log files created on disk
    try {
      if (Platform.isAndroid) {
        final legacyFiles = [
          File('/storage/emulated/0/sonicWave/$_logFileName'),
          File('/storage/emulated/0/sonicWave/$_logFileName.1'),
          File('/storage/emulated/0/sonicWave/.diag_probe'),
        ];
        for (final f in legacyFiles) {
          if (await f.exists()) {
            await f.delete();
          }
        }
      }
    } catch (_) {}
  }

  /// Disk logging is disabled to eliminate unnecessary log file creation.
  void _write(Map<String, dynamic> entry) {
    // Disk logging disabled — no file operations executed.
  }

  // ──────────────────────────────────────────────────────────────────────────
  // Public API
  // ──────────────────────────────────────────────────────────────────────────

  /// Enqueue a diagnostic entry. Never throws.
  void log(String event, Map<String, dynamic> fields) {
    if (!_initialised) return;
    try {
      _write({'ts': _ts(), 'event': event, ...fields});
    } catch (_) {}
  }

  static String _ts() => DateTime.now().toUtc().toIso8601String();

  // ──────────────────────────────────────────────────────────────────────────
  // Event name constants
  // ──────────────────────────────────────────────────────────────────────────

  static const String session = 'session';
  static const String appLifecycle = 'app_lifecycle';
  static const String playStart = 'play_start';
  static const String playResolved = 'play_resolved';
  static const String playSourceFail = 'play_source_fail';
  static const String playLoaded = 'play_loaded';
  static const String playError = 'play_error';
  static const String streamCacheHit = 'stream_cache_hit';
  static const String ytdlpExtract = 'ytdlp_extract';
  static const String ytdlpRace = 'ytdlp_race';
  static const String ytdlpRuntime = 'ytdlp_runtime';
  static const String searchStart = 'search_start';
  static const String searchResult = 'search_result';
  static const String searchError = 'search_error';
  static const String audioFocus = 'audio_focus';
  static const String autoRecovery = 'auto_recovery';
  static const String downloadStart = 'download_start';
  static const String downloadHttpPath = 'download_http_path';
  static const String downloadYtdlp = 'download_ytdlp';
  static const String downloadComplete = 'download_complete';
  static const String downloadError = 'download_error';
  static const String downloadRetry = 'download_retry';
  static const String downloadResumed = 'download_resumed';
  static const String sharedLink = 'shared_link';
  static const String prefetch = 'prefetch';
}
