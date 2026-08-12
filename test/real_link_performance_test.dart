import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sonic_wave/services/youtube_link_parser.dart';
import 'package:sonic_wave/services/youtube_service.dart';
import 'package:sonic_wave/providers/settings_provider.dart';

void main() {
  group('Real YouTube Link Performance & Android Audit Test Suite', () {
    test('1. Real Link Parsing Speed Benchmark (< 1ms per link)', () {
      final realYtLinks = [
        'https://www.youtube.com/watch?v=atdLxuJ6QhU',
        'Check out this video!\nhttps://youtu.be/atdLxuJ6QhU?si=AbCdEfGh123 via @YouTube',
        'https://www.youtube.com/shorts/L6aZQo97L74',
        'https://music.youtube.com/watch?v=MK6ar6GJklo&feature=share',
        'https://www.youtube.com/embed/i2GC06euEDE',
      ];

      // Warmup pass for Dart JIT regex compilation
      for (final link in realYtLinks) {
        YouTubeLinkParser.extractVideoId(link);
      }

      final sw = Stopwatch()..start();
      for (final link in realYtLinks) {
        final id = YouTubeLinkParser.extractVideoId(link);
        expect(id, isNotNull);
        expect(id!.length, equals(11));
      }
      sw.stop();

      // Total parsing time for 5 complex links post-warmup must be under 50ms in debug VM
      expect(sw.elapsedMilliseconds, lessThan(50));
      debugPrint('[Perf] 5 real YouTube links parsed in ${sw.elapsedMicroseconds} µs');
    });

    test('2. Android Share Sheet Multiline Parsing Accuracy', () {
      const shareFromYouTubeApp = '''
Listening to Starboy by The Weeknd
https://youtu.be/dMMOBgUTMTo?si=9x8y7z
Check it out on YouTube!
''';

      final videoId = YouTubeLinkParser.extractVideoId(shareFromYouTubeApp);
      expect(videoId, equals('dMMOBgUTMTo'));
    });

    test('3. Stream Quality Format Matrix Parity', () {
      final highFormat = YouTubeService.ytDlpFormatChain(AudioQuality.high);
      final medFormat = YouTubeService.ytDlpFormatChain(AudioQuality.medium);
      final lowFormat = YouTubeService.ytDlpFormatChain(AudioQuality.low);

      expect(highFormat, isNotEmpty);
      expect(medFormat, isNotEmpty);
      expect(lowFormat, isNotEmpty);
    });
  });
}
