import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';
import 'package:flutter_cache_manager/flutter_cache_manager.dart';
import 'package:path_provider/path_provider.dart';

import 'download_service.dart';
import 'storage_location_service.dart';
import 'stream_cache_service.dart';

/// Breakdown of disk usage across every storage category SonicWave owns.
class StorageBreakdown {
  /// Audio files in the Download folder & registered download index.
  final int downloadedSongs;

  /// Audio files inside custom album sub-folders.
  final int albumFolders;

  /// Streamed audio cached by [StreamCacheService].
  final int streamCache;

  /// `flutter_cache_manager` disk cache & network image cache.
  final int imageCache;

  /// Embedded / extracted cover art in `localart/` and native fallback art.
  final int coverArt;

  /// JSON metadata indices, local_meta_index, SharedPreferences, etc.
  final int metadata;

  const StorageBreakdown({
    this.downloadedSongs = 0,
    this.albumFolders = 0,
    this.streamCache = 0,
    this.imageCache = 0,
    this.coverArt = 0,
    this.metadata = 0,
  });

  int get total =>
      downloadedSongs +
      albumFolders +
      streamCache +
      imageCache +
      coverArt +
      metadata;

  /// Total clearable cache (everything except downloaded songs & albums).
  int get clearable => streamCache + imageCache + coverArt + metadata;
}

/// Scans every SonicWave-managed directory and reports byte usage.
///
/// Designed to be called from the UI on demand (tap to refresh / after clear).
/// All IO is async; exceptions are swallowed so the caller always gets a result.
class StorageAnalyzer {
  StorageAnalyzer._();
  static final StorageAnalyzer instance = StorageAnalyzer._();

  /// Walk every known storage location and sum file sizes accurately.
  Future<StorageBreakdown> analyze() async {
    int downloadedSongs = 0;
    int albumFolders = 0;
    int streamCacheBytes = 0;
    int imageCacheBytes = 0;
    int coverArtBytes = 0;
    int metadataBytes = 0;

    final storage = StorageLocationService();
    final countedPaths = <String>{};

    // 1. Downloaded songs — sum indexed songs from DownloadService + files in <root>/Download/
    try {
      final songs = await DownloadService().getDownloadedSongs();
      for (final song in songs) {
        if (song.filePath != null && song.filePath!.isNotEmpty) {
          final normalized = song.filePath!.replaceAll('\\', '/').toLowerCase();
          if (!countedPaths.contains(normalized)) {
            final f = File(song.filePath!);
            if (await f.exists()) {
              downloadedSongs += await f.length();
              countedPaths.add(normalized);
            }
          }
        }
      }
    } catch (_) {}

    try {
      final dlDir = await storage.getDownloadDir();
      if (await dlDir.exists()) {
        await for (final entity in dlDir.list(
          recursive: true,
          followLinks: false,
        )) {
          if (entity is File) {
            final normalized = entity.path.replaceAll('\\', '/').toLowerCase();
            if (!countedPaths.contains(normalized)) {
              try {
                downloadedSongs += await entity.length();
                countedPaths.add(normalized);
              } catch (_) {}
            }
          }
        }
      }
    } catch (_) {}

    // 2. Album sub-folders — every visible child of root that isn't Download/ or .sonicwave/
    try {
      final root = await storage.getAppRootDir();
      final dlName = StorageLocationService.downloadFolderName;
      final metaName = StorageLocationService.metaFolderName;
      if (await root.exists()) {
        await for (final entity in root.list(followLinks: false)) {
          if (entity is Directory) {
            final name = entity.path.split(RegExp(r'[/\\]')).last;
            if (name == dlName || name == metaName || name.startsWith('.')) {
              continue;
            }
            albumFolders += await _dirSize(entity);
          }
        }
      }
    } catch (_) {}

    // 3. Stream cache
    try {
      streamCacheBytes = await StreamCacheService().size();
    } catch (_) {}

    // 4. Image cache (flutter_cache_manager + disk image caches)
    try {
      imageCacheBytes = await _flutterCacheSize();
    } catch (_) {}

    // 5. Cover art — localart/ + native_art_* (temporary cover caches)
    try {
      final support = await getApplicationSupportDirectory();
      final localArt = Directory(
        '${support.path}${Platform.pathSeparator}localart',
      );
      coverArtBytes += await _dirSize(localArt);
    } catch (_) {}
    try {
      final cacheDir = await getTemporaryDirectory();
      if (await cacheDir.exists()) {
        await for (final f in cacheDir.list(followLinks: false)) {
          if (f is File && f.path.contains('native_art_')) {
            try {
              coverArtBytes += await f.length();
            } catch (_) {}
          }
        }
      }
    } catch (_) {}

    // 6. Metadata — .sonicwave/ minus covers/ + local_meta_index.json
    try {
      final metaDir = await storage.getMetaDir();
      final coverDir = await storage.getCoverDir();
      final totalMeta = await _dirSize(metaDir);
      final coverInMeta = await _dirSize(coverDir);
      metadataBytes += (totalMeta - coverInMeta).clamp(0, totalMeta);
    } catch (_) {}
    try {
      final support = await getApplicationSupportDirectory();
      final indexFile = File(
        '${support.path}${Platform.pathSeparator}local_meta_index.json',
      );
      if (await indexFile.exists()) {
        metadataBytes += await indexFile.length();
      }
    } catch (_) {}

    return StorageBreakdown(
      downloadedSongs: downloadedSongs,
      albumFolders: albumFolders,
      streamCache: streamCacheBytes,
      imageCache: imageCacheBytes,
      coverArt: coverArtBytes,
      metadata: metadataBytes,
    );
  }

  /// Clear ALL clearable caches (stream + image + temporary cover art).
  /// Does NOT touch downloaded songs, album folders, or downloaded song covers.
  Future<void> clearAllCaches() async {
    await clearStreamCache();
    await clearImageCache();
    await clearCoverArt();
  }

  /// Clear the stream cache.
  Future<void> clearStreamCache() async {
    try {
      await StreamCacheService().clear();
    } catch (e) {
      debugPrint('[StorageAnalyzer] clearStreamCache failed: $e');
    }
  }

  /// Clear all image caches (flutter_cache_manager + in-memory + physical disk files).
  Future<void> clearImageCache() async {
    try {
      PaintingBinding.instance.imageCache.clear();
      PaintingBinding.instance.imageCache.clearLiveImages();
    } catch (_) {}
    try {
      await DefaultCacheManager().emptyCache();
    } catch (e) {
      debugPrint('[StorageAnalyzer] clearImageCache emptyCache failed: $e');
    }
    // Delete files physically from disk image cache folders to guarantee 0 B result
    try {
      final tempDir = await getTemporaryDirectory();
      final cacheDirs = [
        Directory('${tempDir.path}${Platform.pathSeparator}libCachedImageData'),
        Directory(
          '${tempDir.path}${Platform.pathSeparator}flutter_cache_manager',
        ),
      ];
      for (final dir in cacheDirs) {
        if (await dir.exists()) {
          await dir.delete(recursive: true);
        }
      }
    } catch (e) {
      debugPrint(
        '[StorageAnalyzer] physical image cache directory delete failed: $e',
      );
    }
  }

  /// Clear temporary extracted cover art (localart + native_art_*).
  /// Note: Keeps offline song covers in .sonicwave/covers/ safe.
  Future<void> clearCoverArt() async {
    try {
      final support = await getApplicationSupportDirectory();
      final localArt = Directory(
        '${support.path}${Platform.pathSeparator}localart',
      );
      if (await localArt.exists()) {
        await localArt.delete(recursive: true);
      }
    } catch (e) {
      debugPrint('[StorageAnalyzer] clearLocalArt failed: $e');
    }
    try {
      final cacheDir = await getTemporaryDirectory();
      if (await cacheDir.exists()) {
        await for (final f in cacheDir.list(followLinks: false)) {
          if (f is File && f.path.contains('native_art_')) {
            try {
              await f.delete();
            } catch (_) {}
          }
        }
      }
    } catch (e) {
      debugPrint('[StorageAnalyzer] clearNativeArt failed: $e');
    }
  }

  // ── Helpers ──────────────────────────────────────────────────────────────

  /// Recursively sum all file sizes in [dir].
  static Future<int> _dirSize(Directory dir) async {
    int total = 0;
    try {
      if (!await dir.exists()) return 0;
      await for (final entity in dir.list(
        recursive: true,
        followLinks: false,
      )) {
        if (entity is File) {
          try {
            total += await entity.length();
          } catch (_) {}
        }
      }
    } catch (_) {}
    return total;
  }

  /// Size of flutter_cache_manager's on-disk cache + temp image caches.
  static Future<int> _flutterCacheSize() async {
    int total = 0;
    try {
      final tempDir = await getTemporaryDirectory();
      final dirs = [
        Directory('${tempDir.path}${Platform.pathSeparator}libCachedImageData'),
        Directory(
          '${tempDir.path}${Platform.pathSeparator}flutter_cache_manager',
        ),
      ];
      for (final d in dirs) {
        total += await _dirSize(d);
      }
    } catch (_) {}
    return total;
  }

  /// Format bytes into a human-readable string.
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
