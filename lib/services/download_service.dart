import 'dart:convert';
import 'dart:io';
import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:youtube_explode_dart/youtube_explode_dart.dart';
import '../models/song.dart';
import '../providers/settings_provider.dart';
import 'diagnostic_log_service.dart';
import 'local_metadata_service.dart';
import 'storage_location_service.dart';
import 'stream_resolver_service.dart';
import 'id3_tag_writer.dart';
import 'mediastore_scanner.dart';
import 'ytdlp_downloader.dart';

/// Status for individual download tasks
enum DownloadStatus {
  queued,
  downloading,
  paused,
  completed,
  failed,
  cancelled,
  retrying,
}

/// Represents a group of duplicate audio files found on storage
class DuplicateAudioGroup {
  final String songTitle;
  final String artist;
  final List<File> candidateFiles;

  DuplicateAudioGroup({
    required this.songTitle,
    required this.artist,
    required this.candidateFiles,
  });

  int get totalRedundantBytes {
    if (candidateFiles.length <= 1) return 0;
    int redundant = 0;
    for (int i = 1; i < candidateFiles.length; i++) {
      try {
        if (candidateFiles[i].existsSync()) {
          redundant += candidateFiles[i].lengthSync();
        }
      } catch (_) {}
    }
    return redundant;
  }

  String get formattedRedundantSize {
    final bytes = totalRedundantBytes;
    if (bytes == 0) return '0 B';
    final mb = bytes / (1024 * 1024);
    if (mb >= 1024) {
      return '${(mb / 1024).toStringAsFixed(1)} GB';
    }
    return '${mb.toStringAsFixed(1)} MB';
  }
}

/// Structured outcome of a storage diagnostic & repair pipeline run
class StorageRepairResult {
  final int repairedContainers;
  final int recoveredUnindexedSongs;
  final int prunedGhosts;
  final int cleanedTempFiles;
  final int repairedCovers;
  final List<DuplicateAudioGroup> duplicatesFound;

  const StorageRepairResult({
    this.repairedContainers = 0,
    this.recoveredUnindexedSongs = 0,
    this.prunedGhosts = 0,
    this.cleanedTempFiles = 0,
    this.repairedCovers = 0,
    this.duplicatesFound = const [],
  });

  int get totalFixed =>
      repairedContainers +
      recoveredUnindexedSongs +
      prunedGhosts +
      cleanedTempFiles +
      repairedCovers;
}

/// Rich download item model exposed to UI
class DownloadItem {
  final Song song;
  DownloadStatus status;
  double progress;
  double speedBytesPerSec;
  Duration? eta;
  int bytesDownloaded;
  int totalBytes;
  String? errorMessage;
  int retryCount;

  DownloadItem({
    required this.song,
    this.status = DownloadStatus.queued,
    this.progress = 0.0,
    this.speedBytesPerSec = 0.0,
    this.eta,
    this.bytesDownloaded = 0,
    this.totalBytes = 0,
    this.errorMessage,
    this.retryCount = 0,
  });

  String get formattedSpeed {
    if (speedBytesPerSec <= 0) return '';
    if (speedBytesPerSec >= 1024 * 1024) {
      return '${(speedBytesPerSec / (1024 * 1024)).toStringAsFixed(1)} MB/s';
    } else if (speedBytesPerSec >= 1024) {
      return '${(speedBytesPerSec / 1024).toStringAsFixed(0)} KB/s';
    }
    return '${speedBytesPerSec.toStringAsFixed(0)} B/s';
  }

  String get formattedEta {
    if (eta == null || eta!.inSeconds <= 0) return '';
    if (eta!.inHours >= 1) {
      return '~${eta!.inHours}h ${eta!.inMinutes % 60}m left';
    }
    if (eta!.inMinutes >= 1) {
      return '~${eta!.inMinutes}m ${eta!.inSeconds % 60}s left';
    }
    return '~${eta!.inSeconds}s left';
  }

  String get formattedBytesDownloaded => formatFileSize(bytesDownloaded);
  String get formattedTotalBytes => formatFileSize(totalBytes);

  String get formattedSizeProgress {
    if (totalBytes <= 0) return '';
    return '$formattedBytesDownloaded / $formattedTotalBytes';
  }

  static String formatFileSize(int bytes) {
    if (bytes >= 1024 * 1024 * 1024) {
      return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(1)} GB';
    } else if (bytes >= 1024 * 1024) {
      return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
    } else if (bytes >= 1024) {
      return '${(bytes / 1024).toStringAsFixed(0)} KB';
    }
    return '$bytes B';
  }
}

class DownloadTask {
  final Song song;
  final File audioFile;
  final File thumbFile;
  final VoidCallback? onStateChanged;

  double progress = 0.0;
  bool isPaused = false;
  bool isCancelled = false;
  DownloadStatus status = DownloadStatus.queued;
  String? errorMessage;
  int retryCount = 0;

  /// True when the transfer is driven by the native yt-dlp binary rather than
  /// this class's own HttpClient. Native downloads cannot be paused/resumed —
  /// only cancelled — so the UI should not offer a pause control for them.
  bool isNative = false;

  StreamSubscription<List<int>>? _subscription;
  IOSink? _output;
  HttpClient? _httpClient;
  int bytesDownloaded = 0;
  int totalSize = 0;

  // Speed tracking
  double speedBytesPerSec = 0.0;
  Duration? eta;
  int _lastSpeedBytes = 0;
  Timer? _speedTimer;

  DownloadTask({
    required this.song,
    required this.audioFile,
    required this.thumbFile,
    this.onStateChanged,
  });

  /// Where the bytes actually land while the transfer is running.
  ///
  /// Nothing is written straight into the final name any more. A `.part` file
  /// keeps the target name free, so a retry resolves to the SAME name instead
  /// of sliding to `Title (2).m4a` because attempt one's stub made `Title.m4a`
  /// look taken; it keeps an unfinished transfer out of the user's file manager
  /// and out of every other music app's library; and it is what makes resuming
  /// possible at all, since the partial survives a failure under a name the
  /// next attempt knows how to find.
  ///
  /// `.part` is deliberately not in [DownloadService._knownAudioExts], so the
  /// name-clash check never sees it.
  File get partFile => File('${audioFile.path}.part');

  /// Identity of the byte stream behind [url], for deciding whether a partial
  /// file may be appended to.
  ///
  /// The URL itself says nothing useful: resolved links are single-use and
  /// time-limited, so the signature and expiry parameters differ on every
  /// resolution even for the identical stream. What does identify the bytes is
  /// the format — YouTube puts it in `itag`, and everything else is pinned
  /// well enough by host + path.
  static String formatKeyOf(Uri url) {
    final itag = url.queryParameters['itag'];
    if (itag != null && itag.isNotEmpty) return 'itag:$itag';
    return '${url.host}${url.path}';
  }

  /// Total size out of a `Content-Range: bytes 500-1023/1024` header.
  static int? _totalFromContentRange(String? header) {
    if (header == null) return null;
    final slash = header.lastIndexOf('/');
    if (slash < 0) return null;
    return int.tryParse(header.substring(slash + 1).trim());
  }

  /// Promote a finished `.part` file to its final name.
  Future<void> _promotePartFile() async {
    final part = partFile;
    if (!await part.exists()) return;
    if (await audioFile.exists()) {
      try {
        await audioFile.delete();
      } catch (_) {}
    }
    try {
      await part.rename(audioFile.path);
    } on FileSystemException {
      // Rename is only atomic within one filesystem; a staging dir and a target
      // on different volumes (SD card) need a copy.
      await part.copy(audioFile.path);
      try {
        await part.delete();
      } catch (_) {}
    }
  }

  void _startSpeedTracking() {
    _lastSpeedBytes = bytesDownloaded;
    _speedTimer?.cancel();
    _speedTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (isPaused || isCancelled) {
        speedBytesPerSec = 0;
        eta = null;
        return;
      }
      final delta = bytesDownloaded - _lastSpeedBytes;
      _lastSpeedBytes = bytesDownloaded;

      // Exponential moving average keeps the displayed speed and ETA stable
      // instead of jumping with every 1s network burst.
      if (speedBytesPerSec <= 0) {
        speedBytesPerSec = delta.toDouble();
      } else {
        speedBytesPerSec = speedBytesPerSec * 0.7 + delta * 0.3;
      }

      if (speedBytesPerSec > 0 && totalSize > 0) {
        final remaining = totalSize - bytesDownloaded;
        eta = Duration(seconds: (remaining / speedBytesPerSec).round());
      } else {
        eta = null;
      }
      if (onStateChanged != null) onStateChanged!();
    });
  }

  void _stopSpeedTracking() {
    _speedTimer?.cancel();
    speedBytesPerSec = 0;
    eta = null;
  }

  /// Run the transfer, writing into [partFile] and promoting it to [audioFile]
  /// once every byte has arrived.
  ///
  /// With [allowResume], an existing `.part` is continued via an HTTP `Range`
  /// request instead of thrown away. A dropped connection on a phone is
  /// ordinary, and restarting a 4-minute song from zero every time turned a
  /// blip into a total loss — resuming turns "failed at 80%" into a delay.
  /// The caller is responsible for only setting it when the partial provably
  /// came from the same rendition (see [DownloadService._resumeHints]);
  /// everything below is the second line of defence against appending one
  /// encoding onto another.
  Future<void> start(
    Uri streamUrl,
    int size, {
    Map<String, String>? headers,
    bool allowResume = false,
  }) async {
    totalSize = size;
    status = DownloadStatus.downloading;
    if (onStateChanged != null) onStateChanged!();

    final part = partFile;
    int resumeFrom = 0;
    try {
      if (await part.exists()) {
        if (allowResume) {
          final onDisk = await part.length();
          if (onDisk > 0) resumeFrom = onDisk;
        } else {
          // Not resumable — a leftover from a different rendition or a cold
          // start with nothing to validate against. Drop it rather than guess.
          await part.delete();
        }
      }
    } catch (_) {}

    Future<HttpClientResponse> open(int from) async {
      _httpClient?.close();
      _httpClient = HttpClient()
        ..connectionTimeout = const Duration(seconds: 8)
        ..idleTimeout = const Duration(seconds: 15);
      final request = await _httpClient!.getUrl(streamUrl);
      request.headers.set('User-Agent', 'Mozilla/5.0 (Linux; Android 10; Mobile) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Mobile Safari/537.36');
      if (headers != null) {
        headers.forEach((k, v) => request.headers.set(k, v));
      }
      if (from > 0) {
        request.headers.set(HttpHeaders.rangeHeader, 'bytes=$from-');
      }
      return request.close();
    }

    var response = await open(resumeFrom);
    bool appending = false;

    if (resumeFrom > 0) {
      if (response.statusCode == HttpStatus.partialContent) {
        final total =
            _totalFromContentRange(response.headers.value(HttpHeaders.contentRangeHeader));
        if (totalSize > 0 && total != null && total != totalSize) {
          // The server is handing back a different rendition than the one that
          // produced the partial. Appending would splice two encodings into a
          // single file, which decodes as noise — start over instead.
          debugPrint('[DownloadTask] Resume rejected for ${song.title}: '
              'server reports $total bytes, partial belongs to $totalSize');
          await response.drain();
          resumeFrom = 0;
          totalSize = 0;
          response = await open(0);
        } else {
          appending = true;
          if (total != null && total > 0) {
            totalSize = total;
          } else if (totalSize <= 0 && response.contentLength > 0) {
            totalSize = resumeFrom + response.contentLength;
          }
        }
      } else if (response.statusCode == HttpStatus.requestedRangeNotSatisfiable) {
        // Everything the server has is already on disk.
        await response.drain();
        _httpClient?.close();
        bytesDownloaded = resumeFrom;
        if (totalSize <= 0) totalSize = resumeFrom;
        await _promotePartFile();
        progress = 1.0;
        status = DownloadStatus.completed;
        if (onStateChanged != null) onStateChanged!();
        return;
      } else {
        // 200 means the server ignored Range and is sending the whole body from
        // byte 0, so the partial is worthless.
        debugPrint('[DownloadTask] Server ignored Range for ${song.title} '
            '(status ${response.statusCode}) — restarting from 0');
        resumeFrom = 0;
      }
    }

    if (response.statusCode != HttpStatus.ok && response.statusCode != HttpStatus.partialContent) {
      await response.drain();
      _httpClient!.close();
      throw Exception('Server returned status ${response.statusCode}');
    }

    if (appending) {
      bytesDownloaded = resumeFrom;
      debugPrint('[DownloadTask] Resuming ${song.title} at '
          '${DownloadItem.formatFileSize(resumeFrom)} of '
          '${DownloadItem.formatFileSize(totalSize)}');
    } else {
      bytesDownloaded = 0;
      // On a full response the SERVER's length wins over whatever the caller
      // predicted. The size handed in is an estimate from the extractor
      // (Explode's manifest, or a previous attempt's Content-Range) and can
      // legitimately disagree with the rendition actually served — and since
      // the completeness check below compares against totalSize, trusting a
      // stale estimate would reject a download that arrived in full.
      if (response.contentLength > 0) {
        totalSize = response.contentLength;
      } else if (totalSize > 0) {
        // No Content-Length (chunked): there is nothing to verify against, so
        // don't hold the transfer to a number nobody confirmed.
        totalSize = 0;
      }
    }
    if (totalSize > 0) {
      progress = (bytesDownloaded / totalSize).clamp(0.0, 1.0);
    }

    try {
      await part.parent.create(recursive: true);
    } catch (_) {}
    _output = part.openWrite(mode: appending ? FileMode.append : FileMode.write);
    final completer = Completer<void>();

    _startSpeedTracking();
    int lastReportedTime = DateTime.now().millisecondsSinceEpoch;

    _subscription = response.listen(
      (chunk) {
        if (isCancelled) return;
        _output!.add(chunk);
        bytesDownloaded += chunk.length;

        final now = DateTime.now().millisecondsSinceEpoch;
        if (totalSize > 0) {
          progress = (bytesDownloaded / totalSize).clamp(0.0, 1.0);
        } else {
          // Fallback smooth estimation when size header is unprovided
          progress = (progress + 0.01).clamp(0.01, 0.95);
        }

        // Throttle UI rebuild notifications to max once per ~100ms to keep UI 60fps silky smooth
        if (now - lastReportedTime >= 100 || bytesDownloaded == totalSize) {
          lastReportedTime = now;
          if (onStateChanged != null) onStateChanged!();
        }
      },
      onDone: () async {
        _stopSpeedTracking();
        await _output?.close();
        _output = null;
        _httpClient?.close();

        // A stream can end cleanly and still be short: a proxy that drops the
        // connection mid-body closes it without an error, and the old code
        // promoted that truncated file as a finished song. Failing here instead
        // keeps the `.part` around, so the retry continues it rather than
        // leaving the user with a track that cuts off.
        if (totalSize > 0 && bytesDownloaded < totalSize) {
          status = DownloadStatus.failed;
          errorMessage = 'Connection closed after '
              '${DownloadItem.formatFileSize(bytesDownloaded)} of '
              '${DownloadItem.formatFileSize(totalSize)}';
          if (onStateChanged != null) onStateChanged!();
          completer.completeError(Exception(errorMessage));
          return;
        }

        try {
          await _promotePartFile();
        } catch (e) {
          status = DownloadStatus.failed;
          errorMessage = e.toString();
          if (onStateChanged != null) onStateChanged!();
          completer.completeError(e);
          return;
        }
        progress = 1.0;
        status = DownloadStatus.completed;
        if (onStateChanged != null) onStateChanged!();
        completer.complete();
      },
      onError: (e) async {
        _stopSpeedTracking();
        await _output?.close();
        _output = null;
        _httpClient?.close();
        // The `.part` file is deliberately left on disk — it is exactly what
        // the next attempt resumes from.
        status = DownloadStatus.failed;
        errorMessage = e.toString();
        if (onStateChanged != null) onStateChanged!();
        completer.completeError(e);
      },
      cancelOnError: true,
    );

    return completer.future;
  }

  void pause() {
    if (isPaused || isCancelled) return;
    _subscription?.pause();
    isPaused = true;
    status = DownloadStatus.paused;
    _stopSpeedTracking();
    if (onStateChanged != null) onStateChanged!();
  }

  void resume() {
    if (!isPaused || isCancelled) return;
    _subscription?.resume();
    isPaused = false;
    status = DownloadStatus.downloading;
    _startSpeedTracking();
    if (onStateChanged != null) onStateChanged!();
  }

  Future<void> cancel() async {
    isCancelled = true;
    status = DownloadStatus.cancelled;
    _stopSpeedTracking();
    _subscription?.cancel();
    await _output?.close();
    _httpClient?.close();

    // Clean up partial files. Cancelling is an explicit "I don't want this",
    // so unlike a failure the `.part` goes too — there is nothing to resume.
    try {
      if (await partFile.exists()) await partFile.delete();
      if (await audioFile.exists()) await audioFile.delete();
      if (await thumbFile.exists()) await thumbFile.delete();
    } catch (_) {}
    if (onStateChanged != null) onStateChanged!();
  }
}

class DownloadService {
  static final DownloadService _instance = DownloadService._internal();
  factory DownloadService() => _instance;
  DownloadService._internal();

  final List<Song> _downloadedSongs = [];
  bool _isLoaded = false;

  // Track active downloading tasks
  final Map<String, DownloadTask> _activeTasks = {};
  Map<String, DownloadTask> get activeTasks => _activeTasks;

  // Download queue
  final List<_QueuedDownload> _queue = [];
  static const int maxConcurrent = 2;
  int _runningCount = 0;

  // Retry config
  static const int maxRetries = 3;

  /// Per-song record of what the last failed transfer was reading, keyed by
  /// videoId. Present only while a `.part` file is worth continuing.
  ///
  /// Resume is offered ONLY against the same rendition. A retry re-resolves
  /// from the network (deliberately — see [_executeDownload]), and a fresh
  /// resolution can legitimately land on a different format, a different
  /// mirror, or a different bitrate; appending those bytes to the partial
  /// would produce a file that is neither. Held in memory rather than on disk
  /// because a partial from a previous run has no recorded total to validate
  /// against, and silently guessing is how you ship corrupt audio.
  final Map<String, _ResumeHint> _resumeHints = {};

  final StorageLocationService _storageService = StorageLocationService();

  Future<Directory> get _downloadDir async {
    return _storageService.getDownloadDir();
  }

  /// The downloads index, in the hidden meta folder.
  ///
  /// It used to sit in the visible `Download/` folder, where it was one more
  /// piece of app clutter in a directory the user browses. [_migrateHiddenLayout]
  /// moves any pre-existing copy here on first run.
  Future<File> get _metadataFile async {
    final dir = await _storageService.getMetaDir();
    return File('${dir.path}${Platform.pathSeparator}metadata.json');
  }

  /// Where this song's cover image belongs *if one is needed at all*: the
  /// hidden cover folder, never beside the audio. See
  /// [StorageLocationService.coverFolderName].
  ///
  /// A cover only reaches disk when the artwork could NOT be embedded into the
  /// audio container — see [_settleArtwork].
  Future<File> _coverFileFor(String videoId) async =>
      File(await _storageService.coverPathFor(videoId));

  /// Container the downloader aims for.
  ///
  /// M4A because that is what YouTube already serves (AAC), so producing it is
  /// a stream copy rather than a transcode, and because it carries a real
  /// `covr` atom — cover art can be embedded without re-encoding a thing.
  static const String preferredContainer = 'm4a';

  /// Audio extensions a download may end up with, used when checking whether a
  /// title-derived name is already claimed on disk.
  static const List<String> _knownAudioExts = [
    'm4a', 'mp3', 'aac', 'flac', 'ogg', 'opus', 'wav', 'webm', 'mp4'
  ];

  static String _basenameOf(String path) => path.split(RegExp(r'[/\\]')).last;

  static String _extensionOf(String path) {
    final name = _basenameOf(path);
    final dot = name.lastIndexOf('.');
    if (dot <= 0 || dot == name.length - 1) return preferredContainer;
    return name.substring(dot + 1).toLowerCase();
  }

  /// Full path minus the extension. Titles legitimately contain dots ("Mr.
  /// Brightside"), so only the LAST one is treated as the extension separator.
  static String _stemOf(String path) {
    final dot = path.lastIndexOf('.');
    final sep = path.lastIndexOf(RegExp(r'[/\\]'));
    return dot > sep && dot > 0 ? path.substring(0, dot) : path;
  }

  /// Case- and separator-insensitive key for comparing two paths.
  static String _pathKey(String path) =>
      path.replaceAll('\\', '/').toLowerCase();

  /// The file a download of [song] should produce: `<download dir>/<title>.<ext>`.
  ///
  /// Songs are stored under their TITLE, not under the source's internal id. A
  /// folder of `dQw4w9WgXcQ.m4a` is unusable the moment the user opens it in a
  /// file manager, copies tracks to a computer, or plays them in another app —
  /// the id is meaningful to this app and to nothing else.
  ///
  /// Two different songs can genuinely share a title, so a name already taken
  /// by another track gets a ` (2)`, ` (3)` suffix. Re-downloading the SAME
  /// song deliberately reuses its own existing name instead of piling up
  /// copies, which is why the song's registered path is exempt from the clash
  /// check. Falls back to the id in the pathological case where 99 tracks share
  /// a title, since the id is unique by construction.
  ///
  /// [_downloadedSongs] must already be loaded; callers run after
  /// [loadDownloads].
  Future<File> _resolveAudioFile(Song song, String ext) async {
    final dir = await _downloadDir;
    final sep = Platform.pathSeparator;
    final base = StorageLocationService.sanitizeFileName(
      song.title,
      fallback: song.videoId,
    );

    String? ownKey;
    for (final s in _downloadedSongs) {
      if (s.videoId == song.videoId) {
        final p = s.filePath;
        if (p != null && p.isNotEmpty) ownKey = _pathKey(p);
        break;
      }
    }

    for (int n = 1; n <= 99; n++) {
      final stem = n == 1 ? base : '$base ($n)';
      bool clash = false;
      // Any container counts: `Title.mp3` sitting there makes `Title.m4a` a
      // confusing near-duplicate, and the container-repair pass may rename one
      // onto the other.
      for (final e in _knownAudioExts) {
        final candidate = '${dir.path}$sep$stem.$e';
        if (_pathKey(candidate) == ownKey) continue;
        // The in-progress `.part` counts as taken. Transfers no longer create
        // the final file until they finish (see [DownloadTask.partFile]), so
        // without this a second song with the same title would look at an empty
        // slot, reserve the identical name, and the two would write over each
        // other's staging file.
        if (File(candidate).existsSync() || File('$candidate.part').existsSync()) {
          clash = true;
          break;
        }
      }
      // Same reasoning for a name another running task has reserved but not yet
      // written anything to.
      if (!clash) {
        for (final t in _activeTasks.values) {
          if (t.song.videoId == song.videoId) continue;
          if (_stemOf(_pathKey(t.audioFile.path)) == _pathKey('${dir.path}$sep$stem')) {
            clash = true;
            break;
          }
        }
      }
      if (!clash) return File('${dir.path}$sep$stem.$ext');
    }
    return File('${dir.path}$sep${song.videoId}.$ext');
  }

  /// The path this song currently occupies, before the download replaces it.
  String? _registeredPathFor(String videoId) {
    for (final s in _downloadedSongs) {
      if (s.videoId == videoId) return s.filePath;
    }
    return null;
  }

  /// Delete the file a re-download has just superseded.
  ///
  /// A song re-downloaded after a title edit (or into a different container)
  /// lands under a new name; without this the old file stays behind as an
  /// orphan that no index entry points at, invisible to the app but still
  /// eating the user's storage and still listed by every other music player.
  Future<void> _removeSupersededFile(String? previousPath, String newPath) async {
    if (previousPath == null || previousPath.isEmpty) return;
    if (_pathKey(previousPath) == _pathKey(newPath)) return;
    try {
      final old = File(previousPath);
      if (await old.exists()) {
        await old.delete();
        await MediaStoreScanner.scanAll([previousPath]);
        debugPrint('[DownloadService] Removed superseded file: $previousPath');
      }
    } catch (e) {
      debugPrint('[DownloadService] Could not remove superseded file: $e');
    }
  }

  /// Put the artwork where it belongs and report where the index should point.
  ///
  /// The rule, in order:
  /// 1. If the cover is already inside the audio container, we are done. The
  ///    file is self-contained — it shows its own art in every other player and
  ///    on every other device — and NO image is written to disk.
  /// 2. Otherwise try to embed it ourselves ([ID3TagWriter]).
  /// 3. Only if embedding is genuinely impossible (an Opus/WebM container, a
  ///    malformed MP4) does a standalone image get written, into the hidden
  ///    cover folder, and mapped to the song through `metadata.json`.
  ///
  /// Returns the path the index should point at: the hidden sidecar for case 3,
  /// otherwise the app-private render cache written by [_writeArtCache]. Null
  /// only when no artwork could be obtained at all, in which case the caller
  /// keeps the song's remote thumbnail URL.
  ///
  /// The render cache is what makes the embedded art VISIBLE in this app while
  /// offline. Embedding alone is not enough for that: nothing decodes the
  /// container to draw a list tile, so with only a remote URL in the index a
  /// downloaded song fell back to the placeholder as soon as the HTTP image
  /// cache was evicted. The cache lives in app-private support storage — not in
  /// the user's music folder — so it is invisible to file managers and the media
  /// scanner, and it goes away with the app.
  ///
  /// [stagedThumbnail] is an image yt-dlp already fetched; it saves a network
  /// round-trip and is deleted either way, since staging is not storage.
  Future<String?> _settleArtwork(
    Song song,
    File audioFile, {
    String? stagedThumbnail,
    bool alreadyEmbedded = false,
  }) async {
    bool embedded =
        alreadyEmbedded || await ID3TagWriter.hasEmbeddedCover(audioFile);

    // Only fetch the image if the file still needs one, and fetch it at most
    // once: a cover the network refuses to hand over will not appear on a
    // second ask, and this runs at the tail of a download the user is watching.
    Uint8List? bytes;
    bool isPng = false;
    bool coverLookedUp = false;

    Future<void> loadCover() async {
      if (coverLookedUp) return;
      coverLookedUp = true;
      if (stagedThumbnail != null) {
        try {
          final staged = File(stagedThumbnail);
          if (await staged.exists()) {
            bytes = await staged.readAsBytes();
            isPng = stagedThumbnail.toLowerCase().endsWith('.png');
          }
        } catch (e) {
          debugPrint('[DownloadService] Could not read staged cover: $e');
        }
      }
      if (bytes == null || bytes!.isEmpty) {
        final fetched = await _fetchCoverBytes(song);
        bytes = fetched?.bytes;
        isPng = fetched?.isPng ?? false;
      }
    }

    if (!embedded) {
      await loadCover();
      final image = bytes;
      if (image != null && image.isNotEmpty && await audioFile.exists()) {
        try {
          embedded = await ID3TagWriter.embedCoverArt(
            audioFile: audioFile,
            imageBytes: image,
            mimeType: isPng ? 'image/png' : 'image/jpeg',
            title: song.title,
            artist: song.artist,
          );
        } catch (e) {
          debugPrint('[DownloadService] Cover embedding failed: $e');
          embedded = false;
        }
      }
    }

    // Staged artwork has done its job; it is cache, not storage.
    if (stagedThumbnail != null) {
      try {
        final staged = File(stagedThumbnail);
        if (await staged.exists()) await staged.delete();
      } catch (_) {}
    }

    if (embedded) {
      // No sidecar in the user's folder — but the app still needs a copy it can
      // draw offline. Reading it costs nothing here: the bytes are already in
      // hand unless yt-dlp embedded the art without leaving its staged image,
      // and a download is by definition online.
      await _removeCoverFile(song.videoId);
      await loadCover();
      final image = bytes;
      if (image == null || image.isEmpty) return null;
      return _writeArtCache(song.videoId, image, isPng: isPng);
    }

    await loadCover();
    final image = bytes;
    if (image == null || image.isEmpty) return null;

    debugPrint('[DownloadService] Could not embed art into '
        '${_basenameOf(audioFile.path)} — keeping a hidden sidecar cover');
    return _writeCoverFile(song.videoId, image, isPng: isPng);
  }

  /// Write the fallback cover into the hidden folder. Returns its path, or null.
  Future<String?> _writeCoverFile(String videoId, Uint8List bytes,
      {bool isPng = false}) async {
    try {
      // coverPathFor always names the file .jpg; keep a PNG honest so decoders
      // that trust the extension don't choke on it.
      var path = await _storageService.coverPathFor(videoId);
      if (isPng) path = '${path.substring(0, path.length - 4)}.png';
      final file = File(path);
      if (!await file.parent.exists()) {
        await file.parent.create(recursive: true);
      }
      await file.writeAsBytes(bytes, flush: true);
      return file.path;
    } catch (e) {
      debugPrint('[DownloadService] Could not write sidecar cover: $e');
      return null;
    }
  }

  /// Drop any sidecar cover for [videoId] — used once the art is embedded, so
  /// an upgrade or a re-download cleans up the copy an older build left behind.
  Future<void> _removeCoverFile(String videoId) async {
    for (final ext in const ['jpg', 'png']) {
      try {
        var path = await _storageService.coverPathFor(videoId);
        if (ext == 'png') path = '${path.substring(0, path.length - 4)}.png';
        final file = File(path);
        if (await file.exists()) await file.delete();
      } catch (_) {}
    }
  }

  Directory? _artCacheDir;

  /// App-private directory holding the render copy of embedded cover art.
  ///
  /// Application *support* rather than cache storage: the OS may clear a cache
  /// directory at will, and losing these files would silently return every
  /// downloaded song to the placeholder. Mirrors `LocalMetadataService`'s
  /// `localart` folder, which does the same job for imported local files.
  Future<Directory> _getArtCacheDir() async {
    final cached = _artCacheDir;
    if (cached != null && await cached.exists()) return cached;
    final support = await getApplicationSupportDirectory();
    final dir =
        Directory('${support.path}${Platform.pathSeparator}downloadart');
    if (!await dir.exists()) await dir.create(recursive: true);
    _artCacheDir = dir;
    return dir;
  }

  /// Store the render copy of [videoId]'s embedded art. Returns its path, or
  /// null on failure — in which case the caller falls back to the remote URL,
  /// so a failed cache write costs artwork offline and nothing else.
  Future<String?> _writeArtCache(String videoId, Uint8List bytes,
      {bool isPng = false}) async {
    try {
      final dir = await _getArtCacheDir();
      final file = File(
          '${dir.path}${Platform.pathSeparator}$videoId.${isPng ? 'png' : 'jpg'}');
      await file.writeAsBytes(bytes, flush: true);
      // A re-download can change the format; leave no stale twin behind for the
      // index to point at.
      final other = File(
          '${dir.path}${Platform.pathSeparator}$videoId.${isPng ? 'jpg' : 'png'}');
      if (await other.exists()) await other.delete();
      return file.path;
    } catch (e) {
      debugPrint('[DownloadService] Could not cache cover art: $e');
      return null;
    }
  }

  /// Drop the cached render copy for [videoId]. Called on delete: the file lives
  /// outside the download folder, so the directory sweeps never reach it.
  Future<void> _removeArtCache(String videoId) async {
    try {
      final dir = await _getArtCacheDir();
      for (final ext in const ['jpg', 'png']) {
        final file =
            File('${dir.path}${Platform.pathSeparator}$videoId.$ext');
        if (await file.exists()) await file.delete();
      }
    } catch (_) {}
  }

  /// Forget everything derived from the current storage root.
  ///
  /// Must be called when the user switches storage location: the download-dir
  /// path is cached inside [loadDownloads], which returns early once `_isLoaded`
  /// is set, so without this the sync path probe
  /// ([getCachedLocalPathSync]) keeps looking on the volume the library just
  /// left and reports every downloaded song as missing.
  void invalidateStorageCaches() {
    _isLoaded = false;
    _cachedDownloadDirPath = null;
    _migrationChecked = false;
  }

  /// Get the local file path for a downloaded song's audio
  Future<String> getLocalAudioPath(String videoId) async {
    await loadDownloads();
    final songIdx = _downloadedSongs.indexWhere((s) => s.videoId == videoId);
    if (songIdx >= 0) {
      final song = _downloadedSongs[songIdx];
      if (song.filePath != null && song.filePath!.isNotEmpty && File(song.filePath!).existsSync()) {
        return song.filePath!;
      }
    }
    final dir = await _downloadDir;
    final exts = ['mp3', 'm4a', 'aac', 'flac', 'ogg', 'opus', 'wav', 'webm'];
    for (final ext in exts) {
      final candidate = '${dir.path}/$videoId.$ext';
      if (File(candidate).existsSync()) {
        return candidate;
      }
    }
    return '${dir.path}/$videoId.mp3';
  }

  /// Move a downloaded song file into an album's folder.
  ///
  /// Returns the new file path, or null on failure.
  Future<String?> moveFileToAlbumFolder(String videoId, String albumName) async {
    await loadDownloads();
    final songIdx = _downloadedSongs.indexWhere((s) => s.videoId == videoId);
    if (songIdx < 0) return null;

    final song = _downloadedSongs[songIdx];
    final currentPath = song.filePath ?? await getLocalAudioPath(videoId);
    final albumDir = await _storageService.getAlbumDir(albumName);
    final newPath = await _storageService.moveFile(currentPath, albumDir);

    if (newPath != null) {
      _downloadedSongs[songIdx] = song.copyWith(
        filePath: newPath,
        albumFolderName: albumName,
      );
      await _saveMetadata();
    }
    return newPath;
  }

  /// Move a list of externally-scanned songs into the app's root folder.
  ///
  /// Optionally place them into an album subfolder.
  /// Returns the list of songs with updated file paths.
  Future<List<Song>> moveAllToAppFolder(List<Song> songs, {String? albumName}) async {
    final movedSongs = <Song>[];
    final targetDir = albumName != null
        ? await _storageService.getAlbumDir(albumName)
        : await _storageService.getDownloadDir();

    for (final song in songs) {
      final sourcePath = song.filePath ?? song.videoId;
      final sourceFile = File(sourcePath);
      if (!await sourceFile.exists()) continue;

      final newPath = await _storageService.moveFile(sourcePath, targetDir);
      if (newPath != null) {
        final updatedSong = song.copyWith(
          filePath: newPath,
          albumFolderName: albumName,
        );
        movedSongs.add(updatedSong);

        // Add to downloaded songs tracking if not already present
        if (!_downloadedSongs.any((s) => s.videoId == song.videoId)) {
          _downloadedSongs.add(updatedSong);
        } else {
          final idx = _downloadedSongs.indexWhere((s) => s.videoId == song.videoId);
          _downloadedSongs[idx] = updatedSong;
        }
      }
    }

    if (movedSongs.isNotEmpty) {
      await _saveMetadata();
    }
    return movedSongs;
  }

  /// Check whether a song's file is inside the app-managed folder.
  ///
  /// Used for smart delete behavior:
  /// - true → "Delete Permanently" (red)
  /// - false → "Delete Memory" (yellow)
  Future<bool> isFileInAppFolder(Song song) async {
    String? path = song.filePath;
    if (path == null || path.isEmpty || !File(path).existsSync()) {
      path = getCachedLocalPathSync(song.videoId);
    }
    if (path == null || !File(path).existsSync()) {
      return false;
    }
    return _storageService.isFileInAppFolder(path);
  }

  String? _cachedDownloadDirPath;

  /// Inspect binary magic bytes, strip invalid ID3 headers from non-MP3 files,
  /// and rename mislabeled audio files to authentic container extensions (.m4a, .webm, .ogg, .flac).
  ///
  /// Only the first bytes are read for sniffing. This used to `readAsBytes()`
  /// the whole file, which made [repairCorruptedDownloads] pull the entire
  /// download library through RAM on the first `loadDownloads()` — work that
  /// sits on the play path. The full read now happens only in the rare case
  /// where a bogus ID3 header actually has to be stripped.
  static Future<String> detectAndFixAudioContainer(File audioFile) async {
    if (!await audioFile.exists()) return audioFile.path;
    try {
      // 16 bytes covers every magic-byte check below plus the 10-byte ID3 header.
      Uint8List header;
      final raf = await audioFile.open();
      try {
        header = await raf.read(16);
      } finally {
        await raf.close();
      }
      if (header.length < 12) return audioFile.path;

      // 1. Strip prepended ID3 tags if accidentally injected into non-MP3 container
      if (header[0] == 0x49 && header[1] == 0x44 && header[2] == 0x33) {
        final existingTagSize = (header[6] & 0x7F) << 21 |
            (header[7] & 0x7F) << 14 |
            (header[8] & 0x7F) << 7 |
            (header[9] & 0x7F);
        final tagLen = 10 + existingTagSize;

        final fileLen = await audioFile.length();
        if (fileLen > tagLen + 8) {
          // Read just the payload's first bytes to identify the real container
          // before committing to rewriting the file.
          final probe = await audioFile.open();
          Uint8List payloadHead;
          try {
            await probe.setPosition(tagLen);
            payloadHead = await probe.read(12);
          } finally {
            await probe.close();
          }

          final isM4a = payloadHead.length >= 8 && payloadHead[4] == 0x66 && payloadHead[5] == 0x74 && payloadHead[6] == 0x79 && payloadHead[7] == 0x70;
          final isWebm = payloadHead.length >= 4 && payloadHead[0] == 0x1A && payloadHead[1] == 0x45 && payloadHead[2] == 0xDF && payloadHead[3] == 0xA3;
          final isOgg = payloadHead.length >= 4 && payloadHead[0] == 0x4F && payloadHead[1] == 0x67 && payloadHead[2] == 0x67 && payloadHead[3] == 0x53;
          final isFlac = payloadHead.length >= 4 && payloadHead[0] == 0x66 && payloadHead[1] == 0x4C && payloadHead[2] == 0x61 && payloadHead[3] == 0x43;

          if (isM4a || isWebm || isOgg || isFlac) {
            debugPrint('[DownloadService] Stripped prepended ID3 header from non-MP3 container: ${audioFile.path}');
            // Only now is the full read justified.
            final all = await audioFile.readAsBytes();
            final payload = Uint8List.sublistView(all, tagLen);
            await audioFile.writeAsBytes(payload, flush: true);
            header = Uint8List.sublistView(
                payload, 0, payload.length < 16 ? payload.length : 16);
          }
        }
      }

      // 2. Determine authentic container extension from magic bytes
      final bytes = header;
      String correctExt = 'mp3';
      if (bytes.length >= 8 && bytes[4] == 0x66 && bytes[5] == 0x74 && bytes[6] == 0x79 && bytes[7] == 0x70) {
        correctExt = 'm4a';
      } else if (bytes.length >= 4 && bytes[0] == 0x1A && bytes[1] == 0x45 && bytes[2] == 0xDF && bytes[3] == 0xA3) {
        correctExt = 'webm';
      } else if (bytes.length >= 4 && bytes[0] == 0x4F && bytes[1] == 0x67 && bytes[2] == 0x67 && bytes[3] == 0x53) {
        correctExt = 'ogg';
      } else if (bytes.length >= 4 && bytes[0] == 0x66 && bytes[1] == 0x4C && bytes[2] == 0x61 && bytes[3] == 0x43) {
        correctExt = 'flac';
      } else if (bytes.length >= 4 && bytes[0] == 0x52 && bytes[1] == 0x49 && bytes[2] == 0x46 && bytes[3] == 0x46) {
        correctExt = 'wav';
      }

      // 3. Rename file to correct extension if needed
      final currentPath = audioFile.path;
      final dotIdx = currentPath.lastIndexOf('.');
      final basePath = dotIdx != -1 ? currentPath.substring(0, dotIdx) : currentPath;
      final targetPath = '$basePath.$correctExt';

      if (currentPath != targetPath) {
        final targetFile = File(targetPath);
        if (await targetFile.exists() && targetPath != currentPath) {
          await targetFile.delete();
        }
        final renamed = await audioFile.rename(targetPath);
        debugPrint('[DownloadService] Fixed container extension: $currentPath -> ${renamed.path}');
        return renamed.path;
      }
      return currentPath;
    } catch (e) {
      debugPrint('[DownloadService] Error detecting/repairing container: $e');
      return audioFile.path;
    }
  }

  Future<void> loadDownloads({bool force = false}) async {
    if (_isLoaded && !force) return;
    try {
      await _storageService.initialize();
      final dir = await _downloadDir;
      _cachedDownloadDirPath = dir.path;

      // Relocate a pre-update library before the index is read, so what we read
      // is already pointing at the hidden layout.
      await _migrateHiddenLayout(dir);

      final file = await _metadataFile;
      if (await file.exists()) {
        final content = await file.readAsString();
        final List<dynamic> jsonList = json.decode(content);
        _downloadedSongs.clear();
        for (final item in jsonList) {
          var song = Song.fromJson(item as Map<String, dynamic>);
          if (song.filePath == null || song.filePath!.isEmpty) {
            final exts = ['mp3', 'm4a', 'webm', 'ogg', 'flac', 'wav'];
            for (final ext in exts) {
              final candidate = '${dir.path}/${song.videoId}.$ext';
              if (File(candidate).existsSync()) {
                song = song.copyWith(filePath: candidate);
                break;
              }
            }
          }
          _downloadedSongs.add(song);
        }
      }
      _isLoaded = true;
      await repairCorruptedDownloads();
      await verifyStorageIntegrity();
    } catch (e) {
      debugPrint('Error loading downloads metadata: $e');
    }
  }

  /// Set once per resolved root so the probe below runs at most once per launch
  /// (and again after a storage switch, which is a different root).
  bool _migrationChecked = false;

  /// Move a pre-update library into the hidden layout: `metadata.json` and every
  /// cover image out of the visible `Download/` folder.
  ///
  /// Before this, a download wrote `<Download>/<id>.jpg` next to the audio. On
  /// device storage or an SD card the media scanner indexes any visible image,
  /// so the user's Gallery filled up with album art from songs they downloaded.
  /// Moving the files is only half the fix — MediaStore keeps the row until it
  /// is told the path is gone, which is what the closing scan does.
  ///
  /// Deliberately best-effort per song: a cover that fails to move is left for
  /// the next launch rather than aborting the whole migration or, worse, losing
  /// the song's artwork reference.
  Future<void> _migrateHiddenLayout(Directory downloadDir) async {
    if (_migrationChecked) return;
    _migrationChecked = true;
    try {
      final sep = Platform.pathSeparator;
      final removedPaths = <String>[];

      // 1. The index itself.
      final newIndex = await _metadataFile;
      final legacyIndex = File('${downloadDir.path}${sep}metadata.json');
      if (!await newIndex.exists() && await legacyIndex.exists()) {
        try {
          await newIndex.writeAsString(await legacyIndex.readAsString(), flush: true);
          await legacyIndex.delete();
          debugPrint('[DownloadService] Moved metadata.json into the hidden meta folder');
        } catch (e) {
          debugPrint('[DownloadService] metadata.json migration failed: $e');
        }
      }

      // 2. Cover images. Read the index directly — _downloadedSongs is not
      //    populated yet at this point in loadDownloads().
      if (!await newIndex.exists()) return;
      final List<dynamic> raw = json.decode(await newIndex.readAsString());
      final downloadPath = downloadDir.path.replaceAll('\\', '/').toLowerCase();
      bool changed = false;

      for (int i = 0; i < raw.length; i++) {
        final map = raw[i] as Map<String, dynamic>;
        final thumb = (map['thumbnailUrl'] as String?) ?? '';
        if (thumb.isEmpty || thumb.startsWith('http')) continue;
        // Only relocate covers that are actually sitting in the visible folder.
        if (!thumb.replaceAll('\\', '/').toLowerCase().startsWith(downloadPath)) {
          continue;
        }

        final videoId = (map['videoId'] as String?) ?? '';
        if (videoId.isEmpty) continue;

        try {
          final source = File(thumb);
          if (!await source.exists()) continue;
          final target = await _coverFileFor(videoId);
          if (!await target.parent.exists()) {
            await target.parent.create(recursive: true);
          }
          await source.copy(target.path);
          await source.delete();
          map['thumbnailUrl'] = target.path;
          map['highResThumbnailUrl'] = target.path;
          removedPaths.add(source.path);
          changed = true;
        } catch (e) {
          debugPrint('[DownloadService] Cover migration failed for $videoId: $e');
        }
      }

      if (changed) {
        await newIndex.writeAsString(json.encode(raw), flush: true);
        debugPrint('[DownloadService] Moved ${removedPaths.length} cover(s) '
            'into the hidden cover folder');
      }
      // Drop the stale MediaStore rows so the images leave the Gallery.
      await MediaStoreScanner.scanAll(removedPaths);
    } catch (e) {
      debugPrint('[DownloadService] Hidden-layout migration failed: $e');
    }
  }

  /// Self-healing repair for existing downloaded tracks on disk.
  /// Repair container-extension mismatches (e.g. an M4A file saved as .mp3).
  Future<int> repairCorruptedDownloads() async {
    int repaired = 0;
    for (int i = 0; i < _downloadedSongs.length; i++) {
      final song = _downloadedSongs[i];
      if (song.filePath != null && song.filePath!.isNotEmpty) {
        final f = File(song.filePath!);
        if (await f.exists()) {
          final repairedPath = await detectAndFixAudioContainer(f);
          if (repairedPath != song.filePath) {
            _downloadedSongs[i] = song.copyWith(filePath: repairedPath);
            repaired++;
          }
        }
      }
    }
    if (repaired > 0) {
      await _saveMetadata();
    }
    return repaired;
  }

  /// Comprehensive diagnostic & repair pipeline:
  /// 1. Cleans orphan .part / .tmp / 0-byte temporary download files.
  /// 2. Discovers & adopts unindexed audio files in Download folder into library.
  /// 3. Detects & fixes container/extension mismatches (.m4a mislabeled as .mp3).
  /// 4. Verifies physical existence of indexed songs & prunes ghost entries.
  /// 5. Cleans orphan cover art files & restores missing artwork links.
  Future<StorageRepairResult> runComprehensiveStorageDiagnostics() async {
    await loadDownloads();

    int cleanedTemp = 0;
    int recoveredSongs = 0;
    int repairedContainers = 0;
    int prunedGhosts = 0;
    int repairedCovers = 0;

    // 1. Clean temp / part / 0-byte files
    try {
      final dlDir = await _storageService.getDownloadDir();
      if (await dlDir.exists()) {
        await for (final entity in dlDir.list(recursive: true, followLinks: false)) {
          if (entity is File) {
            final name = entity.path.toLowerCase();
            if (name.endsWith('.part') || name.endsWith('.tmp') || name.endsWith('.download')) {
              try {
                await entity.delete();
                cleanedTemp++;
              } catch (_) {}
            } else if (await entity.length() == 0 && !name.endsWith('.nomedia')) {
              try {
                await entity.delete();
                cleanedTemp++;
              } catch (_) {}
            }
          }
        }
      }
    } catch (e) {
      debugPrint('[DownloadService] Temp cleanup error: $e');
    }

    // 2. Discover & adopt unindexed audio files in Download directory
    try {
      final dlDir = await _storageService.getDownloadDir();
      if (await dlDir.exists()) {
        final audioExts = {'.mp3', '.m4a', '.aac', '.flac', '.ogg', '.opus', '.wav', '.webm'};
        final indexedPaths = _downloadedSongs
            .where((s) => s.filePath != null && s.filePath!.isNotEmpty)
            .map((s) => s.filePath!.replaceAll('\\', '/').toLowerCase())
            .toSet();

        await for (final entity in dlDir.list(recursive: true, followLinks: false)) {
          if (entity is File) {
            final path = entity.path;
            final ext = _extensionOf(path).toLowerCase();
            if (audioExts.contains('.$ext')) {
              final normPath = path.replaceAll('\\', '/').toLowerCase();
              if (!indexedPaths.contains(normPath)) {
                final fileLen = await entity.length();
                if (fileLen > 1024) {
                  final stem = _stemOf(_basenameOf(path));
                  final videoId = 'local_${entity.statSync().modified.millisecondsSinceEpoch}_${stem.hashCode.abs()}';
                  Song orphanSong = Song(
                    id: videoId,
                    videoId: videoId,
                    title: stem,
                    artist: 'Local Audio',
                    thumbnailUrl: '',
                    highResThumbnailUrl: '',
                    duration: Duration.zero,
                    filePath: path,
                    albumFolderName: 'Downloads',
                  );
                  try {
                    orphanSong = await LocalMetadataService().enrichSong(orphanSong);
                  } catch (_) {}
                  _downloadedSongs.add(orphanSong);
                  indexedPaths.add(normPath);
                  recoveredSongs++;
                }
              }
            }
          }
        }
      }
    } catch (e) {
      debugPrint('[DownloadService] Unindexed audio scan error: $e');
    }

    // 3. Container & Extension Mismatches
    try {
      repairedContainers = await repairCorruptedDownloads();
    } catch (e) {
      debugPrint('[DownloadService] Container repair error: $e');
    }

    // 4. Verify storage integrity & prune ghosts
    try {
      final hadGhosts = await verifyStorageIntegrity();
      if (hadGhosts) {
        prunedGhosts++;
      }
    } catch (e) {
      debugPrint('[DownloadService] Integrity verification error: $e');
    }

    // 5. Cover Art Maintenance & Orphan Cleanup
    try {
      final coverDir = await _storageService.getCoverDir();
      final validIds = _downloadedSongs.map((s) => s.videoId).toSet();

      if (await coverDir.exists()) {
        await for (final f in coverDir.list(followLinks: false)) {
          if (f is File) {
            final name = _stemOf(_basenameOf(f.path));
            if (!validIds.contains(name) && !f.path.contains('.nomedia')) {
              try {
                await f.delete();
                repairedCovers++;
              } catch (_) {}
            }
          }
        }
      }
    } catch (e) {
      debugPrint('[DownloadService] Cover art maintenance error: $e');
    }

    // 6. Duplicate Audio Files Scan
    List<DuplicateAudioGroup> duplicatesFound = [];
    try {
      duplicatesFound = await findDuplicateAudioFiles();
    } catch (e) {
      debugPrint('[DownloadService] Duplicate audio scan error: $e');
    }

    await _saveMetadata();

    return StorageRepairResult(
      repairedContainers: repairedContainers,
      recoveredUnindexedSongs: recoveredSongs,
      prunedGhosts: prunedGhosts,
      cleanedTempFiles: cleanedTemp,
      repairedCovers: repairedCovers,
      duplicatesFound: duplicatesFound,
    );
  }

  /// Scans storage directories and groups duplicate audio files by stem/size.
  Future<List<DuplicateAudioGroup>> findDuplicateAudioFiles() async {
    final Map<String, List<File>> groups = {};
    final Map<String, String> titles = {};

    try {
      final dlDir = await _storageService.getDownloadDir();
      final audioExts = {'.mp3', '.m4a', '.aac', '.flac', '.ogg', '.opus', '.wav', '.webm'};

      final candidates = <File>[];

      if (await dlDir.exists()) {
        await for (final entity in dlDir.list(recursive: true, followLinks: false)) {
          if (entity is File) {
            final ext = _extensionOf(entity.path).toLowerCase();
            if (audioExts.contains('.$ext')) {
              candidates.add(entity);
            }
          }
        }
      }

      // Group candidates by key: clean stem + file size in bytes
      for (final file in candidates) {
        try {
          final len = file.lengthSync();
          if (len < 2048) continue; // Skip tiny fragments

          final basename = _basenameOf(file.path);
          final stem = _cleanTitleKey(_stemOf(basename));
          if (stem.isEmpty) continue;

          final key = '${stem}_$len';

          groups.putIfAbsent(key, () => []).add(file);
          titles.putIfAbsent(key, () => _stemOf(basename));
        } catch (_) {}
      }
    } catch (e) {
      debugPrint('[DownloadService] findDuplicateAudioFiles error: $e');
    }

    final List<DuplicateAudioGroup> result = [];
    groups.forEach((key, files) {
      if (files.length > 1) {
        result.add(DuplicateAudioGroup(
          songTitle: titles[key] ?? 'Audio Track',
          artist: 'Storage File',
          candidateFiles: files,
        ));
      }
    });

    return result;
  }

  static String _cleanTitleKey(String input) {
    return input
        .toLowerCase()
        .replaceAll(RegExp(r'[^a-z0-9]'), '')
        .trim();
  }

  /// Deletes selected duplicate files from disk and purges their metadata index entries.
  Future<int> deleteSelectedDuplicateFiles(List<String> filePathsToDelete) async {
    int freedBytes = 0;
    for (final path in filePathsToDelete) {
      try {
        final f = File(path);
        if (await f.exists()) {
          freedBytes += await f.length();
          await f.delete();
        }
        final normPath = path.replaceAll('\\', '/').toLowerCase();
        _downloadedSongs.removeWhere((s) => s.filePath?.replaceAll('\\', '/').toLowerCase() == normPath);
      } catch (e) {
        debugPrint('[DownloadService] Error deleting duplicate file $path: $e');
      }
    }
    await _saveMetadata();
    return freedBytes;
  }

  /// Verify physical existence of all downloaded tracks.
  /// Auto-prunes ghost download entries whose files have been deleted on disk.
  Future<bool> verifyStorageIntegrity() async {
    bool changed = false;
    final List<Song> valid = [];

    for (var song in _downloadedSongs) {
      String? path = song.filePath;
      bool exists = false;

      if (path != null && path.isNotEmpty) {
        if (File(path).existsSync()) {
          exists = true;
        } else {
          final normalized = path.replaceAll('\\', '/');
          if (File(normalized).existsSync()) {
            exists = true;
            song = song.copyWith(filePath: normalized);
          }
        }
      }

      if (!exists) {
        final probed = getCachedLocalPathSync(song.videoId);
        if (probed != null && File(probed).existsSync()) {
          exists = true;
          song = song.copyWith(filePath: probed);
        }
      }

      if (exists) {
        valid.add(song);
      } else {
        changed = true;
        await _removeArtCache(song.videoId);
        debugPrint('[DownloadService] Purged ghost download: ${song.title} ($path)');
      }
    }

    if (changed) {
      _downloadedSongs.clear();
      _downloadedSongs.addAll(valid);
      await _saveMetadata();
    }
    return changed;
  }

  Future<List<Song>> getDownloadedSongs() async {
    await loadDownloads();
    // verifyStorageIntegrity is already called inside loadDownloads() —
    // calling it again here doubled every disk-walk on startup and on every
    // download completion. loadDownloads guards on _isLoaded so it returns
    // immediately on the second call, but verifyStorageIntegrity does not,
    // meaning TWO full filesystem-scans fired unconditionally on every call.
    return List.unmodifiable(_downloadedSongs);
  }

  Future<bool> isSongDownloaded(String videoId) async {
    await loadDownloads();
    return _downloadedSongs.any((s) => s.videoId == videoId);
  }

  bool isSongDownloadedSync(String videoId) {
    return _downloadedSongs.any((s) => s.videoId == videoId);
  }

  /// True once [loadDownloads] has populated the in-memory index.
  ///
  /// Lets the play path trust [getCachedLocalPathSync] and skip the async
  /// re-probe: before the first load the sync probe cannot see anything, but
  /// after it the metadata list and cached dir path are authoritative.
  bool get isIndexLoaded => _isLoaded && _cachedDownloadDirPath != null;

  String? getCachedLocalPathSync(String videoId) {
    for (final s in _downloadedSongs) {
      if (s.videoId == videoId) {
        if (s.filePath != null && s.filePath!.isNotEmpty && File(s.filePath!).existsSync()) {
          return s.filePath;
        }
        if (_cachedDownloadDirPath != null) {
          final exts = ['mp3', 'm4a', 'aac', 'flac', 'ogg', 'opus', 'wav', 'webm'];
          for (final ext in exts) {
            final candidate = '$_cachedDownloadDirPath/$videoId.$ext';
            if (File(candidate).existsSync()) {
              return candidate;
            }
          }
        }
      }
    }
    if (_cachedDownloadDirPath != null) {
      final exts = ['mp3', 'm4a', 'aac', 'flac', 'ogg', 'opus', 'wav'];
      for (final ext in exts) {
        final candidate = '$_cachedDownloadDirPath/$videoId.$ext';
        if (File(candidate).existsSync()) {
          return candidate;
        }
      }
    }
    return null;
  }

  /// Check network connectivity.
  ///
  /// Fails OPEN, without exception. Only a lookup that comes back with a
  /// definite, *fast* "no such host" would be evidence of being offline — and
  /// even that is unreliable on mobile, where a captive portal, a carrier DNS
  /// hiccup or a network handing over between cells all produce a
  /// SocketException on a connection that works perfectly a second later.
  ///
  /// The previous version returned false on any exception, which is what turned
  /// a flaky DNS answer into "No network connection. Please check your internet"
  /// and refused a download that would have succeeded — while playback, which
  /// never consults this gate, kept streaming and made the refusal look absurd.
  /// The transfer itself is a far better judge of reachability, and it reports a
  /// real error instead of a guess, so this now only ever logs.
  Future<bool> isNetworkAvailable() async {
    try {
      final result = await InternetAddress.lookup('google.com')
          .timeout(const Duration(seconds: 8));
      if (result.isNotEmpty && result.first.rawAddress.isNotEmpty) return true;
      debugPrint('[DownloadService] DNS probe returned no address — '
          'letting the transfer decide');
      return true;
    } on TimeoutException {
      debugPrint('[DownloadService] DNS probe timed out — assuming online');
      return true;
    } catch (e) {
      debugPrint('[DownloadService] DNS probe failed ($e) — assuming online; '
          'the transfer will report the real error');
      return true;
    }
  }

  /// Calculate total storage used by downloads and metadata
  Future<int> getStorageUsed() async {
    try {
      final root = await _storageService.getAppRootDir();
      if (!await root.exists()) return 0;
      int total = 0;
      await for (final entity in root.list(recursive: true)) {
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

  /// Enqueue a download — respects max concurrent limit
  Future<void> downloadSong(Song song, ValueChanged<double>? onProgress, {VoidCallback? onStateChanged, AudioQuality quality = AudioQuality.high}) async {
    if (song.isLiveRadio) {
      throw Exception('Live radio streams cannot be downloaded for offline playback.');
    }

    DiagnosticLogService().log(DiagnosticLogService.downloadStart, {
      'videoId': song.videoId, 'title': song.title,
      'quality': quality.name, 'queued': _runningCount >= maxConcurrent,
    });

    final hasNetwork = await isNetworkAvailable();
    if (!hasNetwork) {
      throw Exception('No network connection. Please check your internet and try again.');
    }

    // Verify storage directory exists and is writable
    try {
      final dir = await _downloadDir;
      if (!await dir.exists()) {
        await dir.create(recursive: true);
      }
    } catch (e) {
      throw Exception('Insufficient storage permission or disk write failure.');
    }

    if (_runningCount < maxConcurrent) {
      _runningCount++;
      try {
        await _executeDownload(song, onProgress, onStateChanged: onStateChanged, quality: quality);
      } finally {
        _runningCount--;
        _processQueue();
      }
    } else {
      // Enqueue
      final completer = Completer<void>();
      _queue.add(_QueuedDownload(
        song: song,
        onProgress: onProgress,
        onStateChanged: onStateChanged,
        completer: completer,
        quality: quality,
      ));

      // Create a placeholder task so UI shows queued state
      await loadDownloads();
      final audioFile = await _resolveAudioFile(song, preferredContainer);
      final thumbFile = await _coverFileFor(song.videoId);
      final task = DownloadTask(
        song: song,
        audioFile: audioFile,
        thumbFile: thumbFile,
        onStateChanged: onStateChanged,
      );
      task.status = DownloadStatus.queued;
      _activeTasks[song.videoId] = task;
      if (onStateChanged != null) onStateChanged();

      return completer.future;
    }
  }

  void _processQueue() {
    while (_queue.isNotEmpty && _runningCount < maxConcurrent) {
      final queued = _queue.removeAt(0);
      _runningCount++;

      _executeDownload(queued.song, queued.onProgress, onStateChanged: queued.onStateChanged, quality: queued.quality).then((_) {
        queued.completer.complete();
      }).catchError((e) {
        queued.completer.completeError(e);
      }).whenComplete(() {
        _runningCount--;
        _processQueue();
      });
    }
  }

  /// Select the best audio stream based on user's quality preference.
  /// Strongly prefers M4A/AAC streams over WebM/Opus to avoid WebM output
  /// and enable native cover art embedding.
  AudioOnlyStreamInfo _pickStreamByQuality(StreamManifest manifest, AudioQuality quality) {
    final streams = manifest.audioOnly.toList();
    if (streams.isEmpty) throw Exception('No audio streams available');

    // Separate M4A/AAC streams from WebM/Opus
    final m4aStreams = streams.where((s) =>
        s.container.name.toLowerCase() == 'm4a' ||
        s.audioCodec.toLowerCase().contains('mp4a') ||
        s.audioCodec.toLowerCase().contains('aac')).toList();
    final candidates = m4aStreams.isNotEmpty ? m4aStreams : streams;

    // Sort by bitrate ascending
    candidates.sort((a, b) => a.bitrate.bitsPerSecond.compareTo(b.bitrate.bitsPerSecond));

    switch (quality) {
      case AudioQuality.low:
        return candidates.first;

      case AudioQuality.medium:
        AudioOnlyStreamInfo? best;
        int bestDiff = 999999;
        for (final s in candidates) {
          final diff = (s.bitrate.bitsPerSecond - 128000).abs();
          if (diff < bestDiff) {
            bestDiff = diff;
            best = s;
          }
        }
        return best ?? candidates[candidates.length ~/ 2];

      case AudioQuality.high:
        return candidates.last;
    }
  }

  /// True when [videoId] refers to a YouTube video, i.e. one of the sources
  /// yt-dlp can download directly. Every other source (JioSaavn, Jamendo,
  /// Archive, Audius, radio) is already a plain URL, so the HTTP path is both
  /// correct and faster for those.
  static bool _isYouTubeId(String videoId) {
    if (videoId.isEmpty) return false;
    if (videoId.startsWith('content://') ||
        videoId.startsWith('file://') ||
        videoId.startsWith('/')) {
      return false;
    }
    const foreignPrefixes = [
      'jiosaavn_', 'jamendo_', 'radio_', 'archive_', 'audius_', 'local_'
    ];
    for (final p in foreignPrefixes) {
      if (videoId.startsWith(p)) return false;
    }
    // YouTube ids are 11 chars of [A-Za-z0-9_-].
    return RegExp(r'^[A-Za-z0-9_-]{11}$').hasMatch(videoId);
  }

  /// Download a YouTube song with the native yt-dlp binary.
  ///
  /// Returns true on success. Returns false (or throws) to let the caller fall
  /// back to the direct HTTP path — this must never be the only way to get a
  /// file, since yt-dlp depends on a runtime that can fail to unpack.
  Future<bool> _executeYtDlpDownload(
    Song song,
    ValueChanged<double>? onProgress, {
    VoidCallback? onStateChanged,
    required AudioQuality quality,
    File? reservedAudioFile,
  }) async {
    final dir = await _downloadDir;

    // The index has to be in memory before a name can be reserved: title
    // collisions are resolved against the songs already downloaded.
    await loadDownloads();
    final previousPath = _registeredPathFor(song.videoId);
    // Reuse the name the first attempt reserved, so a retry does not slide onto
    // `Title (2).m4a` — see [_executeDownload]'s `reservedAudioFile`.
    final plannedAudio =
        reservedAudioFile ?? await _resolveAudioFile(song, preferredContainer);

    // Register a task up front so the existing UI (progress bar, speed, cancel)
    // works exactly as it does for the HTTP path. thumbFile points at the
    // hidden cover location because DownloadTask.cancel() deletes it.
    final task = DownloadTask(
      song: song,
      audioFile: plannedAudio,
      thumbFile: await _coverFileFor(song.videoId),
      onStateChanged: () {
        if (onProgress != null && _activeTasks.containsKey(song.videoId)) {
          onProgress(_activeTasks[song.videoId]!.progress);
        }
        if (onStateChanged != null) onStateChanged();
      },
    );
    task.status = DownloadStatus.downloading;
    task.isNative = true;
    _activeTasks[song.videoId] = task;
    if (onStateChanged != null) onStateChanged();

    // Speed tracker for the native download — derives bytes/sec from the
    // progress fraction reported by yt-dlp. Updated every second.
    double lastFraction = 0.0;
    DateTime lastSpeedSample = DateTime.now();
    Timer? speedTimer;
    speedTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (task.isCancelled || task.status != DownloadStatus.downloading) {
        task.speedBytesPerSec = 0;
        return;
      }
      final now = DateTime.now();
      final dtSec = now.difference(lastSpeedSample).inMilliseconds / 1000.0;
      if (dtSec <= 0) return;
      final dFraction = task.progress - lastFraction;
      lastFraction = task.progress;
      lastSpeedSample = now;
      // Estimate total size as ~5MB for speed display (yt-dlp doesn't report
      // total bytes for stream copies). The fraction itself is accurate.
      const estimatedTotalBytes = 5 * 1024 * 1024;
      final bytesThisSec = (dFraction * estimatedTotalBytes) / dtSec;
      if (task.speedBytesPerSec <= 0) {
        task.speedBytesPerSec = bytesThisSec;
      } else {
        task.speedBytesPerSec = task.speedBytesPerSec * 0.7 + bytesThisSec * 0.3;
      }
      task.onStateChanged?.call();
    });

    try {
      final result = await YtDlpDownloader.download(
        videoId: song.videoId,
        quality: quality,
        onProgress: (fraction) {
          if (task.isCancelled) return;
          task.progress = fraction;
          task.onStateChanged?.call();
        },
        onEta: (eta) {
          if (task.isCancelled) return;
          task.eta = eta;
        },
      );

      if (task.isCancelled) return false;

      // Move the finished artifact out of staging into whichever location the
      // user has configured (app-internal, device internal, or SD card), and
      // rename it from the staging id to the song's title in the same step.
      // The container is whatever yt-dlp actually produced — normally the
      // requested M4A, but the extension has to follow the bytes.
      final producedExt = _extensionOf(result.audioPath);
      final targetName = producedExt == preferredContainer
          ? _basenameOf(plannedAudio.path)
          : '${_stemOf(plannedAudio.path)}.$producedExt';
      final movedAudio = await _storageService
          .moveFile(result.audioPath, dir, fileName: targetName);
      if (movedAudio == null) {
        throw Exception('Could not move downloaded audio into $dir');
      }

      // Artwork belongs INSIDE the file. yt-dlp's --embed-thumbnail normally
      // has already put it there; anything else is handled (and any stale
      // sidecar cleaned up) by _settleArtwork, which only writes a standalone
      // image when embedding turns out to be impossible.
      final coverPath = await _settleArtwork(
        song,
        File(movedAudio),
        stagedThumbnail: result.thumbnailPath,
        alreadyEmbedded: result.thumbnailEmbedded,
      );

      task.progress = 1.0;
      task.status = DownloadStatus.completed;
      _activeTasks.remove(song.videoId);
      if (onStateChanged != null) onStateChanged();

      await loadDownloads();
      await _removeSupersededFile(previousPath, movedAudio);
      _downloadedSongs.removeWhere((s) => s.videoId == song.videoId);
      _downloadedSongs.add(Song(
        id: song.id,
        videoId: song.videoId,
        title: song.title,
        artist: song.artist,
        thumbnailUrl: coverPath ?? song.thumbnailUrl,
        highResThumbnailUrl: coverPath ?? song.highResThumbnailUrl,
        duration: song.duration,
        filePath: movedAudio,
      ));
      await _saveMetadata();

      // Make the AUDIO visible to other music apps / file managers when it
      // landed somewhere the media scanner indexes. The cover is deliberately
      // NOT scanned: it lives in the hidden folder precisely so it stays out of
      // the user's Gallery, and other players read the art embedded in the file.
      await MediaStoreScanner.scanIfPublic(movedAudio);

      return true;
    } catch (e) {
      _activeTasks.remove(song.videoId);
      if (onStateChanged != null) onStateChanged();
      // Clear partial staging output so a retry starts clean.
      await YtDlpDownloader.cancel(song.videoId);
      rethrow;
    } finally {
      speedTimer.cancel();
    }
  }

  /// Fetch the song's cover image into memory.
  ///
  /// Nothing is written to disk here: the bytes are destined for the inside of
  /// the audio file, and only [_settleArtwork] decides whether a copy ever
  /// needs to exist separately. The high-res URL is tried first because the
  /// embedded art is what other players and other devices will render, and the
  /// list thumbnail is too small to look good there.
  Future<_CoverBytes?> _fetchCoverBytes(Song song) async {
    final candidates = <String>[];
    for (final url in [song.highResThumbnailUrl, song.thumbnailUrl]) {
      if (url.isNotEmpty && url.startsWith('http') && !candidates.contains(url)) {
        candidates.add(url);
      }
    }
    if (candidates.isEmpty) return null;

    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 8);
    try {
      for (final url in candidates) {
        try {
          final request = await client.getUrl(Uri.parse(url));
          final response = await request.close();
          if (response.statusCode != HttpStatus.ok) {
            await response.drain();
            continue;
          }
          final bytes = await consolidateHttpClientResponseBytes(response);
          if (bytes.isEmpty) continue;
          // Trust the magic bytes over the URL: YouTube serves .jpg URLs that
          // are actually WebP, and a mislabelled PNG breaks strict decoders.
          final isPng = bytes.length >= 4 &&
              bytes[0] == 0x89 &&
              bytes[1] == 0x50 &&
              bytes[2] == 0x4E &&
              bytes[3] == 0x47;
          return _CoverBytes(bytes, isPng);
        } catch (e) {
          debugPrint('[DownloadService] Cover fetch failed ($url): $e');
        }
      }
      return null;
    } finally {
      client.close();
    }
  }

  Future<void> _executeDownload(Song song, ValueChanged<double>? onProgress, {VoidCallback? onStateChanged, int attempt = 0, AudioQuality quality = AudioQuality.high, File? reservedAudioFile}) async {
    // Preferred path for YouTube: let yt-dlp + FFmpeg do the download, the
    // container conversion and the artwork embedding natively. Falls through to
    // the HTTP path below on any failure, so this can only add capability.
    //
    // A retry re-enters this method from the top, so yt-dlp is tried again on
    // every attempt rather than the first failure demoting the song to the
    // weaker HTTP path for good.
    if (_isYouTubeId(song.videoId)) {
      try {
        final ok = await _executeYtDlpDownload(
          song,
          onProgress,
          onStateChanged: onStateChanged,
          quality: quality,
          reservedAudioFile: reservedAudioFile,
        );
        if (ok) {
          // yt-dlp won this attempt, so whatever the HTTP path had staged for
          // this song is dead weight.
          _resumeHints.remove(song.videoId);
          if (reservedAudioFile != null) {
            try {
              final leftover = File('${reservedAudioFile.path}.part');
              if (await leftover.exists()) await leftover.delete();
            } catch (_) {}
          }
          return;
        }
      } catch (e) {
        debugPrint('[DownloadService] yt-dlp path failed for ${song.title}: $e '
            '— falling back to direct HTTP download');
      }
    }

    // Reserve the title-derived name (see [_resolveAudioFile]) against the
    // songs already in the library. The extension starts as the preferred
    // container and is corrected from the magic bytes once the transfer is
    // done — the server decides the container, not us.
    await loadDownloads();
    final previousPath = _registeredPathFor(song.videoId);
    // The target name is reserved ONCE and reused by every retry of this
    // download. Re-resolving it per attempt walked the clash suffix forward:
    // once attempt one had put something at `Title.m4a`, attempt two saw the
    // name as taken and landed on `Title (2).m4a`, attempt three on
    // `Title (3).m4a` — littering the folder with stubs no index entry points
    // at, and making resume impossible because each attempt wrote to a
    // different file.
    final audioFile =
        reservedAudioFile ?? await _resolveAudioFile(song, preferredContainer);
    // The fallback cover — only ever written if the art cannot be embedded —
    // goes in the hidden folder, NEVER beside the audio, where the media
    // scanner would put it in the device Gallery.
    final thumbFile = await _coverFileFor(song.videoId);

    // Identity of the rendition this attempt ends up reading, recorded so a
    // failure can leave a resume hint the NEXT attempt can validate against.
    // Declared out here because the catch block needs it and `streamUrl` is
    // scoped to the try.
    String? usedFormatKey;

    try {
      // 1. Resolve stream URL using StreamResolverService (works for JioSaavn, YouTube, Jamendo, etc.)
      late final Uri streamUrl;
      int totalBytes = 0;
      Map<String, String>? headers;

      // A retry MUST go back to the network instead of re-reading the resolved
      // URL cache. Stream URLs are time-limited and IP-bound, so the single
      // most likely reason the previous attempt died is that this exact URL
      // stopped working — handing the same one back made all three attempts
      // fail identically and turned the retry loop into a slow way of
      // reporting the first error.
      final resolved =
          await StreamResolverService().resolve(song, forceRefresh: attempt > 0);
      if (resolved != null && resolved.url.isNotEmpty && !resolved.url.startsWith('file://')) {
        streamUrl = Uri.parse(resolved.url);
        headers = resolved.headers;
        debugPrint('[DownloadService] Resolved online stream via StreamResolver (${resolved.source}): ${song.title}');
      } else {
        // Fallback to YoutubeExplode if StreamResolver returned null
        final yt = YoutubeExplode();
        try {
          final manifest = await yt.videos.streamsClient.getManifest(
            song.videoId,
            ytClients: [
              YoutubeApiClient.ios,
              YoutubeApiClient.androidVr,
              YoutubeApiClient.safari,
            ],
          );
          final streamInfo = _pickStreamByQuality(manifest, quality);
          streamUrl = streamInfo.url;
          totalBytes = streamInfo.size.totalBytes;
          debugPrint('Download via YoutubeExplode: ${song.title} at ${streamInfo.bitrate.bitsPerSecond ~/ 1000}kbps (${quality.name})');
        } finally {
          yt.close();
        }
      }

      // 2. Create and run task
      final task = DownloadTask(
        song: song,
        audioFile: audioFile,
        thumbFile: thumbFile,
        onStateChanged: () {
          if (onProgress != null && _activeTasks.containsKey(song.videoId)) {
            onProgress(_activeTasks[song.videoId]!.progress);
          }
          if (onStateChanged != null) onStateChanged();
        },
      );
      _activeTasks[song.videoId] = task;
      if (onStateChanged != null) onStateChanged();

      // Continue an existing `.part` only if the previous attempt left a hint
      // proving it came from this same rendition. Any other partial — a
      // different itag, a different mirror, a leftover from a previous run — is
      // discarded inside start(), because appending across encodings produces a
      // file that plays as noise.
      usedFormatKey = DownloadTask.formatKeyOf(streamUrl);
      final hint = _resumeHints[song.videoId];
      final canResume = hint != null && hint.formatKey == usedFormatKey;
      if (canResume && totalBytes <= 0) {
        // Give start() the size the earlier attempt learned, so its
        // Content-Range cross-check has something to compare against.
        totalBytes = hint.total;
      }

      await task.start(
        streamUrl,
        totalBytes,
        headers: headers,
        allowResume: canResume,
      );

      // Landed. Any partial is now consumed, so the hint must not outlive it.
      _resumeHints.remove(song.videoId);

      // Clean up task from active list
      _activeTasks.remove(song.videoId);

      // 3. Container validation & extension normalization. This runs BEFORE the
      // artwork step, not after: the tag writer picks its strategy from the
      // container's magic bytes, so tagging first meant an AAC stream that had
      // not yet been recognised got an ID3 header prepended — which the repair
      // pass then stripped straight back off, taking the artwork with it.
      final validFilePath = await detectAndFixAudioContainer(audioFile);

      // 4. Cover art goes INSIDE the file so it travels with it. Only when the
      // container cannot carry artwork does a standalone image get written, and
      // then only into the hidden folder, mapped through metadata.json.
      final coverPath = await _settleArtwork(song, File(validFilePath));

      // Update metadata
      await loadDownloads();
      await _removeSupersededFile(previousPath, validFilePath);
      _downloadedSongs.removeWhere((s) => s.videoId == song.videoId);

      // Update song with local paths including the physical validFilePath
      final localSong = Song(
        id: song.id,
        videoId: song.videoId,
        title: song.title,
        artist: song.artist,
        thumbnailUrl: coverPath ?? song.thumbnailUrl,
        highResThumbnailUrl: coverPath ?? song.highResThumbnailUrl,
        duration: song.duration,
        filePath: validFilePath,
      );

      _downloadedSongs.add(localSong);
      await _saveMetadata();

      // Same MediaStore refresh the yt-dlp path does. This path writes the
      // file with dart:io, so without a scan it stays invisible to every other
      // app on the device. Only the AUDIO is scanned — the cover lives in the
      // hidden folder precisely so it stays out of the user's Gallery.
      await MediaStoreScanner.scanIfPublic(validFilePath);
    } catch (e) {
      // Record what this attempt was reading, so the retry can decide whether
      // the `.part` file it left behind is safe to continue. Only worth keeping
      // when there are actually bytes on disk AND a known total to validate the
      // next server response against.
      final failedTask = _activeTasks[song.videoId];
      if (failedTask != null &&
          usedFormatKey != null &&
          failedTask.bytesDownloaded > 0 &&
          failedTask.totalSize > 0 &&
          !failedTask.isCancelled) {
        _resumeHints[song.videoId] =
            _ResumeHint(usedFormatKey, failedTask.totalSize);
        debugPrint('[DownloadService] Kept ${DownloadItem.formatFileSize(failedTask.bytesDownloaded)} '
            'of ${song.title} for resume');
      } else {
        _resumeHints.remove(song.videoId);
      }

      // Retry logic
      if (attempt < maxRetries - 1) {
        debugPrint('Download attempt ${attempt + 1} failed for ${song.title}, retrying...');
        DiagnosticLogService().log(DiagnosticLogService.downloadRetry, {
          'videoId': song.videoId, 'title': song.title,
          'attempt': attempt + 1, 'max': maxRetries,
          'error': e.toString(),
          'resume_bytes': _resumeHints[song.videoId]?.total ?? 0,
        });
        final task = _activeTasks[song.videoId];
        if (task != null) {
          task.status = DownloadStatus.retrying;
          task.retryCount = attempt + 1;
          task.errorMessage = 'Retrying (${attempt + 2}/$maxRetries)...';
          if (onStateChanged != null) onStateChanged();
        }
        await Future.delayed(Duration(seconds: 2 * (attempt + 1)));
        return _executeDownload(song, onProgress,
            onStateChanged: onStateChanged,
            attempt: attempt + 1,
            quality: quality,
            reservedAudioFile: audioFile);
      }

      // Final failure.
      _resumeHints.remove(song.videoId);
      try {
        final leftover = File('${audioFile.path}.part');
        if (await leftover.exists()) await leftover.delete();
      } catch (_) {}

      final task = _activeTasks[song.videoId];
      if (task != null) {
        task.status = DownloadStatus.failed;
        task.errorMessage = e.toString();
        task.retryCount = attempt + 1;
        if (onStateChanged != null) onStateChanged();
      }
      debugPrint('Download error after $maxRetries attempts: $e');
      DiagnosticLogService().log(DiagnosticLogService.downloadError, {
        'videoId': song.videoId, 'title': song.title,
        'attempts': attempt + 1, 'error': e.toString(),
      });
      rethrow;
    }
  }

  void pauseDownload(String videoId) {
    _activeTasks[videoId]?.pause();
  }

  void resumeDownload(String videoId) {
    _activeTasks[videoId]?.resume();
  }

  Future<void> cancelDownload(String videoId) async {
    // Remove from queue if queued
    _queue.removeWhere((q) => q.song.videoId == videoId);
    // An explicit cancel discards the partial too, so nothing may claim it is
    // resumable afterwards.
    _resumeHints.remove(videoId);
    await _activeTasks[videoId]?.cancel();
    _activeTasks.remove(videoId);
  }

  /// Pause all active downloads (used when network drops)
  void pauseAllDownloads() {
    for (final task in _activeTasks.values) {
      if (task.status == DownloadStatus.downloading) {
        task.pause();
      }
    }
  }

  /// Resume all paused downloads (used when network returns)
  void resumeAllDownloads() {
    for (final task in _activeTasks.values) {
      if (task.status == DownloadStatus.paused) {
        task.resume();
      }
    }
  }

  /// Cancel all active downloads
  Future<void> cancelAllDownloads() async {
    _queue.clear();
    final ids = _activeTasks.keys.toList();
    for (final id in ids) {
      await cancelDownload(id);
    }
  }

  Future<void> deleteSong(String videoId) async {
    try {
      await loadDownloads();
      // Paths whose MediaStore row has to go once the bytes are gone —
      // otherwise other players keep listing a track that no longer plays.
      final removed = <String>[];
      final idx = _downloadedSongs.indexWhere((s) => s.videoId == videoId);
      if (idx >= 0) {
        final song = _downloadedSongs[idx];
        if (song.filePath != null && song.filePath!.isNotEmpty) {
          final file = File(song.filePath!);
          if (await file.exists()) {
            await file.delete();
            removed.add(file.path);
          }
        }
        if (song.thumbnailUrl.isNotEmpty && !song.thumbnailUrl.startsWith('http')) {
          final thumb = File(song.thumbnailUrl);
          if (await thumb.exists()) {
            await thumb.delete();
            removed.add(thumb.path);
          }
        }
        _downloadedSongs.removeAt(idx);
      }

      final dir = await _downloadDir;
      final defaultAudioMp3 = File('${dir.path}/$videoId.mp3');
      final defaultAudioM4a = File('${dir.path}/$videoId.m4a');
      final defaultThumb = File('${dir.path}/$videoId.jpg');

      if (await defaultAudioMp3.exists()) {
        await defaultAudioMp3.delete();
        removed.add(defaultAudioMp3.path);
      }
      if (await defaultAudioM4a.exists()) {
        await defaultAudioM4a.delete();
        removed.add(defaultAudioM4a.path);
      }
      if (await defaultThumb.exists()) {
        await defaultThumb.delete();
        removed.add(defaultThumb.path);
      }
      await _removeCoverFile(videoId);
      await _removeArtCache(videoId);

      await _saveMetadata();
      await MediaStoreScanner.scanAll(removed);
    } catch (e) {
      debugPrint('Delete download error: $e');
    }
  }

  /// Delete all downloaded songs
  Future<void> deleteAllDownloads() async {
    try {
      await loadDownloads();
      final removed = <String>[];

      for (final song in List<Song>.from(_downloadedSongs)) {
        if (song.filePath != null && song.filePath!.isNotEmpty) {
          final file = File(song.filePath!);
          if (await file.exists()) {
            await file.delete();
            removed.add(file.path);
          }
        }
        if (song.thumbnailUrl.isNotEmpty && !song.thumbnailUrl.startsWith('http')) {
          final thumb = File(song.thumbnailUrl);
          if (await thumb.exists()) {
            await thumb.delete();
          }
        }
        await _removeArtCache(song.videoId);
      }

      final coverDir = await _storageService.getCoverDir();
      if (await coverDir.exists()) {
        await for (final entity in coverDir.list(recursive: true)) {
          if (entity is File) {
            try {
              await entity.delete();
            } catch (_) {}
          }
        }
      }

      final dir = await _downloadDir;
      if (await dir.exists()) {
        await for (final entity in dir.list(recursive: true)) {
          if (entity is File && !entity.path.endsWith('metadata.json')) {
            try {
              await entity.delete();
              removed.add(entity.path);
            } catch (_) {}
          }
        }
      }

      _downloadedSongs.clear();
      await _saveMetadata();
      await MediaStoreScanner.scanAll(removed);
    } catch (e) {
      debugPrint('Delete all downloads error: $e');
    }
  }

  Future<void> updateSongMetadata(
    String videoId,
    String title,
    String artist, {
    double? speed,
    double? pitch,
    double? fadeIn,
    double? fadeOut,
    String? isolationMode,
  }) async {
    await loadDownloads();
    final idx = _downloadedSongs.indexWhere((s) => s.videoId == videoId);
    if (idx >= 0) {
      _downloadedSongs[idx] = _downloadedSongs[idx].copyWith(
        title: title,
        artist: artist,
        speed: speed,
        pitch: pitch,
        fadeIn: fadeIn,
        fadeOut: fadeOut,
        isEdited: true,
        isolationMode: isolationMode,
      );
      await _saveMetadata();
    }
  }

  Future<void> updateSongDuration(String videoId, Duration duration) async {
    await loadDownloads();
    final idx = _downloadedSongs.indexWhere((s) => s.videoId == videoId);
    if (idx >= 0) {
      _downloadedSongs[idx] = _downloadedSongs[idx].copyWith(
        duration: duration,
        isEdited: true,
      );
      await _saveMetadata();
    }
  }

  Future<void> updateDownloadedSong(Song updatedSong) async {
    await loadDownloads();
    final idx = _downloadedSongs.indexWhere((s) => s.videoId == updatedSong.videoId);
    if (idx >= 0) {
      _downloadedSongs[idx] = updatedSong.copyWith(isEdited: true);
      await _saveMetadata();
    }
  }

  /// Bulk update downloaded song paths (used after storage migration)
  Future<void> updateAllSongPaths(List<Song> updatedSongs) async {
    await loadDownloads();
    _downloadedSongs.clear();
    _downloadedSongs.addAll(updatedSongs);
    await _saveMetadata();
  }

  Future<void> saveNewSongCopy(Song originalSong, Song newSong, String sourceFilePath) async {
    await loadDownloads();
    final sourceFile = File(sourceFilePath);
    final ext = sourceFilePath.contains('.') ? sourceFilePath.split('.').last.toLowerCase() : 'mp3';
    final dir = await _downloadDir;
    final newPath = '${dir.path}${Platform.pathSeparator}${newSong.videoId}.$ext';
    if (await sourceFile.exists()) {
      await sourceFile.copy(newPath);
    }
    
    // Add to list and save metadata
    final savedSong = newSong.copyWith(filePath: newPath, isEdited: true);
    _downloadedSongs.add(savedSong);
    await _saveMetadata();
  }

  Future<void> _saveMetadata() async {
    try {
      final file = await _metadataFile;
      final jsonContent = json.encode(_downloadedSongs.map((s) => s.toJson()).toList());
      await file.writeAsString(jsonContent);
    } catch (e) {
      debugPrint('Error saving downloads metadata: $e');
    }
  }
}

/// Cover image bytes plus the container they really are, sniffed from the
/// magic bytes rather than believed from the URL.
class _CoverBytes {
  final Uint8List bytes;
  final bool isPng;
  const _CoverBytes(this.bytes, this.isPng);
}

/// What a failed transfer established about the stream it was reading, so the
/// next attempt can continue the `.part` file instead of starting over.
class _ResumeHint {
  /// [DownloadTask.formatKeyOf] of the URL that produced the partial.
  final String formatKey;

  /// Full size of that rendition, as the server reported it.
  final int total;

  const _ResumeHint(this.formatKey, this.total);
}

class _QueuedDownload {
  final Song song;
  final ValueChanged<double>? onProgress;
  final VoidCallback? onStateChanged;
  final Completer<void> completer;
  final AudioQuality quality;

  _QueuedDownload({
    required this.song,
    this.onProgress,
    this.onStateChanged,
    required this.completer,
    this.quality = AudioQuality.high,
  });
}
