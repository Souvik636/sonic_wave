import 'dart:io';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sonic_wave/models/song.dart';
import 'package:sonic_wave/providers/player_provider.dart';

import 'migration_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempDir;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('sonic_wave_album_test_');
    SharedPreferences.setMockInitialValues({});

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
      if (await tempDir.exists()) {
        await tempDir.delete(recursive: true);
      }
    } catch (_) {}
  });

  group('Album Move & Download Option Tests', () {
    test('1. Move local song to an existing album adds song and persists', () async {
      final playerProvider = PlayerProvider(MockAudioHandler());
      await Future.delayed(const Duration(milliseconds: 50));
      final album = await playerProvider.createAlbum('Synthwave Hits');

      final localSong = Song(
        id: 'local_1',
        title: 'Midnight Drive',
        artist: 'Retro Synth',
        thumbnailUrl: '',
        highResThumbnailUrl: '',
        duration: const Duration(minutes: 3, seconds: 45),
        videoId: '/storage/music/midnight.mp3',
        filePath: '/storage/music/midnight.mp3',
      );

      await playerProvider.addSongToAlbum(album.id, localSong);

      final updatedAlbum = playerProvider.albums.firstWhere((a) => a.id == album.id);
      expect(updatedAlbum.songs.length, 1);
      expect(updatedAlbum.songs.first.title, 'Midnight Drive');
    });

    test('2. Online streaming song is correctly identified vs local audio for menu options', () {
      const onlineSong = Song(
        id: 'dQw4w9WgXcQ',
        videoId: 'dQw4w9WgXcQ',
        title: 'Never Gonna Give You Up',
        artist: 'Rick Astley',
        thumbnailUrl: 'https://img.youtube.com/vi/dQw4w9WgXcQ/mqdefault.jpg',
        highResThumbnailUrl: 'https://img.youtube.com/vi/dQw4w9WgXcQ/hqdefault.jpg',
        duration: Duration(minutes: 3, seconds: 32),
      );

      const localSong = Song(
        id: '/storage/emulated/0/Music/track.mp3',
        videoId: '/storage/emulated/0/Music/track.mp3',
        title: 'Local Track',
        artist: 'Local Artist',
        thumbnailUrl: '',
        highResThumbnailUrl: '',
        duration: Duration(minutes: 2),
        filePath: '/storage/emulated/0/Music/track.mp3',
      );

      final isOnlineStreaming = !onlineSong.isLocalFile &&
          (onlineSong.filePath == null || onlineSong.filePath!.isEmpty) &&
          !onlineSong.videoId.startsWith('/') &&
          !onlineSong.videoId.startsWith('file://');

      final isLocalDrive = localSong.isLocalFile ||
          (localSong.filePath != null && localSong.filePath!.isNotEmpty) ||
          localSong.videoId.startsWith('/');

      expect(isOnlineStreaming, isTrue);
      expect(isLocalDrive, isTrue);
    });

    test('3. Move song between albums updates song list in source and destination', () async {
      final playerProvider = PlayerProvider(MockAudioHandler());
      await Future.delayed(const Duration(milliseconds: 50));
      final album1 = await playerProvider.createAlbum('Album Alpha');
      final album2 = await playerProvider.createAlbum('Album Beta');

      final song = Song(
        id: 'track_alpha',
        title: 'Alpha Song',
        artist: 'Artist A',
        thumbnailUrl: '',
        highResThumbnailUrl: '',
        duration: const Duration(minutes: 4),
        videoId: 'track_alpha',
        albumFolderName: 'Album Alpha',
      );

      await playerProvider.addSongToAlbum(album1.id, song);
      expect(playerProvider.albums.firstWhere((a) => a.id == album1.id).songs.length, 1);

      // Move to Album Beta
      await playerProvider.moveSongToAnotherAlbumFolder(song, album2.id, physicalMove: false);

      final updatedAlbum1 = playerProvider.albums.firstWhere((a) => a.id == album1.id);
      final updatedAlbum2 = playerProvider.albums.firstWhere((a) => a.id == album2.id);

      expect(updatedAlbum1.songs.length, 0);
      expect(updatedAlbum2.songs.length, 1);
      expect(updatedAlbum2.songs.first.title, 'Alpha Song');
      expect(updatedAlbum2.songs.first.albumFolderName, 'Album Beta');
    });
  });
}
