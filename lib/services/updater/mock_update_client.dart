import 'dart:async';
import 'dart:io';
import 'checksum_verifier.dart';
import 'github_release_client.dart';
import 'update_client.dart';
import 'update_models.dart';

enum MockScenario {
  updateAvailable,
  upToDate,
  networkError,
  rateLimited,
  checksumMismatch,
  installerCancellation,
}

class MockUpdateClient implements UpdateClient {
  @override
  final String currentVersion;
  final MockScenario scenario;
  final String mockTargetVersion;

  MockUpdateClient({
    required this.currentVersion,
    this.scenario = MockScenario.updateAvailable,
    this.mockTargetVersion = 'v1.1.0',
  });

  @override
  Future<AppRelease?> checkForUpdate() async {
    await Future.delayed(const Duration(milliseconds: 300));

    switch (scenario) {
      case MockScenario.networkError:
        throw const SocketException('Failed host lookup: api.github.com');
      case MockScenario.rateLimited:
        throw const GitHubRateLimitException('GitHub API rate limit exceeded.');
      case MockScenario.upToDate:
        return null;
      case MockScenario.updateAvailable:
      case MockScenario.checksumMismatch:
      case MockScenario.installerCancellation:
        return AppRelease(
          tag: mockTargetVersion,
          name: 'SonicWave Android 64-Bit Release ($mockTargetVersion)',
          releaseNotes:
              '''
## What's New in $mockTargetVersion (Android 64-Bit)
* **64-Bit Audio Engine:** Optimized arm64-v8a high-bitrate playback pipeline.
* **YouTube Stream Resilience:** Enhanced 403 Forbidden auto-retry with chrome user-agent headers.
* **ProGuard Keep Rules:** Hardened extractor JNI native methods for zero release crashes.
''',
          isPrerelease: false,
          publishedAt: DateTime.now(),
          targetAsset: const ReleaseAsset(
            name: 'app-arm64-v8a-release.apk',
            size: 104200000, // ~104.2 MB
            downloadUrl: 'https://mock.github.com/app-arm64-v8a-release.apk',
          ),
          checksumAsset: const ReleaseAsset(
            name: 'app-arm64-v8a-release.apk.sha256',
            size: 64,
            downloadUrl: 'https://mock.github.com/checksum.sha256',
          ),
        );
    }
  }

  @override
  Stream<UpdateProgress> downloadAsset(
    ReleaseAsset asset,
    File destinationFile,
  ) async* {
    final totalBytes = asset.size > 0 ? asset.size : 104200000;
    const steps = 10;
    final chunkSize = totalBytes ~/ steps;

    // Create dummy mock file content
    await destinationFile.writeAsBytes(List.generate(1024, (i) => i % 256));

    for (int i = 1; i <= steps; i++) {
      await Future.delayed(const Duration(milliseconds: 60));
      final downloaded = i * chunkSize;
      yield UpdateProgress(
        downloadedBytes: downloaded,
        totalBytes: totalBytes,
        speedBytesPerSec: 6800000, // 6.8 MB/s
      );
    }
  }

  @override
  Future<bool> verifyChecksum(
    ReleaseAsset? checksumAsset,
    File downloadedFile,
  ) async {
    await Future.delayed(const Duration(milliseconds: 200));

    if (scenario == MockScenario.checksumMismatch) {
      throw const ChecksumMismatchException(
        'Mock downloaded APK file SHA-256 hash does not match official release hash.',
        expectedHash:
            'a1b2c3d4e5f67890a1b2c3d4e5f67890a1b2c3d4e5f67890a1b2c3d4e5f67890',
        actualHash:
            '0000000000000000000000000000000000000000000000000000000000000000',
      );
    }

    return true;
  }

  @override
  Future<bool> applyUpdate(File downloadedFile) async {
    await Future.delayed(const Duration(milliseconds: 300));

    if (scenario == MockScenario.installerCancellation) {
      throw const SocketException(
        'User cancelled Android PackageInstaller prompt.',
      );
    }

    return true;
  }
}
