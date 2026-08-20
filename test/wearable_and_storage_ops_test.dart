import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sonic_wave/models/song.dart';
import 'package:sonic_wave/providers/player_provider.dart';
import 'package:sonic_wave/services/wearable_service.dart';
import 'package:sonic_wave/widgets/wearable_connection_banner.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('Duplicate Deletion & Canonical Path Keying Tests', () {
    test('Canonical path keys distinguish duplicate songs sharing videoId', () {
      final song1 = Song(
        id: '1',
        videoId: 'duplicate_vid_123',
        title: 'Song Title',
        artist: 'Artist',
        thumbnailUrl: 'https://example.com/art.jpg',
        highResThumbnailUrl: 'https://example.com/art_hd.jpg',
        duration: const Duration(minutes: 3),
        filePath: '/storage/emulated/0/Music/Song.mp3',
      );
      final song2 = Song(
        id: '2',
        videoId: 'duplicate_vid_123',
        title: 'Song Title',
        artist: 'Artist',
        thumbnailUrl: 'https://example.com/art.jpg',
        highResThumbnailUrl: 'https://example.com/art_hd.jpg',
        duration: const Duration(minutes: 3),
        filePath: '/storage/emulated/0/Download/Song.mp3',
      );

      final key1 = PlayerProvider.canonicalizePath(song1.filePath ?? song1.videoId);
      final key2 = PlayerProvider.canonicalizePath(song2.filePath ?? song2.videoId);

      // Keys must be distinct so selecting song2 will never select or delete song1!
      expect(key1, isNot(equals(key2)));
      expect(key1, '/storage/emulated/0/Music/Song.mp3');
      expect(key2, '/storage/emulated/0/Download/Song.mp3');

      final selectedKeys = <String>{};
      selectedKeys.add(key2); // Select only song 2

      final toDelete = [song1, song2].where((s) => selectedKeys.contains(
        PlayerProvider.canonicalizePath(s.filePath ?? s.videoId),
      )).toList();

      // Only song2 is selected for deletion
      expect(toDelete.length, 1);
      expect(toDelete.first.filePath, song2.filePath);
    });
  });

  group('WearableService Event Parsing & Classification Tests', () {
    test('Correctly identifies smartwatches and fitness bands', () {
      final service = WearableService();
      expect(service.connectedDevices, isEmpty);

      // Verify WearableEvent properties
      final watchEvent = WearableEvent(
        name: 'Galaxy Watch6 Classic',
        type: WearableDeviceType.watch,
        isConnected: true,
        timestamp: DateTime.now(),
      );

      expect(watchEvent.iconLabel, '⌚');
      expect(watchEvent.typeTitle, 'Smartwatch & Wearable');
      expect(watchEvent.isConnected, true);
    });

    test('Correctly identifies wireless headsets and earbuds', () {
      final headsetEvent = WearableEvent(
        name: 'Sony WH-1000XM5',
        type: WearableDeviceType.headset,
        isConnected: true,
        timestamp: DateTime.now(),
      );

      expect(headsetEvent.iconLabel, '🎧');
      expect(headsetEvent.typeTitle, 'Wireless Headset');
    });

    test('Correctly identifies bluetooth speakers and car audio', () {
      final speakerEvent = WearableEvent(
        name: 'JBL Flip 6',
        type: WearableDeviceType.speaker,
        isConnected: true,
        timestamp: DateTime.now(),
      );
      final carEvent = WearableEvent(
        name: 'Android Auto Car Media',
        type: WearableDeviceType.car,
        isConnected: true,
        timestamp: DateTime.now(),
      );

      expect(speakerEvent.iconLabel, '🔊');
      expect(carEvent.iconLabel, '🚗');
    });

    testWidgets('WearableConnectionBanner renders compact luxury pill without overflow on 320px phone', (tester) async {
      tester.view.physicalSize = const Size(320, 640);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);

      WearableService().activeEventNotifier.value = WearableEvent(
        name: 'OnePlus Bullets Wireless Z2',
        type: WearableDeviceType.headset,
        isConnected: true,
        timestamp: DateTime.now(),
      );

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Stack(
              children: const [
                WearableConnectionBanner(),
              ],
            ),
          ),
        ),
      );

      await tester.pump(const Duration(milliseconds: 100));
      expect(find.text('OnePlus Bullets Wireless Z2'), findsOneWidget);
      expect(find.text('CONNECTED • LOSSLESS HI-FI'), findsOneWidget);

      WearableService().activeEventNotifier.value = null;
    });
  });
}
