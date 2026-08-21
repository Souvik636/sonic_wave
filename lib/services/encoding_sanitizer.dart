import 'dart:convert';
import 'package:flutter/foundation.dart';

/// Ultra-Robust Audio Metadata & Encoding Sanitizer.
///
/// Fixes all common forms of string & thumbnail corruption:
/// 1. HTML entities: `&quot;`, `&#39;`, `&#039;`, `&amp;`, `&lt;`, `&gt;`, `&nbsp;`, `&ndash;`, `&mdash;`, decimal `&#...;`, hex `&#x...;`
/// 2. URL / Percent-encoding: `%20`, `%28`, `%29`, `%2C`, `%2B`, `%C3%A9`, etc.
/// 3. Unicode Mojibake / Latin-1 double-encoding: `Ã©` -> `é`, `â€™` -> `’`, `Ã±` -> `ñ`, `Ã³` -> `ó`, `Ã¼` -> `ü`, etc.
/// 4. ID3 parser UTF-16 byte-swap mojibake: 8-bit bytes decoded as 16-bit CJK code units (`"He"` -> `何`).
/// 5. Null bytes (`\x00`), control characters, escaped slashes (`\/`), and excessive whitespace.
/// 6. Thumbnail URL cleaning: upgrades `http://` to `https://`, resolves `//`, expands JioSaavn `150x150`/`50x50` to `500x500`, validates Base64 data URIs.
class EncodingSanitizer {
  EncodingSanitizer._();

  /// Bump when the repair logic changes, so callers that cache sanitized
  /// results (see LocalMetadataService's on-disk index) can invalidate them.
  static const int version = 5;

  // ─────────────────────────────────────────────────────────
  // Public String Sanitization API
  // ─────────────────────────────────────────────────────────

  /// Attempt to repair a potentially garbled, encrypted, or encoded metadata string.
  ///
  /// Safe to call on any string (returns clean string or original if already clean).
  static String sanitize(String rawInput) {
    if (rawInput.isEmpty) return rawInput;
    String text = rawInput;

    // 1. Strip null bytes & control chars (\x00..\x08, \x0B..\x1F, \x7F)
    text = _stripControlChars(text);
    if (text.isEmpty) return '';

    // 2. Unescape escaped slashes (e.g. from raw JSON strings: "Artist\/Title")
    if (text.contains(r'\/')) {
      text = text.replaceAll(r'\/', '/');
    }

    // 3. Unescape HTML entities (named, decimal &#...;, and hex &#x...;)
    if (text.contains('&')) {
      text = _unescapeHtml(text);
    }

    // 4. Safe URL/Percent decoding (e.g. "Hotel%20California" or "%D8%A3%D8%BA%D9%86%D9%8A%D8%A9")
    if (text.contains('%')) {
      text = _safePercentDecode(text);
    }

    // 5. Repair Latin-1 / CP1252 double-encoded UTF-8 mojibake (e.g. Ã© -> é, â€™ -> ’)
    if (_hasLatin1Mojibake(text)) {
      text = _repairLatin1Mojibake(text);
    }

    // 6. Repair UTF-16 Byte-Swap ID3 Parser Mojibake (8-bit bytes read as 16-bit CJK units)
    if (_hasSignificantWideUnits(text)) {
      text = _repairUtf16ByteSwap(text);
    }

    // 7. Clean up repeated whitespace
    text = text.replaceAll(RegExp(r'\s+'), ' ').trim();

    return text;
  }

  // ─────────────────────────────────────────────────────────
  // Public Thumbnail URL Sanitization API
  // ─────────────────────────────────────────────────────────

  /// Clean, normalize, and upgrade thumbnail URLs for reliable rendering.
  static String sanitizeThumbnailUrl(String rawUrl, {String? videoId}) {
    if (rawUrl.isEmpty) {
      if (videoId != null && videoId.isNotEmpty && !videoId.startsWith('jiosaavn_') && !videoId.startsWith('local_')) {
        return 'https://i.ytimg.com/vi/$videoId/hqdefault.jpg';
      }
      return '';
    }

    String url = rawUrl.trim();

    // 1. Unescape JSON slashes
    url = url.replaceAll(r'\/', '/');

    // 2. Check for Base64 Data URI or raw base64
    if (url.startsWith('data:image/') || _isRawBase64Image(url)) {
      return url;
    }

    // 3. Protocol-relative URL fix: //img.youtube.com/... -> https://img.youtube.com/...
    if (url.startsWith('//')) {
      url = 'https:$url';
    }

    // 4. Upgrade HTTP to HTTPS for modern Android/iOS ATS compliance
    if (url.startsWith('http://')) {
      url = 'https://${url.substring(7)}';
    }

    // 5. JioSaavn thumbnail quality upgrade: 50x50 / 150x150 -> 500x500
    if (url.contains('saavncdn.com') || url.contains('jiosaavn')) {
      url = url.replaceAll('150x150', '500x500')
               .replaceAll('50x50', '500x500')
               .replaceAll('_50x50.jpg', '_500x500.jpg')
               .replaceAll('_150x150.jpg', '_500x500.jpg');
    }

    // 6. YouTube thumbnail fallback & normalization
    if (url.contains('img.youtube.com') || url.contains('i.ytimg.com')) {
      // If thumbnail is empty placeholder, replace with standard resolution
      if (url.contains('/default.jpg') && videoId != null && videoId.isNotEmpty) {
        url = 'https://i.ytimg.com/vi/$videoId/hqdefault.jpg';
      }
    }

    return url;
  }

  // ─────────────────────────────────────────────────────────
  // HTML Entity Decoder
  // ─────────────────────────────────────────────────────────

  static const Map<String, String> _namedHtmlEntities = {
    'quot': '"',
    'amp': '&',
    'apos': "'",
    'lt': '<',
    'gt': '>',
    'nbsp': ' ',
    'ndash': '–',
    'mdash': '—',
    'hellip': '…',
    'laquo': '«',
    'raquo': '»',
    'lsquo': '‘',
    'rsquo': '’',
    'ldquo': '“',
    'rdquo': '”',
    'bull': '•',
    'copy': '©',
    'reg': '®',
    'trade': '™',
    'cent': '¢',
    'pound': '£',
    'yen': '¥',
    'euro': '€',
    'iexcl': '¡',
    'iquest': '¿',
    'times': '×',
    'divide': '÷',
  };

  static final RegExp _htmlEntityRegex =
      RegExp(r'&(#x[0-9a-fA-F]+|#[0-9]+|[a-zA-Z]+);');

  static String _unescapeHtml(String input) {
    if (!input.contains('&')) return input;

    String current = input;
    // Handle double-escaped entities (e.g. &amp;quot; -> ")
    for (int pass = 0; pass < 2; pass++) {
      if (!current.contains('&')) break;

      final unescaped = current.replaceAllMapped(_htmlEntityRegex, (match) {
        final entity = match.group(1)!;

        // Decimal: &#39; &#039;
        if (entity.startsWith('#') && !entity.startsWith('#x') && !entity.startsWith('#X')) {
          final code = int.tryParse(entity.substring(1));
          if (code != null && code > 0 && code < 0x10FFFF) {
            return String.fromCharCode(code);
          }
        }
        // Hexadecimal: &#x27;
        else if (entity.startsWith('#x') || entity.startsWith('#X')) {
          final code = int.tryParse(entity.substring(2), radix: 16);
          if (code != null && code > 0 && code < 0x10FFFF) {
            return String.fromCharCode(code);
          }
        }
        // Named: &quot;
        else {
          final lower = entity.toLowerCase();
          if (_namedHtmlEntities.containsKey(lower)) {
            return _namedHtmlEntities[lower]!;
          }
        }
        return match.group(0)!;
      });

      if (unescaped == current) break;
      current = unescaped;
    }

    return current;
  }

  // ─────────────────────────────────────────────────────────
  // Safe Percent / URL Decoder
  // ─────────────────────────────────────────────────────────

  static String _safePercentDecode(String input) {
    if (!input.contains('%')) return input;

    // Quick regex check: does it look like valid percent-encoding (%XX)?
    if (!RegExp(r'%[0-9a-fA-F]{2}').hasMatch(input)) return input;

    try {
      final decoded = Uri.decodeComponent(input);
      if (decoded.isNotEmpty) return decoded;
    } catch (_) {
      // If full decode fails (e.g. stray '%' in title), decode isolated valid %XX tokens safely
      try {
        return input.replaceAllMapped(RegExp(r'(%[0-9a-fA-F]{2})+'), (match) {
          try {
            return Uri.decodeComponent(match.group(0)!);
          } catch (_) {
            return match.group(0)!;
          }
        });
      } catch (_) {}
    }

    return input;
  }

  // ─────────────────────────────────────────────────────────
  // Latin-1 / CP1252 Double-Encoded UTF-8 Mojibake Repair
  // ─────────────────────────────────────────────────────────

  static const List<String> _mojibakeSignatures = [
    'Ã©', 'Ã¨', 'Ã ', 'Ã¡', 'Ã±', 'Ã³', 'Ã¼', 'Ã®', 'Ã´', 'Ã§', 'Ã»', 'Ã¶', 'Ã¤',
    'Ãª', 'Ã­', 'Ãº', 'Ã²', 'Ã¬', 'Ã¹', 'Ã¥', 'Ã¦', 'Ã¸', 'Ã°', 'Ã¾', 'ÃŸ',
    'â€™', 'â€œ', 'â€\x9D', 'â€“', 'â€”', 'â€¦', 'Â©', 'Â®', 'Â ', 'Ã ', 'Ã‹',
  ];

  static bool _hasLatin1Mojibake(String text) {
    for (final sig in _mojibakeSignatures) {
      if (text.contains(sig)) return true;
    }
    return false;
  }

  static String _repairLatin1Mojibake(String input) {
    try {
      final bytes = _encodeCp1252(input);
      final decoded = utf8.decode(bytes, allowMalformed: false);
      if (_isPlausibleText(decoded)) {
        return decoded;
      }
    } catch (_) {
      try {
        final bytes = latin1.encode(input);
        final decoded = utf8.decode(bytes, allowMalformed: false);
        if (_isPlausibleText(decoded)) {
          return decoded;
        }
      } catch (_) {}
    }
    return input;
  }

  static List<int> _encodeCp1252(String input) {
    final bytes = <int>[];
    for (final rune in input.runes) {
      if (rune <= 0x7F) {
        bytes.add(rune);
      } else if (rune >= 0xA0 && rune <= 0xFF) {
        bytes.add(rune);
      } else {
        final idx = _cp1252Upper.indexOf(rune);
        if (idx >= 0) {
          bytes.add(0x80 + idx);
        } else {
          bytes.add(rune & 0xFF);
        }
      }
    }
    return bytes;
  }

  // ─────────────────────────────────────────────────────────
  // UTF-16 Byte-Swap Mojibake Repair (ID3 parser bug)
  // ─────────────────────────────────────────────────────────

  static bool _isCjkCodeUnit(int codeUnit) {
    return (codeUnit >= 0x4E00 && codeUnit <= 0x9FFF) ||
        (codeUnit >= 0x3400 && codeUnit <= 0x4DBF) ||
        (codeUnit >= 0x20000 && codeUnit <= 0x2A6DF) ||
        (codeUnit >= 0xF900 && codeUnit <= 0xFAFF);
  }

  /// Check if a string contains significant CJK characters (mojibake signature).
  static bool hasMojibakeCjk(String input) {
    if (input.isEmpty) return false;
    int cjkCount = 0;
    for (int i = 0; i < input.length; i++) {
      if (_isCjkCodeUnit(input.codeUnitAt(i))) {
        cjkCount++;
      }
    }
    return cjkCount > 0 && (cjkCount / input.length) >= 0.15;
  }

  static bool _hasSignificantWideUnits(String input) {
    if (input.length < 2) return false;
    int wideCount = 0;
    for (int i = 0; i < input.length; i++) {
      if (input.codeUnitAt(i) > 0xFF) {
        wideCount++;
      }
    }
    return (wideCount / input.length) >= 0.40 || hasMojibakeCjk(input);
  }

  static String _repairUtf16ByteSwap(String trimmed) {
    for (final littleEndian in [true, false]) {
      for (final filterNulls in [true, false]) {
        final bytes = _unpack(trimmed, littleEndian, filterNulls: filterNulls);
        final repaired = _decodeIfPlausible(bytes);
        if (repaired != null && repaired != trimmed && !hasMojibakeCjk(repaired)) {
          debugPrint('[EncodingSanitizer] Repaired '
              '${littleEndian ? 'LE' : 'BE'} (nullFilter=$filterNulls) mojibake: "$trimmed" -> "$repaired"');
          return repaired;
        }
      }
    }
    return trimmed;
  }

  static List<int> _unpack(String s, bool littleEndian, {required bool filterNulls}) {
    final out = <int>[];
    for (int i = 0; i < s.length; i++) {
      final code = s.codeUnitAt(i);
      if (code > 0xFF) {
        final low = code & 0xFF;
        final high = (code >> 8) & 0xFF;
        final first = littleEndian ? low : high;
        final second = littleEndian ? high : low;

        if (!filterNulls || first != 0) out.add(first);
        if (!filterNulls || second != 0) out.add(second);
      } else {
        if (!filterNulls || code != 0) out.add(code);
      }
    }
    return out;
  }

  static String? _decodeIfPlausible(List<int> bytes) {
    if (bytes.isEmpty) return null;

    // Strict UTF-8 first.
    try {
      final decoded = utf8.decode(bytes, allowMalformed: false);
      if (_isPlausibleText(decoded)) return decoded.trim();
    } catch (_) {}

    // Windows-1252 (CP1252).
    try {
      final decoded = _decodeWindows1252(bytes);
      if (_isPlausibleText(decoded)) return decoded.trim();
    } catch (_) {}

    // Latin-1 fallback.
    try {
      final decoded = latin1.decode(bytes);
      if (_isPlausibleText(decoded)) return decoded.trim();
    } catch (_) {}

    return null;
  }

  static bool _isPlausibleText(String s) {
    if (s.trim().isEmpty) return false;

    int total = 0;
    int clean = 0;
    for (final rune in s.runes) {
      if (_isControl(rune)) return false;
      total++;
      if (_isSensibleRune(rune)) clean++;
    }
    if (total == 0) return false;
    return clean / total >= 0.85;
  }

  static const List<int> _cp1252Upper = [
    0x20AC, 0x0081, 0x201A, 0x0192, 0x201E, 0x2026, 0x2020, 0x2021,
    0x02C6, 0x2030, 0x0160, 0x2039, 0x0152, 0x008D, 0x017D, 0x008F,
    0x0090, 0x2018, 0x2019, 0x201C, 0x201D, 0x2022, 0x2013, 0x2014,
    0x02DC, 0x2122, 0x0161, 0x203A, 0x0153, 0x009D, 0x017E, 0x0178,
  ];

  static String _decodeWindows1252(List<int> bytes) {
    final buf = StringBuffer();
    for (final b in bytes) {
      if (b >= 0x80 && b <= 0x9F) {
        buf.writeCharCode(_cp1252Upper[b - 0x80]);
      } else {
        buf.writeCharCode(b);
      }
    }
    return buf.toString();
  }

  static String _stripControlChars(String input) {
    final buf = StringBuffer();
    for (int i = 0; i < input.length; i++) {
      final code = input.codeUnitAt(i);
      // Strip null bytes and non-printable control characters (\x00-\x08, \x0B, \x0C, \x0E-\x1F, \x7F)
      if (code == 0 || (code < 0x20 && code != 0x09 && code != 0x0A && code != 0x0D) || code == 0x7F) {
        continue;
      }
      buf.writeCharCode(code);
    }
    return buf.toString();
  }

  static bool _isControl(int rune) {
    if (rune < 0x20 && rune != 0x09 && rune != 0x0A && rune != 0x0D) return true;
    if (rune == 0x7F) return true;
    if (rune == 0xFFFD) return true;
    return false;
  }

  static bool _isSensibleRune(int rune) {
    if (rune >= 0x20 && rune <= 0x7E) return true;
    if (rune >= 0xA0 && rune <= 0x24F) return true;
    if (rune >= 0x370 && rune <= 0x97F) return true;
    if (rune >= 0xE00 && rune <= 0xE7F) return true;
    if (rune >= 0x2010 && rune <= 0x2027) return true;
    if (rune >= 0x2030 && rune <= 0x205E) return true;
    if (rune >= 0x20A0 && rune <= 0x21FF) return true;
    if (rune >= 0x3000 && rune <= 0x9FFF) return true;
    if (rune >= 0xAC00 && rune <= 0xD7AF) return true;
    if (rune >= 0xF900 && rune <= 0xFAFF) return true;
    if (rune >= 0xFF00 && rune <= 0xFFEF) return true;
    if (rune >= 0x1F000 && rune <= 0x1FAFF) return true;
    if (rune >= 0x20000 && rune <= 0x2FA1F) return true;
    return false;
  }

  static bool _isRawBase64Image(String s) {
    if (s.length < 64) return false;
    // Fast check: starts with standard JPEG (/9j/) or PNG (iVBOR) base64 header
    return s.startsWith('/9j/') || s.startsWith('iVBORw0KGgo') || s.startsWith('R0lGOD') || s.startsWith('UklGR');
  }
}
