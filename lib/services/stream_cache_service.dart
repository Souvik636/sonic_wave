import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:extractor/extractor.dart';
import '../providers/settings_provider.dart' show AudioQuality;
import 'youtube_service.dart';
import 'ytdlp_runtime.dart';

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

  static const String _prefKey = 'stream_cache_max_mb';

  /// Default ceiling on the cache (512 MB). Roughly 100–150 songs at typical
  /// streamed bitrates — enough to cover the tracks someone actually replays,
  /// small enough to be an unremarkable line in the app's storage figure.
  static const int defaultMaxMB = 512;

  /// Available options the user can pick from.
  static const List<int> limitOptionsMB = [128, 256, 512, 1024];

  /// Active ceiling in bytes. Updated by [setMaxMB].
  int _maxBytes = defaultMaxMB * 1024 * 1024;
  int get maxBytes => _maxBytes;

  /// Current limit in MB (for UI display).
  int get maxMB => _maxBytes ~/ (1024 * 1024);

  /// Load the persisted limit. Call once at app start.
  Future<void> initialize() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final mb = prefs.getInt(_prefKey) ?? defaultMaxMB;
      _maxBytes = mb * 1024 * 1024;
    } catch (_) {}
  }

  /// Update the ceiling and persist it. Triggers a trim if needed.
  Future<void> setMaxMB(int mb) async {
    _maxBytes = mb * 1024 * 1024;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setInt(_prefKey, mb);
    } catch (_) {}
    unawaited(trim());
  }

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
    return File(
      '${dir.path}${Platform.pathSeparator}'
      '${_safeKey(songId)}@$quality.audio',
    );
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
      if (total <= _maxBytes) return;

      entries.sort((a, b) => a.modified.compareTo(b.modified));
      for (final entry in entries) {
        if (total <= _maxBytes) break;
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

  /// Minimum bytes before we consider a partially-downloaded file playable.
  /// ExoPlayer needs a few hundred KB of AAC/Opus header + audio data before it
  /// can initialize the codec and start outputting audio.
  static const int _playableThreshold = 256 * 1024; // 256 KB

  /// Check if a playable cache file exists for [songId] at [quality].
  Future<bool> hasCache(String songId, String quality) async {
    try {
      final file = await fileFor(songId, quality);
      if (await file.exists()) {
        final len = await file.length();
        return len > 1024; // Needs to be a real file, not an empty stub
      }
    } catch (_) {}
    return false;
  }

  /// Get the cached file path if it exists and is playable, else null.
  Future<String?> getCachedFile(String songId, String quality) async {
    try {
      final file = await fileFor(songId, quality);
      if (await file.exists() && (await file.length()) > 1024) {
        return file.path;
      }
    } catch (_) {}
    return null;
  }

  /// Download YouTube audio via yt-dlp native binary directly to the stream
  /// cache, bypassing the problematic ExoPlayer-direct-URL path.
  ///
  /// yt-dlp handles its own HTTP session context (User-Agent, cookies, PO
  /// tokens, client signatures) — which is exactly why downloads always succeed
  /// while ExoPlayer streaming fails. This method reuses that same mechanism
  /// for streaming playback: download to cache file, play from cache file.
  ///
  /// [onPlayable] fires once the file has grown past [_playableThreshold] bytes,
  /// giving the caller a path it can begin `AudioSource.file()` playback from
  /// while the download continues in the background.
  ///
  /// Returns the path to the completed cache file.
  ///
  /// **Performance-critical design choices:**
  /// - NO `extractAudio`/`audioFormat`: these force FFmpeg remux AFTER download,
  ///   meaning the playable file doesn't exist until download+remux both complete.
  ///   ExoPlayer natively decodes Opus/WebM and AAC/M4A, so raw stream bytes are fine.
  /// - `--no-part`: writes directly to the output file (no `.part` → rename dance),
  ///   enabling progressive file monitoring for early playback.
  /// - Single `ios` client: fastest unthrottled YouTube client. Multiple clients
  ///   add extraction round-trips that delay first bytes.
  Future<String> downloadToCache({
    required String videoId,
    required AudioQuality quality,
    ValueChanged<String>? onPlayable,
    ValueChanged<double>? onProgress,
  }) async {
    // 1. Check if already cached
    final qualityName = quality.name;
    final cachedPath = await getCachedFile(videoId, qualityName);
    if (cachedPath != null) {
      debugPrint('[StreamCache] Cache hit for $videoId — skipping download');
      onPlayable?.call(cachedPath);
      return cachedPath;
    }

    // 2. Ensure yt-dlp runtime is ready
    if (!YtDlpRuntime.isReady) {
      final ok = await YtDlpRuntime.ensureInitialized().timeout(
        const Duration(seconds: 5),
        onTimeout: () => false,
      );
      if (!ok && !YtDlpRuntime.isReady) {
        throw Exception('yt-dlp runtime unavailable for stream cache download');
      }
    }

    // 3. Set up staging directory and target cache file
    final cacheFile = await fileFor(videoId, qualityName);
    final stagingDir = await getTemporaryDirectory();
    final stagingPath =
        '${stagingDir.path}${Platform.pathSeparator}stream_dl_$videoId';
    final stagingDirObj = Directory(stagingPath);
    if (await stagingDirObj.exists()) {
      await stagingDirObj.delete(recursive: true);
    }
    await stagingDirObj.create(recursive: true);

    // 4. Monitor file growth and fire onPlayable when buffered enough
    bool playableFired = false;
    Timer? monitorTimer;
    final processId = 'stream_$videoId';

    // Listen for yt-dlp progress updates
    StreamSubscription<DownloadProgress>? progressSub;
    if (onProgress != null || onPlayable != null) {
      progressSub = YoutubeDLFlutter.instance.onProgress.listen((event) {
        if (event.processId != processId) return;
        if (event.progress < 0) {
          onProgress?.call(0.05);
        } else {
          final fraction = event.progressFraction.clamp(0.0, 1.0);
          onProgress?.call(fraction);
        }
      });
    }

    try {
      debugPrint('[StreamCache] Starting yt-dlp cache download for $videoId');

      // KEY: No extractAudio, no audioFormat → yt-dlp writes raw audio bytes
      // directly without FFmpeg remux. ExoPlayer decodes Opus/WebM and AAC/M4A
      // natively, so the container doesn't matter for streaming.
      final request = DownloadRequest(
        url: 'https://www.youtube.com/watch?v=$videoId',
        outputPath: stagingPath,
        outputTemplate: '$videoId.%(ext)s',
        processId: processId,
        noPlaylist: true,
        // NO extractAudio — skip FFmpeg remux entirely for instant playability
        extractAudio: false,
        embedThumbnail: false,
        embedMetadata: false,
        format: YouTubeService.ytDlpStreamFormatChain(quality),
        customOptions: {
          '--no-update': '',
          '--force-ipv4': '',
          '--no-check-certificates': '',
          '--socket-timeout': '6',
          '-R': '2',
          '-S': YouTubeService.ytDlpAudioSorter(quality),
          // Start with ios (fastest unthrottled client), with fallbacks for resilience:
          '--extractor-args':
              'youtube:player_client=ios,tv,mweb,android,web;skip=hls,dash,translated_subs,webpage',
          // Write directly to output file, not .part → enables progressive monitoring
          '--no-part': '',
          // Skip unnecessary side-files
          '--no-write-info-json': '',
          '--no-write-thumbnail': '',
          // Buffer size for download speed
          '--buffer-size': '256k',
        },
      );

      // Start a timer to monitor staging directory for file growth.
      // With --no-part, yt-dlp writes directly to the output file, so we can
      // detect playability progressively even during download.
      monitorTimer = Timer.periodic(const Duration(milliseconds: 400), (
        _,
      ) async {
        if (playableFired) return;
        try {
          final entities = await stagingDirObj.list().toList();
          for (final entity in entities) {
            if (entity is File &&
                entity.path.contains(videoId) &&
                !entity.path.endsWith('.ytdl') &&
                !entity.path.endsWith('.json')) {
              final len = await entity.length();
              if (len >= _playableThreshold) {
                playableFired = true;
                debugPrint(
                  '[StreamCache] File playable at ${len ~/ 1024}KB: ${entity.path}',
                );
                onPlayable?.call(entity.path);
                break;
              }
            }
          }
        } catch (_) {}
      });

      final result = await YoutubeDLFlutter.instance.download(request);

      monitorTimer.cancel();
      monitorTimer = null;

      if (result.status != OperationStatus.success) {
        throw Exception(
          result.errorMessage ?? 'yt-dlp stream cache download failed',
        );
      }

      // 5. Find the produced file and move to cache
      String? producedPath;
      try {
        final entities = await stagingDirObj.list().toList();
        for (final entity in entities) {
          if (entity is File &&
              entity.path.contains(videoId) &&
              !entity.path.endsWith('.ytdl') &&
              !entity.path.endsWith('.json')) {
            producedPath = entity.path;
            break;
          }
        }
      } catch (_) {}

      if (producedPath == null) {
        throw Exception('yt-dlp cache download produced no audio file');
      }

      // Move to the stream cache location
      final produced = File(producedPath);
      if (await cacheFile.exists()) {
        await cacheFile.delete();
      }
      await produced.copy(cacheFile.path);

      final fileSize = await cacheFile.length();
      noteWrite(fileSize);

      debugPrint(
        '[StreamCache] Cached $videoId: ${fileSize ~/ 1024}KB → ${cacheFile.path}',
      );

      // Fire playable if we didn't during download (small files)
      if (!playableFired) {
        onPlayable?.call(cacheFile.path);
      }

      // Clean up staging
      try {
        await stagingDirObj.delete(recursive: true);
      } catch (_) {}

      YtDlpRuntime.markHealthy();
      return cacheFile.path;
    } catch (e) {
      monitorTimer?.cancel();
      debugPrint('[StreamCache] Cache download failed for $videoId: $e');
      // Clean up on failure
      try {
        await stagingDirObj.delete(recursive: true);
      } catch (_) {}
      rethrow;
    } finally {
      await progressSub?.cancel();
    }
  }
}

class _CacheEntry {
  final File file;
  final int size;
  final DateTime modified;
  const _CacheEntry(this.file, this.size, this.modified);
}
