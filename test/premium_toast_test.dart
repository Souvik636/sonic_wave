import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sonic_wave/widgets/premium_toast.dart';

void main() {
  group('classifyPlaybackError maps message context to icon/duration/retry', () {
    test('network errors get the wifi icon and the longest dwell', () {
      final ctx = classifyPlaybackError(
          'No internet connection. Please check your network and try again.');
      expect(ctx.icon, Icons.wifi_off_rounded);
      expect(ctx.dismissAfter, const Duration(seconds: 6));
      expect(ctx.canRetry, isTrue);
    });

    test('timeouts are classified as slow, retryable', () {
      final ctx = classifyPlaybackError(
          'Connection timed out. Your internet may be slow — please try again.');
      expect(ctx.icon, Icons.hourglass_bottom_rounded);
      expect(ctx.dismissAfter, const Duration(seconds: 5));
      expect(ctx.canRetry, isTrue);
    });

    test('rate limiting is retryable with its own icon', () {
      final ctx = classifyPlaybackError(
          'Too many requests. Please wait a moment and try again.');
      expect(ctx.icon, Icons.speed_rounded);
      expect(ctx.canRetry, isTrue);
    });

    test('unavailable/restricted songs are NOT retryable and dismiss fastest', () {
      for (final msg in [
        'This song is currently restricted. Please try a different song.',
        'This song is no longer available. Please try a different song.',
      ]) {
        final ctx = classifyPlaybackError(msg);
        expect(ctx.icon, Icons.music_off_rounded, reason: msg);
        expect(ctx.dismissAfter, const Duration(seconds: 4), reason: msg);
        expect(ctx.canRetry, isFalse, reason: msg);
      }
    });

    test('unknown errors fall back to the generic retryable context', () {
      final ctx = classifyPlaybackError('Something went wrong. Please try again.');
      expect(ctx.icon, Icons.error_outline_rounded);
      expect(ctx.dismissAfter, const Duration(seconds: 4));
      expect(ctx.canRetry, isTrue);
    });
  });
}
