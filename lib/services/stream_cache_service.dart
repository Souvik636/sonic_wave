import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

/// On-disk cache for audio that has been streamed.
///
/// just_audio's [LockCachingAudioSource] writes every byte it plays to a file
/// and serves later plays from it, which is what turns replaying a song from
/// "download it again" into "read it off flash". Two things it does NOT do are
/// handled here.
///
/// **Naming.** Its default cache file is `sha256(url)`, and a YouTube stream URL
/// is freshly signed on every resolution — same audio, different URL, different
/// hash, so the default would never register a single hit for the one source
/// this app streams most. [fileFor] keys on the stable videoId instead.
///
/// **Bounding.** It also never deletes anything, and a music app left running
/// would quietly fill the device. [trim] enforces a byte ceiling by evicting
/// least-recently-used entries.
class StreamCacheService {
  static final StreamCacheService _instance = StreamCacheService._internal();
  factory StreamCacheService() => _instance;
  StreamCacheService._internal();

  /// Ceiling on the cache. Roughly 100–150 songs at typical streamed bitrates —
  /// enough to cover the tracks someone actually replays, small enough to be an
  /// unremarkable line in the app's storage figure.
  static const int maxBytes = 512 * 1024 * 1024;

  /// Only trim once this much has been written since the last sweep. Listing
  /// and stat-ing the directory on every song would be pointless work for a
  /// cache that moves a few megabytes at a time.
  static const int _trimInterval = 32 * 1024 * 1024;

  Directory? _dir;
  int _writtenSinceTrim = 0;
  Future<void>? _trimInFlight;

  /// Cache lives in the app's *cache* directory, not its documents directory:
  /// this is regenerable data, and Android is entitled to reclaim it under
  /// storage pressure rather than reporting the app as a space hog.
  Future<Directory> _cacheDir() async {
    final existing = _dir;
    if (existing != null) return existing;
    final base = await getTemporaryDirectory();
    final dir = Directory('${base.path}${Platform.pathSeparator}stream_cache');
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    _dir = dir;
    return dir;
  }

  /// Characters that are safe in a filename on every platform this ships to.
  /// Source ids are alphanumeric plus `-_`, but ids from other providers carry
  /// a `provider_` prefix and are not guaranteed to be, so this is not
  /// theoretical.
  static String _safeKey(String id) =>
      id.replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '_');

  /// Cache file for [songId] at [quality].
  ///
  /// Quality is in the name because the streams differ: without it, switching
  /// to High would keep replaying the Low copy that happened to be cached, and
  /// the setting would look broken.
  Future<File> fileFor(String songId, String quality) async {
    final dir = await _cacheDir();
    return File('${dir.path}${Platform.pathSeparator}'
        '${_safeKey(songId)}@$quality.audio');
  }

  /// Note that roughly [bytes] were just written, and sweep if enough has
  /// accumulated. Cheap to call after every song.
  void noteWrite(int bytes) {
    if (bytes <= 0) return;
    _writtenSinceTrim += bytes;
    if (_writtenSinceTrim >= _trimInterval) {
      _writtenSinceTrim = 0;
      unawaited(trim());
    }
  }

  /// Evict least-recently-used entries until the cache is under [maxBytes].
  ///
  /// LRU by mtime rather than atime: Android mounts userdata with `noatime`, so
  /// access times do not advance and would rank every entry by when it was
  /// first written. mtime is the honest signal available.
  Future<void> trim() async {
    // A second caller joins the sweep already running instead of racing it into
    // deleting files the first one is mid-stat on.
    final running = _trimInFlight;
    if (running != null) return running;
    final task = _trim();
    _trimInFlight = task;
    try {
      await task;
    } finally {
      _trimInFlight = null;
    }
  }

  Future<void> _trim() async {
    try {
      final dir = await _cacheDir();
      if (!await dir.exists()) return;

      final entries = <_CacheEntry>[];
      int total = 0;
      await for (final entity in dir.list()) {
        if (entity is! File) continue;
        try {
          final stat = await entity.stat();
          // A `.part`/`.mime` sidecar belongs to whichever entry it is named
          // after; it is counted, but only the audio file drives eviction, and
          // deleting one takes its sidecars with it.
          total += stat.size;
          if (entity.path.endsWith('.audio')) {
            entries.add(_CacheEntry(entity, stat.size, stat.modified));
          }
        } catch (_) {}
      }
      if (total <= maxBytes) return;

      entries.sort((a, b) => a.modified.compareTo(b.modified));
      for (final entry in entries) {
        if (total <= maxBytes) break;
        try {
          await entry.file.delete();
          total -= entry.size;
          for (final suffix in const ['.part', '.mime']) {
            final sidecar = File('${entry.file.path}$suffix');
            if (await sidecar.exists()) {
              total -= (await sidecar.stat()).size;
              await sidecar.delete();
            }
          }
        } catch (_) {}
      }
      debugPrint('[StreamCache] Trimmed to ${total ~/ (1024 * 1024)}MB');
    } catch (e) {
      debugPrint('[StreamCache] Trim failed: $e');
    }
  }

  /// Total bytes currently held, for the storage screen.
  Future<int> size() async {
    try {
      final dir = await _cacheDir();
      if (!await dir.exists()) return 0;
      int total = 0;
      await for (final entity in dir.list()) {
        if (entity is File) {
          try {
            total += await entity.length();
          } catch (_) {}
        }
      }
      return total;
    } catch (_) {
      return 0;
    }
  }

  /// Drop everything. Used by "clear cache" in Settings.
  Future<void> clear() async {
    try {
      final dir = await _cacheDir();
      if (await dir.exists()) {
        await dir.delete(recursive: true);
      }
      _dir = null;
      _writtenSinceTrim = 0;
    } catch (e) {
      debugPrint('[StreamCache] Clear failed: $e');
    }
  }
}

class _CacheEntry {
  final File file;
  final int size;
  final DateTime modified;
  const _CacheEntry(this.file, this.size, this.modified);
}
