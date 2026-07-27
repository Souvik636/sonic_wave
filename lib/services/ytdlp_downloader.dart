import 'dart:async';
import 'dart:io';

import 'package:extractor/extractor.dart';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

import '../providers/settings_provider.dart' show AudioQuality;
import 'youtube_service.dart';
import 'ytdlp_runtime.dart';

/// Outcome of a native yt-dlp download.
class YtDlpDownloadResult {
  /// Absolute path to the downloaded audio file (still in the staging dir).
  final String audioPath;

  /// Absolute path to the sidecar cover image, when yt-dlp wrote one.
  final String? thumbnailPath;

  /// True when the cover art was embedded INTO the audio container, so the
  /// artwork travels with the file into other players.
  final bool thumbnailEmbedded;

  const YtDlpDownloadResult({
    required this.audioPath,
    this.thumbnailPath,
    this.thumbnailEmbedded = false,
  });
}

/// Downloads YouTube audio with the native yt-dlp binary, the way
/// JunkFood02/Seal's `DownloadUtil.downloadAudio` does.
///
/// Why this exists alongside the plain `HttpClient` path in DownloadService:
/// pulling the raw stream bytes ourselves gives a file whose container is
/// whatever YouTube served (usually M4A/AAC), and cover art then has to be
/// hand-injected. The app's ID3 writer only supports MP3, so for the common
/// M4A case artwork was silently dropped. yt-dlp + FFmpeg + mutagen do the
/// whole job natively: correct container, real embedded artwork, real tags.
///
/// Output is M4A by remux, not MP3. YouTube audio is already AAC, so ffmpeg
/// stream-copies it (`-c:a copy`) — no transcode, no generation loss, and a
/// second or two of post-processing instead of tens of seconds of re-encoding
/// on a phone CPU.
class YtDlpDownloader {
  YtDlpDownloader._();

  /// Audio container produced for downloads. AAC-in-M4A is what YouTube already
  /// serves, so this is a lossless remux.
  static const String audioFormat = 'm4a';

  /// Extensions yt-dlp may leave behind as the audio artifact.
  static const List<String> _audioExts = [
    'm4a', 'mp3', 'opus', 'webm', 'ogg', 'aac', 'flac', 'wav', 'mp4'
  ];

  static const List<String> _imageExts = ['jpg', 'jpeg', 'png', 'webp'];

  /// Staging directory. yt-dlp writes here first, then the finished file is
  /// moved to the user's chosen storage location.
  ///
  /// Downloading straight into the destination would litter it with `.part`
  /// files, and the destination may be an SD card with awkward write
  /// permissions. The cache dir is always writable by the app's own UID, which
  /// is what the forked native process runs as.
  static Future<Directory> stagingDir() async {
    final cache = await getTemporaryDirectory();
    final dir = Directory('${cache.path}${Platform.pathSeparator}ytdlp_dl');
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    return dir;
  }

  /// Download [videoId]'s audio at [quality].
  ///
  /// [onProgress] receives a 0..1 fraction. [onEta] receives yt-dlp's own
  /// estimate. Throws on failure so the caller can fall back to the HTTP path.
  static Future<YtDlpDownloadResult> download({
    required String videoId,
    required AudioQuality quality,
    ValueChanged<double>? onProgress,
    ValueChanged<Duration>? onEta,
  }) async {
    if (!await YtDlpRuntime.ensureInitialized()) {
      throw Exception('yt-dlp runtime unavailable');
    }

    final dir = await stagingDir();
    // Clear any leftovers for this id so the post-run glob can't pick up a
    // stale artifact from an earlier cancelled attempt.
    await _cleanup(videoId, dir);

    final processId = 'dl_$videoId';

    // yt-dlp reports progress on a stream keyed by processId, not per-call.
    StreamSubscription<DownloadProgress>? progressSub;
    if (onProgress != null || onEta != null) {
      progressSub = YoutubeDLFlutter.instance.onProgress.listen((event) {
        if (event.processId != processId) return;
        // The native side emits -1 while it is still resolving formats.
        if (event.progress < 0) {
          onProgress?.call(0.04);
        } else {
          // Smoothly scale raw download fraction (0.0..1.0) to 0.05..0.90
          final fraction = event.progressFraction.clamp(0.0, 1.0);
          final scaled = 0.05 + (fraction * 0.85);
          onProgress?.call(scaled);
        }
        if (event.etaInSeconds > 0) {
          onEta?.call(event.eta);
        }
      });
    }

    try {
      final request = DownloadRequest(
        url: 'https://www.youtube.com/watch?v=$videoId',
        outputPath: dir.path,
        // Name by videoId so the result is findable without guessing the title.
        outputTemplate: '$videoId.%(ext)s',
        processId: processId,
        noPlaylist: true,
        extractAudio: true,
        audioFormat: audioFormat,
        // Embed artwork + tags natively (needs FFmpeg, which YtDlpRuntime now
        // initializes, and mutagen, which is bundled in the library's Python).
        embedThumbnail: true,
        embedMetadata: true,
        format: YouTubeService.ytDlpFormatChain(quality),
        customOptions: {
          '--no-update': '',
          // Low-internet resilience: generous timeout, 5 retries with
          // exponential backoff, and IPv4 to avoid dual-stack DNS stalls.
          '--force-ipv4': '',
          '--socket-timeout': '15',
          '-R': '5',
          '--retry-sleep': 'linear=1::2',
          '--fragment-retries': '5',
          // Don't stamp the file with YouTube's upload date — it makes
          // "recently added" sorting in other players nonsense.
          '--no-mtime': '',
          // Keep network concurrency smooth (1 fragment) so background audio
          // streaming never stutters or drops connection.
          '--concurrent-fragments': '1',
          '--buffersize': '16k',
          // ALSO write the cover as a sidecar .jpg. The app's own UI reads a
          // local image path (song.thumbnailUrl), and this doubles as the
          // fallback when embedding fails for an unexpected container.
          '--write-thumbnail': '',
          '--convert-thumbnails': 'jpg',
          '-S': YouTubeService.ytDlpAudioSorter(quality),
          // Seal's album tag rule: prefer a real album, else the track title.
          '--parse-metadata': '%(album,title)s:%(meta_album)s',
        },
      );

      onProgress?.call(0.05);
      final result = await YoutubeDLFlutter.instance.download(request);
      onProgress?.call(0.95);

      if (result.status != OperationStatus.success) {
        throw Exception(result.errorMessage ?? 'yt-dlp download failed');
      }

      // Do NOT trust result.outputPath: the plugin returns the template with
      // %(ext)s unexpanded. Find what actually landed on disk instead.
      final artifacts = await _collect(videoId, dir);
      final audioPath = artifacts.audio;
      if (audioPath == null) {
        throw Exception('yt-dlp reported success but wrote no audio file');
      }

      final embedded = await _hasEmbeddedCover(File(audioPath));
      debugPrint('[yt-dlp] Downloaded $videoId -> $audioPath '
          '(embeddedArt=$embedded, sidecar=${artifacts.thumbnail != null})');

      return YtDlpDownloadResult(
        audioPath: audioPath,
        thumbnailPath: artifacts.thumbnail,
        thumbnailEmbedded: embedded,
      );
    } finally {
      await progressSub?.cancel();
    }
  }

  /// Cancel an in-flight download and remove its partial files.
  static Future<void> cancel(String videoId) async {
    try {
      await YoutubeDLFlutter.instance.cancelDownload('dl_$videoId');
    } catch (e) {
      debugPrint('[yt-dlp] Cancel failed for $videoId: $e');
    }
    try {
      await _cleanup(videoId, await stagingDir());
    } catch (_) {}
  }

  /// Remove every staged artifact for [videoId].
  static Future<void> _cleanup(String videoId, Directory dir) async {
    try {
      await for (final entity in dir.list()) {
        if (entity is File && _basename(entity.path).startsWith('$videoId.')) {
          try {
            await entity.delete();
          } catch (_) {}
        }
      }
    } catch (_) {}
  }

  /// Find the audio file and sidecar image yt-dlp left for [videoId].
  static Future<_Artifacts> _collect(String videoId, Directory dir) async {
    String? audio;
    String? thumb;
    try {
      await for (final entity in dir.list()) {
        if (entity is! File) continue;
        final name = _basename(entity.path);
        if (!name.startsWith('$videoId.')) continue;
        // Skip in-progress fragments.
        if (name.endsWith('.part') || name.endsWith('.ytdl')) continue;

        final ext = name.split('.').last.toLowerCase();
        if (_imageExts.contains(ext)) {
          thumb ??= entity.path;
        } else if (_audioExts.contains(ext)) {
          // Prefer the requested container if several are present.
          if (audio == null || ext == audioFormat) audio = entity.path;
        }
      }
    } catch (e) {
      debugPrint('[yt-dlp] Failed to scan staging dir: $e');
    }
    return _Artifacts(audio, thumb);
  }

  /// Best-effort check that cover art really made it into the container.
  ///
  /// Reported so the caller knows whether the sidecar image is decoration or
  /// the only copy of the artwork. A false negative only costs a log line.
  static Future<bool> _hasEmbeddedCover(File file) async {
    try {
      final len = await file.length();
      if (len < 16) return false;
      final raf = await file.open();
      try {
        // MP4/M4A: look for the 'covr' atom in the metadata, which lives near
        // the front for yt-dlp output (faststart-style moov placement).
        final probeLen = len < 262144 ? len : 262144;
        final head = await raf.read(probeLen);
        const covr = [0x63, 0x6F, 0x76, 0x72]; // 'covr'
        const apic = [0x41, 0x50, 0x49, 0x43]; // 'APIC' (ID3v2, mp3 output)
        return _indexOf(head, covr) >= 0 || _indexOf(head, apic) >= 0;
      } finally {
        await raf.close();
      }
    } catch (_) {
      return false;
    }
  }

  static int _indexOf(List<int> haystack, List<int> needle) {
    final limit = haystack.length - needle.length;
    outer:
    for (int i = 0; i <= limit; i++) {
      for (int j = 0; j < needle.length; j++) {
        if (haystack[i + j] != needle[j]) continue outer;
      }
      return i;
    }
    return -1;
  }

  static String _basename(String path) =>
      path.split(RegExp(r'[/\\]')).last;
}

class _Artifacts {
  final String? audio;
  final String? thumbnail;
  const _Artifacts(this.audio, this.thumbnail);
}
