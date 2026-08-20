import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:extractor/extractor.dart';
import '../providers/settings_provider.dart' show AudioQuality;
import 'youtube_service.dart';
import 'ytdlp_runtime.dart';

/// Explicit chunk lifecycle state for streaming tracks.
enum ChunkLifecycleState {
  notRequested,
  loading,
  ready,      // Playable chunk available (>= 64 KB) -> immediate audio start
  completed,  // 100% downloaded and saved to permanent cache
  cancelled,  // Cancelled upon song switch
  error,      // Encountered terminal error
}

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

  final Map<String, ChunkLifecycleState> _chunkStates = {};
  final Set<String> _cancelledIds = {};
  static final ValueNotifier<Map<String, ChunkLifecycleState>> chunkStateNotifier = ValueNotifier({});

  /// Get the current chunk lifecycle state for [videoId].
  ChunkLifecycleState getChunkState(String videoId) {
    return _chunkStates[videoId] ?? ChunkLifecycleState.notRequested;
  }

  void _setChunkState(String videoId, ChunkLifecycleState state) {
    _chunkStates[videoId] = state;
    chunkStateNotifier.value = Map.from(chunkStateNotifier.value)..[videoId] = state;
  }

  /// Explicitly cancel and dispose in-progress chunk download for [videoId].
  /// Called immediately when the user switches away from this song or skips tracks.
  Future<void> cancelAndDispose(String videoId) async {
    debugPrint('[StreamCache] Cancelling and disposing chunk load for $videoId');
    _cancelledIds.add(videoId);
    _setChunkState(videoId, ChunkLifecycleState.cancelled);

    _inFlightDownloads.remove(videoId);
    _inFlightPlayableListeners.remove(videoId);
    _inFlightPlayablePath.remove(videoId);

    // Cancel yt-dlp native process
    try {
      await YoutubeDLFlutter.instance.cancelDownload('stream_$videoId');
    } catch (_) {}

    // Clean up temporary staging directory if download was not completed
    try {
      final tempDir = await getTemporaryDirectory();
      final stagingPath = '${tempDir.path}${Platform.pathSeparator}stream_dl_$videoId';
      final stagingDirObj = Directory(stagingPath);
      if (await stagingDirObj.exists()) {
        await stagingDirObj.delete(recursive: true);
      }
    } catch (_) {}
  }

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

  /// Minimum bytes before we consider a partially-downloaded file playable.
  /// ExoPlayer only needs ~64 KB of audio header + initial stream data to start
  /// decoding and playing while yt-dlp continues downloading in the background.
  static const int _playableThreshold = 64 * 1024; // 64 KB

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

  final Map<String, Future<String>> _inFlightDownloads = {};
  final Map<String, List<ValueChanged<String>>> _inFlightPlayableListeners = {};
  final Map<String, String?> _inFlightPlayablePath = {};
  static final ValueNotifier<Map<String, double>> bufferProgressNotifier = ValueNotifier({});
  static const int _maxConcurrentCacheDownloads = 2;
  int _activeDownloadCount = 0;
  final List<Completer<void>> _waitingQueue = [];
  String? _activePlayingVideoId;

  /// Set the currently active playing song to prioritize its cache download.
  void setActivePlayingSong(String? videoId) {
    _activePlayingVideoId = videoId;
  }

  /// Clean up old or orphaned staging directories from previous runs.
  static Future<void> cleanupStagingDirs() async {
    try {
      final tempDir = await getTemporaryDirectory();
      if (!await tempDir.exists()) return;
      await for (final entity in tempDir.list(followLinks: false)) {
        if (entity is Directory && entity.path.contains('stream_dl_')) {
          try {
            await entity.delete(recursive: true);
          } catch (_) {}
        }
      }
    } catch (_) {}
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
    // If this videoId was previously marked cancelled, reset it since a fresh request came in
    _cancelledIds.remove(videoId);

    // 1. Check if already cached
    final qualityName = quality.name;
    final cachedPath = await getCachedFile(videoId, qualityName);
    if (cachedPath != null) {
      debugPrint('[StreamCache] Cache hit for $videoId — skipping download');
      _setChunkState(videoId, ChunkLifecycleState.completed);
      bufferProgressNotifier.value = Map.from(bufferProgressNotifier.value)..[videoId] = 1.0;
      onPlayable?.call(cachedPath);
      return cachedPath;
    }

    _setChunkState(videoId, ChunkLifecycleState.loading);

    // 1b. If already downloading in-flight, join the existing task to prevent race collisions
    final inFlight = _inFlightDownloads[videoId];
    if (inFlight != null) {
      debugPrint('[StreamCache] In-flight cache download already active for $videoId — joining');
      if (onPlayable != null) {
        final existingPlayable = _inFlightPlayablePath[videoId];
        if (existingPlayable != null) {
          onPlayable(existingPlayable);
        } else {
          _inFlightPlayableListeners.putIfAbsent(videoId, () => []).add(onPlayable);
        }
      }
      return inFlight;
    }

    final future = _executeDownloadToCache(
      videoId: videoId,
      quality: quality,
      onPlayable: onPlayable,
      onProgress: onProgress,
    );
    _inFlightDownloads[videoId] = future;
    try {
      return await future;
    } finally {
      _inFlightDownloads.remove(videoId);
      _inFlightPlayableListeners.remove(videoId);
      _inFlightPlayablePath.remove(videoId);
    }
  }

  Future<String> _executeDownloadToCache({
    required String videoId,
    required AudioQuality quality,
    ValueChanged<String>? onPlayable,
    ValueChanged<double>? onProgress,
  }) async {
    // Concurrency throttle: Non-active background songs wait if pool is full
    while (_activeDownloadCount >= _maxConcurrentCacheDownloads && _activePlayingVideoId != videoId) {
      final completer = Completer<void>();
      _waitingQueue.add(completer);
      await completer.future;
    }
    _activeDownloadCount++;

    try {
      return await _performDownload(
        videoId: videoId,
        quality: quality,
        onPlayable: onPlayable,
        onProgress: onProgress,
      );
    } finally {
      _activeDownloadCount = (_activeDownloadCount - 1).clamp(0, 999);
      if (_waitingQueue.isNotEmpty) {
        _waitingQueue.removeAt(0).complete();
      }
    }
  }

  Future<String> _performDownload({
    required String videoId,
    required AudioQuality quality,
    ValueChanged<String>? onPlayable,
    ValueChanged<double>? onProgress,
  }) async {
    final qualityName = quality.name;

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
    progressSub = YoutubeDLFlutter.instance.onProgress.listen((event) {
      if (event.processId != processId) return;
      if (_cancelledIds.contains(videoId)) return; // Discard late event for cancelled song
      final fraction = event.progress < 0 ? 0.05 : event.progressFraction.clamp(0.0, 1.0);
      bufferProgressNotifier.value = Map.from(bufferProgressNotifier.value)..[videoId] = fraction;
      onProgress?.call(fraction);
    });

    void notifyPlayable(String path) {
      if (_cancelledIds.contains(videoId)) return; // Discard if cancelled
      _setChunkState(videoId, ChunkLifecycleState.ready);
      _inFlightPlayablePath[videoId] = path;
      onPlayable?.call(path);
      final listeners = _inFlightPlayableListeners[videoId];
      if (listeners != null) {
        for (final listener in List<ValueChanged<String>>.from(listeners)) {
          try {
            listener(path);
          } catch (_) {}
        }
        listeners.clear();
      }
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
          // Fast client extraction chain (android, ios, web):
          '--extractor-args':
              'youtube:player_client=android,ios,web;skip=hls,dash,translated_subs,webpage',
          // Write directly to output file, not .part → enables progressive monitoring
          '--no-part': '',
          // Skip unnecessary side-files
          '--no-write-info-json': '',
          '--no-write-thumbnail': '',
          // Buffer size for download speed
          '--buffer-size': '256k',
        },
      );

      // Start a fast timer to monitor staging directory for file growth.
      // With --no-part, yt-dlp writes directly to the output file, so we can
      // detect playability progressively in ~500-1000ms.
      monitorTimer = Timer.periodic(const Duration(milliseconds: 100), (_) async {
        if (playableFired || _cancelledIds.contains(videoId)) return;
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
                debugPrint('[StreamCache] File playable at ${len ~/ 1024}KB: ${entity.path}');
                notifyPlayable(entity.path);
                break;
              }
            }
          }
        } catch (_) {}
      });

      final result = await YoutubeDLFlutter.instance.download(request);

      monitorTimer.cancel();
      monitorTimer = null;

      if (_cancelledIds.contains(videoId)) {
        debugPrint('[StreamCache] Download finished for cancelled $videoId — discarding');
        try {
          await stagingDirObj.delete(recursive: true);
        } catch (_) {}
        throw Exception('Download cancelled for $videoId');
      }

      if (result.status != OperationStatus.success) {
        throw Exception(result.errorMessage ?? 'yt-dlp stream cache download failed');
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

      debugPrint('[StreamCache] Cached $videoId: ${fileSize ~/ 1024}KB → ${cacheFile.path}');

      // Fire playable if we didn't during download (small files)
      if (!playableFired) {
        notifyPlayable(cacheFile.path);
      }

      // Clean up staging directory only if this is NOT currently being played
      if (_activePlayingVideoId != videoId) {
        try {
          await stagingDirObj.delete(recursive: true);
        } catch (_) {}
      }

      _setChunkState(videoId, ChunkLifecycleState.completed);
      bufferProgressNotifier.value = Map.from(bufferProgressNotifier.value)..[videoId] = 1.0;
      YtDlpRuntime.markHealthy();
      return cacheFile.path;
    } catch (e) {
      monitorTimer?.cancel();
      if (_cancelledIds.contains(videoId)) {
        debugPrint('[StreamCache] Discarding error for cancelled song $videoId');
        try {
          await stagingDirObj.delete(recursive: true);
        } catch (_) {}
        return '';
      }

      _setChunkState(videoId, ChunkLifecycleState.error);
      debugPrint('[StreamCache] Cache download failed for $videoId: $e');

      // Preserve partial staged file if it already contains playable audio (> 64KB)
      bool hasPlayableStagedFile = false;
      try {
        final entities = await stagingDirObj.list().toList();
        for (final entity in entities) {
          if (entity is File && entity.path.contains(videoId)) {
            final len = await entity.length();
            if (len >= _playableThreshold) {
              hasPlayableStagedFile = true;
              debugPrint('[StreamCache] Preserving partial stream download (${len ~/ 1024}KB) for $videoId: ${entity.path}');
              notifyPlayable(entity.path);
              break;
            }
          }
        }
      } catch (_) {}

      // Only clean up staging if no playable data exists and song is not active
      if (!hasPlayableStagedFile && _activePlayingVideoId != videoId) {
        try {
          await stagingDirObj.delete(recursive: true);
        } catch (_) {}
      }
      rethrow;
    } finally {
      await progressSub.cancel();
    }
  }
}

class _CacheEntry {
  final File file;
  final int size;
  final DateTime modified;
  const _CacheEntry(this.file, this.size, this.modified);
}
