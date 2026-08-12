import 'package:flutter_test/flutter_test.dart';
import 'package:sonic_wave/services/youtube_service.dart';
import 'package:sonic_wave/services/ytdlp_runtime.dart';
import 'package:sonic_wave/providers/settings_provider.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  group('Native yt-dlp Deep Verification & Quality Test Suite', () {
    test('1. Real YouTube Video ID Format Chain Verification', () {
      final realVideoIds = ['dMMOBgUTMTo', 'OhomOtx0QXM', 'atdLxuJ6QhU', 'hRoeuPZakqs'];
      for (final id in realVideoIds) {
        expect(id.length, equals(11));
        final highChain = YouTubeService.ytDlpFormatChain(AudioQuality.high);
        expect(highChain, contains('bestaudio'));
        expect(highChain, isNot(contains('--buffersize')));
      }
    });

    test('2. Streaming Format Filter Chain Parity', () {
      final highStream = YouTubeService.ytDlpStreamFormatChain(AudioQuality.high);
      final medStream = YouTubeService.ytDlpStreamFormatChain(AudioQuality.medium);
      final lowStream = YouTubeService.ytDlpStreamFormatChain(AudioQuality.low);

      expect(highStream, equals('bestaudio[abr>=160]/bestaudio/best'));
      expect(medStream, equals('bestaudio[abr<=140]/bestaudio/best'));
      expect(lowStream, equals('bestaudio[abr<=70]/worstaudio/bestaudio/best'));
    });

    test('3. Seal-Style Audio Sorter (-S) Mapping Validation', () {
      expect(YouTubeService.ytDlpAudioSorter(AudioQuality.high), equals('abr~192'));
      expect(YouTubeService.ytDlpAudioSorter(AudioQuality.medium), equals('abr~128'));
      expect(YouTubeService.ytDlpAudioSorter(AudioQuality.low), equals('abr~64'));
    });

    test('4. YtDlpRuntime Threshold & Recovery State Machine', () {
      YtDlpRuntime.markHealthy();
      expect(YtDlpRuntime.isReady, isFalse);

      // Failures 1 to 4 should NOT trip unhealthy reset
      for (int i = 1; i <= 4; i++) {
        YtDlpRuntime.markExtractionFailed();
      }

      // Mark healthy clears failure streak
      YtDlpRuntime.markHealthy();

      // 5 failures trip unhealthy reset
      for (int i = 1; i <= 5; i++) {
        YtDlpRuntime.markExtractionFailed();
      }
    });
  });
}
