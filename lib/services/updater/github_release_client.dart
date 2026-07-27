import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
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

  GitHubReleaseClient({
    this.owner = 'Souvik636',
    this.repo = 'sonic_wave',
    required this.currentVersion,
  });

  String get _latestReleaseApiUrl => 'https://api.github.com/repos/$owner/$repo/releases/latest';

  @override
  Future<AppRelease?> checkForUpdate() async {
    // Try up to 2 times for transient network errors.
    for (int attempt = 0; attempt < 2; attempt++) {
      final client = HttpClient()
        ..connectionTimeout = const Duration(seconds: 10);
      try {
        final request = await client.getUrl(Uri.parse(_latestReleaseApiUrl));
        request.headers.set('User-Agent', 'SonicWave-Updater/$currentVersion');
        request.headers.set('Accept', 'application/vnd.github.v3+json');

        final response = await request.close().timeout(const Duration(seconds: 12));

        if (response.statusCode == 403 || response.statusCode == 429) {
          // Drain the response body to release the connection.
          await response.drain<void>();
          throw const GitHubRateLimitException('GitHub API rate limit exceeded. Please try again later.');
        }

        if (response.statusCode == 404) {
          await response.drain<void>();
          debugPrint('[GitHubUpdater] Repository not found: $owner/$repo');
          throw Exception('Repository $owner/$repo not found on GitHub. Check your internet connection.');
        }

        if (response.statusCode == 200) {
          final body = await response.transform(utf8.decoder).join();
          final data = json.decode(body) as Map<String, dynamic>;
          final release = AppRelease.fromJson(data);

          if (_isNewerVersion(currentVersion, release.tag)) {
            debugPrint('[GitHubUpdater] Found newer Android 64-Bit release: ${release.tag} (Installed: $currentVersion)');
            return release;
          } else {
            debugPrint('[GitHubUpdater] App is up to date (Installed: $currentVersion | Remote: ${release.tag})');
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
        if (attempt == 1) rethrow;
        // Brief pause before retry.
        await Future<void>.delayed(const Duration(seconds: 2));
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
      final request = await client.getUrl(Uri.parse(asset.downloadUrl));
      request.headers.set('User-Agent', 'SonicWave-Updater/$currentVersion');
      final response = await request.close();

      if (response.statusCode != 200) {
        throw HttpException('Failed to download asset: HTTP ${response.statusCode}');
      }

      final totalBytes = response.contentLength > 0 ? response.contentLength : asset.size;
      final sink = destinationFile.openWrite();
      int downloadedBytes = 0;
      final startTime = DateTime.now();
      int lastReportTime = startTime.millisecondsSinceEpoch;

      await for (final chunk in response) {
        sink.add(chunk);
        downloadedBytes += chunk.length;

        final now = DateTime.now().millisecondsSinceEpoch;
        if (now - lastReportTime >= 100 || downloadedBytes == totalBytes) {
          lastReportTime = now;
          final elapsedSecs = (now - startTime.millisecondsSinceEpoch) / 1000.0;
          final speedBps = elapsedSecs > 0 ? (downloadedBytes / elapsedSecs) : 0.0;

          yield UpdateProgress(
            downloadedBytes: downloadedBytes,
            totalBytes: totalBytes,
            speedBytesPerSec: speedBps,
          );
        }
      }

      await sink.flush();
      await sink.close();
    } finally {
      client.close();
    }
  }

  @override
  Future<bool> verifyChecksum(ReleaseAsset? checksumAsset, File downloadedFile) async {
    if (checksumAsset == null) {
      debugPrint('[GitHubUpdater] No .sha256 checksum asset provided in release. Skipping hash verification.');
      return true;
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
    return true;
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
