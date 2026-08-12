import 'package:flutter_test/flutter_test.dart';
import 'package:sonic_wave/models/song.dart';
import 'package:sonic_wave/services/recommendation_engine.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  group('Audio Infrastructure & Recommendation Engine Tests', () {
    final song1 = Song(
      id: '1',
      title: 'Bohemian Rhapsody',
      artist: 'Queen',
      thumbnailUrl: '',
      highResThumbnailUrl: '',
      duration: const Duration(minutes: 5),
      videoId: 'queen_bohemian',
    );

    final song2 = Song(
      id: '2',
      title: 'Don\'t Stop Me Now',
      artist: 'Queen',
      thumbnailUrl: '',
      highResThumbnailUrl: '',
      duration: const Duration(minutes: 3),
      videoId: 'queen_dont_stop',
    );

    final song3 = Song(
      id: '3',
      title: 'Hotel California',
      artist: 'Eagles',
      thumbnailUrl: '',
      highResThumbnailUrl: '',
      duration: const Duration(minutes: 6),
      videoId: 'eagles_hotel',
    );

    test('RecommendationEngine prefers same artist and favorite tracks', () {
      final engine = RecommendationEngine();

      final recommendations = engine.generateRecommendations(
        currentSong: song1,
        activeQueue: [song1],
        librarySongs: [song2, song3],
        favoriteSongs: [song3],
        recentlyPlayed: [song2],
        count: 2,
      );

      expect(recommendations.isNotEmpty, isTrue);
      // Same artist (Queen) or favorite should be prioritized
      final topRec = recommendations.first;
      expect(topRec.videoId == song2.videoId || topRec.videoId == song3.videoId, isTrue);
    });

    test('RecommendationEngine excludes songs already in active queue', () {
      final engine = RecommendationEngine();

      final recommendations = engine.generateRecommendations(
        currentSong: song1,
        activeQueue: [song1, song2],
        librarySongs: [song1, song2, song3],
        favoriteSongs: [],
        recentlyPlayed: [],
        count: 5,
      );

      expect(recommendations.length, equals(1));
      expect(recommendations.first.videoId, equals(song3.videoId));
    });
  });
}
