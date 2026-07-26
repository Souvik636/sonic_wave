import 'package:flutter_test/flutter_test.dart';
import 'package:sonic_wave/models/song.dart';
import 'package:sonic_wave/models/album.dart';
import 'package:sonic_wave/services/categorization/categorization_pipeline.dart';
import 'package:sonic_wave/services/categorization/models.dart';
import 'package:sonic_wave/services/categorization/title_cleaner.dart';

void main() {
  group('AI Categorization Pipeline Internal Tests', () {
    late CategorizationPipeline pipeline;

    setUp(() {
      pipeline = CategorizationPipeline();
    });

    test('1. Title & Artist Fallback Parsing', () {
      final parsed = TitleCleaner.parseArtistAndTitle('Coldplay - Yellow (Official Video)', 'Unknown');
      expect(parsed['artist'], equals('Coldplay'));
      expect(parsed['title'], equals('Yellow'));

      final parsed2 = TitleCleaner.parseArtistAndTitle('Arijit Singh - Kesariya [4K]', 'SonicWave');
      expect(parsed2['artist'], equals('Arijit Singh'));
      expect(parsed2['title'], equals('Kesariya'));
    });

    test('2. Artist Strategy Categorization', () async {
      final songs = [
        const Song(
          id: '1', videoId: '1', title: 'Starboy', artist: 'The Weeknd',
          thumbnailUrl: '', highResThumbnailUrl: '', duration: Duration(minutes: 3, seconds: 50),
        ),
        const Song(
          id: '2', videoId: '2', title: 'Blinding Lights', artist: 'The Weeknd',
          thumbnailUrl: '', highResThumbnailUrl: '', duration: Duration(minutes: 3, seconds: 20),
        ),
        const Song(
          id: '3', videoId: '3', title: 'Save Your Tears', artist: 'The Weeknd',
          thumbnailUrl: '', highResThumbnailUrl: '', duration: Duration(minutes: 3, seconds: 35),
        ),
        const Song(
          id: '4', videoId: '4', title: 'Shape of You', artist: 'Ed Sheeran',
          thumbnailUrl: '', highResThumbnailUrl: '', duration: Duration(minutes: 3, seconds: 53),
        ),
        const Song(
          id: '5', videoId: '5', title: 'Perfect', artist: 'Ed Sheeran',
          thumbnailUrl: '', highResThumbnailUrl: '', duration: Duration(minutes: 4, seconds: 23),
        ),
        const Song(
          id: '6', videoId: '6', title: 'Bad Habits', artist: 'Ed Sheeran',
          thumbnailUrl: '', highResThumbnailUrl: '', duration: Duration(minutes: 3, seconds: 51),
        ),
      ];

      final request = CategorizationRequest(
        strategies: [GroupingStrategy.byArtist],
        minGroupSize: 3,
        allowNetwork: false,
      );

      final result = await pipeline.run(songs, [], request);

      expect(result.stats.totalSongs, equals(6));
      expect(result.proposals.length, equals(2));
      expect(result.proposals.any((p) => p.name.contains('The Weeknd')), isTrue);
      expect(result.proposals.any((p) => p.name.contains('Ed Sheeran')), isTrue);
    });

    test('3. Folder Strategy Categorization', () async {
      final songs = [
        const Song(
          id: 'f1', videoId: 'f1', title: 'Eye of the Tiger', artist: 'Survivor',
          filePath: '/storage/emulated/0/Music/Workout/track1.mp3',
          thumbnailUrl: '', highResThumbnailUrl: '', duration: Duration(minutes: 4),
        ),
        const Song(
          id: 'f2', videoId: 'f2', title: 'Stronger', artist: 'Kanye West',
          filePath: '/storage/emulated/0/Music/Workout/track2.mp3',
          thumbnailUrl: '', highResThumbnailUrl: '', duration: Duration(minutes: 5),
        ),
        const Song(
          id: 'f3', videoId: 'f3', title: 'Till I Collapse', artist: 'Eminem',
          filePath: '/storage/emulated/0/Music/Workout/track3.mp3',
          thumbnailUrl: '', highResThumbnailUrl: '', duration: Duration(minutes: 4, seconds: 50),
        ),
      ];

      final request = CategorizationRequest(
        strategies: [GroupingStrategy.byFolder],
        minGroupSize: 3,
        allowNetwork: false,
      );

      final result = await pipeline.run(songs, [], request);

      expect(result.proposals.length, equals(1));
      expect(result.proposals.first.name, equals('Workout'));
      expect(result.proposals.first.songIds.length, equals(3));
    });

    test('4. Existing User Album Match Strategy', () async {
      final List<UserAlbum> existingAlbums = [
        UserAlbum(
          id: 'gym_album_123',
          name: 'Gym Workout Hits',
          songs: [],
        ),
      ];

      final songs = [
        const Song(
          id: 'e1', videoId: 'e1', title: 'Gym Workout Track 1', artist: 'Artist A',
          thumbnailUrl: '', highResThumbnailUrl: '', duration: Duration(minutes: 3),
        ),
        const Song(
          id: 'e2', videoId: 'e2', title: 'Gym Workout Track 2', artist: 'Artist B',
          thumbnailUrl: '', highResThumbnailUrl: '', duration: Duration(minutes: 3),
        ),
      ];

      final request = CategorizationRequest(
        strategies: [GroupingStrategy.existingAlbumsFirst],
        minGroupSize: 1,
        allowNetwork: false,
      );

      final result = await pipeline.run(songs, existingAlbums, request);

      expect(result.proposals.length, equals(1));
      expect(result.proposals.first.existingAlbumId, equals('gym_album_123'));
      expect(result.proposals.first.songIds.length, equals(2));
    });
  });
}
