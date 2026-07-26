import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:sonic_wave/services/updater/checksum_verifier.dart';
import 'package:sonic_wave/services/updater/github_release_client.dart';
import 'package:sonic_wave/services/updater/mock_update_client.dart';
import 'package:sonic_wave/services/updater/update_models.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('Option B: Android 64-Bit (arm64-v8a) Auto-Updater Engine Tests', () {
    test('1. Strict Android 64-Bit Binary Matching Regex Test', () {
      final validAssets = [
        const ReleaseAsset(name: 'app-arm64-v8a-release.apk', size: 104200000, downloadUrl: 'https://example.com/arm64.apk'),
        const ReleaseAsset(name: 'sonicwave-v1.1.0-arm64.apk', size: 104200000, downloadUrl: 'https://example.com/arm64.apk'),
        const ReleaseAsset(name: 'sonicwave-release-v8a.apk', size: 104200000, downloadUrl: 'https://example.com/v8a.apk'),
        const ReleaseAsset(name: 'app-release.apk', size: 104200000, downloadUrl: 'https://example.com/release.apk'),
      ];

      final invalidAssets = [
        const ReleaseAsset(name: 'app-armeabi-v7a-release.apk', size: 80000000, downloadUrl: 'https://example.com/v7a.apk'),
        const ReleaseAsset(name: 'sonicwave-x86.apk', size: 80000000, downloadUrl: 'https://example.com/x86.apk'),
        const ReleaseAsset(name: 'sonicwave-x86_64.apk', size: 80000000, downloadUrl: 'https://example.com/x86_64.apk'),
        const ReleaseAsset(name: 'sonicwave-win-x64.exe', size: 80000000, downloadUrl: 'https://example.com/exe'),
      ];

      for (final asset in validAssets) {
        expect(asset.isAndroid64BitBinary, isTrue, reason: 'Failed to identify valid Android 64-Bit binary: ${asset.name}');
      }

      for (final asset in invalidAssets) {
        expect(asset.isAndroid64BitBinary, isFalse, reason: 'Incorrectly matched 32-bit/non-Android binary: ${asset.name}');
      }
    });

    test('2. GitHub Release AppRelease JSON Parsing & Asset Filtering', () {
      final mockJson = {
        'tag_name': 'v1.2.0',
        'name': 'SonicWave v1.2.0 Android 64-Bit Release',
        'body': 'Major Android 64-bit performance update.',
        'prerelease': false,
        'published_at': '2026-07-26T12:00:00Z',
        'assets': [
          {
            'name': 'app-armeabi-v7a-release.apk',
            'size': 80000000,
            'browser_download_url': 'https://github.com/v7a.apk',
          },
          {
            'name': 'app-arm64-v8a-release.apk',
            'size': 104200000,
            'browser_download_url': 'https://github.com/arm64.apk',
          },
          {
            'name': 'app-arm64-v8a-release.apk.sha256',
            'size': 64,
            'browser_download_url': 'https://github.com/arm64.apk.sha256',
          },
        ]
      };

      final release = AppRelease.fromJson(mockJson);
      expect(release.tag, equals('v1.2.0'));
      expect(release.targetAsset, isNotNull);
      expect(release.targetAsset!.name, equals('app-arm64-v8a-release.apk'));
      expect(release.checksumAsset, isNotNull);
      expect(release.checksumAsset!.name, equals('app-arm64-v8a-release.apk.sha256'));
    });

    test('3. SHA-256 Checksum Verification Engine Test', () async {
      final tempDir = Directory.systemTemp.createTempSync('sonicwave_checksum_test_');
      final testFile = File('${tempDir.path}\\dummy_binary.bin');
      await testFile.writeAsString('SonicWave Android 64-Bit Release Binary Test Payload');

      try {
        final actualHash = await ChecksumVerifier.computeSha256(testFile);
        expect(actualHash.length, equals(64));

        final isValid = await ChecksumVerifier.verifyFile(testFile, actualHash);
        expect(isValid, isTrue);

        const corruptedHash = '0000000000000000000000000000000000000000000000000000000000000000';
        await expectLater(
          () async => await ChecksumVerifier.verifyFile(testFile, corruptedHash),
          throwsA(isA<ChecksumMismatchException>()),
        );
      } finally {
        if (tempDir.existsSync()) {
          tempDir.deleteSync(recursive: true);
        }
      }
    });

    test('4. Mock Client Test Scenarios Harness', () async {
      final clientAvailable = MockUpdateClient(
        currentVersion: '1.0.0',
        scenario: MockScenario.updateAvailable,
        mockTargetVersion: 'v1.1.0',
      );
      final release = await clientAvailable.checkForUpdate();
      expect(release, isNotNull);
      expect(release!.tag, equals('v1.1.0'));
      expect(release.targetAsset, isNotNull);

      final clientUpToDate = MockUpdateClient(
        currentVersion: '1.1.0',
        scenario: MockScenario.upToDate,
      );
      final nullRelease = await clientUpToDate.checkForUpdate();
      expect(nullRelease, isNull);

      final clientError = MockUpdateClient(
        currentVersion: '1.0.0',
        scenario: MockScenario.networkError,
      );
      expect(() async => await clientError.checkForUpdate(), throwsA(isA<SocketException>()));

      final clientRateLimit = MockUpdateClient(
        currentVersion: '1.0.0',
        scenario: MockScenario.rateLimited,
      );
      expect(() async => await clientRateLimit.checkForUpdate(), throwsA(isA<GitHubRateLimitException>()));
    });

    test('5. Mock Download Progress Stream Verification', () async {
      final client = MockUpdateClient(currentVersion: '1.0.0');
      final tempDir = Directory.systemTemp.createTempSync('sonicwave_dl_test_');
      final destFile = File('${tempDir.path}\\test_download.apk');

      final asset = const ReleaseAsset(name: 'test.apk', size: 10000, downloadUrl: 'https://test.com');
      final progressList = <UpdateProgress>[];

      await for (final prog in client.downloadAsset(asset, destFile)) {
        progressList.add(prog);
      }

      expect(progressList.isNotEmpty, isTrue);
      expect(progressList.last.percentage, equals(100));
      expect(await destFile.exists(), isTrue);

      tempDir.deleteSync(recursive: true);
    });
  });
}
