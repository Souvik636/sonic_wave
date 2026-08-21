import 'dart:async';
import 'dart:io';
import 'package:flutter/foundation.dart';
import '../models/song.dart';
import 'archive_org_service.dart';
import 'jamendo_service.dart';
import 'jiosaavn_service.dart';
import 'radio_service.dart';
import 'stream_cache_service.dart';
import 'youtube_service.dart';

/// The result of resolving a Song into something the audio player can open.
class ResolvedStream {
  /// Direct URL the player should open.
  final String url;

  /// True for live radio — the player should hide seek bar / duration.
  final bool isLive;

  /// Where the stream came from: 'radio', 'jamendo', 'jiosaavn', 'youtube', 'archive', 'audius'.
  final String source;

  /// Optional HTTP headers required to stream (e.g. User-Agent / cookies from yt-dlp).
  final Map<String, String>? headers;

  const ResolvedStream(this.url, {this.isLive = false, this.source = '', this.headers});
}

/// SINGLE entry point for playback URL resolution.
///
/// This is the fix for "song/station shows in the list but never plays":
/// radio and Jamendo Songs carry non-YouTube ids (`radio_..._url_https://...`,
/// `jamendo_..._url_https://...`). If the player pushes those ids into the
/// YouTube extractor, resolution fails silently and nothing plays.
///
/// Wire your player through this class instead:
///
///   final resolved = await StreamResolverService().resolve(song);
///   if (resolved == null) { showError('This stream is unavailable'); return; }
///   await audioPlayer.setUrl(resolved.url);
///   if (resolved.isLive) hideSeekBar();
class StreamResolverService {
  static final StreamResolverService _instance =
      StreamResolverService._internal();
  factory StreamResolverService() => _instance;
  StreamResolverService._internal();

  final JioSaavnService _jioSaavn = JioSaavnService();
  final YouTubeService _youtube = YouTubeService();
  final ArchiveOrgService _archive = ArchiveOrgService();

  /// Resolve [song] to something playable.
  ///
  /// [forceRefresh] is passed through to the YouTube resolver so a retry goes
  /// back to the network instead of being handed the cached URL that just
  /// failed. It only affects the YouTube branch — every other source here
  /// either builds its URL from the id or fetches it live, so there is no
  /// cached answer to bypass.
  Future<ResolvedStream?> resolve(Song song, {bool forceRefresh = false}) async {
    final id = song.videoId;

    // 0. Local file / content URI check — ONLY if file physically exists on disk or is explicit content/file URI
    if (id.startsWith('content://') || id.startsWith('file://')) {
      final cleanPath = id.startsWith('file://') ? Uri.parse(id).toFilePath() : id;
      if (cleanPath.startsWith('content://') || File(cleanPath).existsSync()) {
        return ResolvedStream(id, source: 'local');
      }
    }
    if (song.isLocalFile || (song.filePath != null && song.filePath!.isNotEmpty)) {
      final path = song.filePath ?? id;
      if (path.isNotEmpty && File(path).existsSync()) {
        final uri = path.startsWith('file://') ? path : 'file://$path';
        return ResolvedStream(uri, source: 'local');
      }
    }

    if (RadioService.isRadioId(id)) {
      final rawUrl = RadioService.streamUrlFromId(id);
      if (rawUrl == null) {
        debugPrint('[StreamResolver] radio id has no URL: $id');
        return null;
      }
      final resolvedUrl = await RadioService.resolveStreamUrl(rawUrl);
      return ResolvedStream(
        resolvedUrl,
        isLive: true,
        source: 'radio',
        headers: const {
          'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36',
          'Accept': '*/*',
          'Icy-MetaData': '1',
        },
      );
    }

    // 2. Jamendo: direct MP3 URL embedded in the id.
    if (JamendoService.isJamendoId(id)) {
      final url = JamendoService.streamUrlFromId(id);
      if (url == null) {
        debugPrint('[StreamResolver] jamendo id has no URL: $id');
        return null;
      }
      return ResolvedStream(url, source: 'jamendo');
    }

    // 3. Archive.org
    if (id.startsWith('archive_')) {
      final archiveId = id.replaceFirst('archive_', '');
      final url = await _archive.getAudioFileUrl(archiveId);
      if (url == null) {
        debugPrint('[StreamResolver] archive id lookup failed: $id');
        return null;
      }
      return ResolvedStream(url, source: 'archive');
    }

    // 4. Audius
    if (id.startsWith('audius_')) {
      final audiusId = id.replaceFirst('audius_', '');
      final url = 'https://api.audius.co/v1/tracks/$audiusId/stream?app_name=SONICWAVE';
      return ResolvedStream(url, source: 'audius');
    }

    // 5. JioSaavn song
    if (id.startsWith('jiosaavn_')) {
      debugPrint('[StreamResolver] Resolving JioSaavn song exclusively: $id');
      final saavnUrl = await _jioSaavn.getStreamUrlById(id);
      if (saavnUrl != null && saavnUrl.startsWith('http')) {
        return ResolvedStream(saavnUrl, source: 'jiosaavn');
      }
      return null;
    }

    // 6. YouTube song — progressive chunk streaming + direct stream racing
    debugPrint('[StreamResolver] Resolving YouTube song: $id');

    // 6a. Check stream cache for an existing completed file (instant replay, 0ms latency)
    final cache = StreamCacheService();
    final quality = YouTubeService.streamingQuality;
    final cachedFile = await cache.getCachedFile(id, quality.name);
    if (cachedFile != null && !forceRefresh) {
      debugPrint('[StreamResolver] Stream cache hit for $id');
      return ResolvedStream(cachedFile, source: 'youtube_cached');
    }

    // Prioritize this clicked song: cancel all other background loads
    await cache.cancelAllExcept(id);

    final completer = Completer<ResolvedStream?>();

    // 6b. Progressive chunk download via yt-dlp (Fires onPlayable at first 64KB chunk for instant start)
    unawaited(() async {
      try {
        await cache.downloadToCache(
          videoId: id,
          quality: quality,
          onPlayable: (filePath) {
            if (!completer.isCompleted) {
              debugPrint('[StreamResolver] Progressive stream chunk ready for $id: $filePath');
              completer.complete(ResolvedStream(filePath, source: 'youtube_progressive'));
            }
          },
        );
      } catch (e) {
        debugPrint('[StreamResolver] Progressive cache download error for $id: $e');
      }
    }());

    // 6c. Parallel direct stream resolution
    unawaited(() async {
      try {
        final ytUrl = await _youtube.getAudioStreamUrl(id, forceRefresh: forceRefresh);
        if (ytUrl.startsWith('http') && !completer.isCompleted) {
          debugPrint('[StreamResolver] Direct stream URL ready for $id: $ytUrl');
          completer.complete(ResolvedStream(ytUrl, source: 'youtube'));
        }
      } catch (e) {
        debugPrint('[StreamResolver] Direct stream fallback failed for $id: $e');
        try {
          final proxyUrl = await _youtube.getFallbackStreamUrl(id);
          if (proxyUrl != null && proxyUrl.startsWith('http') && !completer.isCompleted) {
            completer.complete(ResolvedStream(proxyUrl, source: 'youtube_proxy'));
          }
        } catch (_) {}
      }
    }());

    // Return the fastest playable source (wait up to 20s for full resolution)
    try {
      final stream = await completer.future.timeout(const Duration(seconds: 20));
      if (stream != null) return stream;
    } catch (_) {}

    // Fallback: Check if cached file or in-flight progressive chunk is playable
    final fallbackCached = await cache.getCachedFile(id, quality.name);
    if (fallbackCached != null && await File(fallbackCached).exists()) {
      return ResolvedStream(fallbackCached, source: 'youtube_cached');
    }

    final inFlightPath = cache.getInFlightPlayablePath(id);
    if (inFlightPath != null && await File(inFlightPath).exists()) {
      return ResolvedStream(inFlightPath, source: 'youtube_progressive');
    }

    return null;
  }
}
