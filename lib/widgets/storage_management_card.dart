import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../providers/player_provider.dart';
import '../providers/settings_provider.dart';
import '../services/download_service.dart';
import '../services/storage_analyzer.dart';
import '../services/storage_location_service.dart';
import '../services/stream_cache_service.dart';
import '../theme/app_colors.dart';
import '../widgets/downloads_hub.dart';
import '../widgets/glassmorphic_card.dart';
import 'app_toast.dart';

/// Premium Storage & Cache management card with animated donut chart,
/// stat cards, per-category breakdown, individual + bulk clear actions,
/// and storage health diagnostics.
class StorageManagementCard extends StatefulWidget {
  const StorageManagementCard({super.key});

  @override
  State<StorageManagementCard> createState() => _StorageManagementCardState();
}

class _StorageManagementCardState extends State<StorageManagementCard>
    with SingleTickerProviderStateMixin {
  StorageBreakdown? _breakdown;
  bool _loading = true;
  String?
  _clearingCategory; // null = idle, 'all' | 'stream' | 'image' | 'cover' | 'history'
  bool _scanning = false;
  String? _scanResult;

  late final AnimationController _ringController;
  late final Animation<double> _ringAnimation;

  // Category colors
  static const _colDownloads = Color(0xFF6C63FF); // primary purple
  static const _colStream = Color(0xFF00C9A7); // teal
  static const _colImages = Color(0xFFFF6584); // accent pink
  static const _colCover = Color(0xFFFFB74D); // amber
  static const _colMeta = Color(0xFF78909C); // blue grey
  static const _colAlbums = Color(0xFF448AFF); // blue

  @override
  void initState() {
    super.initState();
    _ringController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 900),
    );
    _ringAnimation = CurvedAnimation(
      parent: _ringController,
      curve: Curves.easeOutCubic,
    );
    _analyze();
  }

  @override
  void dispose() {
    _ringController.dispose();
    super.dispose();
  }

  Future<void> _analyze() async {
    setState(() => _loading = true);
    final b = await StorageAnalyzer.instance.analyze();
    if (mounted) {
      setState(() {
        _breakdown = b;
        _loading = false;
      });
      _ringController.forward(from: 0);
    }
  }

  Future<void> _clearCategory(String category) async {
    setState(() => _clearingCategory = category);
    try {
      switch (category) {
        case 'stream':
          await StorageAnalyzer.instance.clearStreamCache();
          break;
        case 'image':
          await StorageAnalyzer.instance.clearImageCache();
          break;
        case 'cover':
          await StorageAnalyzer.instance.clearCoverArt();
          break;
        case 'history':
          if (mounted) {
            await context.read<PlayerProvider>().clearHistory();
          }
          break;
        case 'all':
          try {
            await StorageAnalyzer.instance.clearAllCaches();
          } catch (e) {
            debugPrint('[StorageCard] clearAllCaches failed: $e');
          }
          if (mounted) {
            try {
              await context.read<PlayerProvider>().clearHistory();
            } catch (e) {
              debugPrint('[StorageCard] clearHistory failed: $e');
            }
          }
          break;
      }
    } catch (e) {
      debugPrint('[StorageCard] clear $category failed: $e');
    }
    if (mounted) {
      setState(() => _clearingCategory = null);
      _analyze(); // refresh sizes
    }
  }

  void _openDownloadsHub() {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => Scaffold(
          appBar: AppBar(
            title: const Text('Manage Downloads'),
            backgroundColor: AppColors.surface,
          ),
          backgroundColor: AppColors.background,
          body: const DownloadsHub(),
        ),
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
          // ── Header ────────────────────────────────────────────────
          Row(
            children: [
              Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: primary.withValues(alpha: 0.15),
                  shape: BoxShape.circle,
                ),
                child: Icon(Icons.pie_chart_rounded, color: primary, size: 20),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Storage & Cache Usage',
                      style: Theme.of(
                        context,
                      ).textTheme.titleLarge?.copyWith(fontSize: 16),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      _loading
                          ? 'Analyzing disk storage...'
                          : 'Total App Footprint: ${StorageAnalyzer.formatBytes(_breakdown?.total ?? 0)}',
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: AppColors.textTertiary,
                      ),
                    ),
                  ],
                ),
              ),
              // Refresh button
              IconButton(
                onPressed: _loading ? null : _analyze,
                icon: AnimatedRotation(
                  turns: _loading ? 1 : 0,
                  duration: const Duration(milliseconds: 600),
                  child: Icon(
                    Icons.refresh_rounded,
                    color: _loading ? AppColors.textTertiary : primary,
                    size: 20,
                  ),
                ),
                tooltip: 'Refresh Storage',
                visualDensity: VisualDensity.compact,
              ),
            ],
          ),

          const SizedBox(height: 18),

          // ── Quick Stat Badges ─────────────────────────────────────
          _buildStatBadges(context),

          const SizedBox(height: 20),

          // ── Donut Chart Section ───────────────────────────────────
          if (_loading)
            const Center(
              child: Padding(
                padding: EdgeInsets.symmetric(vertical: 24),
                child: SizedBox(
                  width: 32,
                  height: 32,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
              ),
            )
          else
            _buildDonutSection(),

          const SizedBox(height: 18),
          const Divider(height: 1, color: AppColors.divider),
          const SizedBox(height: 18),

          // ── Category Breakdown List ───────────────────────────────
          if (!_loading) ...[
            _buildCategoryRow(
              icon: Icons.music_note_rounded,
              label: 'Downloaded Songs',
              size: _breakdown!.downloadedSongs,
              color: _colDownloads,
              clearable: false,
              onActionTap: _openDownloadsHub,
              actionLabel: 'Manage',
            ),
            if (_breakdown!.albumFolders > 0)
              _buildCategoryRow(
                icon: Icons.album_rounded,
                label: 'Album Folders',
                size: _breakdown!.albumFolders,
                color: _colAlbums,
                clearable: false,
              ),
            _buildCategoryRow(
              icon: Icons.stream_rounded,
              label: 'Stream Cache',
              size: _breakdown!.streamCache,
              color: _colStream,
              clearable: true,
              categoryKey: 'stream',
            ),
            _buildCategoryRow(
              icon: Icons.image_rounded,
              label: 'Image Cache',
              size: _breakdown!.imageCache,
              color: _colImages,
              clearable: true,
              categoryKey: 'image',
            ),
            _buildCategoryRow(
              icon: Icons.photo_library_rounded,
              label: 'Extracted Cover Art',
              size: _breakdown!.coverArt,
              color: _colCover,
              clearable: true,
              categoryKey: 'cover',
            ),
            _buildCategoryRow(
              icon: Icons.history_rounded,
              label: 'Playback History & Index',
              size: _breakdown!.metadata,
              color: _colMeta,
              clearable: true,
              categoryKey: 'history',
            ),

            const SizedBox(height: 18),
            const Divider(height: 1, color: AppColors.divider),
            const SizedBox(height: 18),

            // ── Clear All Caches Button ────────────────────────────
            _buildClearAllButton(),

            const SizedBox(height: 18),
            const Divider(height: 1, color: AppColors.divider),
            const SizedBox(height: 18),

            // ── Stream Cache Limit Picker ──────────────────────────
            _buildStreamCacheLimitPicker(context),

            const SizedBox(height: 18),
            const Divider(height: 1, color: AppColors.divider),
            const SizedBox(height: 18),

            // ── Scan & Repair Tool ────────────────────────────────
            _buildScanRepairButton(context),

            // ── Fallback Location Warning ──────────────────────────
            _buildFallbackWarning(),
          ],
        ],
      ),
    );
  }

  // ── Stat Badges ───────────────────────────────────────────────────

  Widget _buildStatBadges(BuildContext context) {
    final b = _breakdown;
    final downloadedCount = context
        .watch<PlayerProvider>()
        .downloadedSongs
        .length;
    final totalStr = StorageAnalyzer.formatBytes(b?.total ?? 0);
    final clearableStr = StorageAnalyzer.formatBytes(b?.clearable ?? 0);
    final dlStr = StorageAnalyzer.formatBytes(b?.downloadedSongs ?? 0);

    return GridView.count(
      crossAxisCount: 2,
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      crossAxisSpacing: 10,
      mainAxisSpacing: 10,
      childAspectRatio: 2.3,
      children: [
        _buildStatTile(
          icon: Icons.disc_full_rounded,
          color: _colDownloads,
          title: 'App Footprint',
          value: totalStr,
        ),
        _buildStatTile(
          icon: Icons.cleaning_services_rounded,
          color: _colImages,
          title: 'Clearable Cache',
          value: clearableStr,
          badge: (b?.clearable ?? 0) > 0 ? 'Safe to Clear' : 'Clean',
        ),
        _buildStatTile(
          icon: Icons.download_done_rounded,
          color: _colStream,
          title: 'Downloaded Songs',
          value: dlStr,
          subtitle: '$downloadedCount offline tracks',
        ),
        _buildStatTile(
          icon: Icons.sd_storage_rounded,
          color: _colCover,
          title: 'Storage Health',
          value: StorageLocationService().isUsingFallbackLocation
              ? 'Fallback'
              : 'Optimal',
          subtitle: StorageLocationService().isUsingFallbackLocation
              ? 'App Storage'
              : 'Direct Write',
        ),
      ],
    );
  }

  Widget _buildStatTile({
    required IconData icon,
    required Color color,
    required String title,
    required String value,
    String? subtitle,
    String? badge,
  }) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: AppColors.surfaceVariant.withValues(alpha: 0.25),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: AppColors.glassBorder.withValues(alpha: 0.15),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Row(
            children: [
              Icon(icon, color: color, size: 14),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  title,
                  style: const TextStyle(
                    color: AppColors.textTertiary,
                    fontSize: 10,
                    fontWeight: FontWeight.w500,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              if (badge != null)
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 5,
                    vertical: 1.5,
                  ),
                  decoration: BoxDecoration(
                    color: color.withValues(alpha: 0.15),
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: Text(
                    badge,
                    style: TextStyle(
                      color: color,
                      fontSize: 8,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            value,
            style: const TextStyle(
              color: AppColors.textPrimary,
              fontSize: 13,
              fontWeight: FontWeight.bold,
            ),
          ),
          if (subtitle != null) ...[
            const SizedBox(height: 1),
            Text(
              subtitle,
              style: const TextStyle(
                color: AppColors.textTertiary,
                fontSize: 9,
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ],
        ],
      ),
    );
  }

  // ── Donut Chart + Segment Legend ──────────────────────────────────

  Widget _buildDonutSection() {
    final b = _breakdown!;
    final total = b.total;

    // Build segments (skip zero-size)
    final segments = <_DonutSegment>[];
    void addSeg(String label, int value, Color color) {
      if (value > 0) segments.add(_DonutSegment(label, value, color));
    }

    addSeg('Downloads', b.downloadedSongs, _colDownloads);
    addSeg('Albums', b.albumFolders, _colAlbums);
    addSeg('Stream', b.streamCache, _colStream);
    addSeg('Images', b.imageCache, _colImages);
    addSeg('Covers', b.coverArt, _colCover);
    addSeg('Meta', b.metadata, _colMeta);

    if (segments.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 16),
          child: Text(
            'No storage used yet',
            style: TextStyle(color: AppColors.textTertiary, fontSize: 13),
          ),
        ),
      );
    }

    return Row(
      children: [
        // Ring
        AnimatedBuilder(
          animation: _ringAnimation,
          builder: (context, child) {
            return SizedBox(
              width: 105,
              height: 105,
              child: CustomPaint(
                painter: _DonutPainter(
                  segments: segments,
                  total: total,
                  progress: _ringAnimation.value,
                ),
                child: Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        StorageAnalyzer.formatBytes(total),
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 13,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      const Text(
                        'Total Used',
                        style: TextStyle(
                          color: AppColors.textTertiary,
                          fontSize: 9,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            );
          },
        ),
        const SizedBox(width: 20),
        // Legend
        Expanded(
          child: Wrap(
            spacing: 12,
            runSpacing: 6,
            children: segments.map((s) {
              final pct = total > 0
                  ? (s.value / total * 100).toStringAsFixed(1)
                  : '0';
              return Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(
                    width: 8,
                    height: 8,
                    decoration: BoxDecoration(
                      color: s.color,
                      shape: BoxShape.circle,
                    ),
                  ),
                  const SizedBox(width: 5),
                  Text(
                    '${s.label} ($pct%)',
                    style: const TextStyle(
                      color: AppColors.textSecondary,
                      fontSize: 10,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ],
              );
            }).toList(),
          ),
        ),
      ],
    );
  }

  // ── Category Row ──────────────────────────────────────────────────

  Widget _buildCategoryRow({
    required IconData icon,
    required String label,
    required int size,
    required Color color,
    required bool clearable,
    String? categoryKey,
    VoidCallback? onActionTap,
    String? actionLabel,
  }) {
    final isClearing =
        clearable &&
        categoryKey != null &&
        (_clearingCategory == categoryKey || _clearingCategory == 'all');
    final total = _breakdown?.total ?? 1;
    final fraction = total > 0 ? (size / total).clamp(0.0, 1.0) : 0.0;
    final pctString = total > 0
        ? '${(fraction * 100).toStringAsFixed(1)}%'
        : '0%';

    return Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: Column(
        children: [
          Row(
            children: [
              Container(
                padding: const EdgeInsets.all(6),
                decoration: BoxDecoration(
                  color: color.withValues(alpha: 0.15),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Icon(icon, color: color, size: 16),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      label,
                      style: const TextStyle(
                        color: AppColors.textPrimary,
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      '$pctString of total app storage',
                      style: const TextStyle(
                        color: AppColors.textTertiary,
                        fontSize: 10,
                      ),
                    ),
                  ],
                ),
              ),
              AnimatedSwitcher(
                duration: const Duration(milliseconds: 300),
                child: Text(
                  isClearing
                      ? 'Clearing...'
                      : StorageAnalyzer.formatBytes(size),
                  key: ValueKey('$categoryKey-$size-$isClearing'),
                  style: TextStyle(
                    color: isClearing ? color : AppColors.textPrimary,
                    fontSize: 12,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
              if (clearable) ...[
                const SizedBox(width: 8),
                SizedBox(
                  height: 28,
                  child: TextButton(
                    onPressed:
                        (isClearing || _clearingCategory != null || size == 0)
                        ? null
                        : () => _clearCategory(categoryKey!),
                    style: TextButton.styleFrom(
                      padding: const EdgeInsets.symmetric(horizontal: 10),
                      minimumSize: Size.zero,
                      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(8),
                        side: BorderSide(
                          color: size > 0
                              ? color.withValues(alpha: 0.4)
                              : AppColors.divider,
                        ),
                      ),
                    ),
                    child: isClearing
                        ? SizedBox(
                            width: 12,
                            height: 12,
                            child: CircularProgressIndicator(
                              strokeWidth: 1.5,
                              color: color,
                            ),
                          )
                        : Text(
                            'Clear',
                            style: TextStyle(
                              color: size > 0 ? color : AppColors.textTertiary,
                              fontSize: 11,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                  ),
                ),
              ] else if (onActionTap != null && actionLabel != null) ...[
                const SizedBox(width: 8),
                SizedBox(
                  height: 28,
                  child: OutlinedButton(
                    onPressed: onActionTap,
                    style: OutlinedButton.styleFrom(
                      padding: const EdgeInsets.symmetric(horizontal: 10),
                      minimumSize: Size.zero,
                      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                      side: BorderSide(color: color.withValues(alpha: 0.5)),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(8),
                      ),
                    ),
                    child: Text(
                      actionLabel,
                      style: TextStyle(
                        color: color,
                        fontSize: 11,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                ),
              ],
            ],
          ),
          const SizedBox(height: 6),
          // Animated progress bar with smooth rounded corners
          ClipRRect(
            borderRadius: BorderRadius.circular(3),
            child: AnimatedBuilder(
              animation: _ringAnimation,
              builder: (context, _) {
                return LinearProgressIndicator(
                  value: fraction * _ringAnimation.value,
                  minHeight: 4,
                  backgroundColor: AppColors.surfaceVariant.withValues(
                    alpha: 0.3,
                  ),
                  valueColor: AlwaysStoppedAnimation(color),
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  // ── Clear All Button ──────────────────────────────────────────────

  Widget _buildClearAllButton() {
    final clearable = _breakdown?.clearable ?? 0;
    final isClearing = _clearingCategory == 'all';
    final b = _breakdown;

    final streamStr = StorageAnalyzer.formatBytes(b?.streamCache ?? 0);
    final imageStr = StorageAnalyzer.formatBytes(b?.imageCache ?? 0);
    final coverStr = StorageAnalyzer.formatBytes(b?.coverArt ?? 0);

    return SizedBox(
      width: double.infinity,
      child: OutlinedButton.icon(
        onPressed: (isClearing || _clearingCategory != null || clearable == 0)
            ? null
            : () {
                showDialog(
                  context: context,
                  builder: (ctx) => AlertDialog(
                    backgroundColor: AppColors.surface,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(20),
                    ),
                    title: const Row(
                      children: [
                        Icon(
                          Icons.cleaning_services_rounded,
                          color: Colors.redAccent,
                          size: 20,
                        ),
                        SizedBox(width: 8),
                        Text(
                          'Clear All Caches?',
                          style: TextStyle(color: Colors.white, fontSize: 16),
                        ),
                      ],
                    ),
                    content: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'This will free ${StorageAnalyzer.formatBytes(clearable)} across temporary cache locations:',
                          style: const TextStyle(
                            color: AppColors.textSecondary,
                            fontSize: 13,
                          ),
                        ),
                        const SizedBox(height: 10),
                        Text(
                          '• Stream Cache: $streamStr',
                          style: const TextStyle(
                            color: AppColors.textTertiary,
                            fontSize: 12,
                          ),
                        ),
                        Text(
                          '• Image & Thumbnail Cache: $imageStr',
                          style: const TextStyle(
                            color: AppColors.textTertiary,
                            fontSize: 12,
                          ),
                        ),
                        Text(
                          '• Temporary Cover Cache: $coverStr',
                          style: const TextStyle(
                            color: AppColors.textTertiary,
                            fontSize: 12,
                          ),
                        ),
                        Text(
                          '• Playback History & Cache Index',
                          style: const TextStyle(
                            color: AppColors.textTertiary,
                            fontSize: 12,
                          ),
                        ),
                        const SizedBox(height: 14),
                        Container(
                          padding: const EdgeInsets.all(10),
                          decoration: BoxDecoration(
                            color: const Color(
                              0xFF00E676,
                            ).withValues(alpha: 0.1),
                            borderRadius: BorderRadius.circular(8),
                            border: Border.all(
                              color: const Color(
                                0xFF00E676,
                              ).withValues(alpha: 0.3),
                            ),
                          ),
                          child: const Row(
                            children: [
                              Icon(
                                Icons.shield_outlined,
                                color: Color(0xFF00E676),
                                size: 16,
                              ),
                              SizedBox(width: 8),
                              Expanded(
                                child: Text(
                                  '✓ Downloaded songs and offline audio files are 100% safe and will NOT be touched.',
                                  style: TextStyle(
                                    color: Color(0xFF00E676),
                                    fontSize: 11,
                                    fontWeight: FontWeight.w500,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                    actions: [
                      TextButton(
                        onPressed: () => Navigator.pop(ctx),
                        child: const Text(
                          'Cancel',
                          style: TextStyle(color: AppColors.textSecondary),
                        ),
                      ),
                      TextButton(
                        onPressed: () {
                          Navigator.pop(ctx);
                          _clearCategory('all');
                        },
                        child: const Text(
                          'Clear All Caches',
                          style: TextStyle(
                            color: Colors.redAccent,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ),
                    ],
                  ),
                );
              },
        icon: isClearing
            ? const SizedBox(
                width: 16,
                height: 16,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  color: Colors.redAccent,
                ),
              )
            : const Icon(Icons.delete_sweep_rounded, size: 18),
        label: Text(
          isClearing
              ? 'Clearing Caches...'
              : 'Clear All Caches (${StorageAnalyzer.formatBytes(clearable)})',
        ),
        style: OutlinedButton.styleFrom(
          foregroundColor: clearable > 0
              ? Colors.redAccent
              : AppColors.textTertiary,
          side: BorderSide(
            color: clearable > 0
                ? Colors.redAccent.withValues(alpha: 0.4)
                : AppColors.divider,
          ),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
          ),
          padding: const EdgeInsets.symmetric(vertical: 12),
        ),
      ),
    );
  }

  // ── Stream Cache Limit Picker ─────────────────────────────────────

  Widget _buildStreamCacheLimitPicker(BuildContext context) {
    final settings = context.watch<SettingsProvider>();
    final currentMB = settings.streamCacheMaxMB;
    final primary = Theme.of(context).colorScheme.primary;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Icon(Icons.speed_rounded, color: _colStream, size: 18),
            const SizedBox(width: 10),
            const Expanded(
              child: Text(
                'Stream Cache Storage Limit',
                style: TextStyle(
                  color: AppColors.textPrimary,
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
              decoration: BoxDecoration(
                color: _colStream.withValues(alpha: 0.15),
                borderRadius: BorderRadius.circular(6),
              ),
              child: Text(
                '$currentMB MB',
                style: TextStyle(
                  color: _colStream,
                  fontSize: 11,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 4),
        Text(
          'Streamed audio tracks are saved for seamless offline replay. Oldest items are auto-pruned when limit is reached.',
          style: TextStyle(color: AppColors.textTertiary, fontSize: 10),
        ),
        const SizedBox(height: 10),
        Row(
          children: StreamCacheService.limitOptionsMB.map((mb) {
            final isSelected = mb == currentMB;
            return Expanded(
              child: Padding(
                padding: EdgeInsets.only(
                  right: mb != StreamCacheService.limitOptionsMB.last ? 6 : 0,
                ),
                child: GestureDetector(
                  onTap: () => settings.setStreamCacheMaxMB(mb),
                  child: AnimatedContainer(
                    duration: const Duration(milliseconds: 200),
                    padding: const EdgeInsets.symmetric(vertical: 8),
                    decoration: BoxDecoration(
                      color: isSelected
                          ? primary.withValues(alpha: 0.15)
                          : AppColors.surfaceVariant.withValues(alpha: 0.2),
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(
                        color: isSelected
                            ? primary.withValues(alpha: 0.5)
                            : AppColors.glassBorder.withValues(alpha: 0.1),
                        width: isSelected ? 1.5 : 0.5,
                      ),
                    ),
                    child: Center(
                      child: Text(
                        mb >= 1024 ? '${mb ~/ 1024} GB' : '$mb MB',
                        style: TextStyle(
                          color: isSelected
                              ? Colors.white
                              : AppColors.textSecondary,
                          fontSize: 11,
                          fontWeight: isSelected
                              ? FontWeight.bold
                              : FontWeight.w500,
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            );
          }).toList(),
        ),
      ],
    );
  }

  StorageRepairResult? _lastRepairResult;

  // ── Scan & Repair Button ──────────────────────────────────────────

  Widget _buildScanRepairButton(BuildContext context) {
    final primary = Theme.of(context).colorScheme.primary;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Icon(Icons.healing_rounded, color: primary, size: 18),
            const SizedBox(width: 10),
            const Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Storage Scan & Diagnostics',
                    style: TextStyle(
                      color: AppColors.textPrimary,
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  SizedBox(height: 2),
                  Text(
                    'Deep-scans for unindexed audio, fixes container mismatches, cleans temp files & syncs library',
                    style: TextStyle(
                      color: AppColors.textTertiary,
                      fontSize: 10,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            SizedBox(
              height: 32,
              child: OutlinedButton.icon(
                onPressed: _scanning ? null : _runScanRepair,
                icon: _scanning
                    ? SizedBox(
                        width: 14,
                        height: 14,
                        child: CircularProgressIndicator(
                          strokeWidth: 1.5,
                          color: primary,
                        ),
                      )
                    : Icon(Icons.search_rounded, size: 14, color: primary),
                label: Text(
                  _scanning ? 'Scanning...' : 'Run Diagnostics',
                  style: TextStyle(
                    color: _scanning ? AppColors.textTertiary : primary,
                    fontSize: 11,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                style: OutlinedButton.styleFrom(
                  padding: const EdgeInsets.symmetric(horizontal: 10),
                  minimumSize: Size.zero,
                  side: BorderSide(color: primary.withValues(alpha: 0.4)),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(8),
                  ),
                ),
              ),
            ),
          ],
        ),
        if (_scanResult != null) ...[
          const SizedBox(height: 12),
          AnimatedContainer(
            duration: const Duration(milliseconds: 300),
            width: double.infinity,
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: (_lastRepairResult?.totalFixed ?? 0) > 0
                  ? const Color(0xFFFFB74D).withValues(alpha: 0.08)
                  : const Color(0xFF00E676).withValues(alpha: 0.08),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(
                color: (_lastRepairResult?.totalFixed ?? 0) > 0
                    ? const Color(0xFFFFB74D).withValues(alpha: 0.25)
                    : const Color(0xFF00E676).withValues(alpha: 0.25),
              ),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Icon(
                      (_lastRepairResult?.totalFixed ?? 0) > 0
                          ? Icons.build_circle_rounded
                          : Icons.check_circle_outline_rounded,
                      size: 18,
                      color: (_lastRepairResult?.totalFixed ?? 0) > 0
                          ? const Color(0xFFFFB74D)
                          : const Color(0xFF00E676),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        _scanResult!,
                        style: const TextStyle(
                          color: AppColors.textPrimary,
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                  ],
                ),
                if (_lastRepairResult != null) ...[
                  const SizedBox(height: 10),
                  Wrap(
                    spacing: 6,
                    runSpacing: 6,
                    children: [
                      _buildDiagnosticChip(
                        icon: Icons.music_note_rounded,
                        label: 'Unindexed Songs Recovered',
                        value: '${_lastRepairResult!.recoveredUnindexedSongs}',
                        color: _colDownloads,
                      ),
                      _buildDiagnosticChip(
                        icon: Icons.extension_rounded,
                        label: 'Containers Repaired',
                        value: '${_lastRepairResult!.repairedContainers}',
                        color: _colStream,
                      ),
                      _buildDiagnosticChip(
                        icon: Icons.phonelink_erase_rounded,
                        label: 'Ghosts Pruned',
                        value: '${_lastRepairResult!.prunedGhosts}',
                        color: _colImages,
                      ),
                      _buildDiagnosticChip(
                        icon: Icons.cleaning_services_rounded,
                        label: 'Temp Files Freed',
                        value: '${_lastRepairResult!.cleanedTempFiles}',
                        color: _colCover,
                      ),
                      _buildDiagnosticChip(
                        icon: Icons.broken_image_rounded,
                        label: 'Orphan Covers Cleaned',
                        value: '${_lastRepairResult!.repairedCovers}',
                        color: _colMeta,
                      ),
                      if (_lastRepairResult!.duplicatesFound.isNotEmpty)
                        _buildDiagnosticChip(
                          icon: Icons.copy_rounded,
                          label: 'Duplicates Found',
                          value:
                              '${_lastRepairResult!.duplicatesFound.length} sets',
                          color: Colors.amberAccent,
                        ),
                    ],
                  ),
                  if (_lastRepairResult!.duplicatesFound.isNotEmpty) ...[
                    const SizedBox(height: 10),
                    SizedBox(
                      width: double.infinity,
                      child: ElevatedButton.icon(
                        onPressed: () {
                          _showDuplicateCleanerModal(
                            context,
                            _lastRepairResult!.duplicatesFound,
                          );
                        },
                        icon: const Icon(Icons.copy_rounded, size: 14),
                        label: Text(
                          'Review & Clean ${_lastRepairResult!.duplicatesFound.length} Duplicate Set(s)',
                          style: const TextStyle(
                            fontSize: 11,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        style: ElevatedButton.styleFrom(
                          backgroundColor: Colors.amber.shade900,
                          foregroundColor: Colors.white,
                          padding: const EdgeInsets.symmetric(vertical: 8),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(8),
                          ),
                        ),
                      ),
                    ),
                  ],
                ],
              ],
            ),
          ),
        ],
      ],
    );
  }

  void _showDuplicateCleanerModal(
    BuildContext context,
    List<DuplicateAudioGroup> duplicates,
  ) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) =>
          _DuplicateCleanerModal(duplicates: duplicates, onCleaned: _analyze),
    );
  }

  Widget _buildDiagnosticChip({
    required IconData icon,
    required String label,
    required String value,
    required Color color,
  }) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: color.withValues(alpha: 0.2)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, color: color, size: 12),
          const SizedBox(width: 4),
          Text(
            '$label: ',
            style: const TextStyle(
              color: AppColors.textSecondary,
              fontSize: 10,
            ),
          ),
          Text(
            value,
            style: TextStyle(
              color: color,
              fontSize: 10,
              fontWeight: FontWeight.bold,
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _runScanRepair() async {
    setState(() {
      _scanning = true;
      _scanResult = null;
      _lastRepairResult = null;
    });

    StorageRepairResult? result;

    try {
      result = await DownloadService().runComprehensiveStorageDiagnostics();

      if (mounted) {
        await context.read<PlayerProvider>().verifyAndSyncAllStores();
      }
    } catch (e) {
      debugPrint('[StorageCard] scan & repair failed: $e');
    }

    if (mounted) {
      setState(() {
        _scanning = false;
        _lastRepairResult = result;
        if (result != null && result.totalFixed > 0) {
          _scanResult =
              'Fixed ${result.totalFixed} storage issue(s). Offline library fully optimized.';
        } else {
          _scanResult =
              '✓ Storage integrity verified. All audio files, containers, and indexes are 100% healthy.';
        }
      });
      _analyze(); // refresh sizes after repairs
    }
  }

  // ── Fallback Location Warning ─────────────────────────────────────

  Widget _buildFallbackWarning() {
    final storage = StorageLocationService();
    if (!storage.isUsingFallbackLocation) return const SizedBox.shrink();

    final reason =
        storage.fallbackReason ?? 'Using fallback app storage location.';

    return Padding(
      padding: const EdgeInsets.only(top: 16),
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: const Color(0xFFFFB74D).withValues(alpha: 0.08),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(
            color: const Color(0xFFFFB74D).withValues(alpha: 0.25),
          ),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Icon(
              Icons.warning_amber_rounded,
              size: 18,
              color: Color(0xFFFFB74D),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'App Storage Fallback Active',
                    style: TextStyle(
                      color: Color(0xFFFFB74D),
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    reason,
                    style: const TextStyle(
                      color: AppColors.textTertiary,
                      fontSize: 10,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ═══════════════════════════════════════════════════════════════════════════
// Donut chart painter
// ═══════════════════════════════════════════════════════════════════════════

class _DonutSegment {
  final String label;
  final int value;
  final Color color;
  const _DonutSegment(this.label, this.value, this.color);
}

class _DonutPainter extends CustomPainter {
  final List<_DonutSegment> segments;
  final int total;
  final double progress;

  _DonutPainter({
    required this.segments,
    required this.total,
    required this.progress,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final radius = size.width / 2 - 6;
    const strokeWidth = 10.0;
    const gapRadians = 0.04;

    final totalGap = gapRadians * segments.length;
    final available = 2 * math.pi - totalGap;

    // Background ring
    final bgPaint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = strokeWidth
      ..color = AppColors.surfaceVariant.withValues(alpha: 0.4);
    canvas.drawCircle(center, radius, bgPaint);

    // Segments
    double startAngle = -math.pi / 2; // 12 o'clock
    for (final seg in segments) {
      final sweepAngle =
          (total > 0 ? seg.value / total : 0.0) * available * progress;
      final paint = Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = strokeWidth
        ..strokeCap = StrokeCap.round
        ..color = seg.color;

      canvas.drawArc(
        Rect.fromCircle(center: center, radius: radius),
        startAngle,
        sweepAngle,
        false,
        paint,
      );
      startAngle += sweepAngle + gapRadians;
    }
  }

  @override
  bool shouldRepaint(_DonutPainter old) {
    if (progress != old.progress || total != old.total) return true;
    if (segments.length != old.segments.length) return true;
    for (int i = 0; i < segments.length; i++) {
      if (segments[i].value != old.segments[i].value) return true;
    }
    return false;
  }
}

/// Interactive modal for reviewing and cleaning duplicate audio files.
class _DuplicateCleanerModal extends StatefulWidget {
  final List<DuplicateAudioGroup> duplicates;
  final VoidCallback onCleaned;

  const _DuplicateCleanerModal({
    required this.duplicates,
    required this.onCleaned,
  });

  @override
  State<_DuplicateCleanerModal> createState() => _DuplicateCleanerModalState();
}

class _DuplicateCleanerModalState extends State<_DuplicateCleanerModal> {
  final Set<String> _pathsToDelete = {};
  bool _isCleaning = false;

  @override
  void initState() {
    super.initState();
    // Default to auto-selecting 2nd and subsequent duplicate copies for deletion
    for (final group in widget.duplicates) {
      for (int i = 1; i < group.candidateFiles.length; i++) {
        _pathsToDelete.add(group.candidateFiles[i].path);
      }
    }
  }

  int get _calculatedFreedBytes {
    int total = 0;
    for (final path in _pathsToDelete) {
      try {
        final f = File(path);
        if (f.existsSync()) total += f.lengthSync();
      } catch (_) {}
    }
    return total;
  }

  @override
  Widget build(BuildContext context) {
    final freedMb = (_calculatedFreedBytes / (1024 * 1024)).toStringAsFixed(1);

    return Container(
      height: MediaQuery.of(context).size.height * 0.85,
      decoration: BoxDecoration(
        color: AppColors.background,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(28)),
        border: Border.all(color: AppColors.glassBorder, width: 1),
      ),
      child: Column(
        children: [
          // Handle & Header
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 12, 20, 16),
            child: Column(
              children: [
                Container(
                  width: 40,
                  height: 4,
                  decoration: BoxDecoration(
                    color: AppColors.textTertiary.withValues(alpha: 0.3),
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
                const SizedBox(height: 12),
                Row(
                  children: [
                    Container(
                      padding: const EdgeInsets.all(10),
                      decoration: BoxDecoration(
                        color: Colors.amber.withValues(alpha: 0.15),
                        shape: BoxShape.circle,
                      ),
                      child: const Icon(
                        Icons.copy_rounded,
                        color: Colors.amberAccent,
                        size: 20,
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Text(
                            'Duplicate Audio Cleaner',
                            style: TextStyle(
                              color: Colors.white,
                              fontSize: 18,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                          Text(
                            'Found ${widget.duplicates.length} duplicate set(s) • $freedMb MB clearable',
                            style: const TextStyle(
                              color: AppColors.textTertiary,
                              fontSize: 12,
                            ),
                          ),
                        ],
                      ),
                    ),
                    IconButton(
                      icon: const Icon(
                        Icons.close_rounded,
                        color: AppColors.textSecondary,
                      ),
                      onPressed: () => Navigator.pop(context),
                    ),
                  ],
                ),
              ],
            ),
          ),

          const Divider(height: 1, color: AppColors.divider),

          // Duplicate Groups List
          Expanded(
            child: ListView.builder(
              padding: const EdgeInsets.all(16),
              itemCount: widget.duplicates.length,
              itemBuilder: (context, idx) {
                final group = widget.duplicates[idx];
                return Container(
                  margin: const EdgeInsets.only(bottom: 16),
                  padding: const EdgeInsets.all(14),
                  decoration: BoxDecoration(
                    color: AppColors.surfaceVariant.withValues(alpha: 0.4),
                    borderRadius: BorderRadius.circular(16),
                    border: Border.all(
                      color: AppColors.glassBorder.withValues(alpha: 0.3),
                    ),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Expanded(
                            child: Text(
                              group.songTitle,
                              style: const TextStyle(
                                color: Colors.white,
                                fontSize: 14,
                                fontWeight: FontWeight.bold,
                              ),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                          Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 8,
                              vertical: 3,
                            ),
                            decoration: BoxDecoration(
                              color: Colors.amber.withValues(alpha: 0.15),
                              borderRadius: BorderRadius.circular(6),
                            ),
                            child: Text(
                              '${group.candidateFiles.length} Copies',
                              style: const TextStyle(
                                color: Colors.amberAccent,
                                fontSize: 10,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 10),
                      ...group.candidateFiles.asMap().entries.map((entry) {
                        final fileIdx = entry.key;
                        final file = entry.value;
                        final isKept = fileIdx == 0;
                        final isSelectedForDelete = _pathsToDelete.contains(
                          file.path,
                        );

                        final sizeMb =
                            (file.existsSync()
                                    ? file.lengthSync() / (1024 * 1024)
                                    : 0.0)
                                .toStringAsFixed(1);

                        return Container(
                          margin: const EdgeInsets.only(bottom: 6),
                          padding: const EdgeInsets.symmetric(
                            horizontal: 10,
                            vertical: 8,
                          ),
                          decoration: BoxDecoration(
                            color: isKept
                                ? const Color(
                                    0xFF00E676,
                                  ).withValues(alpha: 0.08)
                                : AppColors.surface.withValues(alpha: 0.5),
                            borderRadius: BorderRadius.circular(10),
                            border: Border.all(
                              color: isKept
                                  ? const Color(
                                      0xFF00E676,
                                    ).withValues(alpha: 0.3)
                                  : AppColors.glassBorder.withValues(
                                      alpha: 0.2,
                                    ),
                            ),
                          ),
                          child: Row(
                            children: [
                              if (isKept)
                                const Icon(
                                  Icons.check_circle_rounded,
                                  color: Color(0xFF00E676),
                                  size: 16,
                                )
                              else
                                Checkbox(
                                  value: isSelectedForDelete,
                                  activeColor: Colors.redAccent,
                                  onChanged: (val) {
                                    setState(() {
                                      if (val == true) {
                                        _pathsToDelete.add(file.path);
                                      } else {
                                        _pathsToDelete.remove(file.path);
                                      }
                                    });
                                  },
                                ),
                              const SizedBox(width: 8),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      isKept
                                          ? '✓ Preferred Original ($sizeMb MB)'
                                          : 'Duplicate Copy ($sizeMb MB)',
                                      style: TextStyle(
                                        color: isKept
                                            ? const Color(0xFF00E676)
                                            : Colors.white,
                                        fontSize: 11,
                                        fontWeight: FontWeight.bold,
                                      ),
                                    ),
                                    Text(
                                      file.path,
                                      style: const TextStyle(
                                        color: AppColors.textTertiary,
                                        fontSize: 9.5,
                                      ),
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                  ],
                                ),
                              ),
                            ],
                          ),
                        );
                      }),
                    ],
                  ),
                );
              },
            ),
          ),

          // Actions
          Padding(
            padding: const EdgeInsets.all(16),
            child: SizedBox(
              width: double.infinity,
              child: ElevatedButton.icon(
                onPressed: _pathsToDelete.isEmpty || _isCleaning
                    ? null
                    : () async {
                        setState(() => _isCleaning = true);
                        final freed = await DownloadService()
                            .deleteSelectedDuplicateFiles(
                              _pathsToDelete.toList(),
                            );
                        final freedStr = StorageAnalyzer.formatBytes(freed);
                        if (!context.mounted) return;
                        widget.onCleaned();
                        AppToast.show(
                          context,
                          'Freed $freedStr by cleaning duplicate files!',
                          type: ToastType.success,
                        );
                        Navigator.pop(context);
                      },
                icon: _isCleaning
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: Colors.white,
                        ),
                      )
                    : const Icon(Icons.delete_sweep_rounded, size: 18),
                label: Text(
                  _isCleaning
                      ? 'Cleaning Duplicates...'
                      : 'Clean ${_pathsToDelete.length} Duplicate File(s) ($freedMb MB)',
                  style: const TextStyle(fontWeight: FontWeight.bold),
                ),
                style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.redAccent,
                  foregroundColor: Colors.white,
                  padding: const EdgeInsets.symmetric(vertical: 14),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(14),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
