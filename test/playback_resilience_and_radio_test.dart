import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sonic_wave/models/song.dart';
import 'package:sonic_wave/providers/player_provider.dart';
import 'package:sonic_wave/services/radio_service.dart';
import 'package:sonic_wave/services/stream_resolver_service.dart';
import 'migration_test.dart';

class MockResilienceAudioHandler extends MockAudioHandler {
  final List<Song> _list = [];
  int _index = 0;
  bool wasPlayCalled = false;
  Song? playedSong;

  @override
  List<Song> get playlist => _list;

  @override
  int get currentIndex => _index;

  @override
  void restoreQueue(List<Song> songs, int index, Duration position) {
    _list.clear();
    _list.addAll(songs);
    _index = index;
    // Cold start restore MUST NOT set wasPlayCalled to true
  }

  @override
  Future<void> playSong(Song song) async {
    wasPlayCalled = true;
    playedSong = song;
  }

  @override
  Future<void> playPlaylist(List<Song> songs, {int startIndex = 0}) async {
    wasPlayCalled = true;
    _list.clear();
    _list.addAll(songs);
    _index = startIndex;
    if (startIndex < songs.length) {
      playedSong = songs[startIndex];
    }
  }

}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory tempDir;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('sonic_wave_resilience_radio_test_');

    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      (MethodCall methodCall) async {
        return tempDir.path;
      },
    );
  });

  tearDown(() async {
    try {
      await tempDir.delete(recursive: true);
    } catch (_) {}
  });

  group('Playback Resilience & Radio Stream Verification', () {
    test('1. Session restore on app launch restores queue WITHOUT auto-playing audio', () async {
      const song1 = Song(
        id: 's1',
        videoId: 's1',
        title: 'Cold Start Track 1',
        artist: 'Artist 1',
        thumbnailUrl: 'https://example.com/1.jpg',
        highResThumbnailUrl: 'https://example.com/1.jpg',
        duration: Duration(minutes: 3),
      );

      SharedPreferences.setMockInitialValues({
        'saved_session_playlist': json.encode([song1.toJson()]),
        'saved_session_index': 0,
        'saved_session_position': 15,
      });

      final handler = MockResilienceAudioHandler();
      final provider = PlayerProvider(handler);

      await provider.restoreLastSession();

      expect(handler.playlist.length, equals(1));
      expect(handler.currentIndex, equals(0));
      expect(handler.playlist[0].title, equals('Cold Start Track 1'));
      // Verifying Issue 1: play() was never triggered on app startup
      expect(handler.wasPlayCalled, isFalse);
    });

    test('2. Playing a recently played song with a stale/deleted filePath sanitizes filePath to null for live resolution', () async {
      // Simulating a song that was previously cached or downloaded, but whose file on disk was deleted
      const nonExistentPath = '/storage/emulated/0/Download/deleted_file.mp3';
      const onlineSongWithStalePath = Song(
        id: 'youtube_abc123',
        videoId: 'abc12345678',
        title: 'Recent Online Song',
        artist: 'Popular Artist',
        thumbnailUrl: 'https://example.com/thumb.jpg',
        highResThumbnailUrl: 'https://example.com/thumb.jpg',
        duration: Duration(minutes: 4),
        filePath: nonExistentPath,
      );

      final handler = MockResilienceAudioHandler();
      final provider = PlayerProvider(handler);

      await provider.playSong(onlineSongWithStalePath);

      expect(handler.wasPlayCalled, isTrue);
      // Verifying Issue 2: filePath was sanitized to null so online resolver handles it seamlessly
      expect(handler.playedSong?.filePath, isNull);
      expect(handler.playedSong?.videoId, equals('abc12345678'));
    });

    test('3. Radio Stream Resolver passes Accept-Encoding: identity and ICY headers', () async {
      const radioSong = Song(
        id: 'radio_999_url_https://example.com/stream.mp3',
        videoId: 'radio_999_url_https://example.com/stream.mp3',
        title: 'Radio Mirchi 98.3',
        artist: 'Live FM',
        thumbnailUrl: 'https://example.com/radio.jpg',
        highResThumbnailUrl: 'https://example.com/radio.jpg',
        duration: Duration.zero,
      );

      final resolved = await StreamResolverService().resolve(radioSong);

      expect(resolved, isNotNull);
      expect(resolved!.isLive, isTrue);
      expect(resolved.source, equals('radio'));
      expect(resolved.headers?['Accept-Encoding'], equals('identity'));
      expect(resolved.headers?['Icy-MetaData'], equals('1'));
      expect(RadioService.isRadioId(radioSong.id), isTrue);
    });
  });
}
