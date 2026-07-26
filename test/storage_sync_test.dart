import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sonic_wave/models/album.dart';
import 'package:sonic_wave/models/song.dart';
import 'package:sonic_wave/providers/player_provider.dart';
import 'package:sonic_wave/services/download_service.dart';
import 'package:sonic_wave/services/id3_tag_writer.dart';
import 'package:sonic_wave/services/storage_location_service.dart';
import 'migration_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempDir;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('sonic_wave_sync_test_');
    SharedPreferences.setMockInitialValues({});

    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      (MethodCall methodCall) async {
        if (methodCall.method == 'getApplicationDocumentsDirectory' ||
            methodCall.method == 'getApplicationSupportDirectory') {
          return tempDir.path;
        } else if (methodCall.method == 'getExternalStorageDirectories') {
          return [tempDir.path];
        }
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

  group('Storage Sync Engine & ID3 Tag Writer Tests', () {
    test('1. ID3TagWriter embeds cover art into MP3 file', () async {
      final audioFile = File('${tempDir.path}/test_song.mp3');
      await audioFile.writeAsBytes(Uint8List.fromList(List.filled(1024, 0xFF)));

      final dummyJpg = Uint8List.fromList([0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x10, 0x4A, 0x46, 0x49, 0x46]);
      final success = await ID3TagWriter.embedCoverArt(
        audioFile: audioFile,
        imageBytes: dummyJpg,
        mimeType: 'image/jpeg',
        title: 'Test Song Title',
        artist: 'Test Artist',
      );

      expect(success, isTrue);
      expect(await audioFile.exists(), isTrue);
      final bytes = await audioFile.readAsBytes();
      expect(bytes.length, greaterThan(1024));
      expect(bytes[0], equals(0x49)); // 'I'
      expect(bytes[1], equals(0x44)); // 'D'
      expect(bytes[2], equals(0x33)); // '3'
    });

    test('2. DownloadService verifyStorageIntegrity purges missing files', () async {
      final validSongFile = File('${tempDir.path}/valid_song.mp3');
      await validSongFile.writeAsString('audio data');

      final downloadService = DownloadService();
      final validPath = validSongFile.path;
      final missingPath = '${tempDir.path}/ghost_song.mp3';

      final mockList = [
        Song(
          id: 'v1',
          videoId: 'v1',
          title: 'Valid Song',
          artist: 'Artist',
          thumbnailUrl: '',
          highResThumbnailUrl: '',
          duration: Duration(minutes: 3),
          filePath: validPath,
        ),
        Song(
          id: 'g1',
          videoId: 'g1',
          title: 'Ghost Song',
          artist: 'Artist',
          thumbnailUrl: '',
          highResThumbnailUrl: '',
          duration: Duration(minutes: 3),
          filePath: missingPath,
        ),
      ];

      final storageService = StorageLocationService();
      await storageService.initialize();
      final downloadDir = await storageService.getDownloadDir();

      final metaFile = File('${downloadDir.path}/metadata.json');
      await metaFile.writeAsString(json.encode(mockList.map((s) => s.toJson()).toList()));

      await downloadService.loadDownloads(force: true);

      final downloads = await downloadService.getDownloadedSongs();
      expect(downloads.length, equals(1));
      expect(downloads.first.videoId, equals('v1'));
    });

    test('3. PlayerProvider verifyAndSyncAllStores prunes deleted songs from albums and favorites', () async {
      final validFile = File('${tempDir.path}/album_track_1.mp3');
      await validFile.writeAsString('valid content');

      final missingFile = File('${tempDir.path}/deleted_by_user.mp3');
      if (await missingFile.exists()) await missingFile.delete();

      final validSong = Song(
        id: 's1', videoId: 's1', title: 'Valid Track', artist: 'Artist',
        thumbnailUrl: '', highResThumbnailUrl: '', duration: Duration(minutes: 3),
        filePath: validFile.path,
      );

      final missingSong = Song(
        id: 's2', videoId: 's2', title: 'Deleted Track', artist: 'Artist',
        thumbnailUrl: '', highResThumbnailUrl: '', duration: Duration(minutes: 3),
        filePath: missingFile.path,
      );

      final mockAlbum = UserAlbum(
        id: 'alb_1',
        name: 'My Mix',
        songs: [validSong, missingSong],
      );

      SharedPreferences.setMockInitialValues({
        'user_albums': json.encode([mockAlbum.toJson()]),
        'favorites_songs': json.encode([validSong.toJson(), missingSong.toJson()]),
      });

      final provider = PlayerProvider(MockAudioHandler());
      await provider.scanLocalSongs();

      expect(provider.albums.first.songs.length, equals(1));
      expect(provider.albums.first.songs.first.videoId, equals('s1'));
      expect(provider.favorites.length, equals(1));
      expect(provider.favorites.first.videoId, equals('s1'));
    });
  });
}
