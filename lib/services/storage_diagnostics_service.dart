import 'dart:async';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';
import 'package:flutter_cache_manager/flutter_cache_manager.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/song.dart';
import '../providers/player_provider.dart';
import 'download_service.dart';
import 'local_metadata_service.dart';
import 'mediastore_scanner.dart';
import 'storage_location_service.dart';
import 'stream_cache_service.dart';
import 'ytdlp_downloader.dart';

/// Performance & Storage Statistics Model.
class StorageStats {
  final int imageCacheBytes;
  final int streamCacheBytes;
  final int stagingBytes;
  final int downloadedMusicBytes;
  final int searchHistoryCount;
  final int playbackHistoryCount;
  final int downloadedSongsCount;

  int get totalCacheBytes => imageCacheBytes + streamCacheBytes + stagingBytes;

  const StorageStats({
    this.imageCacheBytes = 0,
    this.streamCacheBytes = 0,
    this.stagingBytes = 0,
    this.downloadedMusicBytes = 0,
    this.searchHistoryCount = 0,
    this.playbackHistoryCount = 0,
    this.downloadedSongsCount = 0,
  });

  static String formatBytes(int bytes) {
    if (bytes <= 0) return '0 B';
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    if (bytes < 1024 * 1024 * 1024) {
      return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
    }
    return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(2)} GB';
  }
}

/// Detailed results of a Storage Library Deep Repair & Diagnostic.
class StorageRepairReport {
  final int totalScanned;
  final int verifiedTracks;
  final int recoveredTracks;
  final int containersRepaired;
  final int ghostTracksPurged;
  final int junkFilesCleaned;
  final int albumsSynced;
  final int bytesFreed;

  const StorageRepairReport({
    this.totalScanned = 0,
    this.verifiedTracks = 0,
    this.recoveredTracks = 0,
    this.containersRepaired = 0,
    this.ghostTracksPurged = 0,
    this.junkFilesCleaned = 0,
    this.albumsSynced = 0,
    this.bytesFreed = 0,
  });

  String get formattedBytesFreed => StorageStats.formatBytes(bytesFreed);
}

/// Centralized Diagnostic, Cleanup, and Integrity Repair Engine for SonicWave.
class StorageDiagnosticsService {
  static final StorageDiagnosticsService _instance =
      StorageDiagnosticsService._internal();
  factory StorageDiagnosticsService() => _instance;
  StorageDiagnosticsService._internal();

  /// Inspect storage and calculate sizes of each component.
  Future<StorageStats> getStorageStats({
    int recentSearches = 0,
    int playbackHistory = 0,
  }) async {
    int imageBytes = 0;
    int streamBytes = 0;
    int stagingBytes = 0;
    int downloadedBytes = 0;
    int downloadedCount = 0;

    // 1. Image Cache Size
    try {
      final tempDir = await getTemporaryDirectory();
      await for (final entity in tempDir.list(recursive: true)) {
        if (entity is File) {
          final p = entity.path.toLowerCase();
          if (p.contains('cache') ||
              p.endsWith('.jpg') ||
              p.endsWith('.jpeg') ||
              p.endsWith('.png') ||
              p.endsWith('.webp')) {
            try {
              imageBytes += await entity.length();
            } catch (_) {}
          }
        }
      }
    } catch (_) {}

    // 2. Stream Audio Cache Size
    try {
      streamBytes = await StreamCacheService().size();
    } catch (_) {}

    // 3. Staging Files Size
    try {
      final staging = await YtDlpDownloader.stagingDir();
      if (await staging.exists()) {
        await for (final entity in staging.list(recursive: false)) {
          if (entity is File) {
            try {
              stagingBytes += await entity.length();
            } catch (_) {}
          }
        }
      }
    } catch (_) {}

    // 4. Downloaded Songs Size & Count
    try {
      final downloadService = DownloadService();
      await downloadService.loadDownloads();
      final songs = await downloadService.getDownloadedSongs();
      downloadedCount = songs.length;
      for (final s in songs) {
        final path = s.filePath;
        if (path != null && path.isNotEmpty) {
          final f = File(path);
          if (await f.exists()) {
            try {
              downloadedBytes += await f.length();
            } catch (_) {}
          }
        }
      }
    } catch (_) {}

    return StorageStats(
      imageCacheBytes: imageBytes,
      streamCacheBytes: streamBytes,
      stagingBytes: stagingBytes,
      downloadedMusicBytes: downloadedBytes,
      searchHistoryCount: recentSearches,
      playbackHistoryCount: playbackHistory,
      downloadedSongsCount: downloadedCount,
    );
  }

  /// 1. Clear Image Cache
  Future<int> clearImageCache() async {
    int freed = 0;
    try {
      PaintingBinding.instance.imageCache.clear();
      PaintingBinding.instance.imageCache.clearLiveImages();
      await DefaultCacheManager().emptyCache();

      final tempDir = await getTemporaryDirectory();
      await for (final entity in tempDir.list(recursive: true)) {
        if (entity is File) {
          final p = entity.path.toLowerCase();
          if (p.contains('cache') ||
              p.contains('image_picker') ||
              p.endsWith('.jpg') ||
              p.endsWith('.jpeg') ||
              p.endsWith('.png') ||
              p.endsWith('.webp')) {
            try {
              final len = await entity.length();
              await entity.delete();
              freed += len;
            } catch (_) {}
          }
        }
      }
    } catch (e) {
      debugPrint('[StorageDiagnostics] Error clearing image cache: $e');
    }
    return freed;
  }

  /// 2. Clear Stream Audio Cache
  Future<int> clearStreamCache() async {
    int freed = 0;
    try {
      freed = await StreamCacheService().size();
      await StreamCacheService().clear();
    } catch (e) {
      debugPrint('[StorageDiagnostics] Error clearing stream cache: $e');
    }
    return freed;
  }

  /// 3. Clear Staging & Orphaned Download Files
  Future<int> clearStagingFiles() async {
    int freed = 0;
    try {
      final staging = await YtDlpDownloader.stagingDir();
      if (await staging.exists()) {
        await for (final entity in staging.list(recursive: false)) {
          if (entity is File) {
            try {
              final len = await entity.length();
              await entity.delete();
              freed += len;
            } catch (_) {}
          }
        }
      }
    } catch (e) {
      debugPrint('[StorageDiagnostics] Error clearing staging files: $e');
    }
    return freed;
  }

  /// 4. Clear Search History
  Future<void> clearSearchHistory() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove('recent_searches_list');
    } catch (e) {
      debugPrint('[StorageDiagnostics] Error clearing search history: $e');
    }
  }

  /// 5. Master Clean (All Caches & Temporary Files)
  Future<int> cleanAllCaches() async {
    final imgFreed = await clearImageCache();
    final streamFreed = await clearStreamCache();
    final stagingFreed = await clearStagingFiles();
    return imgFreed + streamFreed + stagingFreed;
  }

  /// 6. Deep Diagnostic & Storage Library Repair Engine
  Future<StorageRepairReport> repairAndResyncStorage({
    required PlayerProvider playerProvider,
  }) async {
    int totalScanned = 0;
    int verifiedTracks = 0;
    int recoveredTracks = 0;
    int containersRepaired = 0;
    int ghostPurged = 0;
    int junkCleaned = 0;
    int bytesFreed = 0;

    try {
      final downloadService = DownloadService();
      await downloadService.loadDownloads();

      // Step A: Self-healing container header & extension repair
      final preRepairList = await downloadService.getDownloadedSongs();
      final prePaths = {for (final s in preRepairList) s.id: s.filePath};
      await downloadService.repairCorruptedDownloads();
      final postRepairList = await downloadService.getDownloadedSongs();
      for (final s in postRepairList) {
        if (prePaths[s.id] != null && prePaths[s.id] != s.filePath) {
          containersRepaired++;
        }
      }

      final currentDownloads = postRepairList;
      final currentPaths = <String>{};
      for (final s in currentDownloads) {
        if (s.filePath != null && s.filePath!.isNotEmpty) {
          currentPaths.add(s.filePath!);
        }
      }

      // Step B: Purge Ghost Downloads from Metadata
      final initialCount = currentDownloads.length;
      await downloadService.verifyStorageIntegrity();
      final verifiedList = await downloadService.getDownloadedSongs();
      verifiedTracks = verifiedList.length;
      ghostPurged = initialCount - verifiedTracks;
      if (ghostPurged < 0) ghostPurged = 0;

      // Step C: Scan Physical Directory for Unindexed Audio & Recover Them
      final storageDir = await StorageLocationService().getDownloadDir();
      final audioExts = const [
        '.mp3',
        '.m4a',
        '.aac',
        '.flac',
        '.wav',
        '.ogg',
        '.opus',
        '.webm',
      ];

      if (await storageDir.exists()) {
        await for (final entity in storageDir.list(recursive: false)) {
          if (entity is File) {
            totalScanned++;
            final path = entity.path;
            final lower = path.toLowerCase();
            final len = await entity.length();

            // Check for zero-byte or broken partial files
            if (lower.endsWith('.part') ||
                lower.endsWith('.ytdl') ||
                lower.endsWith('.tmp') ||
                len == 0) {
              try {
                await entity.delete();
                junkCleaned++;
                bytesFreed += len;
              } catch (_) {}
              continue;
            }

            final isAudio = audioExts.any((ext) => lower.endsWith(ext));
            if (isAudio) {
              // If not tracked in download list, auto-recover it
              if (!currentPaths.contains(path)) {
                try {
                  final fileName =
                      path.split(Platform.pathSeparator).last;
                  final rawStem =
                      fileName.substring(0, fileName.lastIndexOf('.'));
                  final rawSong = Song(
                    id: 'rec_${DateTime.now().millisecondsSinceEpoch}_$rawStem',
                    videoId: path,
                    title: rawStem,
                    artist: 'Local Artist',
                    thumbnailUrl: '',
                    highResThumbnailUrl: '',
                    duration: Duration.zero,
                    filePath: path,
                  );

                  // Extract embedded ID3/AAC metadata
                  final enriched =
                      await LocalMetadataService().enrichSong(rawSong);
                  await downloadService.saveNewSongCopy(
                    enriched,
                    enriched,
                    path,
                  );
                  recoveredTracks++;
                  currentPaths.add(path);
                  debugPrint(
                      '[StorageDiagnostics] Recovered unindexed audio: ${enriched.title} ($path)');
                } catch (e) {
                  debugPrint(
                      '[StorageDiagnostics] Failed to recover file $path: $e');
                }
              }
            }
          }
        }
      }

      // Step D: Clean staging directory remnants & stream cache staging
      try {
        await StreamCacheService.cleanupStagingDirs();
      } catch (_) {}

      final staging = await YtDlpDownloader.stagingDir();
      if (await staging.exists()) {
        await for (final entity in staging.list(recursive: false)) {
          if (entity is File) {
            try {
              final len = await entity.length();
              await entity.delete();
              junkCleaned++;
              bytesFreed += len;
            } catch (_) {}
          }
        }
      }

      // Step E: Full PlayerProvider sync & Albums repair
      await playerProvider.verifyAndSyncAllStores();
      await playerProvider.loadDownloads();
      await playerProvider.scanLocalSongs();
      final albumsSynced = await playerProvider.syncAlbumsWithStorage();

      // Step F: Rescan public Android MediaStore
      if (await storageDir.exists()) {
        final samplePaths = <String>[];
        await for (final entity in storageDir.list(recursive: false)) {
          if (entity is File &&
              audioExts.any((ext) => entity.path.toLowerCase().endsWith(ext))) {
            samplePaths.add(entity.path);
            if (samplePaths.length >= 100) break;
          }
        }
        if (samplePaths.isNotEmpty) {
          await MediaStoreScanner.scanAll(samplePaths);
        }
      }

      return StorageRepairReport(
        totalScanned: totalScanned,
        verifiedTracks: verifiedTracks,
        recoveredTracks: recoveredTracks,
        containersRepaired: containersRepaired,
        ghostTracksPurged: ghostPurged,
        junkFilesCleaned: junkCleaned,
        albumsSynced: albumsSynced,
        bytesFreed: bytesFreed,
      );
    } catch (e) {
      debugPrint('[StorageDiagnostics] Storage repair failed: $e');
      return StorageRepairReport(
        totalScanned: totalScanned,
        verifiedTracks: verifiedTracks,
        recoveredTracks: recoveredTracks,
        containersRepaired: containersRepaired,
        ghostTracksPurged: ghostPurged,
        junkFilesCleaned: junkCleaned,
        albumsSynced: 0,
        bytesFreed: bytesFreed,
      );
    }
  }
}
