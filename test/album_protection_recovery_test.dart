import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sonic_wave/models/album.dart';
import 'package:sonic_wave/models/song.dart';
import 'package:sonic_wave/providers/player_provider.dart';
import 'migration_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory tempDir;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('sonic_wave_recovery_test_');

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

  test('Song.isRecovered detects recovery directory paths', () {
    final normalSong = const Song(
      id: 's1', videoId: 's1', title: 'Normal Track', artist: 'Artist',
      thumbnailUrl: '', highResThumbnailUrl: '', duration: Duration(minutes: 3),
      filePath: '/storage/Music/song1.mp3',
    );
    final recoveredSong = const Song(
      id: 's2', videoId: 's2', title: 'Recovered Track', artist: 'Artist',
      thumbnailUrl: '', highResThumbnailUrl: '', duration: Duration(minutes: 3),
      filePath: '/storage/sonicwave/.recovery/song2.mp3',
    );

    expect(normalSong.isRecovered, isFalse);
    expect(recoveredSong.isRecovered, isTrue);
  });

  test('deleteAlbumWithProtection batch-moves songs to target album', () async {
    final song1 = const Song(
      id: 's1', videoId: 's1', title: 'Track 1', artist: 'Artist',
      thumbnailUrl: '', highResThumbnailUrl: '', duration: Duration(minutes: 3),
    );
    final song2 = const Song(
      id: 's2', videoId: 's2', title: 'Track 2', artist: 'Artist',
      thumbnailUrl: '', highResThumbnailUrl: '', duration: Duration(minutes: 3),
    );

    final albumA = UserAlbum(id: 'alb_a', name: 'Album A', songs: [song1]);
    final albumB = UserAlbum(id: 'alb_b', name: 'Album B', songs: [song2]);

    SharedPreferences.setMockInitialValues({
      'user_albums': json.encode([albumA.toJson(), albumB.toJson()]),
    });

    final provider = PlayerProvider(MockAudioHandler());
    await Future.delayed(const Duration(milliseconds: 50));

    expect(provider.albums.length, equals(2));

    await provider.deleteAlbumWithProtection('alb_a', targetAlbumId: 'alb_b');

    expect(provider.albums.length, equals(1));
    expect(provider.albums.first.id, equals('alb_b'));
    expect(provider.albums.first.songs.length, equals(2));
    expect(provider.albums.first.songs.any((s) => s.videoId == 's1'), isTrue);
  });
}
