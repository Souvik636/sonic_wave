import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:path_provider/path_provider.dart';
import '../../services/updater/update_client.dart';
import '../../services/updater/update_models.dart';

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
      barrierColor: Colors.black.withValues(alpha: 0.75),
      builder: (ctx) => UpdateDialog(
        updateClient: updateClient,
        release: release,
      ),
    );
  }

  @override
  State<UpdateDialog> createState() => _UpdateDialogState();
}

class _UpdateDialogState extends State<UpdateDialog> with SingleTickerProviderStateMixin {
  UpdateStatus _status = UpdateStatus.available;
  UpdateProgress? _progress;
  String? _errorMessage;
  File? _downloadedFile;
  StreamSubscription<UpdateProgress>? _downloadSub;
  late AnimationController _animController;
  late Animation<double> _scaleAnimation;

  @override
  void initState() {
    super.initState();
    _animController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 300),
    );
    _scaleAnimation = CurvedAnimation(
      parent: _animController,
      curve: Curves.easeOutCubic,
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
        _errorMessage = 'No Android 64-Bit (arm64-v8a) APK binary asset found in release.';
      });
      return;
    }

    setState(() {
      _status = UpdateStatus.downloading;
      _errorMessage = null;
    });

    try {
      final tempDir = await getTemporaryDirectory();
      final destFile = File('${tempDir.path}/${asset.name}');

      _downloadSub = widget.updateClient.downloadAsset(asset, destFile).listen(
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
      final valid = await widget.updateClient.verifyChecksum(
        widget.release.checksumAsset,
        file,
      );

      if (valid) {
        setState(() {
          _status = UpdateStatus.readyToInstall;
        });
      }
    } catch (e) {
      setState(() {
        _status = UpdateStatus.error;
        _errorMessage = e.toString().replaceAll('ChecksumMismatchException:', '').trim();
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

    try {
      await widget.updateClient.applyUpdate(file);
    } catch (e) {
      setState(() {
        _status = UpdateStatus.error;
        _errorMessage = 'PackageInstaller launch failed: $e';
      });
    }
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
    const primaryGlow = Color(0xFFA855F7);
    const cardBg = Color(0xFF16162A);

    return ScaleTransition(
      scale: _scaleAnimation,
      child: Dialog(
        backgroundColor: Colors.transparent,
        elevation: 0,
        child: Container(
          width: 520,
          padding: const EdgeInsets.all(24),
          decoration: BoxDecoration(
            color: cardBg.withValues(alpha: 0.94),
            borderRadius: BorderRadius.circular(24),
            border: Border.all(
              color: primaryAccent.withValues(alpha: 0.35),
              width: 1.5,
            ),
            boxShadow: [
              BoxShadow(
                color: primaryAccent.withValues(alpha: 0.25),
                blurRadius: 32,
                spreadRadius: 2,
              ),
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.6),
                blurRadius: 24,
                spreadRadius: -4,
              ),
            ],
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // ── Header Row ───────────────────────────────────────
              Row(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  Container(
                    padding: const EdgeInsets.all(10),
                    decoration: BoxDecoration(
                      gradient: const LinearGradient(
                        colors: [primaryAccent, primaryGlow],
                        begin: Alignment.topLeft,
                        end: Alignment.bottomRight,
                      ),
                      borderRadius: BorderRadius.circular(16),
                      boxShadow: [
                        BoxShadow(
                          color: primaryAccent.withValues(alpha: 0.4),
                          blurRadius: 12,
                        ),
                      ],
                    ),
                    child: const Icon(Icons.android_rounded, color: Colors.white, size: 26),
                  ),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'SonicWave Android 64-Bit Updater',
                          style: GoogleFonts.outfit(
                            color: Colors.white,
                            fontSize: 17,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Row(
                          children: [
                            Container(
                              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                              decoration: BoxDecoration(
                                color: primaryAccent.withValues(alpha: 0.2),
                                borderRadius: BorderRadius.circular(8),
                                border: Border.all(color: primaryAccent.withValues(alpha: 0.4)),
                              ),
                              child: Text(
                                'v${widget.updateClient.currentVersion} → ${widget.release.tag}',
                                style: GoogleFonts.inter(
                                  color: primaryGlow,
                                  fontSize: 11,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ),
                            const SizedBox(width: 8),
                            Container(
                              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                              decoration: BoxDecoration(
                                color: Colors.greenAccent.withValues(alpha: 0.2),
                                borderRadius: BorderRadius.circular(6),
                              ),
                              child: const Text(
                                'arm64-v8a',
                                style: TextStyle(color: Colors.greenAccent, fontSize: 10, fontWeight: FontWeight.bold),
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                  if (_status == UpdateStatus.available)
                    IconButton(
                      icon: const Icon(Icons.close_rounded, color: Colors.white54),
                      onPressed: () {
                        Navigator.of(context).pop();
                        widget.onDismiss?.call();
                      },
                    ),
                ],
              ),
              const SizedBox(height: 16),
              const Divider(color: Colors.white10, height: 1),
              const SizedBox(height: 16),

              // ── Dynamic Body State Switcher ───────────────────────
              _buildBodyContent(primaryAccent, primaryGlow),

              const SizedBox(height: 20),

              // ── Action Controls Footer ────────────────────────────
              _buildActionFooter(context, primaryAccent, primaryGlow),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildBodyContent(Color primaryAccent, Color primaryGlow) {
    switch (_status) {
      case UpdateStatus.available:
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'What\'s New in ${widget.release.tag}',
              style: GoogleFonts.outfit(
                color: Colors.white,
                fontSize: 14,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 8),
            Container(
              constraints: const BoxConstraints(maxHeight: 160),
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: Colors.black.withValues(alpha: 0.3),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: Colors.white10),
              ),
              child: SingleChildScrollView(
                child: Text(
                  widget.release.releaseNotes.isNotEmpty
                      ? widget.release.releaseNotes
                      : 'Performance improvements and bug fixes for 64-Bit Android.',
                  style: GoogleFonts.inter(
                    color: Colors.white70,
                    fontSize: 12,
                    height: 1.5,
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
                Text(
                  'Downloading APK Package...',
                  style: GoogleFonts.outfit(color: Colors.white, fontSize: 13, fontWeight: FontWeight.w600),
                ),
                Text(
                  '${prog?.percentage ?? 0}%',
                  style: GoogleFonts.outfit(color: primaryGlow, fontSize: 14, fontWeight: FontWeight.bold),
                ),
              ],
            ),
            const SizedBox(height: 10),
            ClipRRect(
              borderRadius: BorderRadius.circular(8),
              child: LinearProgressIndicator(
                value: prog?.fraction ?? 0.0,
                minHeight: 8,
                backgroundColor: Colors.white10,
                valueColor: AlwaysStoppedAnimation<Color>(primaryGlow),
              ),
            ),
            const SizedBox(height: 10),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  'Transferred: ${(prog?.downloadedMB ?? 0.0).toStringAsFixed(1)} MB / ${(prog?.totalMB ?? 0.0).toStringAsFixed(1)} MB',
                  style: const TextStyle(color: Colors.white54, fontSize: 11),
                ),
                Text(
                  'Speed: ${(prog?.speedMBps ?? 0.0).toStringAsFixed(1)} MB/s',
                  style: TextStyle(color: primaryAccent, fontSize: 11, fontWeight: FontWeight.w600),
                ),
              ],
            ),
          ],
        );

      case UpdateStatus.verifying:
        return Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: Colors.blue.withValues(alpha: 0.1),
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: Colors.blue.withValues(alpha: 0.3)),
          ),
          child: const Row(
            children: [
              SizedBox(
                width: 20,
                height: 20,
                child: CircularProgressIndicator(strokeWidth: 2, color: Colors.blueAccent),
              ),
              SizedBox(width: 14),
              Expanded(
                child: Text(
                  'Verifying SHA-256 APK binary integrity...',
                  style: TextStyle(color: Colors.white, fontSize: 12, fontWeight: FontWeight.w500),
                ),
              ),
            ],
          ),
        );

      case UpdateStatus.readyToInstall:
        return Container(
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: Colors.green.withValues(alpha: 0.12),
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: Colors.green.withValues(alpha: 0.35)),
          ),
          child: const Row(
            children: [
              Icon(Icons.check_circle_rounded, color: Colors.greenAccent, size: 22),
              SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'APK Download Verified & Ready!',
                      style: TextStyle(color: Colors.white, fontSize: 13, fontWeight: FontWeight.bold),
                    ),
                    SizedBox(height: 2),
                    Text(
                      'Tap below to open Android PackageInstaller.',
                      style: TextStyle(color: Colors.white70, fontSize: 11),
                    ),
                  ],
                ),
              ),
            ],
          ),
        );

      case UpdateStatus.error:
        return Container(
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: Colors.red.withValues(alpha: 0.12),
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: Colors.red.withValues(alpha: 0.35)),
          ),
          child: Row(
            children: [
              const Icon(Icons.error_outline_rounded, color: Colors.redAccent, size: 22),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  _errorMessage ?? 'An unexpected error occurred during update.',
                  style: const TextStyle(color: Colors.white, fontSize: 12),
                ),
              ),
            ],
          ),
        );

      default:
        return const SizedBox.shrink();
    }
  }

  Widget _buildActionFooter(BuildContext context, Color primaryAccent, Color primaryGlow) {
    if (_status == UpdateStatus.available) {
      return Row(
        mainAxisAlignment: MainAxisAlignment.end,
        children: [
          TextButton(
            onPressed: () {
              Navigator.of(context).pop();
              widget.onDismiss?.call();
            },
            child: const Text('Remind Me Later', style: TextStyle(color: Colors.white54)),
          ),
          const SizedBox(width: 10),
          ElevatedButton.icon(
            onPressed: _startDownload,
            style: ElevatedButton.styleFrom(
              backgroundColor: primaryAccent,
              foregroundColor: Colors.white,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
              elevation: 4,
            ),
            icon: const Icon(Icons.download_rounded, size: 18),
            label: const Text('Update Now', style: TextStyle(fontWeight: FontWeight.bold)),
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
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
          ),
          child: const Text('Cancel Download'),
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
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
            padding: const EdgeInsets.symmetric(vertical: 14),
            elevation: 6,
          ),
          icon: const Icon(Icons.android_rounded, size: 20),
          label: const Text('Install APK Update Now', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 14)),
        ),
      );
    }

    if (_status == UpdateStatus.error) {
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
            onPressed: _startDownload,
            style: ElevatedButton.styleFrom(
              backgroundColor: primaryAccent,
              foregroundColor: Colors.white,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
            ),
            icon: const Icon(Icons.refresh_rounded, size: 18),
            label: const Text('Retry Download'),
          ),
        ],
      );
    }

    return const SizedBox.shrink();
  }
}
