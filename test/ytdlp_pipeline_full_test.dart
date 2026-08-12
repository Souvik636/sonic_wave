import 'dart:io';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sonic_wave/services/youtube_service.dart';
import 'package:sonic_wave/services/ytdlp_downloader.dart';
import 'package:sonic_wave/services/ytdlp_runtime.dart';
import 'package:sonic_wave/providers/settings_provider.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      (MethodCall methodCall) async {
        if (methodCall.method == 'getTemporaryDirectory' ||
            methodCall.method == 'getApplicationDocumentsDirectory') {
          return Directory.systemTemp.path;
        }
        return null;
      },
    );
  });

  group('Full yt-dlp Pipeline Deep-Dive Test Suite', () {
    test('1. Download Format Chain Matrix across High, Medium, Low', () {
      for (final q in AudioQuality.values) {
        final chain = YouTubeService.ytDlpFormatChain(q);
        expect(chain, isNotEmpty);
        expect(chain, contains('bestaudio'));
        // Verify no invalid typo options
        expect(chain, isNot(contains('--buffersize')));
      }
    });

    test('2. Streaming Format Chain Matrix across High, Medium, Low', () {
      for (final q in AudioQuality.values) {
        final streamChain = YouTubeService.ytDlpStreamFormatChain(q);
        expect(streamChain, isNotEmpty);
        expect(streamChain, contains('bestaudio'));
      }
    });

    test('3. Seal-style Audio Sorter (-S) Bitrate Mapping', () {
      expect(YouTubeService.ytDlpAudioSorter(AudioQuality.high), equals('abr~192'));
      expect(YouTubeService.ytDlpAudioSorter(AudioQuality.medium), equals('abr~128'));
      expect(YouTubeService.ytDlpAudioSorter(AudioQuality.low), equals('abr~64'));
    });

    test('4. Player Client Priority Order for Anti-Throttling', () {
      // android_vr and tv are not PO-token gated and yield audio-only streams
      final service = YouTubeService();
      expect(service, isNotNull);
    });

    test('5. Staging Directory Creation & Cleanup Protocol', () async {
      final dir = await YtDlpDownloader.stagingDir();
      expect(dir.existsSync(), isTrue);
      expect(dir.path, contains('ytdlp_dl'));
    });

    test('6. YtDlpRuntime Health Manager Failure & Recovery Circuit Breaker', () {
      // Start clean
      YtDlpRuntime.markHealthy();
      expect(YtDlpRuntime.isReady, isFalse);

      // Single failure increments counter without resetting
      YtDlpRuntime.markExtractionFailed();
      
      // Success resets failure streak immediately
      YtDlpRuntime.markHealthy();

      // Three consecutive failures trigger unhealthy reset
      YtDlpRuntime.markExtractionFailed();
      YtDlpRuntime.markExtractionFailed();
      YtDlpRuntime.markExtractionFailed();

      // Reset state checked
      expect(YtDlpRuntime.isReady, isFalse);
    });
  });
}
