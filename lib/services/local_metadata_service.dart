import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:audio_metadata_reader/audio_metadata_reader.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

import '../models/song.dart';
import 'encoding_sanitizer.dart';

/// Reads REAL metadata (title / artist / album / duration / embedded cover art)
/// out of local audio files, so local songs show the file's own tag data and
/// its own embedded thumbnail instead of a filename guess + placeholder image.
///
/// - Pure Dart parsing via `audio_metadata_reader` (ID3v1/v2, FLAC, MP4/M4A,
///   OGG/Opus, WAV/AIFF, APE) — no platform channels needed.
/// - Extracted cover art is written once to app-internal storage
///   (`<support>/localart/<hash>.jpg`) and reused from a persisted JSON index,
///   keyed by path + file size + mtime, so rescans are instant and art
///   survives across sessions.
/// - Bulk scans parse inside a background isolate to keep the UI smooth.
class LocalMetadataService {
  static final LocalMetadataService _instance = LocalMetadataService._internal();
  factory LocalMetadataService() => _instance;
  LocalMetadataService._internal();

  Map<String, _CachedMeta>? _cache;
  Directory? _artDir;
  File? _indexFile;
  bool _dirty = false;
  Timer? _saveDebounce;

  Future<void> _ensureLoaded() async {
    if (_cache != null) return;
    try {
      final support = await getApplicationSupportDirectory();
      _artDir = Directory('${support.path}${Platform.pathSeparator}localart');
      if (!await _artDir!.exists()) {
        await _artDir!.create(recursive: true);
      }
      _indexFile =
          File('${support.path}${Platform.pathSeparator}local_meta_index.json');
      final loaded = <String, _CachedMeta>{};
      if (await _indexFile!.exists()) {
        final raw = json.decode(await _indexFile!.readAsString());
        // Entries hold titles that were already run through EncodingSanitizer,
        // and the staleness guard is size+mtime — which never changes when the
        // FIX is in our code rather than in the file. So a sanitizer revision
        // has to invalidate the index, or previously scanned songs keep their
        // old garbled titles forever. Legacy files have no version and are
        // dropped wholesale.
        if (raw is Map<String, dynamic> &&
            raw['v'] == EncodingSanitizer.version &&
            raw['e'] is Map<String, dynamic>) {
          (raw['e'] as Map<String, dynamic>).forEach((k, v) {
            if (v is Map<String, dynamic>) {
              loaded[k] = _CachedMeta.fromJson(v);
            }
          });
        } else {
          debugPrint('[LocalMeta] index dropped — sanitizer v'
              '${EncodingSanitizer.version} supersedes it; files will reparse');
        }
      }
      _cache = loaded;
    } catch (e) {
      debugPrint('[LocalMeta] index load failed: $e');
      _cache = {};
    }
  }

  void _scheduleSave() {
    _dirty = true;
    _saveDebounce?.cancel();
    _saveDebounce = Timer(const Duration(seconds: 2), () {
      _saveNow();
    });
  }

  Future<void> _saveNow() async {
    if (!_dirty || _cache == null || _indexFile == null) return;
    _dirty = false;
    try {
      final map = _cache!.map((k, v) => MapEntry(k, v.toJson()));
      await _indexFile!.writeAsString(
          json.encode({'v': EncodingSanitizer.version, 'e': map}));
    } catch (e) {
      debugPrint('[LocalMeta] index save failed: $e');
    }
  }

  /// Apply cached/parsed real metadata onto [song] (which must reference a
  /// local file). Falls back to the song's existing values field-by-field.
  Future<Song> enrichSong(Song song) async {
    final path = song.filePath ??
        (song.isLocalFile && !song.videoId.startsWith('local_')
            ? song.videoId
            : null);
    if (path == null || path.isEmpty) return song;
    final enriched = await enrichSongs([song]);
    return enriched.first;
  }

  /// Enrich a batch of local songs. Cache hits are applied instantly; misses
  /// are parsed together inside one background isolate (tag parsing is pure
  /// synchronous IO — running it on the main isolate would jank the UI on a
  /// full device scan).
  Future<List<Song>> enrichSongs(List<Song> songs) async {
    await _ensureLoaded();
    final cache = _cache!;
    final artDirPath = _artDir?.path ?? Directory.systemTemp.path;

    final result = List<Song>.of(songs);
    final toParse = <int, String>{}; // result index -> file path
    final cacheNeedNative = <int, String>{}; // result index -> path

    for (int i = 0; i < result.length; i++) {
      final s = result[i];
      final path = s.filePath ??
          (s.isLocalFile && !s.videoId.startsWith('local_') ? s.videoId : null);
      if (path == null || path.isEmpty) continue;

      FileStat? stat;
      try {
        stat = File(path).statSync();
      } catch (_) {}
      if (stat == null || stat.type == FileSystemEntityType.notFound) continue;

      final hit = cache[path];
      if (hit != null &&
          hit.sizeBytes == stat.size &&
          hit.mtimeMs == stat.modified.millisecondsSinceEpoch) {
        result[i] = _apply(s, hit);
        // Check if the cached result still has garbled CJK
        final applied = result[i];
        if (EncodingSanitizer.hasMojibakeCjk(applied.title) ||
            (applied.artist != 'Local Audio' && EncodingSanitizer.hasMojibakeCjk(applied.artist)) ||
            (applied.thumbnailUrl.isEmpty && applied.highResThumbnailUrl.isEmpty)) {
          cacheNeedNative[i] = path;
        }
      } else {
        toParse[i] = path;
      }
    }

    // Apply native fallback for cache hits that still have garbled data
    if (cacheNeedNative.isNotEmpty) {
      for (final entry in cacheNeedNative.entries) {
        final idx = entry.key;
        final path = entry.value;
        final song = result[idx];
        try {
          final nativeMeta = await _readNativeMetadata(path);
          if (nativeMeta != null) {
            final nTitle = nativeMeta['title'] as String?;
            final nArtist = nativeMeta['artist'] as String?;
            final nDurMs = (nativeMeta['durationMs'] as num?)?.toInt() ?? 0;
            final nArtPath = nativeMeta['artPath'] as String?;

            final updatedMeta = _CachedMeta(
              title: nTitle ?? cache[path]?.title,
              artist: nArtist ?? cache[path]?.artist,
              durationMs: nDurMs > 0 ? nDurMs : (cache[path]?.durationMs ?? 0),
              artPath: nArtPath ?? cache[path]?.artPath,
              sizeBytes: cache[path]?.sizeBytes ?? 0,
              mtimeMs: cache[path]?.mtimeMs ?? 0,
            );
            cache[path] = updatedMeta;
            result[idx] = _applyNative(song, updatedMeta,
                titleGarbled: EncodingSanitizer.hasMojibakeCjk(song.title),
                artistGarbled: song.artist != 'Local Audio' && EncodingSanitizer.hasMojibakeCjk(song.artist),
                missingArt: song.thumbnailUrl.isEmpty && song.highResThumbnailUrl.isEmpty);
            _dirty = true;
            debugPrint('[LocalMeta] Native fallback (cache) applied for: $path');
          }
        } catch (e) {
          debugPrint('[LocalMeta] Native fallback (cache) failed for $path: $e');
        }
      }
      if (_dirty) _scheduleSave();
    }

    if (toParse.isEmpty) return result;

    final paths = toParse.values.toList();
    List<Map<String, dynamic>> parsed;
    try {
      parsed = await Isolate.run(() => _parseFilesSync(paths, artDirPath));
    } catch (e) {
      // Isolates unavailable (e.g. some test envs) — parse inline.
      debugPrint('[LocalMeta] isolate parse failed, falling back inline: $e');
      parsed = _parseFilesSync(paths, artDirPath);
    }

    final indices = toParse.keys.toList();
    for (int j = 0; j < parsed.length && j < indices.length; j++) {
      final meta = _CachedMeta.fromJson(parsed[j]);
      cache[paths[j]] = meta;
      result[indices[j]] = _apply(result[indices[j]], meta);
    }

    // Second pass: for songs whose Dart-parsed metadata is still garbled CJK
    // mojibake, fall back to Android's native MediaMetadataRetriever via
    // MethodChannel. This is the same API that other Android music players
    // use, which is why they display correct titles.
    for (int j = 0; j < parsed.length && j < indices.length; j++) {
      final idx = indices[j];
      final song = result[idx];
      final titleGarbled = EncodingSanitizer.hasMojibakeCjk(song.title);
      final artistGarbled = song.artist != 'Local Audio' &&
          EncodingSanitizer.hasMojibakeCjk(song.artist);
      final missingArt = song.thumbnailUrl.isEmpty &&
          song.highResThumbnailUrl.isEmpty;

      if (titleGarbled || artistGarbled || missingArt) {
        try {
          final nativeMeta = await _readNativeMetadata(paths[j]);
          if (nativeMeta != null) {
            final nTitle = nativeMeta['title'] as String?;
            final nArtist = nativeMeta['artist'] as String?;
            final nDurMs = (nativeMeta['durationMs'] as num?)?.toInt() ?? 0;
            final nArtPath = nativeMeta['artPath'] as String?;

            // Update cache with native results
            final updatedMeta = _CachedMeta(
              title: nTitle ?? cache[paths[j]]?.title,
              artist: nArtist ?? cache[paths[j]]?.artist,
              durationMs: nDurMs > 0 ? nDurMs : (cache[paths[j]]?.durationMs ?? 0),
              artPath: nArtPath ?? cache[paths[j]]?.artPath,
              sizeBytes: cache[paths[j]]?.sizeBytes ?? 0,
              mtimeMs: cache[paths[j]]?.mtimeMs ?? 0,
            );
            cache[paths[j]] = updatedMeta;
            result[idx] = _applyNative(result[idx], updatedMeta,
                titleGarbled: titleGarbled,
                artistGarbled: artistGarbled,
                missingArt: missingArt);
            debugPrint('[LocalMeta] Native fallback applied for: ${paths[j]}');
          }
        } catch (e) {
          debugPrint('[LocalMeta] Native fallback failed for ${paths[j]}: $e');
        }
      }
    }

    _scheduleSave();
    return result;
  }

  Song _apply(Song song, _CachedMeta meta) {
    final hasArt = meta.artPath != null &&
        meta.artPath!.isNotEmpty &&
        File(meta.artPath!).existsSync();
    final cleanTitle = meta.title != null ? EncodingSanitizer.sanitize(meta.title!) : null;
    final cleanArtist = meta.artist != null ? EncodingSanitizer.sanitize(meta.artist!) : null;

    final resolvedTitle = (cleanTitle != null && cleanTitle.trim().isNotEmpty && !EncodingSanitizer.hasMojibakeCjk(cleanTitle))
        ? cleanTitle.trim()
        : ((song.title.trim().isEmpty || song.title == song.filePath || song.title == 'Unknown Track' || song.title.endsWith('.mp3') || song.title.endsWith('.m4a') || song.title.endsWith('.flac'))
            ? cleanTitleFromFilename(song.filePath ?? song.videoId)
            : song.title);

    final resolvedArtist = (cleanArtist != null && cleanArtist.trim().isNotEmpty && !EncodingSanitizer.hasMojibakeCjk(cleanArtist))
        ? cleanArtist.trim()
        : ((song.artist.trim().isEmpty || song.artist == 'Unknown Artist' || song.artist == '<unknown>')
            ? cleanArtistFromFilename(song.filePath ?? song.videoId)
            : song.artist);

    return song.copyWith(
      title: resolvedTitle,
      artist: resolvedArtist,
      duration: meta.durationMs > 0
          ? Duration(milliseconds: meta.durationMs)
          : song.duration,
      thumbnailUrl: hasArt ? meta.artPath! : song.thumbnailUrl,
      highResThumbnailUrl: hasArt ? meta.artPath! : song.highResThumbnailUrl,
    );
  }

  /// Apply native metadata selectively — only override fields that were
  /// garbled or missing from the Dart parser.
  Song _applyNative(Song song, _CachedMeta meta, {
    required bool titleGarbled,
    required bool artistGarbled,
    required bool missingArt,
  }) {
    final hasNativeArt = meta.artPath != null &&
        meta.artPath!.isNotEmpty &&
        File(meta.artPath!).existsSync();

    return song.copyWith(
      title: (titleGarbled && meta.title != null && meta.title!.trim().isNotEmpty)
          ? meta.title!.trim()
          : song.title,
      artist: (artistGarbled && meta.artist != null && meta.artist!.trim().isNotEmpty)
          ? meta.artist!.trim()
          : song.artist,
      duration: meta.durationMs > 0
          ? Duration(milliseconds: meta.durationMs)
          : song.duration,
      thumbnailUrl: (missingArt && hasNativeArt) ? meta.artPath! : song.thumbnailUrl,
      highResThumbnailUrl: (missingArt && hasNativeArt) ? meta.artPath! : song.highResThumbnailUrl,
    );
  }

  /// Call Android's native MediaMetadataRetriever via MethodChannel.
  /// Returns null on non-Android platforms or if the call fails.
  static Future<Map<String, dynamic>?> _readNativeMetadata(String path) async {
    try {
      if (!Platform.isAndroid) return null;
      const channel = MethodChannel('com.sonicwave.sonic_wave/media');
      final result = await channel.invokeMethod<Map>('readNativeMetadata', {'path': path});
      if (result == null) return null;
      return Map<String, dynamic>.from(result);
    } catch (e) {
      debugPrint('[LocalMeta] Native metadata call failed: $e');
      return null;
    }
  }

  /// Runs inside a background isolate (also used inline as fallback).
  /// Must stay self-contained: no plugins, only dart:io + the parser.
  static List<Map<String, dynamic>> _parseFilesSync(
      List<String> paths, String artDirPath) {
    final out = <Map<String, dynamic>>[];
    for (final path in paths) {
      String? title;
      String? artist;
      int durationMs = 0;
      String? artPath;
      int sizeBytes = 0;
      int mtimeMs = 0;
      try {
        final file = File(path);
        final stat = file.statSync();
        sizeBytes = stat.size;
        mtimeMs = stat.modified.millisecondsSinceEpoch;

        AudioMetadata? meta;
        try {
          meta = readMetadata(file, getImage: true);
        } catch (_) {
          // Encrypted, container-wrapped, or unrecognized audio format
        }

        if (meta != null) {
          title = meta.title != null ? EncodingSanitizer.sanitize(meta.title!) : null;
          artist = meta.artist != null ? EncodingSanitizer.sanitize(meta.artist!) : null;
          durationMs = meta.duration?.inMilliseconds ?? 0;
        }

        Uint8List? rawImageBytes;
        String imageExt = 'jpg';

        final metaInstance = meta;
        if (metaInstance != null && metaInstance.pictures.isNotEmpty) {
          // Prefer the front cover when typed, else the first picture.
          final pic = metaInstance.pictures.firstWhere(
            (p) => p.pictureType == PictureType.coverFront,
            orElse: () => metaInstance.pictures.first,
          );
          if (pic.bytes.isNotEmpty) {
            rawImageBytes = Uint8List.fromList(pic.bytes);
            imageExt = pic.mimetype.contains('png')
                ? 'png'
                : (pic.mimetype.contains('webp') ? 'webp' : 'jpg');
          }
        }

        // Universal fallback artwork extraction for FLAC, OGG, WAV, AAC, M4A, MP3, etc.
        if (rawImageBytes == null || rawImageBytes.isEmpty) {
          final fallbackImg = _extractEmbeddedImageFallback(file);
          if (fallbackImg != null) {
            rawImageBytes = fallbackImg.bytes;
            imageExt = fallbackImg.isPng ? 'png' : (fallbackImg.isWebp ? 'webp' : 'jpg');
          }
        }

        if (rawImageBytes != null && rawImageBytes.isNotEmpty) {
          final hash =
              '${path.hashCode.toUnsigned(32).toRadixString(16)}_${sizeBytes.toRadixString(16)}';
          final artFile =
              File('$artDirPath${Platform.pathSeparator}$hash.$imageExt');
          if (!artFile.existsSync() ||
              artFile.lengthSync() != rawImageBytes.length) {
            artFile.writeAsBytesSync(rawImageBytes);
          }
          artPath = artFile.path;
        }

        // If no embedded ID3 picture was found, scan parent directory for folder cover artwork
        if (artPath == null) {
          try {
            final parentDir = file.parent;
            if (parentDir.existsSync()) {
              final candidates = [
                'cover.jpg', 'cover.png', 'cover.jpeg', 'cover.webp',
                'folder.jpg', 'folder.png', 'folder.jpeg', 'folder.webp',
                'album.jpg', 'album.png', 'album.jpeg', 'album.webp',
                'front.jpg', 'front.png', 'front.jpeg', 'front.webp',
                'artwork.jpg', 'artwork.png', 'artwork.jpeg', 'artwork.webp',
              ];
              for (final cand in candidates) {
                final candFile = File('${parentDir.path}${Platform.pathSeparator}$cand');
                if (candFile.existsSync() && candFile.lengthSync() > 0) {
                  artPath = candFile.path;
                  break;
                }
              }
              if (artPath == null) {
                for (final entity in parentDir.listSync()) {
                  if (entity is File) {
                    final name = entity.path.toLowerCase();
                    if (name.endsWith('.jpg') || name.endsWith('.jpeg') || name.endsWith('.png') || name.endsWith('.webp')) {
                      artPath = entity.path;
                      break;
                    }
                  }
                }
              }
            }
          } catch (_) {}
        }
      } catch (_) {
        // Corrupt file or inaccessible file
      }
      out.add(_CachedMeta(
        title: title,
        artist: artist,
        durationMs: durationMs,
        artPath: artPath,
        sizeBytes: sizeBytes,
        mtimeMs: mtimeMs,
      ).toJson());
    }
    return out;
  }

  /// Clean encoded or raw filenames into clean track titles
  static String cleanTitleFromFilename(String filenameOrPath) {
    String name = filenameOrPath.split(Platform.pathSeparator).last;
    name = name.split('/').last;
    if (name.contains('?')) name = name.split('?').first;
    final dotIndex = name.lastIndexOf('.');
    if (dotIndex > 0) {
      name = name.substring(0, dotIndex);
    }
    name = EncodingSanitizer.sanitize(name);
    name = name.replaceAll(RegExp(r'[_+]'), ' ');
    name = name.replaceFirst(RegExp(r'^\s*(\d{1,3}[.\-_\s]+\s*)+'), '');
    name = name.replaceAll(
        RegExp(r'\s*(\[|\()(?:\s*(?:official\s*(?:video|audio|music\s*video|hd|lyric\s*video)?|lyrics?|320\s*kbps|1080p|720p|4k|remastered|hq|audio|video)\s*)(\]|\))',
            caseSensitive: false),
        '');
    if (name.contains(' - ')) {
      final parts = name.split(' - ');
      if (parts.length >= 2 && parts.last.trim().isNotEmpty) {
        name = parts.sublist(1).join(' - ');
      }
    }
    name = name.trim();
    return name.isNotEmpty ? name : 'Unknown Track';
  }

  /// Extract artist from encoded filename if formatted like "Artist - Title"
  static String cleanArtistFromFilename(String filenameOrPath) {
    String name = filenameOrPath.split(Platform.pathSeparator).last;
    name = name.split('/').last;
    if (name.contains('?')) name = name.split('?').first;
    final dotIndex = name.lastIndexOf('.');
    if (dotIndex > 0) {
      name = name.substring(0, dotIndex);
    }
    name = EncodingSanitizer.sanitize(name);
    name = name.replaceAll(RegExp(r'[_+]'), ' ');
    name = name.replaceFirst(RegExp(r'^\s*(\d{1,3}[.\-_\s]+\s*)+'), '');
    if (name.contains(' - ')) {
      final parts = name.split(' - ');
      if (parts.first.trim().isNotEmpty) {
        return parts.first.trim();
      }
    }
    return 'Local Artist';
  }

  /// Universal binary scanner for embedded JPEG/PNG/WebP image streams in M4A/MP4, FLAC, OGG, WAV, MP3.
  /// Handles encrypted/container formats and Vorbis base64 comments where metadata parser misses artwork.
  static _ExtractedImage? _extractEmbeddedImageFallback(File file) {
    try {
      final stat = file.statSync();
      if (stat.size < 1024) return null;

      final raf = file.openSync(mode: FileMode.read);
      
      // 1. Read first 4MB (or whole file)
      final headLen = stat.size > 4 * 1024 * 1024 ? 4 * 1024 * 1024 : stat.size;
      final headBytes = raf.readSync(headLen);

      _ExtractedImage? img = _findImageInBytes(headBytes);
      if (img != null) {
        raf.closeSync();
        return img;
      }

      // 2. Check for base64 image in header (FLAC / OGG METADATA_BLOCK_PICTURE)
      img = _findBase64ImageInBytes(headBytes);
      if (img != null) {
        raf.closeSync();
        return img;
      }

      // 3. If file is large (>4MB), check tail (last 512KB) for APE/ID3v1/appended tags
      if (stat.size > 4 * 1024 * 1024) {
        final tailLen = 512 * 1024;
        raf.setPositionSync(stat.size - tailLen);
        final tailBytes = raf.readSync(tailLen);
        img = _findImageInBytes(tailBytes) ?? _findBase64ImageInBytes(tailBytes);
      }

      raf.closeSync();
      return img;
    } catch (_) {}
    return null;
  }

  static _ExtractedImage? _findImageInBytes(Uint8List bytes) {
    // 1. MP4 'covr' atom detection
    for (int i = 0; i < bytes.length - 16; i++) {
      if (bytes[i] == 0x63 && bytes[i + 1] == 0x6F && bytes[i + 2] == 0x76 && bytes[i + 3] == 0x72) {
        for (int j = i + 4; j < i + 24 && j < bytes.length - 8; j++) {
          if (bytes[j] == 0x64 && bytes[j + 1] == 0x61 && bytes[j + 2] == 0x74 && bytes[j + 3] == 0x61) {
            final dataStart = j + 12;
            if (dataStart < bytes.length) {
              final subSlice = Uint8List.sublistView(bytes, dataStart);
              final subImg = _findDirectImage(subSlice);
              if (subImg != null) return subImg;
            }
          }
        }
      }
    }

    // 2. ID3v2 APIC / PIC frame detection
    for (int i = 0; i < bytes.length - 10; i++) {
      if ((bytes[i] == 0x41 && bytes[i + 1] == 0x50 && bytes[i + 2] == 0x49 && bytes[i + 3] == 0x43) ||
          (bytes[i] == 0x50 && bytes[i + 1] == 0x49 && bytes[i + 2] == 0x43)) {
        final searchOffset = bytes[i] == 0x41 ? i + 10 : i + 6;
        if (searchOffset < bytes.length) {
          final scanLimit = searchOffset + 512 < bytes.length ? searchOffset + 512 : bytes.length;
          final headerSlice = Uint8List.sublistView(bytes, searchOffset, scanLimit);
          final subImg = _findDirectImage(headerSlice);
          if (subImg != null) {
            final firstByte = subImg.bytes.first;
            final imgRelIdx = headerSlice.indexOf(firstByte);
            if (imgRelIdx >= 0) {
              final fullSlice = Uint8List.sublistView(bytes, searchOffset + imgRelIdx);
              final directFull = _findDirectImage(fullSlice);
              if (directFull != null) return directFull;
            }
          }
        }
      }
    }

    return _findDirectImage(bytes);
  }

  static _ExtractedImage? _findDirectImage(Uint8List bytes) {
    // PNG magic numbers: 0x89 0x50 0x4E 0x47 0x0D 0x0A 0x1A 0x0A
    for (int i = 0; i < bytes.length - 8; i++) {
      if (bytes[i] == 0x89 &&
          bytes[i + 1] == 0x50 &&
          bytes[i + 2] == 0x4E &&
          bytes[i + 3] == 0x47 &&
          bytes[i + 4] == 0x0D &&
          bytes[i + 5] == 0x0A &&
          bytes[i + 6] == 0x1A &&
          bytes[i + 7] == 0x0A) {
        int end = -1;
        for (int j = i + 8; j < bytes.length - 8; j++) {
          if (bytes[j] == 0x49 &&
              bytes[j + 1] == 0x45 &&
              bytes[j + 2] == 0x4E &&
              bytes[j + 3] == 0x44) {
            end = j + 8;
            break;
          }
        }
        if (end != -1 && end > i && (end - i) >= 512) {
          final pngData = Uint8List.sublistView(bytes, i, end);
          return _ExtractedImage(pngData, isPng: true);
        }
      }
    }

    // JPEG magic numbers: SOI 0xFF 0xD8 0xFF ... EOI 0xFF 0xD9
    for (int i = 0; i < bytes.length - 4; i++) {
      if (bytes[i] == 0xFF && bytes[i + 1] == 0xD8 && bytes[i + 2] == 0xFF) {
        // Find last EOI within reasonable boundary (up to 4MB)
        int lastEoi = -1;
        final searchLimit = (i + 4 * 1024 * 1024 < bytes.length) ? i + 4 * 1024 * 1024 : bytes.length;
        for (int j = i + 3; j < searchLimit - 1; j++) {
          if (bytes[j] == 0xFF && bytes[j + 1] == 0xD9) {
            lastEoi = j + 2;
          }
        }
        if (lastEoi != -1 && (lastEoi - i) >= 1024) {
          final jpgData = Uint8List.sublistView(bytes, i, lastEoi);
          return _ExtractedImage(jpgData, isPng: false);
        }
      }
    }
    // WebP magic numbers: "RIFF" .... "WEBP"
    for (int i = 0; i < bytes.length - 12; i++) {
      if (bytes[i] == 0x52 &&
          bytes[i + 1] == 0x49 &&
          bytes[i + 2] == 0x46 &&
          bytes[i + 3] == 0x46 &&
          bytes[i + 8] == 0x57 &&
          bytes[i + 9] == 0x45 &&
          bytes[i + 10] == 0x42 &&
          bytes[i + 11] == 0x50) {
        final len = bytes[i + 4] |
            (bytes[i + 5] << 8) |
            (bytes[i + 6] << 16) |
            (bytes[i + 7] << 24);
        final totalLen = len + 8;
        if (totalLen >= 12 && i + totalLen <= bytes.length) {
          final webpData = Uint8List.sublistView(bytes, i, i + totalLen);
          return _ExtractedImage(webpData, isWebp: true);
        }
      }
    }

    return null;
  }

  static _ExtractedImage? _findBase64ImageInBytes(Uint8List bytes) {
    try {
      final asciiStr = String.fromCharCodes(bytes.where((b) => b >= 32 && b <= 126));
      // Base64 JPEG header starts with '/9j/'
      final jpgIndex = asciiStr.indexOf('/9j/');
      if (jpgIndex != -1) {
        final rawB64 = asciiStr.substring(jpgIndex).split(RegExp(r'[^A-Za-z0-9+/=]')).first;
        if (rawB64.length > 512) {
          final decoded = base64Decode(base64.normalize(rawB64));
          if (decoded.length >= 1024) {
            return _ExtractedImage(decoded, isPng: false);
          }
        }
      }
      // Base64 PNG header starts with 'iVBORw0KGgo'
      final pngIndex = asciiStr.indexOf('iVBORw0KGgo');
      if (pngIndex != -1) {
        final rawB64 = asciiStr.substring(pngIndex).split(RegExp(r'[^A-Za-z0-9+/=]')).first;
        if (rawB64.length > 512) {
          final decoded = base64Decode(base64.normalize(rawB64));
          if (decoded.length >= 512) {
            return _ExtractedImage(decoded, isPng: true);
          }
        }
      }
    } catch (_) {}
    return null;
  }
}

class _ExtractedImage {
  final Uint8List bytes;
  final bool isPng;
  final bool isWebp;
  const _ExtractedImage(this.bytes, {this.isPng = false, this.isWebp = false});
}

class _CachedMeta {
  final String? title;
  final String? artist;
  final int durationMs;
  final String? artPath;
  final int sizeBytes;
  final int mtimeMs;

  const _CachedMeta({
    required this.title,
    required this.artist,
    required this.durationMs,
    required this.artPath,
    required this.sizeBytes,
    required this.mtimeMs,
  });

  Map<String, dynamic> toJson() => {
        't': title,
        'a': artist,
        'd': durationMs,
        'p': artPath,
        's': sizeBytes,
        'm': mtimeMs,
      };

  factory _CachedMeta.fromJson(Map<String, dynamic> j) => _CachedMeta(
        title: j['t'] as String?,
        artist: j['a'] as String?,
        durationMs: (j['d'] as num?)?.toInt() ?? 0,
        artPath: j['p'] as String?,
        sizeBytes: (j['s'] as num?)?.toInt() ?? 0,
        mtimeMs: (j['m'] as num?)?.toInt() ?? 0,
      );
}
