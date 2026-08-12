import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:sonic_wave/services/encoding_sanitizer.dart';

/// Reproduce the exact corruption we are trying to undo: real 8-bit tag bytes
/// that a parser decoded as UTF-16LE 16-bit code units.
String asUtf16LeMojibake(String original) {
  final bytes = utf8.encode(original);
  final units = <int>[];
  for (int i = 0; i + 1 < bytes.length; i += 2) {
    units.add(bytes[i] | (bytes[i + 1] << 8));
  }
  if (bytes.length.isOdd) units.add(bytes.last);
  return String.fromCharCodes(units);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  group('EncodingSanitizer Tests', () {
    test('Leaves clean English text unmodified', () {
      expect(EncodingSanitizer.sanitize('Hotel California'), equals('Hotel California'));
      expect(EncodingSanitizer.sanitize('Bohemian Rhapsody - Queen'), equals('Bohemian Rhapsody - Queen'));
      expect(EncodingSanitizer.sanitize('Track 01.mp3'), equals('Track 01.mp3'));
    });

    test('Handles empty and whitespace inputs gracefully', () {
      expect(EncodingSanitizer.sanitize(''), equals(''));
      expect(EncodingSanitizer.sanitize('   '), equals(''));
    });
  });

  group('Round-trips tags a parser misread as UTF-16', () {
    test('ASCII title, even byte length', () {
      expect(EncodingSanitizer.sanitize(asUtf16LeMojibake('Bohemian Rhapsody!!')),
          equals('Bohemian Rhapsody!!'));
    });

    test('ASCII title, odd byte length (trailing lone byte)', () {
      expect(EncodingSanitizer.sanitize(asUtf16LeMojibake('Yesterday')),
          equals('Yesterday'));
    });

    test('title whose pairs mostly fall OUTSIDE the CJK blocks', () {
      // Spaces and digits as the second byte of a pair produce code units below
      // 0x3400, so a CJK-ratio test alone never fires even though the text is
      // unreadable garbage.
      expect(EncodingSanitizer.sanitize(asUtf16LeMojibake('A 1 B 2 C 3 D 4')),
          equals('A 1 B 2 C 3 D 4'));
    });

    test('non-ASCII UTF-8 title', () {
      expect(EncodingSanitizer.sanitize(asUtf16LeMojibake('Café del Mar')),
          equals('Café del Mar'));
    });

    test('long real-world style title', () {
      const original = 'Never Gonna Give You Up (Official Video)';
      expect(EncodingSanitizer.sanitize(asUtf16LeMojibake(original)),
          equals(original));
    });

    test('artist strings round-trip too', () {
      const original = 'Rage Against The Machine';
      expect(EncodingSanitizer.sanitize(asUtf16LeMojibake(original)),
          equals(original));
    });
  });

  group('Leaves legitimate non-Latin text alone', () {
    test('a genuinely Chinese title survives untouched', () {
      const chinese = '月亮代表我的心';
      expect(EncodingSanitizer.sanitize(chinese), equals(chinese));
    });

    test('a genuinely Japanese title survives untouched', () {
      const japanese = '残酷な天使のテーゼ';
      expect(EncodingSanitizer.sanitize(japanese), equals(japanese));
    });

    test('a genuinely Korean title survives untouched', () {
      const korean = '강남스타일';
      expect(EncodingSanitizer.sanitize(korean), equals(korean));
    });

    test('a mixed CJK + ASCII title survives untouched', () {
      const mixed = '君の名は。 (Original Soundtrack)';
      expect(EncodingSanitizer.sanitize(mixed), equals(mixed));
    });
  });
}
