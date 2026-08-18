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

  group('HTML Entity Unescaping Tests', () {
    test('Unescapes common named HTML entities', () {
      expect(
        EncodingSanitizer.sanitize('Rock &amp; Roll &quot;Live&quot;'),
        equals('Rock & Roll "Live"'),
      );
      expect(
        EncodingSanitizer.sanitize('&lt;Unknown&gt; &apos;Track&apos;'),
        equals('<Unknown> \'Track\''),
      );
      expect(
        EncodingSanitizer.sanitize('Song &ndash; Artist &mdash; Album &hellip;'),
        equals('Song – Artist — Album …'),
      );
    });

    test('Unescapes decimal and hex HTML entities', () {
      expect(
        EncodingSanitizer.sanitize('Don&#39;t Stop Me Now &#039;Queen&#039;'),
        equals("Don't Stop Me Now 'Queen'"),
      );
      expect(
        EncodingSanitizer.sanitize('Taylor Swift &#x27;1989&#x27;'),
        equals("Taylor Swift '1989'"),
      );
    });

    test('Unescapes double-escaped HTML entities', () {
      expect(
        EncodingSanitizer.sanitize('Title &amp;quot;Live&amp;quot; &amp;amp; Acoustic'),
        equals('Title "Live" & Acoustic'),
      );
    });
  });

  group('Percent / URL Decoding Tests', () {
    test('Decodes percent-encoded ASCII & UTF-8 characters', () {
      expect(
        EncodingSanitizer.sanitize('Hotel%20California%20%28Remastered%29'),
        equals('Hotel California (Remastered)'),
      );
      expect(
        EncodingSanitizer.sanitize('Caf%C3%A9%20del%20Mar'),
        equals('Café del Mar'),
      );
    });

    test('Safely handles stray percent signs without crashing', () {
      expect(
        EncodingSanitizer.sanitize('100% Hits 2024'),
        equals('100% Hits 2024'),
      );
    });
  });

  group('Latin-1 / UTF-8 Mojibake Repair Tests', () {
    test('Repairs common double-encoded Latin-1 accented characters', () {
      expect(
        EncodingSanitizer.sanitize('CafÃ© del Mar'),
        equals('Café del Mar'),
      );
      expect(
        EncodingSanitizer.sanitize('SeÃ±orita'),
        equals('Señorita'),
      );
      expect(
        EncodingSanitizer.sanitize('BeyoncÃ© â€“ Halo'),
        equals('Beyoncé – Halo'),
      );
    });
  });

  group('Control Characters and Null Byte Stripping', () {
    test('Strips null bytes and ASCII control characters', () {
      expect(
        EncodingSanitizer.sanitize("Track 01\x00\x00\x00"),
        equals('Track 01'),
      );
      expect(
        EncodingSanitizer.sanitize("Artist\x07 - \x00Title\x1F"),
        equals('Artist - Title'),
      );
    });
  });

  group('Thumbnail URL Sanitization Tests', () {
    test('Upgrades HTTP to HTTPS and unescapes slashes', () {
      expect(
        EncodingSanitizer.sanitizeThumbnailUrl(r'http:\/\/c.saavncdn.com\/123\/cover_150x150.jpg'),
        equals('https://c.saavncdn.com/123/cover_500x500.jpg'),
      );
    });

    test('Resolves protocol-relative URLs', () {
      expect(
        EncodingSanitizer.sanitizeThumbnailUrl('//img.youtube.com/vi/abc/mqdefault.jpg'),
        equals('https://img.youtube.com/vi/abc/mqdefault.jpg'),
      );
    });

    test('Preserves valid Base64 data URIs', () {
      const dataUri = 'data:image/jpeg;base64,/9j/4AAQSkZJRgABAQEASABIAAD...';
      expect(
        EncodingSanitizer.sanitizeThumbnailUrl(dataUri),
        equals(dataUri),
      );
    });

    test('Falls back to YouTube high-res when given videoId and empty thumbnail', () {
      expect(
        EncodingSanitizer.sanitizeThumbnailUrl('', videoId: 'dQw4w9WgXcQ'),
        equals('https://i.ytimg.com/vi/dQw4w9WgXcQ/hqdefault.jpg'),
      );
    });
  });
}

