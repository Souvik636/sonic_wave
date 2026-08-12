import 'package:flutter_test/flutter_test.dart';
import 'package:sonic_wave/services/youtube_service.dart';
import 'package:sonic_wave/services/ytdlp_runtime.dart';
import 'package:sonic_wave/providers/settings_provider.dart';

void main() {
  group('yt-dlp Configuration & Option Tests', () {
    test('ytDlpFormatChain produces valid format filters for all qualities', () {
      final highFormat = YouTubeService.ytDlpFormatChain(AudioQuality.high);
      final mediumFormat = YouTubeService.ytDlpFormatChain(AudioQuality.medium);
      final lowFormat = YouTubeService.ytDlpFormatChain(AudioQuality.low);

      expect(highFormat, contains('bestaudio'));
      expect(mediumFormat, contains('bestaudio'));
      expect(lowFormat, contains('bestaudio'));

      // Must not contain malformed syntax
      expect(highFormat, isNot(contains('--')));
      expect(mediumFormat, isNot(contains('--')));
      expect(lowFormat, isNot(contains('--')));
    });

    test('ytDlpStreamFormatChain produces valid streaming format filters', () {
      final highStream = YouTubeService.ytDlpStreamFormatChain(AudioQuality.high);
      final mediumStream = YouTubeService.ytDlpStreamFormatChain(AudioQuality.medium);
      final lowStream = YouTubeService.ytDlpStreamFormatChain(AudioQuality.low);

      expect(highStream, contains('bestaudio[abr>=160]'));
      expect(mediumStream, contains('bestaudio[abr<=140]'));
      expect(lowStream, contains('bestaudio[abr<=70]'));
    });

    test('ytDlpAudioSorter maps quality settings to valid Seal-style ABR targets', () {
      expect(YouTubeService.ytDlpAudioSorter(AudioQuality.high), equals('abr~192'));
      expect(YouTubeService.ytDlpAudioSorter(AudioQuality.medium), equals('abr~128'));
      expect(YouTubeService.ytDlpAudioSorter(AudioQuality.low), equals('abr~64'));
    });

    test('YtDlpRuntime state and recovery tracking', () {
      expect(YtDlpRuntime.isReady, isFalse);

      // Simulate failure streak
      YtDlpRuntime.markExtractionFailed();
      YtDlpRuntime.markExtractionFailed();
      
      // Mark healthy resets failure count
      YtDlpRuntime.markHealthy();
      expect(YtDlpRuntime.isReady, isFalse);
    });
  });
}
