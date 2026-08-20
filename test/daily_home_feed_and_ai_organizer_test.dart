import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sonic_wave/models/song.dart';
import 'package:sonic_wave/providers/home_provider.dart';
import 'package:sonic_wave/services/categorization/models.dart';
import 'package:sonic_wave/services/youtube_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('Daily Home Feed & 1st-Time Network Optimization Tests', () {
    setUp(() {
      SharedPreferences.setMockInitialValues({});
    });

    test('HomeProvider loads from permanent daily cache on same-day startup', () async {
      final now = DateTime.now();
      final todayKey = '${now.year}-${now.month.toString().padLeft(2, '0')}-${now.day.toString().padLeft(2, '0')}';

      final sampleSong = const Song(
        id: 'daily_song_1',
        videoId: 'daily_song_1',
        title: 'Daily Hit',
        artist: 'Trending Artist',
        thumbnailUrl: 'https://example.com/thumb.jpg',
        highResThumbnailUrl: 'https://example.com/thumb_hd.jpg',
        duration: Duration(minutes: 3, seconds: 45),
      );

      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('sonic_permanent_daily_home_feed_date', todayKey);
      await prefs.setString('sonic_permanent_daily_home_feed_data', jsonEncode({
        'trending': [sampleSong.toJson()],
        'categories': {
          'Pop Hits': [sampleSong.toJson()],
        },
      }));

      final provider = HomeProvider();
      await provider.initialize(forceRefresh: false);

      expect(provider.isInitialized, true);
      expect(provider.trendingSongs.length, 1);
      expect(provider.trendingSongs.first.title, 'Daily Hit');
      expect(provider.categorySongs['Pop Hits']?.length, 1);
    });

    test('YouTubeService provides dynamic multi-source fallback for categories', () async {
      final ytService = YouTubeService();
      
      final popSongs = await ytService.getSongsByCategory('Pop Hits');
      expect(popSongs, isNotEmpty);
      expect(popSongs.first.title, isNotEmpty);

      final edmSongs = await ytService.getSongsByCategory('EDM');
      expect(edmSongs, isNotEmpty);
    });
  });

  group('AI Organizer Enhancement Tests', () {
    test('CategorizationRequest smartAuto expands to all modular strategies including genre', () {
      const request = CategorizationRequest();
      final expanded = request.expandedStrategies;

      expect(expanded.contains(GroupingStrategy.existingAlbumsFirst), true);
      expect(expanded.contains(GroupingStrategy.byRealAlbum), true);
      expect(expanded.contains(GroupingStrategy.byFolder), true);
      expect(expanded.contains(GroupingStrategy.byArtist), true);
      expect(expanded.contains(GroupingStrategy.byGenre), true);
      expect(expanded.contains(GroupingStrategy.byMood), true);
    });
  });
}
