import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sonic_wave/models/song.dart';
import 'package:sonic_wave/services/local_metadata_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempDir;
  late Directory supportDir;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('sonic_meta_test_');
    supportDir = await Directory.systemTemp.createTemp('sonic_support_test_');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      (MethodCall methodCall) async {
        if (methodCall.method == 'getApplicationSupportDirectory') {
          return supportDir.path;
        }
        return tempDir.path;
      },
    );
  });

  tearDown(() async {
    for (final d in [tempDir, supportDir]) {
      try {
        if (await d.exists()) await d.delete(recursive: true);
      } catch (_) {}
    }
  });

  /// Build a minimal MP3 file with a hand-rolled ID3v2.3 tag containing
  /// TIT2 (title) + TPE1 (artist), followed by an MPEG frame header — the
  /// exact byte layout the parser detects. No writer dependency.
  File makeTaggedMp3(String name, String title, String artist) {
    List<int> frame(String id, String text) {
      final content = <int>[0x00, ...latin1.encode(text)]; // 0x00 = latin-1
      return [
        ...ascii.encode(id),
        (content.length >> 24) & 0xFF,
        (content.length >> 16) & 0xFF,
        (content.length >> 8) & 0xFF,
        content.length & 0xFF,
        0x00, 0x00, // flags
        ...content,
      ];
    }

    final frames = [...frame('TIT2', title), ...frame('TPE1', artist)];
    final size = frames.length;
    final header = [
      ...ascii.encode('ID3'),
      0x03, 0x00, // v2.3.0
      0x00, // flags
      // syncsafe size (7 bits per byte)
      (size >> 21) & 0x7F,
      (size >> 14) & 0x7F,
      (size >> 7) & 0x7F,
      size & 0x7F,
    ];

    final file = File('${tempDir.path}${Platform.pathSeparator}$name');
    file.writeAsBytesSync([
      ...header,
      ...frames,
      0xFF, 0xFB, 0x90, 0x00, // MPEG-1 Layer III frame sync
      ...List<int>.filled(512, 0),
    ]);
    return file;
  }

  test('enrichSong reads embedded title/artist tags when present', () async {
    final file = makeTaggedMp3('track1.mp3', 'Real Title', 'Real Artist');

    final song = Song(
      id: file.path,
      title: 'track1',
      artist: 'Local Audio',
      thumbnailUrl: '',
      highResThumbnailUrl: '',
      duration: const Duration(minutes: 3),
      videoId: file.path,
      filePath: file.path,
    );

    final enriched = await LocalMetadataService().enrichSong(song);
    expect(enriched.title, 'Real Title');
    expect(enriched.artist, 'Real Artist');
  });

  test('enrichSong leaves non-local (streamed) songs untouched', () async {
    const streamed = Song(
      id: 'abc123',
      title: 'Streamed Song',
      artist: 'Some Artist',
      thumbnailUrl: 'https://img.youtube.com/vi/abc123/mqdefault.jpg',
      highResThumbnailUrl: 'https://img.youtube.com/vi/abc123/hqdefault.jpg',
      duration: Duration(minutes: 4),
      videoId: 'abc123',
    );

    final result = await LocalMetadataService().enrichSong(streamed);
    expect(result.title, 'Streamed Song');
    expect(result.artist, 'Some Artist');
    expect(result.thumbnailUrl, streamed.thumbnailUrl);
  });

  test('enrichSong keeps filename-derived values when file has no tags',
      () async {
    // A file with no readable tags → service must fall back to whatever the
    // Song already carries (filename guess), never blank it out.
    final file = File('${tempDir.path}${Platform.pathSeparator}untagged.mp3');
    file.writeAsBytesSync(List<int>.filled(256, 0));

    final song = Song(
      id: file.path,
      title: 'My Guessed Title',
      artist: 'Guessed Artist',
      thumbnailUrl: '',
      highResThumbnailUrl: '',
      duration: const Duration(minutes: 2),
      videoId: file.path,
      filePath: file.path,
    );

    final enriched = await LocalMetadataService().enrichSong(song);
    expect(enriched.title, 'My Guessed Title');
    expect(enriched.artist, 'Guessed Artist');
  });
}
