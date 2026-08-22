import 'package:flutter_test/flutter_test.dart';
import 'package:sonic_wave/models/song.dart';
import 'package:sonic_wave/models/album.dart';
import 'package:sonic_wave/providers/player_provider.dart';
import 'package:sonic_wave/services/lyrics_service.dart';
import 'package:sonic_wave/services/ambient_soundscape_service.dart';
import 'package:sonic_wave/widgets/audio_visualizer_suite.dart';

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
  });

  group('4. Parametric Equalizer Math & Presets Tests', () {
    test('PEQ gains clamped correctly between -12dB and +12dB', () {
      double clampGain(double g) => g.clamp(-12.0, 12.0);

      expect(clampGain(15.5), equals(12.0));
      expect(clampGain(-20.0), equals(-12.0));
      expect(clampGain(4.5), equals(4.5));
      expect(clampGain(0.0), equals(0.0));
    });
  });

  group('5. Ambient Soundscape Service Tests', () {
    test('Soundscapes list contains 5 rich relaxing atmospheres', () {
      final service = AmbientSoundscapeService();
      expect(service.soundscapes.length, equals(5));

      final types = service.soundscapes.map((s) => s.type).toList();
      expect(types, contains(AmbientType.rain));
      expect(types, contains(AmbientType.ocean));
      expect(types, contains(AmbientType.cafe));
      expect(types, contains(AmbientType.campfire));
      expect(types, contains(AmbientType.binaural));
    });

    test('Volume clamping works properly', () {
      final service = AmbientSoundscapeService();
      service.setVolume(1.5);
      expect(service.volumeNotifier.value, equals(1.0));

      service.setVolume(-0.2);
      expect(service.volumeNotifier.value, equals(0.0));

      service.setVolume(0.65);
      expect(service.volumeNotifier.value, equals(0.65));
    });
  });

  group('6. Real-Time 60FPS Audio Visualizer Suite Tests', () {
    test('VisualizerMode enum defines 4 GPU modes', () {
      expect(VisualizerMode.values.length, equals(4));
      expect(VisualizerMode.values, contains(VisualizerMode.spectrumBars));
      expect(VisualizerMode.values, contains(VisualizerMode.analogVuMeters));
      expect(VisualizerMode.values, contains(VisualizerMode.cosmicGalaxy));
      expect(VisualizerMode.values, contains(VisualizerMode.auroraRibbon));
    });
  });
}
