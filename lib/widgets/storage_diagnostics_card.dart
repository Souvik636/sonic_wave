import 'dart:async';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../providers/player_provider.dart';
import '../providers/search_provider.dart';
import '../services/storage_diagnostics_service.dart';
import '../theme/app_colors.dart';
import 'app_toast.dart';
import 'glassmorphic_card.dart';
import 'premium_interaction.dart';

class StorageDiagnosticsCard extends StatefulWidget {
  const StorageDiagnosticsCard({super.key});

  @override
  State<StorageDiagnosticsCard> createState() => _StorageDiagnosticsCardState();
}

class _StorageDiagnosticsCardState extends State<StorageDiagnosticsCard> {
  final StorageDiagnosticsService _service = StorageDiagnosticsService();
  StorageStats _stats = const StorageStats();
  bool _isLoading = true;
  bool _isCleaning = false;
  bool _isRepairing = false;

  @override
  void initState() {
    super.initState();
    _loadStats();
  }

  Future<void> _loadStats() async {
    if (!mounted) return;
    setState(() => _isLoading = true);

    final player = context.read<PlayerProvider>();
    final historyCount = player.recentlyPlayed.length;

    try {
      final prefs = await SharedPreferences.getInstance();
      final recentSearches =
          (prefs.getStringList('recent_searches_list') ?? []).length;

      final stats = await _service.getStorageStats(
        recentSearches: recentSearches,
        playbackHistory: historyCount,
      );

      if (mounted) {
        setState(() {
          _stats = stats;
          _isLoading = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() => _isLoading = false);
      }
    }
  }

  Future<void> _clearImages() async {
    setState(() => _isCleaning = true);
    final freed = await _service.clearImageCache();
    await _loadStats();
    if (mounted) {
      setState(() => _isCleaning = false);
      AppToast.show(
        context,
        'Cover art cache cleared (${StorageStats.formatBytes(freed)} freed)',
        type: ToastType.success,
      );
    }
  }

  Future<void> _clearStreams() async {
    setState(() => _isCleaning = true);
    final freed = await _service.clearStreamCache();
    await _loadStats();
    if (mounted) {
      setState(() => _isCleaning = false);
      AppToast.show(
        context,
        'Stream buffer cache cleared (${StorageStats.formatBytes(freed)} freed)',
        type: ToastType.success,
      );
    }
  }

  Future<void> _clearStaging() async {
    setState(() => _isCleaning = true);
    final freed = await _service.clearStagingFiles();
    await _loadStats();
    if (mounted) {
      setState(() => _isCleaning = false);
      AppToast.show(
        context,
        'yt-dlp staging files purged (${StorageStats.formatBytes(freed)} freed)',
        type: ToastType.success,
      );
    }
  }

  Future<void> _clearSearchHistory() async {
    await _service.clearSearchHistory();
    if (mounted) {
      try {
        context.read<SearchProvider>().clearRecentSearches();
      } catch (_) {}
    }
    await _loadStats();
    if (mounted) {
      AppToast.show(context, 'Search history cleared', type: ToastType.success);
    }
  }

  Future<void> _confirmWipeHistory() async {
    showDialog(
      context: context,
      builder: (dialogCtx) => AlertDialog(
        backgroundColor: const Color(0xFF16162A),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(20),
          side: BorderSide(color: Colors.white.withValues(alpha: 0.1)),
        ),
        title: Text(
          'Wipe Playback History?',
          style: GoogleFonts.outfit(
              color: Colors.white, fontWeight: FontWeight.bold),
        ),
        content: Text(
          'This will clear all recently played tracks from your Library screen. This cannot be undone.',
          style:
              GoogleFonts.inter(color: AppColors.textSecondary, fontSize: 14),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogCtx),
            child: const Text('Cancel',
                style: TextStyle(color: AppColors.textSecondary)),
          ),
          TextButton(
            onPressed: () async {
              Navigator.pop(dialogCtx);
              await context.read<PlayerProvider>().clearHistory();
              await _loadStats();
              if (mounted) {
                AppToast.show(
                  context,
                  'Playback history wiped successfully',
                  type: ToastType.success,
                );
              }
            },
            child: const Text('Confirm Wipe',
                style: TextStyle(
                    color: Colors.redAccent, fontWeight: FontWeight.bold)),
          ),
        ],
      ),
    );
  }

  Future<void> _cleanAllCaches() async {
    setState(() => _isCleaning = true);
    final freed = await _service.cleanAllCaches();
    await _loadStats();
    if (mounted) {
      setState(() => _isCleaning = false);
      AppToast.show(
        context,
        'Quick clean complete! ${StorageStats.formatBytes(freed)} cache space recovered.',
        type: ToastType.success,
      );
    }
  }

  Future<void> _runDeepRepair() async {
    setState(() => _isRepairing = true);
    AppToast.show(context, 'Running deep storage & library repair...',
        type: ToastType.info);

    final player = context.read<PlayerProvider>();
    final report =
        await _service.repairAndResyncStorage(playerProvider: player);
    await _loadStats();

    if (mounted) {
      setState(() => _isRepairing = false);
      _showRepairReportDialog(report);
    }
  }

  void _showRepairReportDialog(StorageRepairReport report) {
    final primary = Theme.of(context).colorScheme.primary;

    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF16162A),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(24),
          side: BorderSide(color: primary.withValues(alpha: 0.35), width: 1.5),
        ),
        title: Row(
          children: [
            Container(
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: Colors.greenAccent.withValues(alpha: 0.2),
                borderRadius: BorderRadius.circular(12),
              ),
              child: const Icon(Icons.verified_rounded,
                  color: Colors.greenAccent, size: 22),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Storage Health Report',
                    style: GoogleFonts.outfit(
                        color: Colors.white,
                        fontSize: 17,
                        fontWeight: FontWeight.bold),
                  ),
                  Text(
                    'Library Diagnostic & Repair Complete',
                    style: GoogleFonts.inter(
                        color: AppColors.textTertiary, fontSize: 11),
                  ),
                ],
              ),
            ),
          ],
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            _buildReportRow(Icons.check_circle_rounded, 'Verified Offline Tracks',
                '${report.verifiedTracks} tracks', Colors.greenAccent),
            if (report.containersRepaired > 0)
              _buildReportRow(
                  Icons.build_circle_rounded,
                  'Container Formats Repaired',
                  '${report.containersRepaired} files',
                  Colors.orangeAccent),
            _buildReportRow(
                Icons.library_music_rounded,
                'Recovered Unindexed Audio',
                '+${report.recoveredTracks} tracks',
                Colors.cyanAccent),
            _buildReportRow(
                Icons.delete_sweep_rounded,
                'Ghost Records Pruned',
                '${report.ghostTracksPurged} records',
                Colors.amberAccent),
            _buildReportRow(
                Icons.cleaning_services_rounded,
                'Corrupted / Partial Files Cleaned',
                '${report.junkFilesCleaned} files',
                Colors.purpleAccent),
            _buildReportRow(Icons.folder_special_rounded, 'Folder Albums Synced',
                '${report.albumsSynced} albums', primary),
            const Divider(color: Colors.white10, height: 20),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text('Space Recovered:',
                    style: GoogleFonts.inter(
                        color: Colors.white70, fontSize: 13)),
                Text(
                  report.formattedBytesFreed,
                  style: GoogleFonts.outfit(
                      color: Colors.greenAccent,
                      fontSize: 15,
                      fontWeight: FontWeight.bold),
                ),
              ],
            ),
          ],
        ),
        actions: [
          ElevatedButton(
            onPressed: () => Navigator.pop(ctx),
            style: ElevatedButton.styleFrom(
              backgroundColor: primary,
              foregroundColor: Colors.white,
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12)),
              padding:
                  const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
            ),
            child:
                const Text('Done', style: TextStyle(fontWeight: FontWeight.bold)),
          ),
        ],
      ),
    );
  }

  Widget _buildReportRow(
      IconData icon, String label, String value, Color color) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        children: [
          Icon(icon, color: color, size: 16),
          const SizedBox(width: 10),
          Expanded(
            child: Text(label,
                style: GoogleFonts.inter(
                    color: Colors.white70, fontSize: 12)),
          ),
          Text(
            value,
            style: GoogleFonts.inter(
                color: Colors.white,
                fontSize: 12,
                fontWeight: FontWeight.bold),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final primary = Theme.of(context).colorScheme.primary;

    return GlassmorphicCard(
      padding: const EdgeInsets.all(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // ── Title & Total Cache Header ───────────────────────
          Row(
            children: [
              Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    colors: [
                      primary.withValues(alpha: 0.35),
                      primary.withValues(alpha: 0.15),
                    ],
                  ),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: primary.withValues(alpha: 0.3)),
                ),
                child: Icon(Icons.storage_rounded, color: primary, size: 20),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'App Storage & Cache Center',
                      style: Theme.of(context)
                          .textTheme
                          .titleLarge
                          ?.copyWith(fontSize: 15),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      'Granular cache cleaners, storage breakdown & health repair',
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ],
                ),
              ),
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                decoration: BoxDecoration(
                  color: primary.withValues(alpha: 0.15),
                  borderRadius: BorderRadius.circular(20),
                  border: Border.all(color: primary.withValues(alpha: 0.3)),
                ),
                child: Text(
                  _isLoading
                      ? '...'
                      : StorageStats.formatBytes(_stats.totalCacheBytes),
                  style: GoogleFonts.outfit(
                    color: primary,
                    fontSize: 12,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
            ],
          ),

          const SizedBox(height: 16),

          // ── Visual Storage Meter Bar ─────────────────────────
          _buildStorageBar(primary),

          const SizedBox(height: 18),

          // ── Master Actions (Clean All & Deep Repair) ──────────
          Row(
            children: [
              Expanded(
                child: PremiumTap(
                  onTap: (_isCleaning || _isLoading) ? null : _cleanAllCaches,
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                        vertical: 10, horizontal: 8),
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        colors: [
                          primary.withValues(alpha: 0.25),
                          primary.withValues(alpha: 0.10),
                        ],
                      ),
                      borderRadius: BorderRadius.circular(12),
                      border:
                          Border.all(color: primary.withValues(alpha: 0.35)),
                    ),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        _isCleaning
                            ? SizedBox(
                                width: 14,
                                height: 14,
                                child: CircularProgressIndicator(
                                    strokeWidth: 2, color: primary))
                            : Icon(Icons.cleaning_services_rounded,
                                color: primary, size: 16),
                        const SizedBox(width: 6),
                        Flexible(
                          child: Text(
                            'Clean All Caches',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                                color: primary,
                                fontSize: 11.5,
                                fontWeight: FontWeight.bold),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: PremiumTap(
                  onTap: (_isRepairing || _isLoading) ? null : _runDeepRepair,
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                        vertical: 10, horizontal: 8),
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        colors: [
                          Colors.greenAccent.withValues(alpha: 0.20),
                          Colors.greenAccent.withValues(alpha: 0.08),
                        ],
                      ),
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(
                          color: Colors.greenAccent.withValues(alpha: 0.35)),
                    ),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        _isRepairing
                            ? const SizedBox(
                                width: 14,
                                height: 14,
                                child: CircularProgressIndicator(
                                    strokeWidth: 2, color: Colors.greenAccent))
                            : const Icon(Icons.build_circle_rounded,
                                color: Colors.greenAccent, size: 16),
                        const SizedBox(width: 6),
                        const Flexible(
                          child: Text(
                            'Deep Repair Library',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                                color: Colors.greenAccent,
                                fontSize: 11.5,
                                fontWeight: FontWeight.bold),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ],
          ),

          const SizedBox(height: 20),
          const Divider(height: 1, color: AppColors.divider),
          const SizedBox(height: 14),

          // ── Individual Component Breakdowns ──────────────────
          _buildItemRow(
            icon: Icons.image_rounded,
            iconColor: Colors.amberAccent,
            title: 'Cover Art & Image Cache',
            subtitle: 'Cached album art & thumbnail image files',
            sizeText: StorageStats.formatBytes(_stats.imageCacheBytes),
            buttonLabel: 'Clear',
            onAction: _clearImages,
          ),

          const Divider(height: 20, color: Colors.white10),

          _buildItemRow(
            icon: Icons.graphic_eq_rounded,
            iconColor: Colors.purpleAccent,
            title: 'Stream Audio Buffers',
            subtitle: 'Pre-buffered audio for smooth offline re-streaming',
            sizeText: StorageStats.formatBytes(_stats.streamCacheBytes),
            buttonLabel: 'Clear',
            onAction: _clearStreams,
          ),

          const Divider(height: 20, color: Colors.white10),

          _buildItemRow(
            icon: Icons.folder_zip_rounded,
            iconColor: Colors.tealAccent,
            title: 'yt-dlp Staging Fragments',
            subtitle: 'Temporary extraction chunks & partial downloads',
            sizeText: StorageStats.formatBytes(_stats.stagingBytes),
            buttonLabel: 'Purge',
            onAction: _clearStaging,
          ),

          const Divider(height: 20, color: Colors.white10),

          _buildItemRow(
            icon: Icons.search_rounded,
            iconColor: Colors.blueAccent,
            title: 'Search Keyword History',
            subtitle: 'Saved search queries & suggestion cache',
            sizeText: '${_stats.searchHistoryCount} queries',
            buttonLabel: 'Clear',
            onAction: _clearSearchHistory,
          ),

          const Divider(height: 20, color: Colors.white10),

          _buildItemRow(
            icon: Icons.history_rounded,
            iconColor: Colors.redAccent,
            title: 'Recently Played History',
            subtitle: 'Playback logs on your Library screen',
            sizeText: '${_stats.playbackHistoryCount} tracks',
            buttonLabel: 'Wipe',
            buttonColor: Colors.redAccent,
            onAction: _confirmWipeHistory,
          ),
        ],
      ),
    );
  }

  Widget _buildStorageBar(Color primary) {
    final downloaded = _stats.downloadedMusicBytes;
    final stream = _stats.streamCacheBytes;
    final images = _stats.imageCacheBytes;
    final staging = _stats.stagingBytes;
    final total = downloaded + stream + images + staging;

    final dlRatio = total > 0 ? (downloaded / total).clamp(0.05, 0.70) : 0.40;
    final streamRatio = total > 0 ? (stream / total).clamp(0.05, 0.40) : 0.30;
    final imgRatio = total > 0 ? (images / total).clamp(0.05, 0.30) : 0.20;
    final stagingRatio =
        total > 0 ? (staging / total).clamp(0.05, 0.20) : 0.10;

    return Column(
      children: [
        ClipRRect(
          borderRadius: BorderRadius.circular(6),
          child: SizedBox(
            height: 8,
            child: Row(
              children: [
                Expanded(
                    flex: (dlRatio * 100).toInt(),
                    child: Container(color: Colors.cyanAccent)),
                const SizedBox(width: 2),
                Expanded(
                    flex: (streamRatio * 100).toInt(),
                    child: Container(color: Colors.purpleAccent)),
                const SizedBox(width: 2),
                Expanded(
                    flex: (imgRatio * 100).toInt(),
                    child: Container(color: Colors.amberAccent)),
                const SizedBox(width: 2),
                Expanded(
                    flex: (stagingRatio * 100).toInt(),
                    child: Container(color: Colors.tealAccent)),
              ],
            ),
          ),
        ),
        const SizedBox(height: 8),
        Wrap(
          spacing: 12,
          runSpacing: 6,
          alignment: WrapAlignment.start,
          children: [
            _legendItem(Colors.cyanAccent,
                'Music (${StorageStats.formatBytes(downloaded)})'),
            _legendItem(Colors.purpleAccent, 'Stream (${StorageStats.formatBytes(stream)})'),
            _legendItem(Colors.amberAccent, 'Art (${StorageStats.formatBytes(images)})'),
            _legendItem(Colors.tealAccent, 'Staging (${StorageStats.formatBytes(staging)})'),
          ],
        ),
      ],
    );
  }

  Widget _legendItem(Color color, String label) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
            width: 7,
            height: 7,
            decoration:
                BoxDecoration(color: color, shape: BoxShape.circle)),
        const SizedBox(width: 4),
        Text(label,
            style:
                const TextStyle(color: AppColors.textTertiary, fontSize: 10)),
      ],
    );
  }

  Widget _buildItemRow({
    required IconData icon,
    required Color iconColor,
    required String title,
    required String subtitle,
    required String sizeText,
    required String buttonLabel,
    Color? buttonColor,
    required VoidCallback onAction,
  }) {
    final primary = buttonColor ?? Theme.of(context).colorScheme.primary;

    return Row(
      children: [
        Container(
          padding: const EdgeInsets.all(8),
          decoration: BoxDecoration(
            color: iconColor.withValues(alpha: 0.12),
            borderRadius: BorderRadius.circular(10),
          ),
          child: Icon(icon, color: iconColor, size: 18),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Flexible(
                    child: Text(
                      title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: GoogleFonts.outfit(
                        color: Colors.white,
                        fontSize: 13.5,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 6, vertical: 1.5),
                    decoration: BoxDecoration(
                      color: Colors.white.withValues(alpha: 0.08),
                      borderRadius: BorderRadius.circular(6),
                    ),
                    child: Text(
                      sizeText,
                      style: GoogleFonts.inter(
                        color: Colors.white70,
                        fontSize: 10.5,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 2),
              Text(
                subtitle,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                    color: AppColors.textTertiary, fontSize: 11),
              ),
            ],
          ),
        ),
        const SizedBox(width: 8),
        OutlinedButton(
          onPressed: _isCleaning ? null : onAction,
          style: OutlinedButton.styleFrom(
            side: BorderSide(color: primary.withValues(alpha: 0.45)),
            shape:
                RoundedRectangleBorder(borderRadius: BorderRadius.circular(9)),
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            minimumSize: Size.zero,
            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
          ),
          child: Text(
            buttonLabel,
            style: TextStyle(
                color: primary, fontSize: 11.5, fontWeight: FontWeight.bold),
          ),
        ),
      ],
    );
  }
}
