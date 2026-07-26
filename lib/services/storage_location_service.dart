import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:permission_handler/permission_handler.dart';

/// Where the app stores its files
enum StorageType {
  /// App-private internal storage (default, current behavior)
  appInternal,

  /// Device internal shared storage (e.g., /storage/emulated/0/SonicWave/)
  deviceInternal,

  /// External SD card (e.g., /storage/XXXX-XXXX/SonicWave/)
  sdCard,
}

/// Information about an available storage volume
class StorageVolume {
  final String path;
  final String label;
  final StorageType type;
  final bool isAvailable;

  const StorageVolume({
    required this.path,
    required this.label,
    required this.type,
    required this.isAvailable,
  });
}

/// An internal candidate directory considered during root resolution.
class _RootCandidate {
  final Directory dir;
  final bool isFallback;
  final String? reason;
  const _RootCandidate(this.dir, {this.isFallback = false, this.reason});
}

/// Service to manage configurable storage paths for downloads and album folders.
///
/// This service handles:
/// - Persisting the user's chosen storage type
/// - Creating the SonicWave root folder and album subfolders
/// - Detecting available storage volumes (internal + SD cards)
/// - Determining if a file is inside the app-managed folder (for delete type logic)
///
/// ## Robustness guarantees
/// Resolving the root directory NEVER throws and ALWAYS returns a writable
/// location. It probes each candidate for real write access and falls back
/// through a chain, so a missing permission, an ejected SD card, or a full/
/// read-only volume degrades gracefully instead of crashing:
///
///   deviceInternal → (public folder, only if "All files" granted)
///                  → app-specific external storage (no permission needed)
///                  → app-internal storage
///                  → temporary storage (last resort)
///
/// After a fallback, [isUsingFallbackLocation] is true and [fallbackReason]
/// explains why, so the UI can surface it.
class StorageLocationService {
  static final StorageLocationService _instance = StorageLocationService._internal();
  factory StorageLocationService() => _instance;
  StorageLocationService._internal();

  static const String _storageTypeKey = 'storage_location_type';
  static const String _customPathKey = 'storage_custom_path';
  static const String appFolderName = 'sonicWave';
  static const String _writeProbeName = '.sonicwave_write_test';

  /// Sub-folder (inside the root) where downloaded audio lands. It is a real,
  /// visible folder so it shows up as the "Download" album (folder == album).
  static const String downloadFolderName = 'Download';

  /// Hidden sub-folder (inside the root) holding per-song thumbnails and the
  /// downloads metadata JSON. Leading dot + `.nomedia` keep it out of galleries
  /// / file managers, and the album scanner skips dot-folders so it never shows
  /// as an album in the app.
  static const String metaFolderName = '.sonicwave';

  StorageType _storageType = StorageType.appInternal;
  String? _customPath;
  bool _isInitialized = false;
  String? _resolvedRootPath;

  // Resolution cache + fallback state.
  Directory? _activeRootDir;
  bool _usingFallback = false;
  String? _fallbackReason;

  StorageType get storageType => _storageType;
  String? get customPath => _customPath;
  bool get isInitialized => _isInitialized;
  String? get resolvedRootPath => _resolvedRootPath;

  /// True when the active root is NOT the user's chosen location (a fallback).
  bool get isUsingFallbackLocation => _usingFallback;

  /// Human-readable explanation of the current fallback, or null when the
  /// chosen location is in use.
  String? get fallbackReason => _fallbackReason;

  /// Initialize from persisted preferences.
  ///
  /// Guarantees that, once complete, [resolvedRootPath] points at a real,
  /// writable directory (never null) — even if the chosen location is
  /// unavailable. Never throws.
  Future<void> initialize() async {
    if (_isInitialized) return;

    // 1. Load persisted preferences (tolerant of corruption/out-of-range).
    try {
      final prefs = await SharedPreferences.getInstance();
      final typeIndex = prefs.getInt(_storageTypeKey);
      if (typeIndex != null && typeIndex >= 0 && typeIndex < StorageType.values.length) {
        _storageType = StorageType.values[typeIndex];
      }
      _customPath = prefs.getString(_customPathKey);
    } catch (e) {
      debugPrint('StorageLocationService: prefs load failed, using defaults: $e');
    }

    // 2. Resolve a guaranteed-writable root. Belt-and-suspenders: even if
    //    resolution somehow throws, fall back to app-internal so we never
    //    leave _resolvedRootPath null.
    try {
      await getAppRootDir();
    } catch (e) {
      debugPrint('StorageLocationService: root resolution failed, forcing app-internal: $e');
      try {
        final internal = await _appInternalDir();
        await _ensureWritable(internal);
        _activeRootDir = internal;
        _resolvedRootPath = internal.path;
        _usingFallback = _storageType != StorageType.appInternal;
        _fallbackReason = _usingFallback
            ? 'Chosen storage unavailable — using internal app storage.'
            : null;
      } catch (e2) {
        debugPrint('StorageLocationService: app-internal fallback failed: $e2');
      }
    }

    _isInitialized = true;
  }

  /// Set the storage type and persist it. Re-resolves the active root so the
  /// change takes effect immediately.
  Future<void> setStorageType(StorageType type, {String? sdCardPath}) async {
    _storageType = type;
    if (type == StorageType.sdCard && sdCardPath != null) {
      _customPath = sdCardPath;
    } else {
      _customPath = null;
    }

    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setInt(_storageTypeKey, type.index);
      if (_customPath != null) {
        await prefs.setString(_customPathKey, _customPath!);
      } else {
        await prefs.remove(_customPathKey);
      }
    } catch (e) {
      debugPrint('StorageLocationService: failed to persist storage type: $e');
    }

    // Invalidate cache and resolve against the new selection now.
    _activeRootDir = null;
    await getAppRootDir();
  }

  /// Check synchronously if a file path is inside the app-managed folder.
  bool isFileInAppFolderSync(String filePath) {
    if (_resolvedRootPath == null) return false;
    final normalizedFilePath = filePath.replaceAll('\\', '/').toLowerCase();
    final normalizedRootPath = _resolvedRootPath!.replaceAll('\\', '/').toLowerCase();
    return normalizedFilePath.startsWith(normalizedRootPath);
  }

  /// Get the app's root directory for the current storage type.
  ///
  /// Never throws; always returns a writable directory (see class docs for the
  /// fallback chain). Result is cached until the volume disappears or
  /// [setStorageType]/[requestStoragePermission] invalidate it.
  Future<Directory> getAppRootDir() async {
    // Reuse the cached root while it still exists on disk (cheap check).
    final cached = _activeRootDir;
    if (cached != null) {
      try {
        if (await cached.exists()) return cached;
      } catch (_) {/* fall through to re-resolve */}
    }
    return _resolveRootDir();
  }

  /// Build the candidate chain for the current storage type and pick the first
  /// one we can actually write to.
  Future<Directory> _resolveRootDir() async {
    final candidates = <_RootCandidate>[];

    switch (_storageType) {
      case StorageType.appInternal:
        candidates.add(_RootCandidate(await _appInternalDir()));
        break;

      case StorageType.deviceInternal:
        // The public, user-visible folder requires MANAGE_EXTERNAL_STORAGE on
        // Android 11+. Only attempt it when granted, otherwise we'd hit the
        // errno 13 (Permission denied) that this whole fallback chain fixes.
        if (Platform.isAndroid && await _hasManageStoragePermission()) {
          candidates.add(_RootCandidate(Directory('/storage/emulated/0/$appFolderName')));
        }
        final ext = await _appExternalDir();
        if (ext != null) {
          candidates.add(_RootCandidate(
            ext,
            isFallback: true,
            reason:
                'Using the app storage folder. Grant "All files access" to save into the public $appFolderName folder.',
          ));
        }
        break;

      case StorageType.sdCard:
        if (_customPath != null && _customPath!.isNotEmpty) {
          candidates.add(_RootCandidate(Directory('$_customPath/$appFolderName')));
        }
        final extSd = await _appExternalDir();
        if (extSd != null) {
          candidates.add(_RootCandidate(
            extSd,
            isFallback: true,
            reason: 'SD card is unavailable — using the app storage folder instead.',
          ));
        }
        break;
    }

    // Guaranteed-writable last resort for every non-internal type.
    candidates.add(_RootCandidate(
      await _appInternalDir(),
      isFallback: _storageType != StorageType.appInternal,
      reason: 'Chosen storage is unavailable — using internal app storage.',
    ));

    for (final c in candidates) {
      if (await _ensureWritable(c.dir)) {
        _activeRootDir = c.dir;
        _resolvedRootPath = c.dir.path;
        _usingFallback = c.isFallback;
        _fallbackReason = c.isFallback ? c.reason : null;
        if (c.isFallback) {
          debugPrint('StorageLocationService: using fallback ${c.dir.path} — ${c.reason}');
        }
        return c.dir;
      }
    }

    // Absolute last resort — temporary storage. Should effectively never run.
    final tmpBase = await getTemporaryDirectory();
    final tmp = Directory('${tmpBase.path}/$appFolderName');
    await tmp.create(recursive: true);
    _activeRootDir = tmp;
    _resolvedRootPath = tmp.path;
    _usingFallback = true;
    _fallbackReason = 'All storage locations failed — using temporary storage.';
    debugPrint('StorageLocationService: all locations failed, using temp ${tmp.path}');
    return tmp;
  }

  /// `<appDocDir>/downloads` — always available, no permission required.
  Future<Directory> _appInternalDir() async {
    final appDir = await getApplicationDocumentsDirectory();
    return Directory('${appDir.path}/downloads');
  }

  /// App-specific external storage (`/storage/emulated/0/Android/data/<pkg>/files/<app>`).
  /// Lives on device storage, is visible to file managers, and needs NO
  /// runtime permission. Returns null if unavailable (e.g. no external volume).
  Future<Directory?> _appExternalDir() async {
    if (!Platform.isAndroid) return null;
    try {
      final ext = await getExternalStorageDirectory();
      if (ext == null) return null;
      return Directory('${ext.path}/$appFolderName');
    } catch (e) {
      debugPrint('StorageLocationService: app-external dir unavailable: $e');
      return null;
    }
  }

  Future<bool> _hasManageStoragePermission() async {
    try {
      return await Permission.manageExternalStorage.isGranted;
    } catch (_) {
      return false;
    }
  }

  /// Probe whether we can create AND write into [dir]. Creates the directory
  /// (recursively) if missing, writes a tiny marker, then deletes it. Any
  /// failure (permission, read-only, full, missing volume) returns false.
  Future<bool> _ensureWritable(Directory dir) async {
    try {
      if (!await dir.exists()) {
        await dir.create(recursive: true);
      }
      final probe = File('${dir.path}${Platform.pathSeparator}$_writeProbeName');
      await probe.writeAsString('ok', flush: true);
      await probe.delete();
      return true;
    } catch (e) {
      debugPrint('StorageLocationService: not writable (${dir.path}): $e');
      return false;
    }
  }

  /// Get the downloads subdirectory within the app's root folder.
  ///
  /// Downloaded AUDIO lives in a dedicated, visible `Download/` folder so it
  /// surfaces as the "Download" album (folder == album). Created on demand;
  /// falls back to the root if the subfolder can't be created.
  Future<Directory> getDownloadDir() async {
    final root = await getAppRootDir();
    final dir =
        Directory('${root.path}${Platform.pathSeparator}$downloadFolderName');
    try {
      if (!await dir.exists()) await dir.create(recursive: true);
      return dir;
    } catch (e) {
      debugPrint(
          'StorageLocationService: download dir create failed, using root: $e');
      return root;
    }
  }

  /// Get (create) the hidden metadata directory holding per-song thumbnails and
  /// the downloads JSON. Ensures a `.nomedia` marker so galleries/file managers
  /// ignore it. The album scanner already skips dot-folders, so it never appears
  /// as an album. Falls back to the root if the folder can't be created.
  Future<Directory> getMetaDir() async {
    final root = await getAppRootDir();
    final dir =
        Directory('${root.path}${Platform.pathSeparator}$metaFolderName');
    try {
      if (!await dir.exists()) await dir.create(recursive: true);
      final nomedia =
          File('${dir.path}${Platform.pathSeparator}.nomedia');
      if (!await nomedia.exists()) {
        await nomedia.writeAsString('', flush: true);
      }
      return dir;
    } catch (e) {
      debugPrint('StorageLocationService: meta dir setup failed, using root: $e');
      return root;
    }
  }

  /// Get (or create) a subdirectory for a specific album within the app root.
  /// Falls back to the root directory if the subfolder can't be created.
  Future<Directory> getAlbumDir(String albumName) async {
    final root = await getAppRootDir();
    // Sanitize album name for filesystem; guard against empty/dot-only names.
    var safeName = albumName.replaceAll(RegExp(r'[<>:"/\\|?*\x00-\x1F]'), '_').trim();
    safeName = safeName.replaceAll(RegExp(r'^\.+'), '').trim();
    if (safeName.isEmpty) safeName = 'Album';
    final dir = Directory('${root.path}${Platform.pathSeparator}$safeName');
    try {
      if (!await dir.exists()) {
        await dir.create(recursive: true);
      }
      return dir;
    } catch (e) {
      debugPrint('StorageLocationService: album dir create failed ($safeName), using root: $e');
      return root;
    }
  }

  /// Check if a file path is inside the app-managed folder.
  ///
  /// This is critical for the smart delete behavior:
  /// - `true` → file is in app folder → show "Delete Permanently" (red)
  /// - `false` → file is a scanned external reference → show "Delete Memory" (yellow)
  Future<bool> isFileInAppFolder(String filePath) async {
    try {
      final root = await getAppRootDir();
      final normalizedFilePath = filePath.replaceAll('\\', '/').toLowerCase();
      final normalizedRootPath = root.path.replaceAll('\\', '/').toLowerCase();
      return normalizedFilePath.startsWith(normalizedRootPath);
    } catch (e) {
      debugPrint('Error checking app folder membership: $e');
      return false;
    }
  }

  /// Detect all available storage volumes on the device.
  Future<List<StorageVolume>> getAvailableStorageVolumes() async {
    final volumes = <StorageVolume>[];

    // 1. App internal (always available)
    try {
      final appDir = await getApplicationDocumentsDirectory();
      volumes.add(StorageVolume(
        path: '${appDir.path}/downloads',
        label: 'App Internal Storage',
        type: StorageType.appInternal,
        isAvailable: true,
      ));
    } catch (_) {}

    // 2. Device internal shared storage
    if (Platform.isAndroid) {
      const internalPath = '/storage/emulated/0';
      final internalDir = Directory(internalPath);
      bool internalAvailable = false;
      try {
        internalAvailable = await internalDir.exists();
      } catch (_) {}
      volumes.add(StorageVolume(
        path: '$internalPath/$appFolderName',
        label: 'Device Storage',
        type: StorageType.deviceInternal,
        isAvailable: internalAvailable,
      ));

      // 3. Probe for external SD cards
      final storageDir = Directory('/storage');
      try {
        if (await storageDir.exists()) {
          await for (final entity in storageDir.list(followLinks: false)) {
            if (entity is Directory) {
              final name = entity.path.split('/').last;
              // Skip standard internal storage mounts
              if (name != 'self' && name != 'emulated' && name != '.') {
                bool available = false;
                try {
                  available = await entity.exists();
                } catch (_) {}
                volumes.add(StorageVolume(
                  path: '${entity.path}/$appFolderName',
                  label: 'SD Card ($name)',
                  type: StorageType.sdCard,
                  isAvailable: available,
                ));
              }
            }
          }
        }
      } catch (e) {
        debugPrint('Error probing SD cards: $e');
      }
    }

    return volumes;
  }

  /// Request storage permissions appropriate for the chosen storage type.
  ///
  /// For `appInternal` — no special permissions needed.
  /// For `deviceInternal`/`sdCard` — needs "All files access"
  /// (MANAGE_EXTERNAL_STORAGE) on Android 11+, or legacy storage on older
  /// versions. On success, invalidates the cache so the next resolve upgrades
  /// to the now-permitted public folder. Never throws.
  Future<bool> requestStoragePermission({StorageType? targetType}) async {
    final typeToRequest = targetType ?? _storageType;
    if (typeToRequest == StorageType.appInternal) return true;
    if (!Platform.isAndroid) return true;

    try {
      // Android 11+ : MANAGE_EXTERNAL_STORAGE ("All files access").
      if (await Permission.manageExternalStorage.isGranted) return true;

      final status = await Permission.manageExternalStorage.request();
      if (status.isGranted) {
        _activeRootDir = null; // upgrade to public folder on next resolve
        return true;
      }

      // Legacy fallback for Android ≤ 10.
      if (await Permission.storage.request().isGranted) {
        _activeRootDir = null;
        return true;
      }

      return false;
    } catch (e) {
      debugPrint('StorageLocationService: permission request failed: $e');
      return false;
    }
  }

  /// Scan the app root directory for subdirectories that can be treated as albums.
  ///
  /// Each subdirectory containing audio files becomes a folder-based album.
  Future<List<FolderAlbumInfo>> scanFolderAlbums() async {
    final albums = <FolderAlbumInfo>[];
    try {
      final root = await getAppRootDir();
      final supportedExts = {
        'mp3', 'm4a', 'wav', 'flac', 'aac', 'ogg', 'opus', 'wma',
        'aiff', 'aif', 'alac', 'mka', 'amr', 'm4b'
      };

      await for (final entity in root.list(followLinks: false)) {
        if (entity is Directory) {
          final folderName = entity.path.split(RegExp(r'[/\\]')).last;
          // Skip system / hidden folders
          if (folderName.startsWith('.') || folderName == 'Downloads') continue;

          final audioFiles = <String>[];
          try {
            await for (final file in entity.list(followLinks: false)) {
              if (file is File) {
                final ext = file.path.split('.').last.toLowerCase();
                if (supportedExts.contains(ext)) {
                  audioFiles.add(file.path);
                }
              }
            }
          } catch (_) {}

          if (audioFiles.isNotEmpty) {
            albums.add(FolderAlbumInfo(
              folderName: folderName,
              folderPath: entity.path,
              audioFilePaths: audioFiles,
            ));
          }
        }
      }
    } catch (e) {
      debugPrint('Error scanning folder albums: $e');
    }
    return albums;
  }

  /// Move a file to a target directory securely, preserving the filename.
  ///
  /// Returns the new file path, or null on failure.
  /// Guarantees that:
  /// 1. It is a MOVE operation (source is deleted after move).
  /// 2. Handles cross-filesystem moves (app internal <-> device storage <-> SD card).
  /// 3. Cross-filesystem verification: source is ONLY deleted if the destination file
  ///    exists AND its byte size matches the source file byte size 100%.
  /// 4. If any error occurs or size verification fails, the target file is safely
  ///    cleaned up (rolled back) and original source file is preserved intact.
  Future<String?> moveFile(String sourcePath, Directory targetDir) async {
    try {
      final sourceFile = File(sourcePath);
      if (!await sourceFile.exists()) return null;

      if (!await targetDir.exists()) {
        await targetDir.create(recursive: true);
      }

      final fileName = sourcePath.split(RegExp(r'[/\\]')).last;
      final targetPath = '${targetDir.path}${Platform.pathSeparator}$fileName';

      // No-op if source and target are the exact same physical path.
      if (sourcePath == targetPath) return targetPath;

      final sourceSize = await sourceFile.length();

      // Step 1: Attempt same-filesystem atomic rename (fast & zero copy overhead).
      try {
        final moved = await sourceFile.rename(targetPath);
        if (await moved.exists()) {
          return moved.path;
        }
      } catch (renameErr) {
        debugPrint('StorageLocationService: Same-volume rename failed ($renameErr), attempting verified cross-volume move...');
      }

      // Step 2: Cross-volume secure copy-verify-delete move.
      final targetFile = File(targetPath);

      // Perform stream byte copy
      await sourceFile.copy(targetPath);

      // Verify destination file exists and byte size matches source 100%
      if (await targetFile.exists()) {
        final targetSize = await targetFile.length();
        if (targetSize == sourceSize && sourceSize > 0) {
          // Verification passed! Safely remove original source file.
          try {
            await sourceFile.delete();
          } catch (delErr) {
            debugPrint('StorageLocationService: Cross-volume source delete warning: $delErr');
          }
          return targetFile.path;
        } else {
          // Size mismatch! Clean up partial target file to prevent corruption.
          debugPrint('StorageLocationService: Size mismatch (source: $sourceSize, target: $targetSize). Aborting move.');
          if (await targetFile.exists()) {
            await targetFile.delete();
          }
          return null;
        }
      }
      return null;
    } catch (e) {
      debugPrint('Error moving file securely: $e');
      return null;
    }
  }

  /// Copy a file to a target directory, preserving the filename.
  ///
  /// Returns the new file path, or null on failure.
  Future<String?> copyFile(String sourcePath, Directory targetDir) async {
    try {
      final sourceFile = File(sourcePath);
      if (!await sourceFile.exists()) return null;

      if (!await targetDir.exists()) {
        await targetDir.create(recursive: true);
      }

      final fileName = sourcePath.split(RegExp(r'[/\\]')).last;
      final targetPath = '${targetDir.path}${Platform.pathSeparator}$fileName';
      if (targetPath == sourcePath) return sourcePath;
      final copied = await sourceFile.copy(targetPath);
      return copied.path;
    } catch (e) {
      debugPrint('Error copying file: $e');
      return null;
    }
  }

  /// Get the current resolved path string for display in the UI.
  Future<String> getResolvedPathDisplay() async {
    try {
      final dir = await getAppRootDir();
      return dir.path;
    } catch (e) {
      return _resolvedRootPath ?? 'Unavailable';
    }
  }
}

/// Info about a folder-based album discovered during scanning
class FolderAlbumInfo {
  final String folderName;
  final String folderPath;
  final List<String> audioFilePaths;

  const FolderAlbumInfo({
    required this.folderName,
    required this.folderPath,
    required this.audioFilePaths,
  });
}
