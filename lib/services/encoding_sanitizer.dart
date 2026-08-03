import 'dart:convert';
import 'package:flutter/foundation.dart';

/// Repairs audio-tag strings whose 8-bit bytes were decoded as 16-bit units.
///
/// The corruption: a tag holds ordinary ASCII/UTF-8/Latin-1 bytes, but the
/// parser reads them two-at-a-time as UTF-16 code units. `"He"` (0x48 0x65)
/// becomes a single unit 0x6548 — a Chinese ideograph. A whole English title
/// turns into a run of unrelated CJK, which is why other players show these
/// files correctly while we showed mojibake.
class EncodingSanitizer {
  EncodingSanitizer._();

  /// Bump when the repair logic changes, so callers that cache sanitized
  /// results (see LocalMetadataService's on-disk index) can invalidate them.
  static const int version = 4;

  /// Range for CJK Unified Ideographs and Extension A/B blocks
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
    // If 15% or more of code units fall into CJK range for an audio title,
    // it is highly likely to be garbled ID3 tag mojibake unless it's pure CJK.
    return cjkCount > 0 && (cjkCount / input.length) >= 0.15;
  }

  /// Attempt to repair a potentially garbled metadata string.
  ///
  /// Returns the repaired string, or an empty string if the text remains
  /// unrepairable CJK mojibake so callers can fall back to clean filenames.
  static String sanitize(String rawInput) {
    if (rawInput.isEmpty) return rawInput;
    final trimmed = rawInput.trim();
    if (trimmed.isEmpty) return trimmed;

    // Every unit at or below 0xFF means nothing was ever packed two bytes per
    // unit, so there is nothing to invert. Covers all clean ASCII/Latin-1 tags.
    if (!_hasWideUnits(trimmed)) return trimmed;

    // Try both Little-Endian and Big-Endian unpacking, with and without NULL-byte filtering.
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

    // If the input is still garbled CJK mojibake after all repair attempts,
    // return an empty string to force caller to fall back to clean filename.
    if (hasMojibakeCjk(trimmed)) {
      debugPrint('[EncodingSanitizer] Discarding unrepairable CJK mojibake tag: "$trimmed"');
      return '';
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
  /// When [filterNulls] is true, zero bytes (UTF-16 padding) are omitted.
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

  /// Decode reconstructed bytes, accepting only a convincingly clean result.
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

  /// True when [s] reads as real text rather than reconstruction noise.
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

  /// Windows-1252 (CP1252) decoder for the 0x80-0x9F gap.
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
}
