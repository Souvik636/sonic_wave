import 'package:flutter/material.dart';
import 'package:shimmer/shimmer.dart';
import '../theme/app_colors.dart';

class ShimmerSongTile extends StatelessWidget {
  /// Position in the skeleton list — used to vary the placeholder bar widths
  /// deterministically so the skeleton reads as organic content, not a grid
  /// of identical blocks.
  final int index;

  const ShimmerSongTile({super.key, this.index = 0});

  @override
  Widget build(BuildContext context) {
    final accent = Theme.of(context).colorScheme.primary;
    // Deterministic per-row variation (no Random — same rule as the app's
    // visualizers): title 55–95% width, artist 80–140px.
    final titleFactor = 0.55 + 0.40 * (((index * 7) % 5) / 4);
    final artistWidth = 80.0 + 15.0 * ((index * 3) % 5);

    return Shimmer.fromColors(
      baseColor: AppColors.shimmerBase,
      // A whisper of the theme accent in the sweep keeps even the skeleton
      // on-theme.
      highlightColor:
          Color.lerp(AppColors.shimmerHighlight, accent, 0.18)!,
      period: const Duration(milliseconds: 1400),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
        child: Row(
          children: [
            // Thumbnail placeholder
            Container(
              width: 56,
              height: 56,
              decoration: BoxDecoration(
                color: AppColors.shimmerBase,
                borderRadius: BorderRadius.circular(12),
              ),
            ),
            const SizedBox(width: 14),
            // Text placeholders
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  FractionallySizedBox(
                    alignment: Alignment.centerLeft,
                    widthFactor: titleFactor,
                    child: Container(
                      height: 14,
                      decoration: BoxDecoration(
                        color: AppColors.shimmerBase,
                        borderRadius: BorderRadius.circular(4),
                      ),
                    ),
                  ),
                  const SizedBox(height: 8),
                  Container(
                    width: artistWidth,
                    height: 12,
                    decoration: BoxDecoration(
                      color: AppColors.shimmerBase,
                      borderRadius: BorderRadius.circular(4),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 14),
            // Duration placeholder
            Container(
              width: 36,
              height: 12,
              decoration: BoxDecoration(
                color: AppColors.shimmerBase,
                borderRadius: BorderRadius.circular(4),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class ShimmerCard extends StatelessWidget {
  final double width;
  final double height;

  const ShimmerCard({
    super.key,
    this.width = 160,
    this.height = 200,
  });

  @override
  Widget build(BuildContext context) {
    return Shimmer.fromColors(
      baseColor: AppColors.shimmerBase,
      highlightColor: AppColors.shimmerHighlight,
      child: Container(
        width: width,
        height: height,
        margin: const EdgeInsets.only(right: 14),
        decoration: BoxDecoration(
          color: AppColors.shimmerBase,
          borderRadius: BorderRadius.circular(16),
        ),
      ),
    );
  }
}

/// Skeleton list shown while songs load. A ListView (not a Column) so a tall
/// skeleton can never overflow the bottom of a small screen — extra rows just
/// clip/scroll like real content would. Each row cascades in with a short
/// fade+rise so the skeleton itself feels alive.
class ShimmerLoadingList extends StatelessWidget {
  final int itemCount;

  const ShimmerLoadingList({super.key, this.itemCount = 8});

  @override
  Widget build(BuildContext context) {
    return ListView.builder(
      physics: const NeverScrollableScrollPhysics(),
      padding: const EdgeInsets.symmetric(vertical: 4),
      itemCount: itemCount,
      itemBuilder: (context, index) => _SkeletonReveal(
        index: index,
        child: ShimmerSongTile(index: index),
      ),
    );
  }
}

/// Lightweight staggered fade+rise for skeleton rows (self-contained so
/// shimmer_loading has no dependency on the interaction layer).
class _SkeletonReveal extends StatelessWidget {
  final int index;
  final Widget child;

  const _SkeletonReveal({required this.index, required this.child});

  @override
  Widget build(BuildContext context) {
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0.0, end: 1.0),
      duration: Duration(milliseconds: 260 + 40 * index.clamp(0, 10)),
      curve: Curves.easeOutCubic,
      builder: (context, t, child) => Opacity(
        opacity: t,
        child: Transform.translate(
          offset: Offset(0, 10 * (1 - t)),
          child: child,
        ),
      ),
      child: child,
    );
  }
}

class ShimmerHorizontalList extends StatelessWidget {
  final int itemCount;
  final double cardWidth;
  final double cardHeight;

  const ShimmerHorizontalList({
    super.key,
    this.itemCount = 5,
    this.cardWidth = 160,
    this.cardHeight = 200,
  });

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: cardHeight,
      child: ListView.builder(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 20),
        itemCount: itemCount,
        itemBuilder: (context, index) => ShimmerCard(
          width: cardWidth,
          height: cardHeight,
        ),
      ),
    );
  }
}
