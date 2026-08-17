import 'dart:async';
import 'dart:io';
import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:path_provider/path_provider.dart';
import '../../services/updater/android_installer_runner.dart';
import '../../services/updater/update_client.dart';
import '../../services/updater/update_models.dart';
import '../../theme/app_colors.dart';

class UpdateDialog extends StatefulWidget {
  final UpdateClient updateClient;
  final AppRelease release;
  final VoidCallback? onDismiss;

  const UpdateDialog({
    super.key,
    required this.updateClient,
    required this.release,
    this.onDismiss,
  });

  /// Show the premium update modal window as a glassmorphic dialog.
  static Future<void> show(
    BuildContext context, {
    required UpdateClient updateClient,
    required AppRelease release,
  }) {
    return showDialog<void>(
      context: context,
      barrierDismissible: false,
      barrierColor: Colors.black.withValues(alpha: 0.82),
      builder: (ctx) =>
          UpdateDialog(updateClient: updateClient, release: release),
    );
  }

  @override
  State<UpdateDialog> createState() => _UpdateDialogState();
}

class _UpdateDialogState extends State<UpdateDialog>
    with SingleTickerProviderStateMixin {
  UpdateStatus _status = UpdateStatus.available;
  UpdateProgress? _progress;
  String? _errorMessage;
  File? _downloadedFile;

  bool _needsInstallPermission = false;
  bool _checksumSkipped = false;
  StreamSubscription<UpdateProgress>? _downloadSub;
  late AnimationController _animController;
  late Animation<double> _scaleAnimation;
  late Animation<double> _fadeAnimation;

  @override
  void initState() {
    super.initState();
    _animController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 380),
    );
    _scaleAnimation = CurvedAnimation(
      parent: _animController,
      curve: Curves.easeOutBack,
    );
    _fadeAnimation = CurvedAnimation(
      parent: _animController,
      curve: Curves.easeOut,
    );
    _animController.forward();
  }

  @override
  void dispose() {
    _downloadSub?.cancel();
    _animController.dispose();
    super.dispose();
  }

  Future<void> _startDownload() async {
    final asset = widget.release.targetAsset;
    if (asset == null) {
      setState(() {
        _status = UpdateStatus.error;
        _errorMessage =
            'No Android 64-Bit (arm64-v8a) APK binary asset found in release.';
      });
      return;
    }

    setState(() {
      _status = UpdateStatus.downloading;
      _errorMessage = null;
      _needsInstallPermission = false;
    });

    try {
      final downloadDir = await getApplicationSupportDirectory();
      try {
        await for (final entity in downloadDir.list()) {
          if (entity is File && entity.path.toLowerCase().endsWith('.apk')) {
            await entity.delete();
          }
        }
      } catch (_) {}
      final destFile = File('${downloadDir.path}/${asset.name}');

      _downloadSub = widget.updateClient
          .downloadAsset(asset, destFile)
          .listen(
            (progress) {
              setState(() {
                _progress = progress;
              });
            },
            onError: (err) {
              setState(() {
                _status = UpdateStatus.error;
                _errorMessage = 'APK Download failed: $err';
              });
            },
            onDone: () async {
              _downloadedFile = destFile;
              await _verifyAndPrepare(destFile);
            },
          );
    } catch (e) {
      setState(() {
        _status = UpdateStatus.error;
        _errorMessage = 'Download initialization failed: $e';
      });
    }
  }

  Future<void> _verifyAndPrepare(File file) async {
    setState(() {
      _status = UpdateStatus.verifying;
    });

    try {
      final verified = await widget.updateClient.verifyChecksum(
        widget.release.checksumAsset,
        file,
      );

      if (!mounted) return;
      setState(() {
        _checksumSkipped = !verified;
        _status = UpdateStatus.readyToInstall;
      });
    } catch (e) {
      setState(() {
        _status = UpdateStatus.error;
        _errorMessage = e
            .toString()
            .replaceAll('ChecksumMismatchException:', '')
            .trim();
      });
    }
  }

  Future<void> _applyUpdateNow() async {
    final file = _downloadedFile;
    if (file == null || !await file.exists()) {
      setState(() {
        _status = UpdateStatus.error;
        _errorMessage = 'APK binary file missing from storage.';
      });
      return;
    }

    final preflight = await AndroidInstallerRunner.inspect(file);
    if (!mounted) return;

    if (preflight != null && !preflight.isInstallable) {
      setState(() {
        _status = UpdateStatus.error;
        _errorMessage = preflight.blockingReason;
      });
      return;
    }

    if (preflight != null && !preflight.canRequestInstall) {
      setState(() {
        _needsInstallPermission = true;
        _status = UpdateStatus.error;
        _errorMessage =
            'SonicWave needs permission to install apps before it can apply '
            'this update. Grant "Install unknown apps", then tap Install again.';
      });
      return;
    }

    setState(() {
      _status = UpdateStatus.installing;
      _errorMessage = null;
    });

    try {
      await widget.updateClient.applyUpdate(file);
      if (!mounted) return;
      setState(() {
        _status = UpdateStatus.readyToInstall;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _status = UpdateStatus.error;
        _errorMessage = e
            .toString()
            .replaceAll('InstallerExecutionException:', '')
            .trim();
      });
    }
  }

  Future<void> _grantInstallPermission() async {
    await AndroidInstallerRunner.openInstallPermissionSettings();
    if (!mounted) return;
    setState(() {
      _needsInstallPermission = false;
      _status = UpdateStatus.readyToInstall;
      _errorMessage = null;
    });
  }

  void _cancelDownload() {
    _downloadSub?.cancel();
    setState(() {
      _status = UpdateStatus.available;
      _progress = null;
    });
  }

  @override
  Widget build(BuildContext context) {
    const primaryAccent = Color(0xFF8B5CF6);
    const secondaryAccent = Color(0xFF06B6D4);
    const pinkAccent = Color(0xFFEC4899);
    const cardBg = Color(0xFF13132B);

    return FadeTransition(
      opacity: _fadeAnimation,
      child: ScaleTransition(
        scale: _scaleAnimation,
        child: Dialog(
          backgroundColor: Colors.transparent,
          elevation: 0,
          insetPadding: const EdgeInsets.symmetric(
            horizontal: 18,
            vertical: 24,
          ),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(28),
            child: BackdropFilter(
              filter: ImageFilter.blur(sigmaX: 18, sigmaY: 18),
              child: Container(
                width: 520,
                decoration: BoxDecoration(
                  color: cardBg.withValues(alpha: 0.92),
                  borderRadius: BorderRadius.circular(28),
                  border: Border.all(
                    color: primaryAccent.withValues(alpha: 0.38),
                    width: 1.5,
                  ),
                  boxShadow: [
                    BoxShadow(
                      color: primaryAccent.withValues(alpha: 0.30),
                      blurRadius: 36,
                      spreadRadius: 2,
                    ),
                    BoxShadow(
                      color: Colors.black.withValues(alpha: 0.75),
                      blurRadius: 30,
                      spreadRadius: -4,
                    ),
                  ],
                ),
                child: Stack(
                  children: [
                    // Ambient radial glow in corner
                    Positioned(
                      top: -60,
                      right: -60,
                      child: Container(
                        width: 180,
                        height: 180,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          gradient: RadialGradient(
                            colors: [
                              pinkAccent.withValues(alpha: 0.22),
                              Colors.transparent,
                            ],
                          ),
                        ),
                      ),
                    ),

                    Positioned(
                      bottom: -80,
                      left: -60,
                      child: Container(
                        width: 200,
                        height: 200,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          gradient: RadialGradient(
                            colors: [
                              secondaryAccent.withValues(alpha: 0.18),
                              Colors.transparent,
                            ],
                          ),
                        ),
                      ),
                    ),

                    Padding(
                      padding: const EdgeInsets.all(24),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          // ── Header Row ───────────────────────────────
                          Row(
                            crossAxisAlignment: CrossAxisAlignment.center,
                            children: [
                              Container(
                                padding: const EdgeInsets.all(12),
                                decoration: BoxDecoration(
                                  gradient: const LinearGradient(
                                    colors: [primaryAccent, pinkAccent],
                                    begin: Alignment.topLeft,
                                    end: Alignment.bottomRight,
                                  ),
                                  borderRadius: BorderRadius.circular(18),
                                  boxShadow: [
                                    BoxShadow(
                                      color: primaryAccent.withValues(
                                        alpha: 0.45,
                                      ),
                                      blurRadius: 14,
                                    ),
                                  ],
                                ),
                                child: const Icon(
                                  Icons.rocket_launch_rounded,
                                  color: Colors.white,
                                  size: 26,
                                ),
                              ),
                              const SizedBox(width: 14),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      'New Update Available',
                                      style: GoogleFonts.outfit(
                                        color: Colors.white,
                                        fontSize: 18,
                                        fontWeight: FontWeight.bold,
                                        letterSpacing: 0.3,
                                      ),
                                    ),
                                    const SizedBox(height: 3),
                                    Row(
                                      children: [
                                        // Version jump pill
                                        Container(
                                          padding: const EdgeInsets.symmetric(
                                            horizontal: 8,
                                            vertical: 2.5,
                                          ),
                                          decoration: BoxDecoration(
                                            color: primaryAccent.withValues(
                                              alpha: 0.18,
                                            ),
                                            borderRadius: BorderRadius.circular(
                                              8,
                                            ),
                                            border: Border.all(
                                              color: primaryAccent.withValues(
                                                alpha: 0.45,
                                              ),
                                            ),
                                          ),
                                          child: Row(
                                            mainAxisSize: MainAxisSize.min,
                                            children: [
                                              Text(
                                                'v${widget.updateClient.currentVersion}',
                                                style: GoogleFonts.inter(
                                                  color: Colors.white60,
                                                  fontSize: 10.5,
                                                  fontWeight: FontWeight.w500,
                                                ),
                                              ),
                                              const Padding(
                                                padding: EdgeInsets.symmetric(
                                                  horizontal: 4,
                                                ),
                                                child: Icon(
                                                  Icons.arrow_forward_rounded,
                                                  color: Color(0xFFA855F7),
                                                  size: 11,
                                                ),
                                              ),
                                              Text(
                                                widget.release.tag,
                                                style: GoogleFonts.inter(
                                                  color: const Color(
                                                    0xFFC084FC,
                                                  ),
                                                  fontSize: 11,
                                                  fontWeight: FontWeight.bold,
                                                ),
                                              ),
                                            ],
                                          ),
                                        ),
                                        const SizedBox(width: 8),
                                        // Architecture pill
                                        Container(
                                          padding: const EdgeInsets.symmetric(
                                            horizontal: 7,
                                            vertical: 2.5,
                                          ),
                                          decoration: BoxDecoration(
                                            color: Colors.greenAccent
                                                .withValues(alpha: 0.15),
                                            borderRadius: BorderRadius.circular(
                                              8,
                                            ),
                                            border: Border.all(
                                              color: Colors.greenAccent
                                                  .withValues(alpha: 0.3),
                                            ),
                                          ),
                                          child: const Text(
                                            '64-Bit · ARM',
                                            style: TextStyle(
                                              color: Colors.greenAccent,
                                              fontSize: 9.5,
                                              fontWeight: FontWeight.bold,
                                            ),
                                          ),
                                        ),
                                      ],
                                    ),
                                  ],
                                ),
                              ),
                              if (_status == UpdateStatus.available)
                                IconButton(
                                  icon: const Icon(
                                    Icons.close_rounded,
                                    color: Colors.white54,
                                    size: 22,
                                  ),
                                  onPressed: () {
                                    Navigator.of(context).pop();
                                    widget.onDismiss?.call();
                                  },
                                ),
                            ],
                          ),

                          const SizedBox(height: 18),
                          const Divider(color: Colors.white10, height: 1),
                          const SizedBox(height: 16),

                          // ── Dynamic Body State Switcher ───────────────
                          _buildBodyContent(
                            primaryAccent,
                            secondaryAccent,
                            pinkAccent,
                          ),

                          const SizedBox(height: 22),

                          // ── Action Controls Footer ────────────────────
                          _buildActionFooter(
                            context,
                            primaryAccent,
                            secondaryAccent,
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildBodyContent(
    Color primaryAccent,
    Color secondaryAccent,
    Color pinkAccent,
  ) {
    switch (_status) {
      case UpdateStatus.available:
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  'Release Highlights',
                  style: GoogleFonts.outfit(
                    color: Colors.white,
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 7,
                    vertical: 2,
                  ),
                  decoration: BoxDecoration(
                    color: Colors.white.withValues(alpha: 0.08),
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: Text(
                    widget.release.targetAsset?.formattedSize ?? 'Latest APK',
                    style: const TextStyle(
                      color: AppColors.textTertiary,
                      fontSize: 10,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 10),
            Container(
              constraints: const BoxConstraints(maxHeight: 180),
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: Colors.black.withValues(alpha: 0.35),
                borderRadius: BorderRadius.circular(16),
                border: Border.all(color: Colors.white.withValues(alpha: 0.08)),
              ),
              child: RawScrollbar(
                thumbColor: primaryAccent.withValues(alpha: 0.45),
                radius: const Radius.circular(4),
                thickness: 4,
                child: SingleChildScrollView(
                  child: Text(
                    widget.release.releaseNotes.isNotEmpty
                        ? widget.release.releaseNotes
                        : '• Performance improvements and memory optimizations.\n'
                              '• Enhanced yt-dlp native extraction and background streaming.\n'
                              '• Audio equalizer, sound studio, and storage enhancements.\n'
                              '• Native 64-Bit Android arm64-v8a system stability.',
                    style: GoogleFonts.inter(
                      color: Colors.white.withValues(alpha: 0.82),
                      fontSize: 12.5,
                      height: 1.55,
                    ),
                  ),
                ),
              ),
            ),
          ],
        );

      case UpdateStatus.downloading:
        final prog = _progress;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Row(
                  children: [
                    const SizedBox(
                      width: 14,
                      height: 14,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: Color(0xFF06B6D4),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Text(
                      'Downloading APK Binary...',
                      style: GoogleFonts.outfit(
                        color: Colors.white,
                        fontSize: 13.5,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                ),
                Text(
                  '${prog?.percentage ?? 0}%',
                  style: GoogleFonts.outfit(
                    color: const Color(0xFF06B6D4),
                    fontSize: 15,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            ClipRRect(
              borderRadius: BorderRadius.circular(10),
              child: SizedBox(
                height: 9,
                child: Stack(
                  children: [
                    Container(color: Colors.white10),
                    FractionallySizedBox(
                      widthFactor: prog?.fraction.clamp(0.0, 1.0) ?? 0.0,
                      child: Container(
                        decoration: const BoxDecoration(
                          gradient: LinearGradient(
                            colors: [Color(0xFF8B5CF6), Color(0xFF06B6D4)],
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 12),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  '${(prog?.downloadedMB ?? 0.0).toStringAsFixed(1)} MB / ${(prog?.totalMB ?? 0.0).toStringAsFixed(1)} MB',
                  style: const TextStyle(color: Colors.white60, fontSize: 11.5),
                ),
                Text(
                  'Speed: ${(prog?.speedMBps ?? 0.0).toStringAsFixed(1)} MB/s',
                  style: const TextStyle(
                    color: Color(0xFF06B6D4),
                    fontSize: 11.5,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
          ],
        );

      case UpdateStatus.verifying:
        return Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: const Color(0xFF06B6D4).withValues(alpha: 0.12),
            borderRadius: BorderRadius.circular(16),
            border: Border.all(
              color: const Color(0xFF06B6D4).withValues(alpha: 0.35),
            ),
          ),
          child: const Row(
            children: [
              SizedBox(
                width: 22,
                height: 22,
                child: CircularProgressIndicator(
                  strokeWidth: 2.5,
                  color: Color(0xFF06B6D4),
                ),
              ),
              SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Verifying SHA-256 Checksum',
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: 13,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    SizedBox(height: 2),
                    Text(
                      'Validating cryptographic integrity before install...',
                      style: TextStyle(color: Colors.white70, fontSize: 11),
                    ),
                  ],
                ),
              ),
            ],
          ),
        );

      case UpdateStatus.installing:
        return Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: Colors.greenAccent.withValues(alpha: 0.12),
            borderRadius: BorderRadius.circular(16),
            border: Border.all(
              color: Colors.greenAccent.withValues(alpha: 0.35),
            ),
          ),
          child: const Row(
            children: [
              SizedBox(
                width: 22,
                height: 22,
                child: CircularProgressIndicator(
                  strokeWidth: 2.5,
                  color: Colors.greenAccent,
                ),
              ),
              SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Opening Package Installer',
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: 13,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    SizedBox(height: 2),
                    Text(
                      'Confirm the Android prompt to finalize installation.',
                      style: TextStyle(color: Colors.white70, fontSize: 11),
                    ),
                  ],
                ),
              ),
            ],
          ),
        );

      case UpdateStatus.readyToInstall:
        return Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: _checksumSkipped
                ? Colors.amber.withValues(alpha: 0.12)
                : Colors.green.withValues(alpha: 0.12),
            borderRadius: BorderRadius.circular(16),
            border: Border.all(
              color: _checksumSkipped
                  ? Colors.amber.withValues(alpha: 0.35)
                  : Colors.greenAccent.withValues(alpha: 0.4),
            ),
          ),
          child: Row(
            children: [
              Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: _checksumSkipped
                      ? Colors.amber.withValues(alpha: 0.2)
                      : Colors.greenAccent.withValues(alpha: 0.2),
                  shape: BoxShape.circle,
                ),
                child: Icon(
                  _checksumSkipped
                      ? Icons.warning_amber_rounded
                      : Icons.verified_rounded,
                  color: _checksumSkipped ? Colors.amber : Colors.greenAccent,
                  size: 22,
                ),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      _checksumSkipped
                          ? 'APK Ready (Unverified Hash)'
                          : 'APK Verified & Ready to Install!',
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 13.5,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      _checksumSkipped
                          ? 'Package downloaded. Tap Install below.'
                          : 'Cryptographic SHA-256 hash matched perfectly.',
                      style: const TextStyle(
                        color: Colors.white70,
                        fontSize: 11.5,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        );

      case UpdateStatus.error:
        return Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: Colors.red.withValues(alpha: 0.12),
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: Colors.redAccent.withValues(alpha: 0.35)),
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Icon(
                Icons.error_outline_rounded,
                color: Colors.redAccent,
                size: 22,
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  _errorMessage ??
                      'An unexpected error occurred during update.',
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 12,
                    height: 1.4,
                  ),
                ),
              ),
            ],
          ),
        );

      default:
        return const SizedBox.shrink();
    }
  }

  Widget _buildActionFooter(
    BuildContext context,
    Color primaryAccent,
    Color secondaryAccent,
  ) {
    if (_status == UpdateStatus.available) {
      return Row(
        mainAxisAlignment: MainAxisAlignment.end,
        children: [
          TextButton(
            onPressed: () {
              Navigator.of(context).pop();
              widget.onDismiss?.call();
            },
            child: Text(
              'Remind Later',
              style: GoogleFonts.inter(
                color: Colors.white54,
                fontSize: 13,
                fontWeight: FontWeight.w500,
              ),
            ),
          ),
          const SizedBox(width: 10),
          ElevatedButton.icon(
            onPressed: _startDownload,
            style: ElevatedButton.styleFrom(
              backgroundColor: primaryAccent,
              foregroundColor: Colors.white,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(14),
              ),
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 13),
              elevation: 6,
              shadowColor: primaryAccent.withValues(alpha: 0.5),
            ),
            icon: const Icon(Icons.download_rounded, size: 18),
            label: Text(
              'Update Now',
              style: GoogleFonts.outfit(
                fontWeight: FontWeight.bold,
                fontSize: 13.5,
              ),
            ),
          ),
        ],
      );
    }

    if (_status == UpdateStatus.downloading) {
      return SizedBox(
        width: double.infinity,
        child: OutlinedButton(
          onPressed: _cancelDownload,
          style: OutlinedButton.styleFrom(
            foregroundColor: Colors.redAccent,
            side: const BorderSide(color: Colors.redAccent),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(14),
            ),
            padding: const EdgeInsets.symmetric(vertical: 12),
          ),
          child: const Text(
            'Cancel Download',
            style: TextStyle(fontWeight: FontWeight.w600),
          ),
        ),
      );
    }

    if (_status == UpdateStatus.readyToInstall) {
      return SizedBox(
        width: double.infinity,
        child: ElevatedButton.icon(
          onPressed: _applyUpdateNow,
          style: ElevatedButton.styleFrom(
            backgroundColor: Colors.greenAccent.shade700,
            foregroundColor: Colors.white,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(14),
            ),
            padding: const EdgeInsets.symmetric(vertical: 14),
            elevation: 8,
            shadowColor: Colors.greenAccent.withValues(alpha: 0.4),
          ),
          icon: const Icon(Icons.android_rounded, size: 20),
          label: Text(
            'Install APK Update Now',
            style: GoogleFonts.outfit(
              fontWeight: FontWeight.bold,
              fontSize: 14.5,
            ),
          ),
        ),
      );
    }

    if (_status == UpdateStatus.error) {
      final bool permissionFix = _needsInstallPermission;
      return Row(
        mainAxisAlignment: MainAxisAlignment.end,
        children: [
          TextButton(
            onPressed: () {
              Navigator.of(context).pop();
            },
            child: const Text('Close', style: TextStyle(color: Colors.white54)),
          ),
          const SizedBox(width: 10),
          ElevatedButton.icon(
            onPressed: permissionFix ? _grantInstallPermission : _startDownload,
            style: ElevatedButton.styleFrom(
              backgroundColor: primaryAccent,
              foregroundColor: Colors.white,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(14),
              ),
              padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 12),
            ),
            icon: Icon(
              permissionFix ? Icons.settings_rounded : Icons.refresh_rounded,
              size: 18,
            ),
            label: Text(
              permissionFix ? 'Open Settings' : 'Retry Download',
              style: GoogleFonts.outfit(fontWeight: FontWeight.bold),
            ),
          ),
        ],
      );
    }

    return const SizedBox.shrink();
  }
}
