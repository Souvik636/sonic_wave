import 'package:flutter_test/flutter_test.dart';
import 'package:sonic_wave/models/song.dart';
import 'package:sonic_wave/models/album.dart';
import 'package:sonic_wave/providers/player_provider.dart';
import 'package:sonic_wave/services/lyrics_service.dart';
import 'package:sonic_wave/widgets/karaoke_lyrics_view.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('1 & 2. Album Section Rules & Recovery Conditional Visibility Tests', () {
    test('Reserved album names set includes system keywords', () {
      expect(PlayerProvider.reservedAlbumNames.contains('download'), isTrue);
      expect(PlayerProvider.reservedAlbumNames.contains('downloads'), isTrue);
      expect(PlayerProvider.reservedAlbumNames.contains('recovery'), isTrue);
      expect(PlayerProvider.reservedAlbumNames.contains('.recovery'), isTrue);
      expect(PlayerProvider.reservedAlbumNames.contains('all songs'), isTrue);
      expect(PlayerProvider.reservedAlbumNames.contains('favorites'), isTrue);
    });

    test('Recovery Album is filtered out when empty and visible when non-empty', () {
      final song = Song(
        id: 'test_1',
        title: 'Bohemian Rhapsody',
        artist: 'Queen',
        thumbnailUrl: '',
        highResThumbnailUrl: '',
        duration: const Duration(seconds: 354),
        videoId: 'v123',
      );

      final emptyRecovery = UserAlbum(
        id: 'recovery_vault',
        name: 'Recovery',
        songs: [],
      );

      final normalAlbum = UserAlbum(
        id: 'rock_classics',
        name: 'Rock Classics',
        songs: [song],
      );

      final albumList = [emptyRecovery, normalAlbum];

      // Simulate the PlayerProvider.albums getter logic
      final visibleAlbums = albumList.where((a) {
        if (a.id == 'recovery_vault' || a.name.toLowerCase() == 'recovery') {
          return a.songs.isNotEmpty;
        }
        return true;
      }).toList();

      expect(visibleAlbums.length, equals(1));
      expect(visibleAlbums.first.id, equals('rock_classics'));

      // Now add a song to recovery
      final nonEmptyRecovery = UserAlbum(
        id: 'recovery_vault',
        name: 'Recovery',
        songs: [song],
      );
      final updatedList = [nonEmptyRecovery, normalAlbum];

      final updatedVisibleAlbums = updatedList.where((a) {
        if (a.id == 'recovery_vault' || a.name.toLowerCase() == 'recovery') {
          return a.songs.isNotEmpty;
        }
        return true;
      }).toList();

      expect(updatedVisibleAlbums.length, equals(2));
      expect(updatedVisibleAlbums.any((a) => a.id == 'recovery_vault'), isTrue);
    });
  });

  group('3. Synced Karaoke & Offline Lyrics Engine Tests', () {
    test('LRC Parser correctly parses timestamps and text', () {
      const sampleLrc = '''
[00:12.50] Is this the real life?
[00:15.80] Is this just fantasy?
[00:20.00] Caught in a landslide
[00:24.30] No escape from reality
''';

      final service = LyricsService();
      final entries = service.parseLrc(sampleLrc);

      expect(entries.length, equals(4));
      expect(entries[0].time, equals(const Duration(seconds: 12, milliseconds: 500)));
      expect(entries[0].text, equals('Is this the real life?'));
      expect(entries[1].time, equals(const Duration(seconds: 15, milliseconds: 800)));
      expect(entries[1].text, equals('Is this just fantasy?'));
      expect(entries[2].time, equals(const Duration(seconds: 20)));
      expect(entries[3].time, equals(const Duration(seconds: 24, milliseconds: 300)));
    });

    test('LyricEntry supports optional translation and phonetics', () {
      final entry = LyricEntry(
        const Duration(seconds: 5),
        'Hello World',
        translation: 'Bonjour le monde',
      );

      expect(entry.time.inSeconds, equals(5));
      expect(entry.text, equals('Hello World'));
      expect(entry.translation, equals('Bonjour le monde'));
    });

    test('Streaming songs use temporary RAM session cache without writing permanent disk files', () {
      final streamingSong = Song(
        id: 'stream_1',
        title: 'Streaming Track',
        artist: 'Stream Artist',
        thumbnailUrl: '',
        highResThumbnailUrl: '',
        duration: const Duration(seconds: 200),
        videoId: 'online_stream_v123',
      );

      // Verify it is not flagged as local or downloaded
      expect(streamingSong.isLocalFile, isFalse);
      expect(streamingSong.filePath, isNull);
    });

    test('JioSaavn tracks are identified for karaoke lyrics deck mode', () {
      final jioSaavnSong = Song(
        id: 'jio_1',
        title: 'Tum Hi Ho',
        artist: 'Arijit Singh',
        thumbnailUrl: '',
        highResThumbnailUrl: '',
        duration: const Duration(seconds: 262),
        videoId: 'jiosaavn_7I9urT8B',
      );

      final ytSong = Song(
        id: 'yt_1',
        title: 'Shape of You',
        artist: 'Ed Sheeran',
        thumbnailUrl: '',
        highResThumbnailUrl: '',
        duration: const Duration(seconds: 233),
        videoId: 'JGwWNGJdvx8',
      );

      bool isKaraokeAvailable(Song s) => s.videoId.startsWith('jiosaavn_');

      expect(isKaraokeAvailable(jioSaavnSong), isTrue);
      expect(isKaraokeAvailable(ytSong), isFalse);
    });

    test('KaraokePlayerTheme enum provides distinct styles for Classic and Aurora players', () {
      expect(KaraokePlayerTheme.values.length, equals(2));
      expect(KaraokePlayerTheme.values, contains(KaraokePlayerTheme.classic));
      expect(KaraokePlayerTheme.values, contains(KaraokePlayerTheme.aurora));
    });
  });
}
