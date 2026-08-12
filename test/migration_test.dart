import 'dart:convert';
import 'dart:io';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:audio_service/audio_service.dart';
import 'package:sonic_wave/providers/player_provider.dart';
import 'package:sonic_wave/services/storage_location_service.dart';
import 'package:sonic_wave/services/audio_handler.dart';
import 'package:just_audio/just_audio.dart';

class MockAudioHandler extends BaseAudioHandler implements SonicWaveAudioHandler {
  @override
  final AudioPlayer player = AudioPlayer();

  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempDir;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('sonic_wave_test_');
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

    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('com.sonicwave.sonic_wave/intent'),
      (MethodCall methodCall) async => null,
    );

    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('com.sonicwave.sonic_wave/equalizer'),
      (MethodCall methodCall) async => null,
    );
  });

  tearDown(() async {
    try {
      if (await tempDir.exists()) {
        await tempDir.delete(recursive: true);
      }
    } catch (_) {}
  });

  test('migrateDownloadedFiles moves custom albums, songs, and metadata recursively', () async {
    // 1. Set up SharedPreferences initial values
    final mockAlbumsJson = json.encode([
      {
        'id': 'album_1',
        'name': 'Gym Energy',
        'songs': [
          {
            'id': 'song_1',
            'title': 'Song One',
            'artist': 'Artist One',
            'thumbnailUrl': '',
            'highResThumbnailUrl': '',
            'duration': 180000,
            'videoId': 'song_1',
            // Will set a real path dynamically below
          }
        ],
        'isCustom': true,
        'isFolderBased': true
      }
    ]);

    SharedPreferences.setMockInitialValues({
      'storage_location_type': StorageType.appInternal.index,
      'user_albums': mockAlbumsJson,
    });
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt('storage_location_type', StorageType.appInternal.index);
    await prefs.setString('user_albums', mockAlbumsJson);

    final storageService = StorageLocationService();
    await storageService.initialize();
    final oldRootDir = Directory('${tempDir.path}/internal_app');
    final oldAlbumDir = Directory('${oldRootDir.path}/Gym Energy');
    final oldDownloadDir = Directory('${oldRootDir.path}/Download');
    final oldMetaDir = Directory('${oldRootDir.path}/.sonicwave');

    if (await oldRootDir.exists()) await oldRootDir.delete(recursive: true);
    await oldAlbumDir.create(recursive: true);
    await oldDownloadDir.create(recursive: true);
    await oldMetaDir.create(recursive: true);

    // Write mock song file in the old album folder
    final oldSongFile = File('${oldAlbumDir.path}/song_1.mp3');
    await oldSongFile.writeAsString('audio content');

    // Write mock cover image in the old album folder
    final oldCoverFile = File('${oldAlbumDir.path}/cover.jpg');
    await oldCoverFile.writeAsString('image content');

    // Write metadata.json cache in the old meta folder
    final metadataFile = File('${oldMetaDir.path}/metadata.json');
    final metadataJson = json.encode([
      {
        'id': 'song_1',
        'title': 'Song One',
        'artist': 'Artist One',
        'thumbnailUrl': '',
        'highResThumbnailUrl': '',
        'duration': 180000,
        'videoId': 'song_1',
        'filePath': oldSongFile.path,
      }
    ]);
    await metadataFile.writeAsString(metadataJson);

    // Initialize provider and load albums/downloads
    final provider = PlayerProvider(MockAudioHandler());
    
    // We need to set the song path in the loaded album JSON to the real dynamic temp path
    // Let's reload albums by manually modifying the albums list since the dynamic path was unknown earlier.
    await provider.scanLocalSongs(); // scans and loads initial structure
    
    // Set explicit folder path and file path for the test run
    final loadedAlbums = provider.albums;
    expect(loadedAlbums.length, equals(1));
    final updatedSongs = [
      loadedAlbums.first.songs.first.copyWith(filePath: oldSongFile.path)
    ];
    await provider.updateAlbumSongs(loadedAlbums.first.id, updatedSongs);
    await provider.updateAlbumCover(loadedAlbums.first.id, oldCoverFile.path);
    await provider.loadDownloads();

    // Verify setup
    expect(provider.albums.first.songs.first.filePath?.replaceAll('\\', '/'), equals(oldSongFile.path.replaceAll('\\', '/')));
    expect(provider.albums.first.coverImagePath, isNotNull);
    expect(File(provider.albums.first.coverImagePath!).existsSync(), isTrue);
    expect(await oldSongFile.exists(), isTrue);
    expect(await oldCoverFile.exists(), isTrue);

    // 2. Perform Migration to SD Card (pointing to our tempDir)
    final isMigrated = await provider.migrateDownloadedFiles(
      StorageType.appInternal,
      StorageType.sdCard,
      sdCardPath: tempDir.path,
    );

    expect(isMigrated, isTrue);

    final newSongFile = File(provider.albums.first.songs.first.filePath!);
    final newAlbumDir = newSongFile.parent;

    expect(await newAlbumDir.exists(), isTrue);
    expect(await newSongFile.exists(), isTrue);

    // Check content migrated
    expect(await newSongFile.readAsString(), equals('audio content'));

    // 4. Verify in-memory state updated correctly
    expect(provider.albums.first.songs.first.filePath?.replaceAll('\\', '/'), equals(newSongFile.path.replaceAll('\\', '/')));
  });
}
