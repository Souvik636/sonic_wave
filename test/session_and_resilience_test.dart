import 'dart:convert';
import 'dart:io';

import 'package:audio_service/audio_service.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:just_audio/just_audio.dart';
import 'package:rxdart/rxdart.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sonic_wave/models/song.dart';
import 'package:sonic_wave/providers/player_provider.dart';
import 'migration_test.dart';

class TestAudioHandler extends MockAudioHandler {
  final List<Song> _list = [];
  int _index = 0;

  @override
  List<Song> get playlist => _list;

  @override
  int get currentIndex => _index;

  @override
  void restoreQueue(List<Song> songs, int index, Duration position) {
    _list.clear();
    _list.addAll(songs);
    _index = index;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory tempDir;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('sonic_wave_resilience_test_');

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

  test('Session state persistence restores queue on cold boot', () async {
    final song1 = const Song(
      id: 's1', videoId: 's1', title: 'Persisted Song 1', artist: 'Artist 1',
      thumbnailUrl: '', highResThumbnailUrl: '', duration: Duration(minutes: 3),
    );
    final song2 = const Song(
      id: 's2', videoId: 's2', title: 'Persisted Song 2', artist: 'Artist 2',
      thumbnailUrl: '', highResThumbnailUrl: '', duration: Duration(minutes: 4),
    );

    SharedPreferences.setMockInitialValues({
      'saved_session_playlist': json.encode([song1.toJson(), song2.toJson()]),
      'saved_session_index': 1,
      'saved_session_position': 45,
    });

    final handler = TestAudioHandler();
    final provider = PlayerProvider(handler);

    await provider.restoreLastSession();

    expect(handler.playlist.length, equals(2));
    expect(handler.currentIndex, equals(1));
    expect(handler.playlist[1].title, equals('Persisted Song 2'));
  });
}
