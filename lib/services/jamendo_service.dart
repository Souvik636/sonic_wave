import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import '../models/song.dart';

/// Jamendo Creative Commons music (official API, fully legal).
///
/// Playback rules:
///   - The `audio` field returned by the API is a DIRECT streaming MP3 URL
///     (it 302-redirects to a CDN file; just_audio follows redirects fine).
///   - We embed that URL into the Song id after the `_url_` marker so the
///     player never tries to resolve a Jamendo track through YouTube.
///   - Tracks whose `audio` field is empty are skipped — they can be
///     listed by the API but are NOT streamable, which is exactly the
///     "shows in the list but won't play" symptom.
class JamendoService {
  static final JamendoService _instance = JamendoService._internal();
  factory JamendoService() => _instance;
  JamendoService._internal();

  static const String idPrefix = 'jamendo_';
  static const String _urlMarker = '_url_';

  /// Get a free client id at https://developer.jamendo.com
  /// (Set once from your app bootstrap: JamendoService().clientId = '...';)
  String clientId = '';

  final HttpClient _client = HttpClient()
    ..connectionTimeout = const Duration(seconds: 5);

  static bool isJamendoId(String id) => id.startsWith(idPrefix);

  /// Extracts the direct MP3 stream URL from a Jamendo Song id.
  static String? streamUrlFromId(String id) {
    final index = id.indexOf(_urlMarker);
    if (index == -1) return null;
    final url = id.substring(index + _urlMarker.length);
    return url.isEmpty ? null : url;
  }

  Future<List<Song>> search(String query, {int limit = 25}) {
    return _fetchTracks(
      'namesearch=${Uri.encodeComponent(query)}&limit=$limit',
    );
  }

  Future<List<Song>> trending({int limit = 25}) {
    return _fetchTracks('order=popularity_week&limit=$limit');
  }

  Future<List<Song>> byTag(String tag, {int limit = 25}) {
    return _fetchTracks(
      'tags=${Uri.encodeComponent(tag)}&order=popularity_week&limit=$limit',
    );
  }

  Future<List<Song>> _fetchTracks(String params) async {
    if (clientId.isEmpty) {
      debugPrint(
        '[JamendoService] clientId is not set — no results. '
        'Get a free key at developer.jamendo.com',
      );
      return const [];
    }

    try {
      final uri = Uri.parse(
        'https://api.jamendo.com/v3.0/tracks/?client_id=$clientId'
        '&format=json&audioformat=mp32&include=musicinfo&$params',
      );

      final request = await _client
          .getUrl(uri)
          .timeout(const Duration(seconds: 6));
      final response = await request.close().timeout(
        const Duration(seconds: 6),
      );
      if (response.statusCode != 200) {
        debugPrint('[JamendoService] HTTP ${response.statusCode}');
        await response.drain();
        return const [];
      }

      final body = await response
          .transform(utf8.decoder)
          .join()
          .timeout(const Duration(seconds: 8));
      final data = jsonDecode(body) as Map<String, dynamic>;

      final headers = data['headers'] as Map<String, dynamic>?;
      if (headers != null && headers['status'] != 'success') {
        debugPrint('[JamendoService] API error: ${headers['error_message']}');
        return const [];
      }

      final results = data['results'] as List? ?? const [];
      final songs = <Song>[];

      for (final item in results) {
        final trackId = '${item['id'] ?? ''}';
        final name = (item['name'] as String? ?? '').trim();
        final artist = (item['artist_name'] as String? ?? 'Unknown').trim();
        // `audio` is the direct streaming URL. If it's empty the track
        // is not streamable — skip it instead of listing a dead tile.
        final audio = (item['audio'] as String? ?? '').trim();
        final image =
            (item['album_image'] as String? ?? item['image'] as String? ?? '')
                .trim();
        final durationSec = int.tryParse('${item['duration'] ?? 0}') ?? 0;

        if (trackId.isEmpty || name.isEmpty || audio.isEmpty) continue;
        if (!audio.startsWith('https://')) continue;

        final id = '$idPrefix$trackId$_urlMarker$audio';
        songs.add(
          Song(
            id: id,
            videoId: id,
            title: name,
            artist: artist,
            thumbnailUrl: image,
            highResThumbnailUrl: image,
            duration: Duration(seconds: durationSec),
          ),
        );
      }

      return songs;
    } catch (e) {
      debugPrint('[JamendoService] fetch failed: $e');
      return const [];
    }
  }
}
