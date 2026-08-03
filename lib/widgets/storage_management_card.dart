import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../providers/player_provider.dart';
import '../services/storage_analyzer.dart';
import '../theme/app_colors.dart';
import '../widgets/glassmorphic_card.dart';

/// Premium Storage & Cache management card with animated donut chart,
/// per-category size labels, and individual + bulk clear actions.
class StorageManagementCard extends StatefulWidget {
  const StorageManagementCard({super.key});

  @override
  State<StorageManagementCard> createState() => _StorageManagementCardState();
}

class _StorageManagementCardState extends State<StorageManagementCard>
    with SingleTickerProviderStateMixin {
  StorageBreakdown? _breakdown;
  bool _loading = true;
  String? _clearingCategory; // null = idle, 'all' | 'stream' | 'image' | 'cover' | 'history'

  late final AnimationController _ringController;
  late final Animation<double> _ringAnimation;

  // Category colors
  static const _colDownloads = Color(0xFF6C63FF); // primary purple
  static const _colStream = Color(0xFF00C9A7);    // teal
  static const _colImages = Color(0xFFFF6584);     // accent pink
  static const _colCover = Color(0xFFFFB74D);      // amber
  static const _colMeta = Color(0xFF78909C);       // blue grey
  static const _colAlbums = Color(0xFF448AFF);     // blue

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
          await StorageAnalyzer.instance.clearAllCaches();
          if (mounted) {
            await context.read<PlayerProvider>().clearHistory();
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
                      'Storage Usage',
                      style: Theme.of(context).textTheme.titleLarge?.copyWith(fontSize: 16),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      _loading
                          ? 'Scanning...'
                          : 'Total: ${StorageAnalyzer.formatBytes(_breakdown?.total ?? 0)}',
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
                tooltip: 'Refresh',
                visualDensity: VisualDensity.compact,
              ),
            ],
          ),

          const SizedBox(height: 20),

          // ── Donut Chart ───────────────────────────────────────────
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

          const SizedBox(height: 16),
          const Divider(height: 1, color: AppColors.divider),
          const SizedBox(height: 16),

          // ── Category List ─────────────────────────────────────────
          if (!_loading) ...[
            _buildCategoryRow(
              icon: Icons.music_note_rounded,
              label: 'Downloaded Songs',
              size: _breakdown!.downloadedSongs,
              color: _colDownloads,
              clearable: false,
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
              label: 'Cover Art',
              size: _breakdown!.coverArt,
              color: _colCover,
              clearable: true,
              categoryKey: 'cover',
            ),
            _buildCategoryRow(
              icon: Icons.history_rounded,
              label: 'Playback History',
              size: _breakdown!.metadata,
              color: _colMeta,
              clearable: true,
              categoryKey: 'history',
            ),

            const SizedBox(height: 16),
            const Divider(height: 1, color: AppColors.divider),
            const SizedBox(height: 16),

            // ── Clear All ──────────────────────────────────────────
            _buildClearAllButton(),
          ],
        ],
      ),
    );
  }

  // ── Donut chart + legend ──────────────────────────────────────────────

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
            'No storage used',
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
              width: 100,
              height: 100,
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
                        'Total',
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
              final pct = total > 0 ? (s.value / total * 100).toStringAsFixed(0) : '0';
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
                  const SizedBox(width: 4),
                  Text(
                    '${s.label} $pct%',
                    style: const TextStyle(
                      color: AppColors.textSecondary,
                      fontSize: 10,
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

  // ── Category Row ──────────────────────────────────────────────────────

  Widget _buildCategoryRow({
    required IconData icon,
    required String label,
    required int size,
    required Color color,
    required bool clearable,
    String? categoryKey,
  }) {
    final isClearing = _clearingCategory == categoryKey;
    final total = _breakdown?.total ?? 1;
    final fraction = total > 0 ? (size / total).clamp(0.0, 1.0) : 0.0;

    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Column(
        children: [
          Row(
            children: [
              Icon(icon, color: color, size: 18),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  label,
                  style: const TextStyle(
                    color: AppColors.textPrimary,
                    fontSize: 13,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ),
              AnimatedSwitcher(
                duration: const Duration(milliseconds: 300),
                child: Text(
                  isClearing ? 'Clearing...' : StorageAnalyzer.formatBytes(size),
                  key: ValueKey('$categoryKey-$size-$isClearing'),
                  style: TextStyle(
                    color: isClearing ? color : AppColors.textTertiary,
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              if (clearable) ...[
                const SizedBox(width: 8),
                SizedBox(
                  height: 28,
                  child: TextButton(
                    onPressed: (isClearing || _clearingCategory != null || size == 0)
                        ? null
                        : () => _clearCategory(categoryKey!),
                    style: TextButton.styleFrom(
                      padding: const EdgeInsets.symmetric(horizontal: 10),
                      minimumSize: Size.zero,
                      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(8),
                        side: BorderSide(
                          color: size > 0 ? color.withValues(alpha: 0.4) : AppColors.divider,
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
              ],
            ],
          ),
          const SizedBox(height: 6),
          // Animated progress bar
          ClipRRect(
            borderRadius: BorderRadius.circular(2),
            child: AnimatedBuilder(
              animation: _ringAnimation,
              builder: (context, _) {
                return LinearProgressIndicator(
                  value: fraction * _ringAnimation.value,
                  minHeight: 3,
                  backgroundColor: AppColors.surfaceVariant.withValues(alpha: 0.3),
                  valueColor: AlwaysStoppedAnimation(color.withValues(alpha: 0.7)),
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  // ── Clear All Button ──────────────────────────────────────────────────

  Widget _buildClearAllButton() {
    final clearable = _breakdown?.clearable ?? 0;
    final isClearing = _clearingCategory == 'all';

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
                        borderRadius: BorderRadius.circular(20)),
                    title: const Text('Clear All Caches?',
                        style: TextStyle(color: Colors.white)),
                    content: Text(
                      'This will free ${StorageAnalyzer.formatBytes(clearable)} by clearing:\n'
                      '• Stream cache\n'
                      '• Image cache\n'
                      '• Cover art cache\n'
                      '• Playback history\n\n'
                      'Downloaded songs and albums will NOT be affected.',
                      style: const TextStyle(
                          color: AppColors.textSecondary, fontSize: 13),
                    ),
                    actions: [
                      TextButton(
                        onPressed: () => Navigator.pop(ctx),
                        child: const Text('Cancel',
                            style: TextStyle(color: AppColors.textSecondary)),
                      ),
                      TextButton(
                        onPressed: () {
                          Navigator.pop(ctx);
                          _clearCategory('all');
                        },
                        child: const Text('Clear All',
                            style: TextStyle(color: Colors.redAccent)),
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
                    strokeWidth: 2, color: Colors.redAccent),
              )
            : const Icon(Icons.delete_sweep_rounded, size: 18),
        label: Text(
          isClearing
              ? 'Clearing...'
              : 'Clear All Caches (${StorageAnalyzer.formatBytes(clearable)})',
        ),
        style: OutlinedButton.styleFrom(
          foregroundColor: clearable > 0 ? Colors.redAccent : AppColors.textTertiary,
          side: BorderSide(
            color: clearable > 0
                ? Colors.redAccent.withValues(alpha: 0.4)
                : AppColors.divider,
          ),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
          padding: const EdgeInsets.symmetric(vertical: 12),
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
    const gapRadians = 0.04; // small gap between segments

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
      final sweepAngle = (total > 0 ? seg.value / total : 0.0) * available * progress;
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
  bool shouldRepaint(_DonutPainter old) =>
      progress != old.progress || total != old.total;
}
