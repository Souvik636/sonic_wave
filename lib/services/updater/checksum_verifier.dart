import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';

class ChecksumMismatchException implements Exception {
  final String message;
  final String expectedHash;
  final String actualHash;

  const ChecksumMismatchException(this.message, {required this.expectedHash, required this.actualHash});

  @override
  String toString() => 'ChecksumMismatchException: $message (Expected: $expectedHash, Actual: $actualHash)';
}

class ChecksumVerifier {
  /// Calculate SHA-256 hash of a local file asynchronously using chunked conversion.
  static Future<String> computeSha256(File file) async {
    final stream = file.openRead();
    final digest = await sha256.bind(stream).first;
    return digest.toString();
  }

  /// Verify local file against expected SHA-256 hash string.
  static Future<bool> verifyFile(File file, String expectedHash) async {
    if (!await file.exists()) return false;
    final actualHash = await computeSha256(file);
    final cleanExpected = _extractHashFromText(expectedHash).toLowerCase();
    final cleanActual = actualHash.toLowerCase();

    debugPrint('[Checksum] Expected: $cleanExpected | Actual: $cleanActual');

    if (cleanExpected.isEmpty) {
      debugPrint('[Checksum] Warning: Expected hash format invalid or empty, skipping check.');
      return true;
    }

    if (cleanExpected != cleanActual) {
      throw ChecksumMismatchException(
        'Downloaded file binary checksum does not match official release hash.',
        expectedHash: cleanExpected,
        actualHash: cleanActual,
      );
    }

    return true;
  }

  /// Parses raw sha256 checksum string or .sha256sum file content.
  /// Handles formats like:
  ///   "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
  ///   "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855  sonicwave-x64.exe"
  static String _extractHashFromText(String raw) {
    final trimmed = raw.trim();
    if (trimmed.isEmpty) return '';

    // Match 64 hex characters (SHA-256 length)
    final hexRegExp = RegExp(r'([a-fA-F0-9]{64})');
    final match = hexRegExp.firstMatch(trimmed);
    if (match != null) {
      return match.group(1)!;
    }
    return trimmed;
  }
}
