enum UpdateStatus {
  idle,
  checking,
  available,
  downloading,
  verifying,
  readyToInstall,
  error,
  upToDate,
}

/// Represents an asset attached to a GitHub release.
class ReleaseAsset {
  final String name;
  final int size;
  final String downloadUrl;

  const ReleaseAsset({
    required this.name,
    required this.size,
    required this.downloadUrl,
  });

  /// Regex pattern to strictly match Android 64-Bit (arm64-v8a) APK release assets.
  static final RegExp arm64Pattern = RegExp(
    r'^(?=.*(apk|android|sonicwave))(?=.*(arm64|arm64-v8a|v8a|release|app)).*\.apk$',
    caseSensitive: false,
  );

  /// Exclusion regex to reject 32-bit ARM (armeabi-v7a), x86, or non-Android binaries.
  static final RegExp v7aOrNonAndroidPattern = RegExp(
    r'(armeabi-v7a|v7a|x86|x86_64|windows|win32|exe|msi)',
    caseSensitive: false,
  );

  /// Check whether this asset is a valid Android 64-Bit (arm64-v8a) APK binary.
  bool get isAndroid64BitBinary {
    final lowerName = name.toLowerCase();
    if (!lowerName.endsWith('.apk')) return false;
    if (v7aOrNonAndroidPattern.hasMatch(lowerName)) return false;

    return arm64Pattern.hasMatch(lowerName) ||
        lowerName.contains('arm64') ||
        lowerName.contains('v8a') ||
        lowerName == 'app-release.apk' ||
        lowerName.startsWith('sonicwave');
  }

  factory ReleaseAsset.fromJson(Map<String, dynamic> json) {
    return ReleaseAsset(
      name: json['name'] as String? ?? '',
      size: json['size'] as int? ?? 0,
      downloadUrl: json['browser_download_url'] as String? ?? '',
    );
  }
}

/// Represents a published release from GitHub.
class AppRelease {
  final String tag;
  final String name;
  final String releaseNotes;
  final bool isPrerelease;
  final DateTime publishedAt;
  final ReleaseAsset? targetAsset;
  final ReleaseAsset? checksumAsset;

  const AppRelease({
    required this.tag,
    required this.name,
    required this.releaseNotes,
    required this.isPrerelease,
    required this.publishedAt,
    this.targetAsset,
    this.checksumAsset,
  });

  /// Parse GitHub API release payload and select target Android 64-Bit APK asset.
  factory AppRelease.fromJson(Map<String, dynamic> json) {
    final rawAssets = json['assets'] as List? ?? [];
    final List<ReleaseAsset> parsedAssets = rawAssets
        .map((a) => ReleaseAsset.fromJson(a as Map<String, dynamic>))
        .toList();

    ReleaseAsset? target;
    ReleaseAsset? checksum;

    for (final asset in parsedAssets) {
      final nameLower = asset.name.toLowerCase();
      if (nameLower.endsWith('.sha256') || nameLower.endsWith('.sha256sum') || nameLower == 'checksums.txt') {
        checksum = asset;
      } else if (asset.isAndroid64BitBinary) {
        target = asset;
      }
    }

    // Fallback: if no explicit arm64 tag in name, pick main .apk file
    target ??= parsedAssets.cast<ReleaseAsset?>().firstWhere(
          (a) => a != null && a.name.toLowerCase().endsWith('.apk') && !ReleaseAsset.v7aOrNonAndroidPattern.hasMatch(a.name.toLowerCase()),
          orElse: () => null,
        );

    return AppRelease(
      tag: json['tag_name'] as String? ?? '',
      name: json['name'] as String? ?? json['tag_name'] as String? ?? '',
      releaseNotes: json['body'] as String? ?? '',
      isPrerelease: json['prerelease'] as bool? ?? false,
      publishedAt: DateTime.tryParse(json['published_at'] as String? ?? '') ?? DateTime.now(),
      targetAsset: target,
      checksumAsset: checksum,
    );
  }
}

/// Represents real-time update download progress metrics.
class UpdateProgress {
  final int downloadedBytes;
  final int totalBytes;
  final double speedBytesPerSec;

  const UpdateProgress({
    required this.downloadedBytes,
    required this.totalBytes,
    required this.speedBytesPerSec,
  });

  double get fraction => totalBytes > 0 ? (downloadedBytes / totalBytes).clamp(0.0, 1.0) : 0.0;
  int get percentage => (fraction * 100).round();
  double get downloadedMB => downloadedBytes / (1024 * 1024);
  double get totalMB => totalBytes / (1024 * 1024);
  double get speedMBps => speedBytesPerSec / (1024 * 1024);
}
