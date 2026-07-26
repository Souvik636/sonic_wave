import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../providers/home_provider.dart';
import '../providers/player_provider.dart';
import '../services/download_service.dart';
import '../theme/app_colors.dart';
import 'download_widgets.dart';
import 'premium_interaction.dart';

/// THE downloads screen — every download function in one place, styled to the
/// app's premium language. Lives under Storage ▸ Downloads (the Discover copy
/// was removed; see .brain D-007). Composes the per-item widgets from
/// download_widgets.dart: DownloadProgressCard, QueuedDownloadTile,
/// FailedDownloadTile, DownloadedSongTile.
class DownloadsHub extends StatelessWidget {
  const DownloadsHub({super.key});

  @override
  Widget build(BuildContext context) {
    return Consumer2<PlayerProvider, HomeProvider>(
      builder: (context, playerProvider, homeProvider, _) {
        final downloaded = playerProvider.downloadedSongs;
        final activeItems = playerProvider.activeDownloadItems;
        final isOffline = homeProvider.isOffline;

        final downloadingItems = activeItems
            .where((i) =>
                i.status == DownloadStatus.downloading ||
                i.status == DownloadStatus.retrying)
            .toList();
        final pausedItems =
            activeItems.where((i) => i.status == DownloadStatus.paused).toList();
        final queuedItems =
            activeItems.where((i) => i.status == DownloadStatus.queued).toList();
        final failedItems =
            activeItems.where((i) => i.status == DownloadStatus.failed).toList();
        final hasActiveDownloads = activeItems.isNotEmpty;
        final activeCount = downloadingItems.length + pausedItems.length;

        return CustomScrollView(
          physics: const BouncingScrollPhysics(),
          slivers: [
            // Glass stats header with storage meter + bulk actions
            SliverToBoxAdapter(
              child: _StatsHeader(
                provider: playerProvider,
                isOffline: isOffline,
                downloadCount: downloaded.length,
                hasActive: hasActiveDownloads,
                hasDownloaded: downloaded.isNotEmpty,
              ),
            ),

            if (isOffline && hasActiveDownloads)
              const SliverToBoxAdapter(child: _OfflineBanner()),

            // 1. Downloading + paused
            if (activeCount > 0) ...[
              SliverToBoxAdapter(
                child: _SectionHeader(
                  icon: Icons.bolt_rounded,
                  title: 'Active Downloads',
                  count: '$activeCount',
                ),
              ),
              SliverList(
                delegate: SliverChildBuilderDelegate(
                  (context, index) {
                    final item = index < downloadingItems.length
                        ? downloadingItems[index]
                        : pausedItems[index - downloadingItems.length];
                    return StaggeredReveal(
                      key: ValueKey('dl_${item.song.videoId}'),
                      index: index,
                      child: DownloadProgressCard(
                        item: item,
                        playerProvider: playerProvider,
                      ),
                    );
                  },
                  childCount: activeCount,
                ),
              ),
            ],

            // 2. Queued
            if (queuedItems.isNotEmpty) ...[
              SliverToBoxAdapter(
                child: _SectionHeader(
                  icon: Icons.hourglass_top_rounded,
                  title: 'Queued',
                  count: '${queuedItems.length}',
                ),
              ),
              SliverList(
                delegate: SliverChildBuilderDelegate(
                  (context, index) {
                    final item = queuedItems[index];
                    return StaggeredReveal(
                      key: ValueKey('q_${item.song.videoId}'),
                      index: index,
                      child: QueuedDownloadTile(
                        item: item,
                        index: index,
                        playerProvider: playerProvider,
                      ),
                    );
                  },
                  childCount: queuedItems.length,
                ),
              ),
            ],

            // 3. Failed
            if (failedItems.isNotEmpty) ...[
              SliverToBoxAdapter(
                child: _SectionHeader(
                  icon: Icons.error_outline_rounded,
                  title: 'Failed',
                  count: '${failedItems.length}',
                ),
              ),
              SliverList(
                delegate: SliverChildBuilderDelegate(
                  (context, index) {
                    final item = failedItems[index];
                    return StaggeredReveal(
                      key: ValueKey('f_${item.song.videoId}'),
                      index: index,
                      child: FailedDownloadTile(
                        item: item,
                        playerProvider: playerProvider,
                      ),
                    );
                  },
                  childCount: failedItems.length,
                ),
              ),
            ],

            // 4. Downloaded library
            if (downloaded.isEmpty && !hasActiveDownloads)
              const SliverFillRemaining(
                hasScrollBody: false,
                child: GlowEmptyState(
                  icon: Icons.download_for_offline_rounded,
                  title: 'No Offline Downloads',
                  subtitle: 'Download songs to listen without internet',
                ),
              )
            else if (downloaded.isNotEmpty) ...[
              SliverToBoxAdapter(
                child: _SectionHeader(
                  icon: Icons.library_music_rounded,
                  title: 'Downloaded Songs',
                  count: '${downloaded.length}',
                ),
              ),
              SliverList(
                delegate: SliverChildBuilderDelegate(
                  (context, index) {
                    return StaggeredReveal(
                      key: ValueKey('d_${downloaded[index].videoId}'),
                      index: index,
                      child: DownloadedSongTile(
                        song: downloaded[index],
                        index: index,
                        playerProvider: playerProvider,
                        allDownloaded: downloaded,
                      ),
                    );
                  },
                  childCount: downloaded.length,
                ),
              ),
            ],
            const SliverToBoxAdapter(child: SizedBox(height: 140)),
          ],
        );
      },
    );
  }
}

/// Frosted-glass header: connection pill (breathing status dot), song-count +
/// storage chips, an animated accent-gradient storage meter, and the bulk
/// Cancel All / Delete All actions as premium chips.
class _StatsHeader extends StatelessWidget {
  final PlayerProvider provider;
  final bool isOffline;
  final int downloadCount;
  final bool hasActive;
  final bool hasDownloaded;

  const _StatsHeader({
    required this.provider,
    required this.isOffline,
    required this.downloadCount,
    required this.hasActive,
    required this.hasDownloaded,
  });

  @override
  Widget build(BuildContext context) {
    final accent = Theme.of(context).colorScheme.primary;
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 12, 20, 4),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(20),
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: 14, sigmaY: 14),
          child: Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: AppColors.surfaceVariant.withValues(alpha: 0.35),
              borderRadius: BorderRadius.circular(20),
              border: Border.all(
                color: accent.withValues(alpha: 0.18),
                width: 1,
              ),
              boxShadow: [
                BoxShadow(
                  color: accent.withValues(alpha: 0.08),
                  blurRadius: 24,
                  offset: const Offset(0, 8),
                ),
              ],
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    _ConnectionPill(isOffline: isOffline),
                    const SizedBox(width: 8),
                    _InfoChip(
                      icon: Icons.download_done_rounded,
                      label: '$downloadCount songs',
                    ),
                    const Spacer(),
                    _InfoChip(
                      icon: Icons.storage_rounded,
                      label: provider.formattedStorageUsed,
                    ),
                  ],
                ),
                const SizedBox(height: 14),
                _StorageMeter(provider: provider),
                if (hasActive || hasDownloaded) ...[
                  const SizedBox(height: 14),
                  Row(
                    children: [
                      if (hasActive)
                        _ActionChip(
                          icon: Icons.cancel_rounded,
                          label: 'Cancel All',
                          onTap: () => _confirm(
                            context,
                            title: 'Cancel All Downloads?',
                            message:
                                'This will cancel all active and queued downloads. This action cannot be undone.',
                            confirmLabel: 'Cancel All',
                            onConfirm: provider.cancelAllDownloads,
                          ),
                        ),
                      if (hasActive && hasDownloaded) const SizedBox(width: 10),
                      if (hasDownloaded)
                        _ActionChip(
                          icon: Icons.delete_sweep_rounded,
                          label: 'Delete All',
                          onTap: () => _confirm(
                            context,
                            title: 'Delete All Downloads?',
                            message:
                                'All downloaded songs will be permanently removed from your device.',
                            confirmLabel: 'Delete All',
                            onConfirm: provider.deleteAllDownloads,
                          ),
                        ),
                    ],
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }

  void _confirm(
    BuildContext context, {
    required String title,
    required String message,
    required String confirmLabel,
    required VoidCallback onConfirm,
  }) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppColors.surface,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: Text(title, style: const TextStyle(color: Colors.white)),
        content: Text(
          message,
          style: const TextStyle(color: AppColors.textSecondary, fontSize: 14),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Keep'),
          ),
          TextButton(
            onPressed: () {
              AppHaptics.medium();
              onConfirm();
              Navigator.pop(ctx);
            },
            child: Text(confirmLabel,
                style: const TextStyle(color: Colors.redAccent)),
          ),
        ],
      ),
    );
  }
}

/// Online/offline pill whose status dot breathes while online and whose colors
/// crossfade on connectivity changes.
class _ConnectionPill extends StatefulWidget {
  final bool isOffline;

  const _ConnectionPill({required this.isOffline});

  @override
  State<_ConnectionPill> createState() => _ConnectionPillState();
}

class _ConnectionPillState extends State<_ConnectionPill>
    with SingleTickerProviderStateMixin {
  late final AnimationController _pulse;

  @override
  void initState() {
    super.initState();
    _pulse = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1600),
    )..repeat(reverse: true);
  }

  @override
  void dispose() {
    _pulse.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final color = widget.isOffline ? Colors.redAccent : AppColors.success;
    return AnimatedContainer(
      duration: const Duration(milliseconds: 400),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.13),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: color.withValues(alpha: 0.3), width: 0.5),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          AnimatedBuilder(
            animation: _pulse,
            builder: (context, _) {
              final glow = widget.isOffline ? 0.0 : _pulse.value;
              return Container(
                width: 6,
                height: 6,
                decoration: BoxDecoration(
                  color: color,
                  shape: BoxShape.circle,
                  boxShadow: [
                    BoxShadow(
                      color: color.withValues(alpha: 0.5 * glow),
                      blurRadius: 6,
                      spreadRadius: 2 * glow,
                    ),
                  ],
                ),
              );
            },
          ),
          const SizedBox(width: 6),
          Text(
            widget.isOffline ? 'Offline' : 'Online',
            style: TextStyle(
              color: color,
              fontSize: 11,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }
}

class _InfoChip extends StatelessWidget {
  final IconData icon;
  final String label;

  const _InfoChip({required this.icon, required this.label});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: AppColors.surfaceVariant.withValues(alpha: 0.5),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 14, color: AppColors.textTertiary),
          const SizedBox(width: 5),
          Text(
            label,
            style: const TextStyle(
              color: AppColors.textTertiary,
              fontSize: 11,
              fontWeight: FontWeight.w500,
            ),
          ),
        ],
      ),
    );
  }
}

/// Storage usage meter: label row + accent-gradient bar that eases to its
/// value with a soft glow.
class _StorageMeter extends StatelessWidget {
  final PlayerProvider provider;

  const _StorageMeter({required this.provider});

  static const _limitBytes = 500 * 1024 * 1024;

  @override
  Widget build(BuildContext context) {
    final accent = Theme.of(context).colorScheme.primary;
    final target = provider.storageUsedBytes > 0
        ? (provider.storageUsedBytes / _limitBytes).clamp(0.0, 1.0)
        : 0.0;
    return TweenAnimationBuilder<double>(
      tween: Tween<double>(begin: 0.0, end: target),
      duration: const Duration(milliseconds: 1000),
      curve: Curves.easeOutCubic,
      builder: (context, value, child) {
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                const Text(
                  'STORAGE SPACE',
                  style: TextStyle(
                    color: AppColors.textTertiary,
                    fontSize: 9,
                    fontWeight: FontWeight.bold,
                    letterSpacing: 0.5,
                  ),
                ),
                Text(
                  '${provider.formattedStorageUsed} / 500.0 MB limit',
                  style: const TextStyle(
                    color: AppColors.textTertiary,
                    fontSize: 9,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 6),
            ClipRRect(
              borderRadius: BorderRadius.circular(4),
              child: Stack(
                children: [
                  Container(height: 6, color: AppColors.surfaceVariant),
                  FractionallySizedBox(
                    widthFactor: value == 0 ? 0.001 : value,
                    child: Container(
                      height: 6,
                      decoration: BoxDecoration(
                        gradient: LinearGradient(
                          colors: [accent, AppColors.secondary],
                        ),
                        boxShadow: [
                          BoxShadow(
                            color: accent.withValues(alpha: 0.4),
                            blurRadius: 6,
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        );
      },
    );
  }
}

/// Bulk-action chip (Cancel All / Delete All) with press-scale + haptic.
class _ActionChip extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback onTap;

  const _ActionChip({
    required this.icon,
    required this.label,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return PremiumTap(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
        decoration: BoxDecoration(
          color: Colors.redAccent.withValues(alpha: 0.10),
          borderRadius: BorderRadius.circular(20),
          border: Border.all(
            color: Colors.redAccent.withValues(alpha: 0.3),
            width: 0.7,
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 15, color: Colors.redAccent),
            const SizedBox(width: 6),
            Text(
              label,
              style: const TextStyle(
                color: Colors.redAccent,
                fontSize: 12,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _OfflineBanner extends StatelessWidget {
  const _OfflineBanner();

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 10, 20, 0),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 300),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        decoration: BoxDecoration(
          color: Colors.amber.withValues(alpha: 0.1),
          borderRadius: BorderRadius.circular(12),
          border:
              Border.all(color: Colors.amber.withValues(alpha: 0.3), width: 0.5),
        ),
        child: const Row(
          children: [
            Icon(Icons.wifi_off_rounded, color: Colors.amber, size: 18),
            SizedBox(width: 10),
            Expanded(
              child: Text(
                'You\'re offline — Active downloads are paused',
                style: TextStyle(
                  color: Colors.amber,
                  fontSize: 12,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Section header: accent-glow icon badge + title + count pill.
class _SectionHeader extends StatelessWidget {
  final IconData icon;
  final String title;
  final String count;

  const _SectionHeader({
    required this.icon,
    required this.title,
    required this.count,
  });

  @override
  Widget build(BuildContext context) {
    final accent = Theme.of(context).colorScheme.primary;
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 22, 20, 8),
      child: Row(
        children: [
          Container(
            width: 28,
            height: 28,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: accent.withValues(alpha: 0.12),
              border: Border.all(color: accent.withValues(alpha: 0.3)),
            ),
            child: Icon(icon, size: 15, color: accent),
          ),
          const SizedBox(width: 10),
          Text(title, style: Theme.of(context).textTheme.headlineMedium),
          const SizedBox(width: 10),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
            decoration: BoxDecoration(
              color: accent.withValues(alpha: 0.15),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Text(
              count,
              style: TextStyle(
                color: accent,
                fontSize: 11,
                fontWeight: FontWeight.bold,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
