import 'dart:io';
import 'update_models.dart';

/// Abstract contract for app update management engines.
abstract class UpdateClient {
  /// Current installed application version (e.g. "1.0.0+3").
  String get currentVersion;

  /// Check for newer releases available on GitHub repository.
  Future<AppRelease?> checkForUpdate();

  /// Stream real-time progress while downloading target binary file.
  Stream<UpdateProgress> downloadAsset(
    ReleaseAsset asset,
    File destinationFile,
  );

  /// Download accompanying .sha256 asset and verify file checksum.
  Future<bool> verifyChecksum(ReleaseAsset? checksumAsset, File downloadedFile);

  /// Execute 64-bit installer file (.exe / .msi) and gracefully exit app.
  Future<bool> applyUpdate(File downloadedFile);
}
