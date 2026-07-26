import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Tells Android's MediaStore about files the app has just written or removed.
///
/// Why this exists: a file created with plain `dart:io` is invisible to the
/// system media database until something scans it. Until that happens the
/// user's other music players, their gallery and most file managers behave as
/// if the download never happened — and after a delete they keep listing a
/// track whose file is already gone. Handing the path to
/// `MediaScannerConnection` fixes both directions: an existing file gets
/// indexed, a missing one has its stale row dropped.
///
/// Only shared storage is worth scanning. App-private directories (`/data/…`,
/// `/storage/emulated/0/Android/data/…`) are deliberately excluded from
/// MediaStore by the platform, so a scan there is a wasted round trip — hence
/// [scanIfPublic] rather than a blanket scan.
class MediaStoreScanner {
  MediaStoreScanner._();

  static const MethodChannel _channel =
      MethodChannel('com.sonicwave.sonic_wave/media');

  /// A scan is a courtesy, never a blocker. If the platform side is slow or
  /// silent we give up and let Android's own periodic scan catch up, rather
  /// than stalling a download that has otherwise finished.
  static const Duration _timeout = Duration(seconds: 8);

  /// True when [path] lives somewhere the platform media scanner indexes.
  static bool isPublicPath(String? path) {
    if (!Platform.isAndroid || path == null || path.isEmpty) return false;

    final normalized = path.replaceAll('\\', '/');
    if (!normalized.startsWith('/storage/') &&
        !normalized.startsWith('/sdcard/')) {
      return false;
    }

    // App-specific external storage is public in path only — the scanner skips
    // it, and so should we.
    final lower = normalized.toLowerCase();
    if (lower.contains('/android/data/') || lower.contains('/android/obb/')) {
      return false;
    }

    // Anything hidden, or inside a dot-folder such as the app's own
    // `.sonicwave` metadata directory, is meant to stay out of the database.
    for (final segment in normalized.split('/')) {
      if (segment.length > 1 && segment.startsWith('.')) return false;
    }

    return true;
  }

  /// Scan [path] when it is on shared storage; otherwise do nothing.
  ///
  /// Safe to call for a path that no longer exists — that is how a deleted
  /// file's MediaStore row gets removed.
  static Future<void> scanIfPublic(String? path) => scanAll([path]);

  /// Scan every public path in [paths] in a single platform round trip.
  ///
  /// Nulls and app-private paths are filtered out, so callers can pass
  /// optional paths straight through without pre-checking.
  static Future<void> scanAll(Iterable<String?> paths) async {
    final targets = paths
        .where(isPublicPath)
        .cast<String>()
        .toSet()
        .toList(growable: false);
    if (targets.isEmpty) return;

    try {
      await _channel
          .invokeMethod<int>('scanFiles', targets)
          .timeout(_timeout);
      debugPrint('[MediaStore] Scanned ${targets.length} file(s)');
    } on TimeoutException {
      debugPrint('[MediaStore] Scan timed out for ${targets.length} file(s)');
    } catch (e) {
      debugPrint('[MediaStore] Scan failed: $e');
    }
  }
}
