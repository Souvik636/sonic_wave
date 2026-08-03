import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:audio_metadata_reader/audio_metadata_reader.dart';
import 'package:flutter/foundation.dart';
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
      } else {
        toParse[i] = path;
      }
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
    _scheduleSave();
    return result;
  }

  Song _apply(Song song, _CachedMeta meta) {
    final hasArt = meta.artPath != null &&
        meta.artPath!.isNotEmpty &&
        File(meta.artPath!).existsSync();
    final cleanTitle = meta.title != null ? EncodingSanitizer.sanitize(meta.title!) : null;
    final cleanArtist = meta.artist != null ? EncodingSanitizer.sanitize(meta.artist!) : null;

    return song.copyWith(
      title: (cleanTitle != null && cleanTitle.trim().isNotEmpty && !EncodingSanitizer.hasMojibakeCjk(cleanTitle))
          ? cleanTitle.trim()
          : song.title,
      artist: (cleanArtist != null && cleanArtist.trim().isNotEmpty && !EncodingSanitizer.hasMojibakeCjk(cleanArtist))
          ? cleanArtist.trim()
          : song.artist,
      duration: meta.durationMs > 0
          ? Duration(milliseconds: meta.durationMs)
          : song.duration,
      thumbnailUrl: hasArt ? meta.artPath! : song.thumbnailUrl,
      highResThumbnailUrl: hasArt ? meta.artPath! : song.highResThumbnailUrl,
    );
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

        final meta = readMetadata(file, getImage: true);
        title = meta.title != null ? EncodingSanitizer.sanitize(meta.title!) : null;
        artist = meta.artist != null ? EncodingSanitizer.sanitize(meta.artist!) : null;
        durationMs = meta.duration?.inMilliseconds ?? 0;

        Uint8List? rawImageBytes;
        String imageExt = 'jpg';

        if (meta.pictures.isNotEmpty) {
          // Prefer the front cover when typed, else the first picture.
          final pic = meta.pictures.firstWhere(
            (p) => p.pictureType == PictureType.coverFront,
            orElse: () => meta.pictures.first,
          );
          if (pic.bytes.isNotEmpty) {
            rawImageBytes = Uint8List.fromList(pic.bytes);
            imageExt = pic.mimetype.contains('png') ? 'png' : 'jpg';
          }
        }

        // Universal fallback artwork extraction for FLAC, OGG, WAV, AAC, M4A, etc.
        if (rawImageBytes == null || rawImageBytes.isEmpty) {
          final fallbackImg = _extractEmbeddedImageFallback(file);
          if (fallbackImg != null) {
            rawImageBytes = fallbackImg.bytes;
            imageExt = fallbackImg.isPng ? 'png' : 'jpg';
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
        // Unsupported/corrupt file — record a negative entry so we don't
        // re-parse it on every scan (size/mtime still guard staleness).
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

  /// Universal binary header scanner for embedded JPEG/PNG image streams.
  /// Handles container formats where metadata parser fails to detect artwork.
  static _ExtractedImage? _extractEmbeddedImageFallback(File file) {
    try {
      final stat = file.statSync();
      if (stat.size < 1024) return null;
      // Read first 1MB or full file size if smaller
      final readLen = stat.size > 1024 * 1024 ? 1024 * 1024 : stat.size;
      final raf = file.openSync(mode: FileMode.read);
      final bytes = raf.readSync(readLen);
      raf.closeSync();

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
          // Find PNG end chunk (IEND: 0x49 0x45 0x4E 0x44 0xAE 0x42 0x60 0x82)
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
          if (end != -1 && end > i) {
            final pngData = Uint8List.sublistView(bytes, i, end);
            return _ExtractedImage(pngData, isPng: true);
          }
        }
      }

      // JPEG magic numbers: SOI 0xFF 0xD8 0xFF ... EOI 0xFF 0xD9
      for (int i = 0; i < bytes.length - 4; i++) {
        if (bytes[i] == 0xFF && bytes[i + 1] == 0xD8 && bytes[i + 2] == 0xFF) {
          int end = -1;
          for (int j = i + 3; j < bytes.length - 2; j++) {
            if (bytes[j] == 0xFF && bytes[j + 1] == 0xD9) {
              end = j + 2;
              break;
            }
          }
          if (end != -1 && (end - i) >= 2048) {
            final jpgData = Uint8List.sublistView(bytes, i, end);
            return _ExtractedImage(jpgData, isPng: false);
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
  const _ExtractedImage(this.bytes, {required this.isPng});
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
