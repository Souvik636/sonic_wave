import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'android_installer_runner.dart';
import 'checksum_verifier.dart';
import 'update_client.dart';
import 'update_models.dart';

class GitHubRateLimitException implements Exception {
  final String message;
  const GitHubRateLimitException(this.message);
  @override
  String toString() => 'GitHubRateLimitException: $message';
}

class GitHubReleaseClient implements UpdateClient {
  final String owner;
  final String repo;
  @override
  final String currentVersion;

  /// Cached ETag from the last successful /releases/latest response.
  /// Sent as If-None-Match on subsequent requests so GitHub returns 304
  /// (no body, no rate-limit hit) when nothing has changed.
  static String? _cachedETag;
  static AppRelease? _cachedRelease;

  GitHubReleaseClient({
    this.owner = 'Souvik636',
    this.repo = 'sonic_wave',
    required this.currentVersion,
  });

  String get _latestReleaseApiUrl => 'https://api.github.com/repos/$owner/$repo/releases/latest';

  // ─── SharedPreferences keys for auto-check throttling ──────────────
  static const _keyLastCheckMs = 'updater_last_check_ms';
  static const _keyLastCheckResult = 'updater_last_check_result';
  static const _keyETag = 'updater_etag';
  static const _keyCachedRelease = 'updater_cached_release';

  /// How long to wait between automatic background checks (24 hours).
  static const Duration autoCheckInterval = Duration(hours: 24);

  /// Whether enough time has passed since the last automatic check.
  static Future<bool> shouldAutoCheck() async {
    final prefs = await SharedPreferences.getInstance();
    final lastMs = prefs.getInt(_keyLastCheckMs) ?? 0;
    final elapsed = DateTime.now().millisecondsSinceEpoch - lastMs;
    return elapsed >= autoCheckInterval.inMilliseconds;
  }

  /// Record that an automatic check just happened.
  static Future<void> _recordCheck({bool updateAvailable = false}) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_keyLastCheckMs, DateTime.now().millisecondsSinceEpoch);
    await prefs.setBool(_keyLastCheckResult, updateAvailable);
  }

  /// Load persisted ETag from disk (survives app restarts).
  Future<void> _loadPersistedETag() async {
    if (_cachedETag != null) return;
    try {
      final prefs = await SharedPreferences.getInstance();
      _cachedETag = prefs.getString(_keyETag);
      final releaseJson = prefs.getString(_keyCachedRelease);
      if (releaseJson != null) {
        _cachedRelease = AppRelease.fromJson(
            json.decode(releaseJson) as Map<String, dynamic>);
      }
    } catch (e) {
      debugPrint('[GitHubUpdater] Failed to load persisted ETag: $e');
    }
  }

  /// Persist ETag and release data to disk.
  Future<void> _persistETag(String etag, Map<String, dynamic> releaseData) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_keyETag, etag);
      await prefs.setString(_keyCachedRelease, json.encode(releaseData));
    } catch (e) {
      debugPrint('[GitHubUpdater] Failed to persist ETag: $e');
    }
  }

  @override
  Future<AppRelease?> checkForUpdate() async {
    await _loadPersistedETag();

    // Try up to 3 times with exponential backoff for transient network errors.
    for (int attempt = 0; attempt < 3; attempt++) {
      final client = HttpClient()
        ..connectionTimeout = const Duration(seconds: 10);
      try {
        final request = await client.getUrl(Uri.parse(_latestReleaseApiUrl));
        request.headers.set('User-Agent', 'SonicWave-Updater/$currentVersion');
        request.headers.set('Accept', 'application/vnd.github.v3+json');

        // ETag conditional request: avoids re-downloading the full JSON
        // payload and does not count against GitHub's rate limit when the
        // release has not changed.
        if (_cachedETag != null) {
          request.headers.set('If-None-Match', _cachedETag!);
        }

        final response = await request.close().timeout(const Duration(seconds: 12));

        if (response.statusCode == 403 || response.statusCode == 429) {
          await response.drain<void>();
          throw const GitHubRateLimitException('GitHub API rate limit exceeded. Please try again later.');
        }

        // 304 Not Modified — release unchanged since last check.
        // Use cached release data without burning a rate-limit token.
        if (response.statusCode == 304) {
          await response.drain<void>();
          debugPrint('[GitHubUpdater] 304 Not Modified — using cached release data');
          if (_cachedRelease != null && _isNewerVersion(currentVersion, _cachedRelease!.tag)) {
            await _recordCheck(updateAvailable: true);
            return _cachedRelease;
          }
          await _recordCheck(updateAvailable: false);
          return null;
        }

        if (response.statusCode == 404) {
          await response.drain<void>();
          debugPrint('[GitHubUpdater] Repository not found: $owner/$repo');
          throw Exception('Repository $owner/$repo not found on GitHub. Check your internet connection.');
        }

        if (response.statusCode == 200) {
          // Capture and persist the ETag for future conditional requests.
          final etag = response.headers.value('etag');
          final body = await response.transform(utf8.decoder).join();
          final data = json.decode(body) as Map<String, dynamic>;
          final release = AppRelease.fromJson(data);

          // Cache for future 304 responses.
          _cachedRelease = release;
          if (etag != null) {
            _cachedETag = etag;
            await _persistETag(etag, data);
          }

          if (_isNewerVersion(currentVersion, release.tag)) {
            debugPrint('[GitHubUpdater] Found newer Android 64-Bit release: ${release.tag} (Installed: $currentVersion)');
            await _recordCheck(updateAvailable: true);
            return release;
          } else {
            debugPrint('[GitHubUpdater] App is up to date (Installed: $currentVersion | Remote: ${release.tag})');
            await _recordCheck(updateAvailable: false);
            return null;
          }
        }

        // Unexpected status — drain and retry.
        await response.drain<void>();
        debugPrint('[GitHubUpdater] Unexpected HTTP ${response.statusCode}, attempt ${attempt + 1}');
      } on GitHubRateLimitException {
        rethrow;
      } catch (e) {
        debugPrint('[GitHubUpdater] Attempt ${attempt + 1} failed: $e');
        if (attempt == 2) rethrow;
        // Exponential backoff: 2s, 4s before retries.
        await Future<void>.delayed(Duration(seconds: 2 * (attempt + 1)));
      } finally {
        client.close();
      }
    }
    return null;
  }

  @override
  Stream<UpdateProgress> downloadAsset(ReleaseAsset asset, File destinationFile) async* {
    final client = HttpClient();
    try {
      // ── Resume support ─────────────────────────────────────────────
      // If a partial file from a previous attempt exists, resume from
      // where it left off using the HTTP Range header. This avoids
      // re-downloading 60+ MB on flaky connections.
      int existingBytes = 0;
      FileMode writeMode = FileMode.write;
      if (await destinationFile.exists()) {
        existingBytes = await destinationFile.length();
        // Only resume if the partial file is smaller than the expected size.
        // If it's the same size or larger, start fresh (it may be corrupt).
        if (existingBytes > 0 && existingBytes < asset.size) {
          writeMode = FileMode.append;
          debugPrint('[GitHubUpdater] Resuming download from byte $existingBytes');
        } else {
          existingBytes = 0;
        }
      }

      final request = await client.getUrl(Uri.parse(asset.downloadUrl));
      request.headers.set('User-Agent', 'SonicWave-Updater/$currentVersion');
      request.headers.set('Accept', 'application/octet-stream');
      if (existingBytes > 0) {
        request.headers.set('Range', 'bytes=$existingBytes-');
      }
      final response = await request.close();

      // 206 Partial Content = resume accepted, 200 = server ignored Range.
      if (response.statusCode != 200 && response.statusCode != 206) {
        throw HttpException('Failed to download asset: HTTP ${response.statusCode}');
      }

      // If the server returned 200 instead of 206, it doesn't support Range
      // and is sending the whole file — reset to overwrite mode.
      if (response.statusCode == 200 && existingBytes > 0) {
        existingBytes = 0;
        writeMode = FileMode.write;
        debugPrint('[GitHubUpdater] Server does not support Range; restarting download');
      }

      final totalBytes = existingBytes +
          (response.contentLength > 0 ? response.contentLength : (asset.size - existingBytes));
      final sink = destinationFile.openWrite(mode: writeMode);
      int downloadedBytes = existingBytes;
      final startTime = DateTime.now();
      int lastReportTime = startTime.millisecondsSinceEpoch;

      // Emit initial progress if resuming so the UI shows the head start.
      if (existingBytes > 0) {
        yield UpdateProgress(
          downloadedBytes: downloadedBytes,
          totalBytes: totalBytes,
          speedBytesPerSec: 0,
        );
      }

      try {
        await for (final chunk in response) {
          sink.add(chunk);
          downloadedBytes += chunk.length;

          final now = DateTime.now().millisecondsSinceEpoch;
          if (now - lastReportTime >= 100 || downloadedBytes == totalBytes) {
            lastReportTime = now;
            final elapsedSecs = (now - startTime.millisecondsSinceEpoch) / 1000.0;
            // Speed is calculated on newly downloaded bytes only (not resumed).
            final newBytes = downloadedBytes - existingBytes;
            final speedBps = elapsedSecs > 0 ? (newBytes / elapsedSecs) : 0.0;

            yield UpdateProgress(
              downloadedBytes: downloadedBytes,
              totalBytes: totalBytes,
              speedBytesPerSec: speedBps,
            );
          }
        }
        await sink.flush();
      } finally {
        await sink.close();
      }

      // A dropped connection ends the byte stream cleanly, so without this the
      // truncated APK was handed straight to the installer as if it were
      // complete — and Android rejected it as an invalid package ("Install not
      // completed") with nothing anywhere explaining why.
      final expected = totalBytes > 0 ? totalBytes : asset.size;
      final onDisk = await destinationFile.length();
      if (expected > 0 && onDisk != expected) {
        // Don't delete the partial file — it can be resumed next time.
        throw HttpException(
          'Download incomplete: got ${_mb(onDisk)} of ${_mb(expected)}. '
          'Check your connection and try again.',
        );
      }
    } finally {
      client.close();
    }
  }

  static String _mb(int bytes) =>
      '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';

  @override
  Future<bool> verifyChecksum(ReleaseAsset? checksumAsset, File downloadedFile) async {
    if (checksumAsset == null) {
      debugPrint('[GitHubUpdater] No .sha256 checksum asset provided in release. Skipping hash verification.');
      // Return false to indicate verification was SKIPPED, not that the file
      // is verified. The caller (UpdateDialog) uses this to show a warning.
      return false;
    }

    final client = HttpClient();
    try {
      final request = await client.getUrl(Uri.parse(checksumAsset.downloadUrl));
      request.headers.set('User-Agent', 'SonicWave-Updater/$currentVersion');
      final response = await request.close();

      if (response.statusCode == 200) {
        final expectedText = await response.transform(utf8.decoder).join();
        return await ChecksumVerifier.verifyFile(downloadedFile, expectedText);
      }
    } catch (e) {
      debugPrint('[GitHubUpdater] Checksum download/verification failed: $e');
      rethrow;
    } finally {
      client.close();
    }
    return false;
  }

  @override
  Future<bool> applyUpdate(File downloadedFile) async {
    return await AndroidInstallerRunner.installApk(downloadedFile);
  }

  /// Semantic versioning (SemVer) comparison helper.
  static bool _isNewerVersion(String installedVersion, String remoteTag) {
    try {
      final cleanInstalled = installedVersion.replaceAll(RegExp(r'^[vV]'), '').split('+').first;
      final cleanRemote = remoteTag.replaceAll(RegExp(r'^[vV]'), '').split('+').first;

      final instParts = cleanInstalled.split('.').map((e) => int.tryParse(e) ?? 0).toList();
      final remParts = cleanRemote.split('.').map((e) => int.tryParse(e) ?? 0).toList();

      while (instParts.length < 3) {
        instParts.add(0);
      }
      while (remParts.length < 3) {
        remParts.add(0);
      }

      for (int i = 0; i < 3; i++) {
        if (remParts[i] > instParts[i]) return true;
        if (remParts[i] < instParts[i]) return false;
      }

      // Check build numbers (e.g. 1.0.0+3 vs 1.0.0+4, or 1.0.0 vs 1.0.0+1)
      final instBuild = installedVersion.contains('+') ? (int.tryParse(installedVersion.split('+').last) ?? 0) : 0;
      final remBuild = remoteTag.contains('+') ? (int.tryParse(remoteTag.split('+').last) ?? 0) : 0;
      return remBuild > instBuild;
    } catch (e) {
      debugPrint('[GitHubUpdater] Version parsing exception: $e');
    }
    return false;
  }
}
