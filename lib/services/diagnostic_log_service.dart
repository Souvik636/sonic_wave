import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

/// Append-only structured diagnostic log for every significant pipeline event.
///
/// ## File location — why it was invisible
///
/// [StorageLocationService.getAppRootDir] resolves to app-internal storage by
/// default (`/data/data/com.sonicwave.sonic_wave/files/sonicWave`), which is
/// invisible to every Android file manager unless you have root. The log is
/// useless there.
///
/// This service writes to the PUBLIC external path instead:
///
///   /storage/emulated/0/sonicWave/sonicwave_diagnostic.log
///
/// That is the same directory the user's downloaded songs land in when the
/// storage setting is "Device Internal". It is visible in Files, accessible
/// via `adb pull`, and can be emailed from any file-manager app.
///
/// Fallback chain (in order):
///   1. `/storage/emulated/0/sonicWave/` — public, visible
///   2. `<getExternalStorageDirectory()>/sonicWave/` — app-external, visible
///   3. `<getApplicationDocumentsDirectory()>/sonicWave/` — internal, last resort
///
/// The actual path is printed to logcat on init so you can always confirm it:
///   [DiagLog] writing to /storage/emulated/0/sonicWave/sonicwave_diagnostic.log
///
/// ## Format — JSONL
///
/// One JSON object per line. Every entry has at least `ts` (ISO-8601 UTC) and
/// `event`. Parse with `jq` or open in any text editor:
///
///   adb pull /storage/emulated/0/sonicWave/sonicwave_diagnostic.log
///   cat sonicwave_diagnostic.log | jq .
///
/// ## Flush behaviour
///
/// Writes are flushed to disk after every entry. The old code used
/// `IOSink.add()` without flushing — entries sat in an OS buffer and were
/// lost if the process was killed or ANR'd. Each entry is now written with
/// `File.writeAsBytes(... mode: FileMode.append)` directly, which is
/// synchronous at the OS level and survives a kill.
class DiagnosticLogService {
  static final DiagnosticLogService _instance =
      DiagnosticLogService._internal();
  factory DiagnosticLogService() => _instance;
  DiagnosticLogService._internal();

  static const int _maxBytes = 1536 * 1024; // 1.5 MB per file
  static const String _logFileName = 'sonicwave_diagnostic.log';

  File? _logFile;
  int _bytesWritten = 0;
  bool _initialised = false;

  /// Absolute path the log is being written to, or null before init.
  String? get logFilePath => _logFile?.path;

  // ──────────────────────────────────────────────────────────────────────────
  // Initialisation
  // ──────────────────────────────────────────────────────────────────────────

  Future<void> init() async {
    if (_initialised) return;
    _initialised = true;
    try {
      final dir = await _resolveLogDir();
      if (!await dir.exists()) {
        await dir.create(recursive: true);
      }
      _logFile = File('${dir.path}${Platform.pathSeparator}$_logFileName');

      if (await _logFile!.exists()) {
        _bytesWritten = await _logFile!.length();
        if (_bytesWritten >= _maxBytes) await _rotate();
      }

      debugPrint('[DiagLog] writing to ${_logFile!.path}');
      _write({
        'event': session,
        'ts': _ts(),
        'event_detail': 'log_opened',
        'file': _logFile!.path,
        'existing_bytes': _bytesWritten,
      });
    } catch (e) {
      debugPrint('[DiagLog] Init failed: $e');
    }
  }

  /// Resolve the best writable public directory for the log.
  ///
  /// Tries the public `/storage/emulated/0/sonicWave` path first because that
  /// is the only location that is trivially visible in the file manager —
  /// no app needed, no root needed.
  Future<Directory> _resolveLogDir() async {
    if (Platform.isAndroid) {
      // 1. Public primary external — /storage/emulated/0/sonicWave
      final pub = Directory('/storage/emulated/0/sonicWave');
      try {
        if (!await pub.exists()) await pub.create(recursive: true);
        // Verify it is actually writable.
        final probe = File('${pub.path}/.diag_probe');
        await probe.writeAsString('x');
        await probe.delete();
        return pub;
      } catch (_) {}

      // 2. App-scoped external — /sdcard/Android/data/<pkg>/files/sonicWave
      try {
        final ext = await getExternalStorageDirectory();
        if (ext != null) {
          final d = Directory('${ext.path}/sonicWave');
          if (!await d.exists()) await d.create(recursive: true);
          return d;
        }
      } catch (_) {}
    }

    // 3. App documents — always writable, not visible without a file manager
    final docs = await getApplicationDocumentsDirectory();
    final d = Directory('${docs.path}/sonicWave');
    if (!await d.exists()) await d.create(recursive: true);
    debugPrint('[DiagLog] WARNING: log is in app-internal storage — '
        'not visible in the file manager');
    return d;
  }

  Future<void> _rotate() async {
    final file = _logFile;
    if (file == null) return;
    try {
      final backup = File('${file.path}.1');
      if (await backup.exists()) await backup.delete();
      if (await file.exists()) await file.rename(backup.path);
      _logFile = File(file.path);
      _bytesWritten = 0;
    } catch (e) {
      debugPrint('[DiagLog] Rotation failed: $e');
    }
  }

  /// Write one line synchronously (append + flush = no buffered loss).
  void _write(Map<String, dynamic> entry) {
    final file = _logFile;
    if (file == null) return;
    try {
      final bytes = utf8.encode('${jsonEncode(entry)}\n');
      _bytesWritten += bytes.length;
      // RandomAccessFile gives us append + flush in one operation,
      // which survives a process kill better than IOSink.add().
      final raf = file.openSync(mode: FileMode.append);
      try {
        raf.writeFromSync(bytes);
        raf.flushSync();
      } finally {
        raf.closeSync();
      }
      if (_bytesWritten >= _maxBytes) {
        unawaited(_rotate());
      }
    } catch (e) {
      debugPrint('[DiagLog] Write failed: $e');
    }
  }

  // ──────────────────────────────────────────────────────────────────────────
  // Public API
  // ──────────────────────────────────────────────────────────────────────────

  /// Enqueue a diagnostic entry. Never throws.
  void log(String event, Map<String, dynamic> fields) {
    if (!_initialised) return;
    try {
      _write({
        'ts': _ts(),
        'event': event,
        ...fields,
      });
    } catch (_) {}
  }

  static String _ts() => DateTime.now().toUtc().toIso8601String();

  // ──────────────────────────────────────────────────────────────────────────
  // Event name constants
  // ──────────────────────────────────────────────────────────────────────────

  static const String session         = 'session';
  static const String appLifecycle    = 'app_lifecycle';
  static const String playStart       = 'play_start';
  static const String playResolved    = 'play_resolved';
  static const String playSourceFail  = 'play_source_fail';
  static const String playLoaded      = 'play_loaded';
  static const String playError       = 'play_error';
  static const String streamCacheHit  = 'stream_cache_hit';
  static const String ytdlpExtract    = 'ytdlp_extract';
  static const String ytdlpRace       = 'ytdlp_race';
  static const String ytdlpRuntime    = 'ytdlp_runtime';
  static const String searchStart     = 'search_start';
  static const String searchResult    = 'search_result';
  static const String searchError     = 'search_error';
  static const String audioFocus      = 'audio_focus';
  static const String autoRecovery    = 'auto_recovery';
  static const String downloadStart   = 'download_start';
  static const String downloadHttpPath = 'download_http_path';
  static const String downloadYtdlp   = 'download_ytdlp';
  static const String downloadComplete = 'download_complete';
  static const String downloadError   = 'download_error';
  static const String downloadRetry   = 'download_retry';
  static const String downloadResumed = 'download_resumed';
  static const String sharedLink      = 'shared_link';
  static const String prefetch        = 'prefetch';
}
