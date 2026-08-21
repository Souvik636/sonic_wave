import 'dart:io';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sonic_wave/models/song.dart';
import 'package:sonic_wave/providers/player_provider.dart';
import 'package:sonic_wave/widgets/storage_operation_dialog.dart';

import 'migration_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempDir;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('sonic_wave_storage_test_');
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

  group('Unified Storage Operations Tests (Copy, Move, Bookmark)', () {
    test('1. "Make a Copy" duplicates audio file into target album and preserves source', () async {
      final playerProvider = PlayerProvider(MockAudioHandler());
      await Future.delayed(const Duration(milliseconds: 50));

      final sourceDir = Directory('${tempDir.path}/SourceAlbum');
      await sourceDir.create(recursive: true);
      final sourceFile = File('${sourceDir.path}/test_song.mp3');
      await sourceFile.writeAsString('audio binary content mock');

      final targetAlbum = await playerProvider.createAlbum('Target Album');

      final song = Song(
        id: 'song_src_1',
        videoId: sourceFile.path,
        filePath: sourceFile.path,
        title: 'Original Song',
        artist: 'Artist One',
        thumbnailUrl: '',
        highResThumbnailUrl: '',
        duration: const Duration(minutes: 3, seconds: 30),
        albumFolderName: 'SourceAlbum',
      );

      // Perform "Make a Copy"
      final success = await playerProvider.moveSongToAnotherAlbumFolder(
        song,
        targetAlbum.id,
        physicalMove: true,
        isCopyMode: true,
      );

      expect(success, isTrue);
      // Original file must still exist
      expect(await sourceFile.exists(), isTrue);

      // Target album should have 1 song with new copy path
      final updatedTarget = playerProvider.albums.firstWhere((a) => a.id == targetAlbum.id);
      expect(updatedTarget.songs.length, 1);
      final copiedSong = updatedTarget.songs.first;
      expect(copiedSong.title, 'Original Song');
      expect(copiedSong.filePath, isNotNull);
      expect(copiedSong.filePath != sourceFile.path, isTrue);
      expect(await File(copiedSong.filePath!).exists(), isTrue);
      expect(await File(copiedSong.filePath!).readAsString(), 'audio binary content mock');
    });

    test('2. "Permanently Move" physically transfers file and updates previous album', () async {
      final playerProvider = PlayerProvider(MockAudioHandler());
      await Future.delayed(const Duration(milliseconds: 50));

      final sourceAlbum = await playerProvider.createAlbum('Source Folder');
      final targetAlbum = await playerProvider.createAlbum('Destination Folder');

      final sourceDir = Directory('${tempDir.path}/Source Folder');
      await sourceDir.create(recursive: true);
      final sourceFile = File('${sourceDir.path}/move_me.mp3');
      await sourceFile.writeAsString('audio content for moving');

      final song = Song(
        id: 'song_move_1',
        videoId: sourceFile.path,
        filePath: sourceFile.path,
        title: 'Move Me',
        artist: 'Artist Two',
        thumbnailUrl: '',
        highResThumbnailUrl: '',
        duration: const Duration(minutes: 4),
        albumFolderName: 'Source Folder',
      );

      await playerProvider.addSongToAlbum(sourceAlbum.id, song);
      expect(playerProvider.albums.firstWhere((a) => a.id == sourceAlbum.id).songs.length, 1);

      // Perform "Permanently Move"
      final success = await playerProvider.moveSongToAnotherAlbumFolder(
        song,
        targetAlbum.id,
        physicalMove: true,
        isCopyMode: false,
      );

      expect(success, isTrue);
      // Original source file should no longer exist
      expect(await sourceFile.exists(), isFalse);

      // Source album must no longer have the song
      final updatedSource = playerProvider.albums.firstWhere((a) => a.id == sourceAlbum.id);
      expect(updatedSource.songs.length, 0);

      // Destination album must contain the moved song with verified file
      final updatedTarget = playerProvider.albums.firstWhere((a) => a.id == targetAlbum.id);
      expect(updatedTarget.songs.length, 1);
      final movedSong = updatedTarget.songs.first;
      expect(movedSong.title, 'Move Me');
      expect(await File(movedSong.filePath!).exists(), isTrue);
      expect(await File(movedSong.filePath!).readAsString(), 'audio content for moving');
    });

    test('3. "In-App Bookmark" leaves physical file untouched at original location', () async {
      final playerProvider = PlayerProvider(MockAudioHandler());
      await Future.delayed(const Duration(milliseconds: 50));

      final album = await playerProvider.createAlbum('Bookmarked Favorites');

      final sourceFile = File('${tempDir.path}/original_untouched.mp3');
      await sourceFile.writeAsString('untouched original audio bytes');

      final song = Song(
        id: 'bookmark_1',
        videoId: sourceFile.path,
        filePath: sourceFile.path,
        title: 'Bookmark Track',
        artist: 'Artist Three',
        thumbnailUrl: '',
        highResThumbnailUrl: '',
        duration: const Duration(minutes: 2, seconds: 15),
      );

      // Perform In-App Bookmark (physicalMove: false)
      final success = await playerProvider.moveSongToAnotherAlbumFolder(
        song,
        album.id,
        physicalMove: false,
        isCopyMode: false,
      );

      expect(success, isTrue);
      // Original file unchanged
      expect(await sourceFile.exists(), isTrue);
      expect(await sourceFile.readAsString(), 'untouched original audio bytes');

      final updatedAlbum = playerProvider.albums.firstWhere((a) => a.id == album.id);
      expect(updatedAlbum.songs.length, 1);
      expect(updatedAlbum.songs.first.filePath, sourceFile.path);
    });

    test('4. StorageOperationChoice model constants are correctly configured', () {
      expect(StorageOperationChoice.copy.physicalMove, isTrue);
      expect(StorageOperationChoice.copy.isCopyMode, isTrue);

      expect(StorageOperationChoice.move.physicalMove, isTrue);
      expect(StorageOperationChoice.move.isCopyMode, isFalse);

      expect(StorageOperationChoice.bookmark.physicalMove, isFalse);
      expect(StorageOperationChoice.bookmark.isCopyMode, isFalse);
    });
  });
}
