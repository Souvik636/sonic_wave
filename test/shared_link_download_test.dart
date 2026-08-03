import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sonic_wave/models/song.dart';
import 'package:sonic_wave/providers/player_provider.dart';
import 'package:sonic_wave/services/download_notification_service.dart';
import 'package:sonic_wave/widgets/shared_link_download_card.dart';

import 'migration_test.dart' show MockAudioHandler;

/// Covers the feedback path for a YouTube link shared into the app.
///
/// A share is the one download the user cannot watch: it starts in another
/// app's share sheet, so the card is the only thing that reports it, and the
/// notification is the only thing that reports it once SonicWave is off screen.
/// Both are driven off [SharedDownloadStatus], so its phases are what these
/// tests pin down.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    DownloadNotificationService.resetForTest();
  });

  Song song({
    String id = 'dQw4w9WgXcQ',
    String title = 'Bohemian Rhapsody',
    String artist = 'Queen',
  }) {
    return Song(
      id: id,
      videoId: id,
      title: title,
      artist: artist,
      // Empty artwork + a local path keeps SongAlbumArt on its offline
      // placeholder, so no widget test reaches for the network.
      thumbnailUrl: '',
      highResThumbnailUrl: '',
      duration: const Duration(minutes: 3),
      filePath: '/tmp/$id.m4a',
    );
  }

  group('SharedDownloadStatus', () {
    test('running phases are cancellable and not terminal', () {
      for (final phase in [
        SharedDownloadPhase.resolving,
        SharedDownloadPhase.downloading,
      ]) {
        final status = SharedDownloadStatus(phase: phase, videoId: 'abc');
        expect(status.isCancellable, isTrue, reason: '$phase');
        expect(status.isTerminal, isFalse, reason: '$phase');
      }
    });

    test('finished phases are terminal and no longer cancellable', () {
      for (final phase in [
        SharedDownloadPhase.done,
        SharedDownloadPhase.failed,
        SharedDownloadPhase.duplicate,
      ]) {
        final status = SharedDownloadStatus(phase: phase, videoId: 'abc');
        expect(status.isTerminal, isTrue, reason: '$phase');
        expect(status.isCancellable, isFalse, reason: '$phase');
      }
    });

    test('copyWith keeps the video id — it identifies the whole exchange', () {
      const original = SharedDownloadStatus(
        phase: SharedDownloadPhase.resolving,
        videoId: 'dQw4w9WgXcQ',
      );
      final moved = original.copyWith(
        phase: SharedDownloadPhase.downloading,
        progress: 0.4,
      );
      expect(moved.videoId, 'dQw4w9WgXcQ');
      expect(moved.phase, SharedDownloadPhase.downloading);
      expect(moved.progress, 0.4);
    });

    test('retry is offered by default and withheld explicitly', () {
      const retryable =
          SharedDownloadStatus(phase: SharedDownloadPhase.failed, videoId: 'a');
      expect(retryable.canRetry, isTrue);
      const dead = SharedDownloadStatus(
        phase: SharedDownloadPhase.failed,
        videoId: '',
        canRetry: false,
      );
      expect(dead.canRetry, isFalse);
    });
  });

  group('notification percent gate', () {
    test('only whole-percent changes are pushed', () {
      // onProgress fires per socket chunk; without this gate each one would be
      // a binder round-trip for a bar 1px wider.
      expect(DownloadNotificationService.shouldPushPercent(0.0), isTrue);
      expect(DownloadNotificationService.shouldPushPercent(0.001), isFalse);
      expect(DownloadNotificationService.shouldPushPercent(0.004), isFalse);
      expect(DownloadNotificationService.shouldPushPercent(0.01), isTrue);
      expect(DownloadNotificationService.shouldPushPercent(0.014), isFalse);
      expect(DownloadNotificationService.shouldPushPercent(0.02), isTrue);
    });

    test('a completed transfer always reports its last percent', () {
      DownloadNotificationService.shouldPushPercent(0.5);
      expect(DownloadNotificationService.shouldPushPercent(1.0), isTrue);
      expect(DownloadNotificationService.shouldPushPercent(1.0), isFalse);
    });
  });

  group('handleSharedText', () {
    test('a share with no YouTube link fails with no Retry offered', () async {
      final provider = PlayerProvider(MockAudioHandler());
      await provider.handleSharedText('lunch at 1? here is a cat photo');

      final status = provider.sharedDownload;
      expect(status, isNotNull);
      expect(status!.phase, SharedDownloadPhase.failed);
      // Nothing was parsed, so there is nothing a retry could do differently.
      expect(status.canRetry, isFalse);
      expect(status.videoId, isEmpty);
      provider.dispose();
    });

    test('dismissing clears the card', () async {
      final provider = PlayerProvider(MockAudioHandler());
      await provider.handleSharedText('no link here');
      expect(provider.sharedDownload, isNotNull);

      provider.dismissSharedDownload();
      expect(provider.sharedDownload, isNull);
      provider.dispose();
    });

    test('listeners are notified so the card can animate in', () async {
      final provider = PlayerProvider(MockAudioHandler());
      var notified = 0;
      provider.addListener(() => notified++);

      await provider.handleSharedText('still no link');
      expect(notified, greaterThan(0));
      provider.dispose();
    });
  });

  group('SharedLinkDownloadCard', () {
    Widget harness(PlayerProvider provider) {
      return ChangeNotifierProvider<PlayerProvider>.value(
        value: provider,
        child: const MaterialApp(
          home: Scaffold(
            body: Stack(children: [SharedLinkDownloadCard()]),
          ),
        ),
      );
    }

    /// Never pumpAndSettle: the shimmer, the progress bar and the artwork
    /// skeleton all run repeating controllers that never come to rest.
    Future<void> settle(WidgetTester tester) async {
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 450));
    }

    testWidgets('renders nothing when no link has been shared',
        (tester) async {
      final provider = PlayerProvider(MockAudioHandler());
      await tester.pumpWidget(harness(provider));
      await settle(tester);

      // Dismissible is the card's root once it is on screen, so its absence is
      // the card's absence.
      expect(find.byType(Dismissible), findsNothing);
      expect(find.textContaining('Reading video details'), findsNothing);
      provider.dispose();
    });

    testWidgets('resolving shows the placeholder copy, not an invented title',
        (tester) async {
      final provider = PlayerProvider(MockAudioHandler());
      await tester.pumpWidget(harness(provider));
      provider.debugSetSharedDownload(const SharedDownloadStatus(
        phase: SharedDownloadPhase.resolving,
        videoId: 'dQw4w9WgXcQ',
      ));
      await settle(tester);

      expect(find.text('Reading video details…'), findsOneWidget);
      // Cancel is available before the transfer starts.
      expect(find.byIcon(Icons.close_rounded), findsOneWidget);
      provider.dispose();
    });

    testWidgets('downloading shows title, artist, percent and cancel',
        (tester) async {
      final provider = PlayerProvider(MockAudioHandler());
      await tester.pumpWidget(harness(provider));
      provider.debugSetSharedDownload(SharedDownloadStatus(
        phase: SharedDownloadPhase.downloading,
        videoId: 'dQw4w9WgXcQ',
        song: song(),
        progress: 0.62,
      ));
      await settle(tester);

      expect(find.text('Bohemian Rhapsody'), findsOneWidget);
      expect(find.text('Queen'), findsOneWidget);
      expect(find.text('62%'), findsOneWidget);
      expect(find.byIcon(Icons.close_rounded), findsOneWidget);
      provider.dispose();
    });

    testWidgets('done shows the checkmark and a Play action', (tester) async {
      final provider = PlayerProvider(MockAudioHandler());
      await tester.pumpWidget(harness(provider));
      provider.debugSetSharedDownload(SharedDownloadStatus(
        phase: SharedDownloadPhase.done,
        videoId: 'dQw4w9WgXcQ',
        song: song(),
        progress: 1.0,
        message: 'Saved to Downloads',
      ));
      await settle(tester);

      expect(find.byIcon(Icons.check_rounded), findsOneWidget);
      expect(find.text('Play'), findsOneWidget);
      // The bar has collapsed — the job is done, the percent is noise.
      expect(find.text('100%'), findsNothing);
      provider.dispose();
    });

    testWidgets('an already-downloaded share offers Play instead of a dead end',
        (tester) async {
      final provider = PlayerProvider(MockAudioHandler());
      await tester.pumpWidget(harness(provider));
      provider.debugSetSharedDownload(SharedDownloadStatus(
        phase: SharedDownloadPhase.duplicate,
        videoId: 'dQw4w9WgXcQ',
        song: song(),
        message: 'Already in your Downloads',
      ));
      await settle(tester);

      expect(find.text('Already in your Downloads'), findsOneWidget);
      expect(find.text('Play'), findsOneWidget);
      provider.dispose();
    });

    testWidgets('a retryable failure offers Retry', (tester) async {
      final provider = PlayerProvider(MockAudioHandler());
      await tester.pumpWidget(harness(provider));
      provider.debugSetSharedDownload(SharedDownloadStatus(
        phase: SharedDownloadPhase.failed,
        videoId: 'dQw4w9WgXcQ',
        song: song(),
        message: 'Download failed',
      ));
      await settle(tester);

      expect(find.text('Retry'), findsOneWidget);
      provider.dispose();
    });

    testWidgets('an unparseable share offers dismissal, never Retry',
        (tester) async {
      final provider = PlayerProvider(MockAudioHandler());
      await tester.pumpWidget(harness(provider));
      provider.debugSetSharedDownload(const SharedDownloadStatus(
        phase: SharedDownloadPhase.failed,
        videoId: '',
        message: 'No YouTube link in what you shared',
        canRetry: false,
      ));
      await settle(tester);

      expect(find.text('No YouTube link in what you shared'), findsOneWidget);
      expect(find.text('Retry'), findsNothing);
      expect(find.byIcon(Icons.close_rounded), findsOneWidget);
      provider.dispose();
    });

    testWidgets('tapping cancel clears the card', (tester) async {
      final provider = PlayerProvider(MockAudioHandler());
      await tester.pumpWidget(harness(provider));
      provider.debugSetSharedDownload(SharedDownloadStatus(
        phase: SharedDownloadPhase.downloading,
        videoId: 'dQw4w9WgXcQ',
        song: song(),
        progress: 0.3,
      ));
      await settle(tester);

      await tester.tap(find.byIcon(Icons.close_rounded));
      await settle(tester);

      expect(provider.sharedDownload, isNull);
      provider.dispose();
    });

    testWidgets('a terminal card dismisses itself after its dwell time',
        (tester) async {
      final provider = PlayerProvider(MockAudioHandler());
      await tester.pumpWidget(harness(provider));
      provider.debugSetSharedDownload(SharedDownloadStatus(
        phase: SharedDownloadPhase.done,
        videoId: 'dQw4w9WgXcQ',
        song: song(),
        progress: 1.0,
      ));
      await settle(tester);
      expect(provider.sharedDownload, isNotNull);

      await tester.pump(const Duration(seconds: 5));
      expect(provider.sharedDownload, isNull);
      provider.dispose();
    });

    testWidgets('a download in progress is never auto-dismissed',
        (tester) async {
      final provider = PlayerProvider(MockAudioHandler());
      await tester.pumpWidget(harness(provider));
      provider.debugSetSharedDownload(SharedDownloadStatus(
        phase: SharedDownloadPhase.downloading,
        videoId: 'dQw4w9WgXcQ',
        song: song(),
        progress: 0.1,
      ));
      await settle(tester);

      // Long past every terminal dwell time — this card is the only place the
      // download's progress is shown, so it has to stay.
      await tester.pump(const Duration(seconds: 20));
      expect(provider.sharedDownload, isNotNull);
      provider.dispose();
    });
  });
}
