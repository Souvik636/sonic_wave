import 'dart:convert';
import 'package:flutter/foundation.dart';

/// Repairs audio-tag strings whose 8-bit bytes were decoded as 16-bit units.
///
/// The corruption: a tag holds ordinary ASCII/UTF-8/Latin-1 bytes, but the
/// parser reads them two-at-a-time as UTF-16 code units. `"He"` (0x48 0x65)
/// becomes a single unit 0x6548 — a Chinese ideograph. A whole English title
/// turns into a run of unrelated CJK, which is why other players show these
/// files correctly while we showed mojibake.
///
/// ## How the repair decides
/// The corruption is deterministic and therefore invertible: split each wide
/// code unit back into its two bytes and re-decode. The hard part is knowing
/// when NOT to do that, because a genuinely Chinese title looks identical to a
/// corrupted English one by character class alone — both are "all CJK".
///
/// So this does not guess from the input. It performs the inversion and judges
/// the *output*: a repair is accepted only when the reconstructed bytes decode
/// as strict UTF-8 (or Latin-1) into text with no control characters and
/// almost entirely sensible ones. Real CJK/Kana/Hangul/Cyrillic text
/// reconstructs into control-character noise or invalid UTF-8 and is rejected,
/// so legitimate titles in any script pass through untouched.
class EncodingSanitizer {
  EncodingSanitizer._();

  /// Bump when the repair logic changes, so callers that cache sanitized
  /// results (see LocalMetadataService's on-disk index) can invalidate them.
  static const int version = 3;

  /// Range for CJK Unified Ideographs and Extension A/B blocks
  static bool _isCjkCodeUnit(int codeUnit) {
    return (codeUnit >= 0x4E00 && codeUnit <= 0x9FFF) ||
        (codeUnit >= 0x3400 && codeUnit <= 0x4DBF) ||
        (codeUnit >= 0x20000 && codeUnit <= 0x2A6DF) ||
        (codeUnit >= 0xF900 && codeUnit <= 0xFAFF);
  }

  /// Check if a string contains significant CJK characters.
  ///
  /// Retained for diagnostics only. It is deliberately NOT the gate for
  /// [sanitize] any more: mojibake whose bytes land outside the CJK blocks
  /// (anything with spaces or digits at even offsets, for instance) is just as
  /// broken but never trips a CJK ratio.
  static bool hasMojibakeCjk(String input) {
    if (input.isEmpty) return false;
    int cjkCount = 0;
    for (int i = 0; i < input.length; i++) {
      if (_isCjkCodeUnit(input.codeUnitAt(i))) {
        cjkCount++;
      }
    }
    // If more than 25% of code units fall into CJK range for an audio title
    return cjkCount > 0 && (cjkCount / input.length) >= 0.25;
  }

  /// Attempt to repair a potentially garbled metadata string.
  ///
  /// Returns the input trimmed and unchanged when no confident repair exists —
  /// leaving a title alone is always safer than mangling a correct one.
  static String sanitize(String rawInput) {
    if (rawInput.isEmpty) return rawInput;
    final trimmed = rawInput.trim();
    if (trimmed.isEmpty) return trimmed;

    // Every unit at or below 0xFF means nothing was ever packed two bytes per
    // unit, so there is nothing to invert. Covers all clean ASCII/Latin-1 tags.
    if (!_hasWideUnits(trimmed)) return trimmed;

    for (final littleEndian in [true, false]) {
      final repaired = _decodeIfPlausible(_unpack(trimmed, littleEndian));
      if (repaired != null && repaired != trimmed) {
        debugPrint('[EncodingSanitizer] Repaired '
            '${littleEndian ? 'LE' : 'BE'} mojibake: "$trimmed" -> "$repaired"');
        return repaired;
      }
    }

    return trimmed;
  }

  static bool _hasWideUnits(String s) {
    for (int i = 0; i < s.length; i++) {
      if (s.codeUnitAt(i) > 0xFF) return true;
    }
    return false;
  }

  /// Split each code unit back into the bytes it was built from.
  ///
  /// A unit at or below 0xFF is a lone leftover byte — an odd-length tag leaves
  /// one at the end. It contributes exactly ONE byte. Emitting two (the old
  /// behaviour) is what duplicated the last character of every odd-length
  /// title: "Yesterday" came back as "Yesterdayy".
  static List<int> _unpack(String s, bool littleEndian) {
    final out = <int>[];
    for (int i = 0; i < s.length; i++) {
      final code = s.codeUnitAt(i);
      if (code > 0xFF) {
        final low = code & 0xFF;
        final high = (code >> 8) & 0xFF;
        if (littleEndian) {
          out.add(low);
          out.add(high);
        } else {
          out.add(high);
          out.add(low);
        }
      } else {
        out.add(code);
      }
    }
    return out;
  }

  /// Decode reconstructed bytes, accepting only a convincingly clean result.
  static String? _decodeIfPlausible(List<int> bytes) {
    if (bytes.isEmpty) return null;

    // Strict UTF-8 first. Refusing malformed input is most of the safety here:
    // bytes recovered from genuine CJK text are almost never valid UTF-8.
    try {
      final decoded = utf8.decode(bytes, allowMalformed: false);
      if (_isPlausibleText(decoded)) return decoded.trim();
    } catch (_) {}

    // Windows-1252 (CP1252): the most common encoding for ID3 tags in the
    // wild. Bytes 0x80-0x9F are C1 controls in ISO-8859-1 but map to
    // printable characters in CP1252 (€, –, —, ', ', ", ", etc.).
    // Trying this before Latin-1 catches the vast majority of non-UTF-8
    // music tags, which is what was producing the Chinese mojibake.
    try {
      final decoded = _decodeWindows1252(bytes);
      if (_isPlausibleText(decoded)) return decoded.trim();
    } catch (_) {}

    // Then Latin-1, for tags actually written in ISO-8859-1.
    try {
      final decoded = latin1.decode(bytes);
      if (_isPlausibleText(decoded)) return decoded.trim();
    } catch (_) {}

    return null;
  }

  /// True when [s] reads as real text rather than reconstruction noise.
  ///
  /// A single control character is a hard no: that is the signature of having
  /// torn apart characters that were never two bytes to begin with.
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
    return clean / total >= 0.9;
  }

  /// Windows-1252 (CP1252) decoder for the 0x80-0x9F gap that Latin-1 maps
  /// to invisible C1 control characters. Nearly all "Latin-1" tags from
  /// Windows ripping software actually use CP1252.
  static const List<int> _cp1252Upper = [
    // 0x80-0x8F
    0x20AC, 0x0081, 0x201A, 0x0192, 0x201E, 0x2026, 0x2020, 0x2021,
    0x02C6, 0x2030, 0x0160, 0x2039, 0x0152, 0x008D, 0x017D, 0x008F,
    // 0x90-0x9F
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

  /// C0 controls, the DEL character (0x7F), and the Unicode replacement
  /// character. The 0x80-0x9F (C1) range is NOT rejected here because
  /// Windows-1252 maps those to printable characters, and the input has
  /// already been decoded through the appropriate codec by the time this
  /// check runs.
  static bool _isControl(int rune) {
    if (rune < 0x20) return true;
    if (rune == 0x7F) return true;
    if (rune == 0xFFFD) return true;
    return false;
  }

  /// Characters that legitimately appear in a track title, in any script.
  static bool _isSensibleRune(int rune) {
    // Printable ASCII.
    if (rune >= 0x20 && rune <= 0x7E) return true;
    // Latin-1 supplement + Latin Extended-A/B (accented European text).
    if (rune >= 0xA0 && rune <= 0x24F) return true;
    // Greek, Cyrillic, Hebrew, Arabic, Devanagari and neighbours.
    if (rune >= 0x370 && rune <= 0x97F) return true;
    // Thai.
    if (rune >= 0xE00 && rune <= 0xE7F) return true;
    // Typographic punctuation: curly quotes, en/em dashes, ellipsis.
    if (rune >= 0x2010 && rune <= 0x2027) return true;
    if (rune >= 0x2030 && rune <= 0x205E) return true;
    // Currency, letterlike, arrows, common symbols.
    if (rune >= 0x20A0 && rune <= 0x21FF) return true;
    // CJK punctuation, Kana, Hangul, Ideographs.
    if (rune >= 0x3000 && rune <= 0x9FFF) return true;
    if (rune >= 0xAC00 && rune <= 0xD7AF) return true;
    if (rune >= 0xF900 && rune <= 0xFAFF) return true;
    // Halfwidth/fullwidth forms.
    if (rune >= 0xFF00 && rune <= 0xFFEF) return true;
    // Supplementary planes: emoji and rare ideographs.
    if (rune >= 0x1F000 && rune <= 0x1FAFF) return true;
    if (rune >= 0x20000 && rune <= 0x2FA1F) return true;
    return false;
  }
}
