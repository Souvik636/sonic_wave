import 'dart:convert';
import 'dart:io';
import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:youtube_explode_dart/youtube_explode_dart.dart';
import '../models/song.dart';
import '../providers/settings_provider.dart';
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

  Future<void> start(Uri streamUrl, int size, {Map<String, String>? headers}) async {
    totalSize = size;
    status = DownloadStatus.downloading;
    if (onStateChanged != null) onStateChanged!();

    _httpClient = HttpClient()
      ..connectionTimeout = const Duration(seconds: 8)
      ..idleTimeout = const Duration(seconds: 15);

    final request = await _httpClient!.getUrl(streamUrl);
    request.headers.set('User-Agent', 'Mozilla/5.0 (Linux; Android 10; Mobile) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Mobile Safari/537.36');
    if (headers != null) {
      headers.forEach((k, v) => request.headers.set(k, v));
    }

    final response = await request.close();
    if (response.statusCode != HttpStatus.ok && response.statusCode != HttpStatus.partialContent) {
      _httpClient!.close();
      throw Exception('Server returned status ${response.statusCode}');
    }

    if (totalSize <= 0 && response.contentLength > 0) {
      totalSize = response.contentLength;
    }

    _output = audioFile.openWrite(mode: FileMode.write);
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
        _httpClient?.close();
        progress = 1.0;
        status = DownloadStatus.completed;
        if (onStateChanged != null) onStateChanged!();
        completer.complete();
      },
      onError: (e) async {
        _stopSpeedTracking();
        await _output?.close();
        _httpClient?.close();
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

    // Clean up partial files
    try {
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

  /// Where this song's cover image belongs: the hidden cover folder, never
  /// beside the audio. See [StorageLocationService.coverFolderName].
  Future<File> _coverFileFor(String videoId) async =>
      File(await _storageService.coverPathFor(videoId));

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
    final exts = ['mp3', 'm4a', 'aac', 'flac', 'ogg', 'opus', 'wav'];
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
  Future<void> repairCorruptedDownloads() async {
    bool changed = false;
    for (int i = 0; i < _downloadedSongs.length; i++) {
      final song = _downloadedSongs[i];
      if (song.filePath != null && song.filePath!.isNotEmpty) {
        final f = File(song.filePath!);
        if (await f.exists()) {
          final repairedPath = await detectAndFixAudioContainer(f);
          if (repairedPath != song.filePath) {
            _downloadedSongs[i] = song.copyWith(filePath: repairedPath);
            changed = true;
          }
        }
      }
    }
    if (changed) {
      await _saveMetadata();
    }
  }

  /// Verify physical existence of all downloaded tracks.
  /// Auto-prunes ghost download entries whose files have been deleted on disk.
  Future<bool> verifyStorageIntegrity() async {
    bool changed = false;
    final List<Song> valid = [];

    for (final song in _downloadedSongs) {
      final path = song.filePath ?? (_cachedDownloadDirPath != null ? '$_cachedDownloadDirPath/${song.videoId}.mp3' : null);
      if (path != null && File(path).existsSync()) {
        valid.add(song);
      } else {
        changed = true;
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
    await verifyStorageIntegrity();
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
          final exts = ['mp3', 'm4a', 'aac', 'flac', 'ogg', 'opus', 'wav'];
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
  /// Fails OPEN: only a lookup that comes back with a definite "no such host"
  /// counts as offline. A slow DNS answer does not — this gate used to give up
  /// after 3 seconds and report "No network connection", which on a weak mobile
  /// connection rejected downloads that would have worked, while playback
  /// (which never consults this) kept streaming and made the refusal look
  /// nonsensical. If the network really is down, the transfer itself reports it
  /// with a far more accurate error than a DNS probe can.
  Future<bool> isNetworkAvailable() async {
    try {
      final result = await InternetAddress.lookup('google.com')
          .timeout(const Duration(seconds: 8));
      return result.isNotEmpty && result.first.rawAddress.isNotEmpty;
    } on TimeoutException {
      debugPrint('[DownloadService] DNS probe timed out — assuming online');
      return true;
    } catch (e) {
      debugPrint('[DownloadService] Network probe failed: $e');
      return false;
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

    // Check network first
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
      final dir = await _downloadDir;
      final audioFile = File('${dir.path}/${song.videoId}.mp3');
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

  /// Select the best audio stream based on user's quality preference
  AudioOnlyStreamInfo _pickStreamByQuality(StreamManifest manifest, AudioQuality quality) {
    final streams = manifest.audioOnly.toList();
    if (streams.isEmpty) throw Exception('No audio streams available');

    // Sort by bitrate ascending
    streams.sort((a, b) => a.bitrate.bitsPerSecond.compareTo(b.bitrate.bitsPerSecond));

    switch (quality) {
      case AudioQuality.low:
        // Pick lowest bitrate (~48-64kbps) — smallest file size
        return streams.first;

      case AudioQuality.medium:
        // Pick stream closest to 128kbps — good quality/size balance
        AudioOnlyStreamInfo? best;
        int bestDiff = 999999;
        for (final s in streams) {
          final diff = (s.bitrate.bitsPerSecond - 128000).abs();
          if (diff < bestDiff) {
            bestDiff = diff;
            best = s;
          }
        }
        return best ?? streams[streams.length ~/ 2];

      case AudioQuality.high:
        // Pick highest bitrate — best quality
        return streams.last;
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
  }) async {
    final dir = await _downloadDir;

    // Register a task up front so the existing UI (progress bar, speed, cancel)
    // works exactly as it does for the HTTP path. thumbFile points at the
    // hidden cover location because DownloadTask.cancel() deletes it.
    final task = DownloadTask(
      song: song,
      audioFile: File('${dir.path}/${song.videoId}.m4a'),
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

      // Move the finished artifacts out of staging into whichever location the
      // user has configured (app-internal, device internal, or SD card).
      final movedAudio =
          await _storageService.moveFile(result.audioPath, dir);
      if (movedAudio == null) {
        throw Exception('Could not move downloaded audio into $dir');
      }

      // The artwork the USER gets is the copy embedded inside the audio file by
      // yt-dlp (--embed-thumbnail), so the file is self-contained wherever it
      // ends up. This second copy is only the app's render cache, and it goes
      // into the hidden cover folder — beside the audio it would land in the
      // device Gallery.
      final coverDir = await _storageService.getCoverDir();
      String? movedThumb;
      if (result.thumbnailPath != null) {
        movedThumb =
            await _storageService.moveFile(result.thumbnailPath!, coverDir);
      }

      movedThumb ??= await _fetchSidecarThumbnail(song, coverDir);

      if (!result.thumbnailEmbedded && movedThumb != null && File(movedThumb).existsSync()) {
        try {
          final thumbFile = File(movedThumb);
          final bytes = await thumbFile.readAsBytes();
          final mime = movedThumb.toLowerCase().contains('.png') ? 'image/png' : 'image/jpeg';
          await ID3TagWriter.embedCoverArt(
            audioFile: File(movedAudio),
            imageBytes: bytes,
            mimeType: mime,
            title: song.title,
            artist: song.artist,
          );
        } catch (e) {
          debugPrint('[DownloadService] Cover embedding fallback error: $e');
        }
      }

      task.progress = 1.0;
      task.status = DownloadStatus.completed;
      _activeTasks.remove(song.videoId);
      if (onStateChanged != null) onStateChanged();

      await loadDownloads();
      _downloadedSongs.removeWhere((s) => s.videoId == song.videoId);
      _downloadedSongs.add(Song(
        id: song.id,
        videoId: song.videoId,
        title: song.title,
        artist: song.artist,
        thumbnailUrl: movedThumb ?? song.thumbnailUrl,
        highResThumbnailUrl: movedThumb ?? song.highResThumbnailUrl,
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

  /// Download the cover art on its own, for when yt-dlp produced no image.
  ///
  /// [dir] must be the hidden cover directory — never the download folder.
  /// Returns the local path, or null if the fetch failed.
  Future<String?> _fetchSidecarThumbnail(Song song, Directory dir) async {
    if (song.thumbnailUrl.isEmpty || !song.thumbnailUrl.startsWith('http')) {
      return null;
    }
    final client = HttpClient();
    try {
      final request = await client.getUrl(Uri.parse(song.thumbnailUrl));
      final response = await request.close();
      if (response.statusCode != HttpStatus.ok) return null;
      final bytes = await consolidateHttpClientResponseBytes(response);
      if (bytes.isEmpty) return null;
      final ext = song.thumbnailUrl.toLowerCase().contains('.png') ? 'png' : 'jpg';
      final file = File('${dir.path}/${song.videoId}.$ext');
      await file.writeAsBytes(bytes);
      return file.path;
    } catch (e) {
      debugPrint('[DownloadService] Sidecar thumbnail fetch failed: $e');
      return null;
    } finally {
      client.close();
    }
  }

  Future<void> _executeDownload(Song song, ValueChanged<double>? onProgress, {VoidCallback? onStateChanged, int attempt = 0, AudioQuality quality = AudioQuality.high}) async {
    final dir = await _downloadDir;
    final audioFile = File('${dir.path}/${song.videoId}.mp3');
    // The cover cache goes in the hidden folder, NEVER beside the audio — a
    // visible .jpg in the download folder ends up in the device Gallery.
    final thumbFile = await _coverFileFor(song.videoId);

    // Preferred path for YouTube: let yt-dlp + FFmpeg do the download, the
    // container conversion and the artwork embedding natively. Falls through to
    // the HTTP path below on any failure, so this can only add capability.
    if (_isYouTubeId(song.videoId)) {
      try {
        final ok = await _executeYtDlpDownload(
          song,
          onProgress,
          onStateChanged: onStateChanged,
          quality: quality,
        );
        if (ok) return;
      } catch (e) {
        debugPrint('[DownloadService] yt-dlp path failed for ${song.title}: $e '
            '— falling back to direct HTTP download');
      }
    }

    try {
      // 1. Resolve stream URL using StreamResolverService (works for JioSaavn, YouTube, Jamendo, etc.)
      late final Uri streamUrl;
      int totalBytes = 0;
      Map<String, String>? headers;

      final resolved = await StreamResolverService().resolve(song);
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

      await task.start(streamUrl, totalBytes, headers: headers);

      // Clean up task from active list
      _activeTasks.remove(song.videoId);

      // 3. Cover art. Try to EMBED it into the audio file first (ID3/APIC —
      // only possible for real MP3 containers); the on-disk copy is the app's
      // render cache and lives in the hidden cover folder so it never appears
      // in the device Gallery.
      final thumbHttpClient = HttpClient();
      try {
        final request = await thumbHttpClient.getUrl(Uri.parse(song.thumbnailUrl));
        final response = await request.close();
        if (response.statusCode == HttpStatus.ok) {
          final List<int> bytes = await consolidateHttpClientResponseBytes(response);
          await thumbFile.writeAsBytes(bytes);

          // Embed cover art into the downloaded audio file
          if (bytes.isNotEmpty && await audioFile.exists()) {
            final mime = song.thumbnailUrl.toLowerCase().contains('.png') ? 'image/png' : 'image/jpeg';
            await ID3TagWriter.embedCoverArt(
              audioFile: audioFile,
              imageBytes: Uint8List.fromList(bytes),
              mimeType: mime,
              title: song.title,
              artist: song.artist,
            );
          }
        }
      } catch (e) {
        debugPrint('Error downloading thumbnail: $e');
      } finally {
        thumbHttpClient.close();
      }

      // 4. Container validation & extension normalization
      final validFilePath = await detectAndFixAudioContainer(audioFile);

      // Update metadata
      await loadDownloads();
      _downloadedSongs.removeWhere((s) => s.videoId == song.videoId);

      // Update song with local paths including the physical validFilePath
      final localSong = Song(
        id: song.id,
        videoId: song.videoId,
        title: song.title,
        artist: song.artist,
        thumbnailUrl: thumbFile.path,
        highResThumbnailUrl: thumbFile.path,
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
      // Retry logic
      if (attempt < maxRetries - 1) {
        debugPrint('Download attempt ${attempt + 1} failed for ${song.title}, retrying...');
        final task = _activeTasks[song.videoId];
        if (task != null) {
          task.status = DownloadStatus.retrying;
          task.retryCount = attempt + 1;
          task.errorMessage = 'Retrying (${attempt + 2}/$maxRetries)...';
          if (onStateChanged != null) onStateChanged();
        }
        await Future.delayed(Duration(seconds: 2 * (attempt + 1)));
        return _executeDownload(song, onProgress, onStateChanged: onStateChanged, attempt: attempt + 1, quality: quality);
      }

      // Final failure
      final task = _activeTasks[song.videoId];
      if (task != null) {
        task.status = DownloadStatus.failed;
        task.errorMessage = e.toString();
        task.retryCount = attempt + 1;
        if (onStateChanged != null) onStateChanged();
      }
      debugPrint('Download error after $maxRetries attempts: $e');
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
      final sidecarCover = await _coverFileFor(videoId);

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
      if (await sidecarCover.exists()) {
        await sidecarCover.delete();
      }

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
