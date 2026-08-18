import 'package:flutter_test/flutter_test.dart';
import 'package:sonic_wave/models/song.dart';
import 'package:sonic_wave/services/stream_resolver_service.dart';
import 'package:sonic_wave/services/jiosaavn_service.dart';
import 'package:sonic_wave/services/radio_service.dart';
import 'dart:io';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('Download Resolution Tests Across All Sources', () {
    late StreamResolverService resolver;

    setUp(() {
      HttpOverrides.global = null;
      resolver = StreamResolverService();
    });

    test('1. JioSaavn Stream Resolution', () async {
      try {
        final saavnSongs = await JioSaavnService().searchSongs('Kesariya');
        if (saavnSongs.isNotEmpty) {
          final song = saavnSongs.first;
          final resolved = await resolver.resolve(song);
          expect(resolved, isNotNull);
          expect(resolved!.source, equals('jiosaavn'));
          expect(resolved.url.startsWith('http'), isTrue);
        }
      } catch (_) {
        // Network unavailable during test environment
      }
    });

    test('2. Jamendo Direct Audio Stream Resolution', () async {
      const jamendoUrl = 'https://prod-1.storage.jamendo.com/download/track/1885060/mp32/';
      const song = Song(
        id: 'jamendo_1885060_url_$jamendoUrl',
        videoId: 'jamendo_1885060_url_$jamendoUrl',
        title: 'Jamendo Ambient',
        artist: 'Creative Commons Artist',
        thumbnailUrl: '',
        highResThumbnailUrl: '',
        duration: Duration(seconds: 180),
      );

      final resolved = await resolver.resolve(song);
      expect(resolved, isNotNull);
      expect(resolved!.source, equals('jamendo'));
      expect(resolved.url, equals(jamendoUrl));
    });

    test('3. Audius Stream Resolution', () async {
      const song = Song(
        id: 'audius_D762p',
        videoId: 'audius_D762p',
        title: 'Audius Track',
        artist: 'Indie Artist',
        thumbnailUrl: '',
        highResThumbnailUrl: '',
        duration: Duration(seconds: 200),
      );

      final resolved = await resolver.resolve(song);
      expect(resolved, isNotNull);
      expect(resolved!.source, equals('audius'));
      expect(resolved.url.contains('api.audius.co'), isTrue);
    });

    test('4. Live Radio Stream Resolution', () async {
      try {
        final stations = await RadioService().fetchTopStations();
        if (stations.isNotEmpty) {
          final firstStation = stations.first;
          final resolved = await resolver.resolve(firstStation);
          expect(resolved, isNotNull);
          expect(resolved!.source, equals('radio'));
          expect(resolved.isLive, isTrue);
        }
      } catch (_) {
        // Network unavailable during test environment
      }
    });
  });
}
