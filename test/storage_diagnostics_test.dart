import 'package:flutter_test/flutter_test.dart';
import 'package:sonic_wave/services/storage_diagnostics_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('StorageDiagnostics & Sizing Tests', () {
    test('StorageStats.formatBytes formats data sizes correctly', () {
      expect(StorageStats.formatBytes(0), equals('0 B'));
      expect(StorageStats.formatBytes(-50), equals('0 B'));
      expect(StorageStats.formatBytes(512), equals('512 B'));
      expect(StorageStats.formatBytes(1024), equals('1.0 KB'));
      expect(StorageStats.formatBytes(1536), equals('1.5 KB'));
      expect(StorageStats.formatBytes(1024 * 1024), equals('1.0 MB'));
      expect(StorageStats.formatBytes(25 * 1024 * 1024), equals('25.0 MB'));
      expect(StorageStats.formatBytes(1024 * 1024 * 1024), equals('1.00 GB'));
      expect(StorageStats.formatBytes((2.5 * 1024 * 1024 * 1024).toInt()), equals('2.50 GB'));
    });

    test('StorageStats aggregates total cache bytes accurately', () {
      const stats = StorageStats(
        imageCacheBytes: 10 * 1024 * 1024,
        streamCacheBytes: 25 * 1024 * 1024,
        stagingBytes: 5 * 1024 * 1024,
        downloadedMusicBytes: 150 * 1024 * 1024,
        searchHistoryCount: 12,
        playbackHistoryCount: 30,
        downloadedSongsCount: 25,
      );

      expect(stats.totalCacheBytes, equals(40 * 1024 * 1024));
      expect(StorageStats.formatBytes(stats.totalCacheBytes), equals('40.0 MB'));
      expect(stats.searchHistoryCount, equals(12));
      expect(stats.playbackHistoryCount, equals(30));
      expect(stats.downloadedSongsCount, equals(25));
    });

    test('StorageRepairReport reports statistics and formatted space recovered', () {
      const report = StorageRepairReport(
        totalScanned: 50,
        verifiedTracks: 45,
        recoveredTracks: 2,
        ghostTracksPurged: 3,
        junkFilesCleaned: 5,
        albumsSynced: 4,
        bytesFreed: 14 * 1024 * 1024,
      );

      expect(report.totalScanned, equals(50));
      expect(report.verifiedTracks, equals(45));
      expect(report.recoveredTracks, equals(2));
      expect(report.ghostTracksPurged, equals(3));
      expect(report.junkFilesCleaned, equals(5));
      expect(report.albumsSynced, equals(4));
      expect(report.formattedBytesFreed, equals('14.0 MB'));
    });
  });
}
