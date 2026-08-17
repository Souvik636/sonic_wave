import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import '../models/song.dart';
import 'jamendo_service.dart';

class DiscoverService {
  static final DiscoverService _instance = DiscoverService._internal();
  factory DiscoverService() => _instance;
  DiscoverService._internal();

  final HttpClient _client = HttpClient()
    ..connectionTimeout = const Duration(seconds: 5);

  /// Fetch trending tracks from Audius (fully legal indie source)
  Future<List<Song>> fetchAudiusTrending() async {
    try {
      final uri = Uri.parse(
        'https://api.audius.co/v1/tracks/trending?app_name=SONICWAVE',
      );
      final request = await _client
          .getUrl(uri)
          .timeout(const Duration(seconds: 5));
      final response = await request.close().timeout(
        const Duration(seconds: 5),
      );

      if (response.statusCode != 200) {
        return [];
      }

      final body = await response.transform(utf8.decoder).join();
      final data = jsonDecode(body);
      final list = data['data'] as List?;
      if (list == null) return [];

      final songs = <Song>[];
      for (final item in list) {
        final id = item['id'] as String?;
        final title = item['title'] as String? ?? 'Unknown Track';
        final artist = item['user']?['name'] as String? ?? 'Audius Artist';
        final coverArt = item['artwork']?['150x150'] as String? ?? '';
        final durationSec = item['duration'] as int? ?? 180;

        if (id == null || id.isEmpty) continue;

        songs.add(
          Song(
            id: 'audius_$id',
            videoId: 'audius_$id',
            title: title,
            artist: artist,
            thumbnailUrl: coverArt,
            highResThumbnailUrl:
                item['artwork']?['480x480'] as String? ?? coverArt,
            duration: Duration(seconds: durationSec),
          ),
        );
      }
      return songs;
    } catch (e) {
      debugPrint('Audius trending fetch failed: $e');
      return [];
    }
  }

  /// Fetch popular tracks from Jamendo (fully legal source)
  Future<List<Song>> fetchJamendoPopular() async {
    try {
      return await JamendoService().trending(limit: 25);
    } catch (e) {
      debugPrint('Jamendo popular fetch failed: $e');
      return [];
    }
  }
}
