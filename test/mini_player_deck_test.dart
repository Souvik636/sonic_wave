import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:audio_service/audio_service.dart';
import 'package:sonic_wave/models/song.dart';
import 'package:sonic_wave/providers/player_provider.dart';
import 'package:sonic_wave/providers/settings_provider.dart';
import 'package:sonic_wave/widgets/mini_player.dart';
import 'package:sonic_wave/widgets/shared_link_download_card.dart';

import 'migration_test.dart' show MockAudioHandler;

class _TestAudioHandler extends MockAudioHandler {
  Song? _current;
  final List<Song> _playlist = [];

  @override
  Song? get currentSong => _current;

  set testCurrentSong(Song? s) {
    _current = s;
    if (s != null) {
      _playlist.clear();
      _playlist.add(s);
      mediaItem.add(MediaItem(id: s.id, title: s.title, artist: s.artist));
    } else {
      mediaItem.add(null);
    }
  }

  @override
  List<Song> get playlist => _playlist;

  @override
  int get currentIndex => 0;

  @override
  bool get isShuffled => false;

  @override
  AudioServiceRepeatMode get repeatMode => AudioServiceRepeatMode.none;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  Song createSong({
    String id = 'dQw4w9WgXcQ',
    String title = 'Test Track',
    String artist = 'Test Artist',
  }) {
    return Song(
      id: id,
      videoId: id,
      title: title,
      artist: artist,
      thumbnailUrl: '',
      highResThumbnailUrl: '',
      duration: const Duration(minutes: 3),
      filePath: '/tmp/$id.m4a',
    );
  }

  Widget buildTestableWidget({
    required PlayerProvider playerProvider,
    required SettingsProvider settingsProvider,
  }) {
    return MultiProvider(
      providers: [
        ChangeNotifierProvider<PlayerProvider>.value(value: playerProvider),
        ChangeNotifierProvider<SettingsProvider>.value(value: settingsProvider),
      ],
      child: const MaterialApp(
        home: Scaffold(
          body: Stack(
            children: [
              Positioned(
                left: 0,
                right: 0,
                bottom: 62,
                child: MiniPlayer(),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> settle(WidgetTester tester) async {
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 450));
  }

  testWidgets('MiniPlayer renders Now Playing card when only song is present', (tester) async {
    final audioHandler = _TestAudioHandler();
    final playerProvider = PlayerProvider(audioHandler);
    final settingsProvider = SettingsProvider();

    final testSong = createSong(title: 'Active Now Playing Track');
    audioHandler.testCurrentSong = testSong;

    await tester.pumpWidget(buildTestableWidget(
      playerProvider: playerProvider,
      settingsProvider: settingsProvider,
    ));
    await settle(tester);

    expect(find.text('Active Now Playing Track'), findsOneWidget);
    expect(find.text('Test Artist'), findsOneWidget);
    playerProvider.dispose();
    settingsProvider.dispose();
  });

  testWidgets('MiniPlayer renders Shared Download card when only shared download is active', (tester) async {
    final audioHandler = _TestAudioHandler();
    final playerProvider = PlayerProvider(audioHandler);
    final settingsProvider = SettingsProvider();

    playerProvider.debugSetSharedDownload(SharedDownloadStatus(
      phase: SharedDownloadPhase.downloading,
      videoId: 'shared123',
      progress: 0.45,
      song: createSong(id: 'shared123', title: 'Shared YouTube Audio'),
    ));

    await tester.pumpWidget(buildTestableWidget(
      playerProvider: playerProvider,
      settingsProvider: settingsProvider,
    ));
    await settle(tester);

    expect(find.text('Shared YouTube Audio'), findsOneWidget);
    expect(find.byType(SharedDownloadCardSurface), findsOneWidget);
    playerProvider.dispose();
    settingsProvider.dispose();
  });

  testWidgets('MiniPlayer dual deck allows vertical swipe & tap switching between Now Playing and Shared Download', (tester) async {
    final audioHandler = _TestAudioHandler();
    final playerProvider = PlayerProvider(audioHandler);
    final settingsProvider = SettingsProvider();

    final testSong = createSong(id: 'playing1', title: 'Current Playing Song');
    audioHandler.testCurrentSong = testSong;

    // Report shared download
    playerProvider.debugSetSharedDownload(SharedDownloadStatus(
      phase: SharedDownloadPhase.downloading,
      videoId: 'shared999',
      progress: 0.75,
      song: createSong(id: 'shared999', title: 'Shared Downloading Track'),
    ));

    await tester.pumpWidget(buildTestableWidget(
      playerProvider: playerProvider,
      settingsProvider: settingsProvider,
    ));
    await settle(tester);

    // Auto-promotes download card to front
    expect(find.byKey(const ValueKey('deck_shared_download')), findsOneWidget);
    expect(find.text('Shared Downloading Track'), findsOneWidget);

    // Swipe up or down to flip deck
    await tester.fling(find.byType(MiniPlayer), const Offset(0, -300), 1000, warnIfMissed: false);
    await settle(tester);

    // Now Playing card comes to front
    expect(find.byKey(const ValueKey('deck_now_playing')), findsOneWidget);
    expect(find.text('Current Playing Song'), findsOneWidget);

    // Swipe again to flip back
    await tester.fling(find.byType(MiniPlayer), const Offset(0, 300), 1000, warnIfMissed: false);
    await settle(tester);

    // Download card comes back to front
    expect(find.byKey(const ValueKey('deck_shared_download')), findsOneWidget);
    expect(find.text('Shared Downloading Track'), findsOneWidget);
    playerProvider.dispose();
    settingsProvider.dispose();
  });
}
