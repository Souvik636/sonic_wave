import 'dart:async';
import 'dart:io';

import 'package:extractor/extractor.dart';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

import '../providers/settings_provider.dart' show AudioQuality;
import 'diagnostic_log_service.dart';
import 'id3_tag_writer.dart';
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
  /// [onProgress] receives a 0..1 fraction. [onEta] receives yt-dlp's own
  /// estimate. Throws on failure so the caller can fall back to the HTTP path.
  static Future<YtDlpDownloadResult> download({
    required String videoId,
    required AudioQuality quality,
    ValueChanged<double>? onProgress,
    ValueChanged<Duration>? onEta,
  }) async {
    final sw = Stopwatch()..start();

    if (!await YtDlpRuntime.ensureInitialized()) {
      DiagnosticLogService().log(DiagnosticLogService.downloadYtdlp, {
        'videoId': videoId, 'ok': false, 'reason': 'runtime_unavailable',
      });
      throw Exception('yt-dlp runtime unavailable');
    }

    final dir = await stagingDir();
    await _cleanup(videoId, dir);

    final processId = 'dl_$videoId';

    StreamSubscription<DownloadProgress>? progressSub;
    if (onProgress != null || onEta != null) {
      progressSub = YoutubeDLFlutter.instance.onProgress.listen((event) {
        if (event.processId != processId) return;
        if (event.progress < 0) {
          onProgress?.call(0.04);
        } else {
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
      final formatChain = YouTubeService.ytDlpFormatChain(quality);
      final sorter = YouTubeService.ytDlpAudioSorter(quality);

      DiagnosticLogService().log(DiagnosticLogService.downloadYtdlp, {
        'videoId': videoId, 'phase': 'start',
        'quality': quality.name, 'format': formatChain,
      });

      final request = DownloadRequest(
        url: 'https://www.youtube.com/watch?v=$videoId',
        outputPath: dir.path,
        outputTemplate: '$videoId.%(ext)s',
        processId: processId,
        noPlaylist: true,
        extractAudio: true,
        audioFormat: audioFormat,
        embedThumbnail: true,
        embedMetadata: true,
        format: formatChain,
        customOptions: {
          '--no-update': '',
          '--force-ipv4': '',
          '--no-check-certificates': '',
          '--socket-timeout': '10',
          '-R': '3',
          // 'linear=1::2' is yt-dlp 2023.10+ syntax; older bundled binaries
          // silently reject it and retry immediately, making the three retries
          // fire in under a second and all hit the same rate-limit window.
          // Plain integer is accepted by every version.
          '--retry-sleep': '2',
          '--fragment-retries': '3',
          '--no-mtime': '',
          '--concurrent-fragments': '2',
          '--buffer-size': '64k',
          // 10M was too large for mobile: a 10 MB chunk that drops mid-flight
          // restarts the whole chunk rather than continuing from the last byte.
          // 1M keeps partial retries cheap without sacrificing throughput
          // (--concurrent-fragments=2 still pulls two streams at once).
          '--http-chunk-size': '1M',
          '--write-thumbnail': '',
          '--convert-thumbnails': 'jpg',
          '-S': sorter,
          '--parse-metadata': '%(album,title)s:%(meta_album)s',
          // Skip HLS/DASH manifest and translated subtitles fetches — the
          // player-client response already carries direct audio URLs, so these
          // round-trips cost 1-3s with zero benefit for audio-only downloads.
          '--extractor-args':
              'youtube:player_client=mweb,android_vr,tv,ios;skip=hls,dash,translated_subs,webpage',
        },
      );

      onProgress?.call(0.05);

      // Hard ceiling on the entire yt-dlp process. Without it a process that
      // hangs in a bad network state (partial write, stalled fragment) will
      // keep the download task alive indefinitely; the user sees a spinner that
      // never moves and only a force-close clears it.
      const downloadDeadline = Duration(minutes: 8);
      final result = await YoutubeDLFlutter.instance
          .download(request)
          .timeout(downloadDeadline, onTimeout: () {
        throw TimeoutException(
            'yt-dlp download exceeded ${downloadDeadline.inMinutes} min',
            downloadDeadline);
      });
      onProgress?.call(0.95);

      if (result.status != OperationStatus.success) {
        sw.stop();
        DiagnosticLogService().log(DiagnosticLogService.downloadYtdlp, {
          'videoId': videoId, 'ok': false, 'elapsed_ms': sw.elapsedMilliseconds,
          'reason': 'bad_status',
          'error': result.errorMessage ?? 'yt-dlp download failed',
        });
        throw Exception(result.errorMessage ?? 'yt-dlp download failed');
      }

      final artifacts = await _collect(videoId, dir);
      final audioPath = artifacts.audio;
      if (audioPath == null) {
        sw.stop();
        DiagnosticLogService().log(DiagnosticLogService.downloadYtdlp, {
          'videoId': videoId, 'ok': false, 'elapsed_ms': sw.elapsedMilliseconds,
          'reason': 'no_audio_file',
        });
        throw Exception('yt-dlp reported success but wrote no audio file');
      }

      YtDlpRuntime.markHealthy();
      final embedded = await ID3TagWriter.hasEmbeddedCover(File(audioPath));
      sw.stop();
      debugPrint('[yt-dlp] Downloaded $videoId -> $audioPath '
          '(embeddedArt=$embedded, sidecar=${artifacts.thumbnail != null})');
      DiagnosticLogService().log(DiagnosticLogService.downloadYtdlp, {
        'videoId': videoId, 'ok': true, 'elapsed_ms': sw.elapsedMilliseconds,
        'embedded_art': embedded,
        'has_sidecar': artifacts.thumbnail != null,
        'ext': audioPath.split('.').last,
      });

      return YtDlpDownloadResult(
        audioPath: audioPath,
        thumbnailPath: artifacts.thumbnail,
        thumbnailEmbedded: embedded,
      );
    } catch (e) {
      sw.stop();
      DiagnosticLogService().log(DiagnosticLogService.downloadYtdlp, {
        'videoId': videoId, 'ok': false, 'elapsed_ms': sw.elapsedMilliseconds,
        'error': e.toString(),
      });
      rethrow;
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

  static String _basename(String path) =>
      path.split(RegExp(r'[/\\]')).last;
}

class _Artifacts {
  final String? audio;
  final String? thumbnail;
  const _Artifacts(this.audio, this.thumbnail);
}
