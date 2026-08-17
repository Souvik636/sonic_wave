import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:cached_network_image/cached_network_image.dart';
import '../models/song.dart';
import '../providers/player_provider.dart';
import '../theme/app_colors.dart';
import '../services/download_service.dart';
import 'song_tile.dart';

// ─── DOWNLOAD PROGRESS CARD ─────────────────────────────────────────────────

class DownloadProgressCard extends StatefulWidget {
  final DownloadItem item;
  final PlayerProvider playerProvider;

  const DownloadProgressCard({
    super.key,
    required this.item,
    required this.playerProvider,
  });

  @override
  State<DownloadProgressCard> createState() => DownloadProgressCardState();
}

class DownloadProgressCardState extends State<DownloadProgressCard>
    with SingleTickerProviderStateMixin {
  late AnimationController _pulseController;
  late Animation<double> _pulseAnimation;

  @override
  void initState() {
    super.initState();
    _pulseController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1500),
    );
    _pulseAnimation = Tween<double>(begin: 0.85, end: 1.0).animate(
      CurvedAnimation(parent: _pulseController, curve: Curves.easeInOut),
    );
    if (widget.item.status == DownloadStatus.downloading) {
      _pulseController.repeat(reverse: true);
    }
  }

  @override
  void didUpdateWidget(DownloadProgressCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.item.status == DownloadStatus.downloading &&
        !_pulseController.isAnimating) {
      _pulseController.repeat(reverse: true);
    } else if (widget.item.status != DownloadStatus.downloading &&
        _pulseController.isAnimating) {
      _pulseController.stop();
      _pulseController.value = 1.0;
    }
  }

  @override
  void dispose() {
    _pulseController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final item = widget.item;
    final isPaused = item.status == DownloadStatus.paused;
    final isRetrying = item.status == DownloadStatus.retrying;
    final primaryColor = Theme.of(context).colorScheme.primary;

    final statusColor = isPaused
        ? AppColors.downloadPaused
        : isRetrying
        ? AppColors.downloadRetrying
        : primaryColor;

    final statusText = isPaused
        ? 'Paused'
        : isRetrying
        ? 'Retrying (${item.retryCount}/3)...'
        : item.progress < 0.05
        ? 'Resolving stream...'
        : item.progress >= 0.90 && item.progress < 1.0
        ? 'Processing container & tags...'
        : 'Downloading (${(item.progress * 100).toInt()}%)...';

    return AnimatedContainer(
      duration: const Duration(milliseconds: 400),
      curve: Curves.easeOut,
      margin: const EdgeInsets.symmetric(horizontal: 20, vertical: 6),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: AppColors.surfaceVariant.withValues(alpha: 0.4),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: statusColor.withValues(alpha: 0.3),
          width: 0.8,
        ),
        boxShadow: [
          BoxShadow(
            color: statusColor.withValues(alpha: 0.08),
            blurRadius: 12,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: Column(
        children: [
          Row(
            children: [
              AnimatedBuilder(
                animation: _pulseAnimation,
                builder: (context, child) {
                  return Container(
                    width: 50,
                    height: 50,
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(
                        color: statusColor.withValues(
                          alpha: _pulseAnimation.value * 0.5,
                        ),
                        width: 2,
                      ),
                    ),
                    child: child,
                  );
                },
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(10),
                  child: item.song.thumbnailUrl.startsWith('http')
                      ? CachedNetworkImage(
                          imageUrl: item.song.thumbnailUrl,
                          fit: BoxFit.cover,
                          width: 46,
                          height: 46,
                          errorWidget: (context, url, error) => Container(
                            color: AppColors.surfaceVariant,
                            child: const Icon(
                              Icons.music_note_rounded,
                              color: AppColors.textTertiary,
                              size: 20,
                            ),
                          ),
                        )
                      : Container(
                          color: AppColors.surfaceVariant,
                          width: 46,
                          height: 46,
                          child: const Icon(
                            Icons.music_note_rounded,
                            color: AppColors.textTertiary,
                            size: 20,
                          ),
                        ),
                ),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      item.song.title,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: 3),
                    Text(
                      item.song.artist,
                      style: const TextStyle(
                        color: AppColors.textTertiary,
                        fontSize: 11,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  AnimatedControlButton(
                    icon: isPaused
                        ? Icons.play_arrow_rounded
                        : Icons.pause_rounded,
                    color: Colors.white,
                    bgColor: statusColor.withValues(alpha: 0.2),
                    size: 34,
                    onTap: () {
                      if (isPaused) {
                        widget.playerProvider.resumeDownload(item.song.videoId);
                      } else {
                        widget.playerProvider.pauseDownload(item.song.videoId);
                      }
                    },
                  ),
                  const SizedBox(width: 8),
                  AnimatedControlButton(
                    icon: Icons.close_rounded,
                    color: Colors.redAccent,
                    bgColor: Colors.redAccent.withValues(alpha: 0.12),
                    size: 34,
                    onTap: () =>
                        widget.playerProvider.cancelDownload(item.song.videoId),
                  ),
                ],
              ),
            ],
          ),
          const SizedBox(height: 12),
          GradientProgressBar(progress: item.progress, isPaused: isPaused),
          const SizedBox(height: 8),
          Row(
            children: [
              AnimatedSwitcher(
                duration: const Duration(milliseconds: 200),
                child: Container(
                  key: ValueKey(statusText),
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 3,
                  ),
                  decoration: BoxDecoration(
                    color: statusColor.withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Text(
                    statusText,
                    style: TextStyle(
                      color: statusColor,
                      fontSize: 10,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Wrap(
                  alignment: WrapAlignment.end,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  spacing: 12,
                  runSpacing: 4,
                  children: [
                    if (item.formattedSpeed.isNotEmpty && !isPaused)
                      Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            Icons.speed_rounded,
                            size: 12,
                            color: statusColor.withValues(alpha: 0.7),
                          ),
                          const SizedBox(width: 4),
                          Text(
                            item.formattedSpeed,
                            style: TextStyle(
                              color: statusColor,
                              fontSize: 10,
                              fontWeight: FontWeight.w500,
                            ),
                          ),
                        ],
                      ),
                    if (item.formattedSizeProgress.isNotEmpty)
                      Text(
                        item.formattedSizeProgress,
                        style: const TextStyle(
                          color: AppColors.textTertiary,
                          fontSize: 10,
                        ),
                      ),
                    if (item.formattedEta.isNotEmpty && !isPaused)
                      Text(
                        item.formattedEta,
                        style: const TextStyle(
                          color: AppColors.textTertiary,
                          fontSize: 10,
                        ),
                      ),
                    Text(
                      '${(item.progress * 100).toInt()}%',
                      style: TextStyle(
                        color: statusColor,
                        fontSize: 12,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

// ─── ANIMATED CONTROL BUTTON ────────────────────────────────────────────────

class AnimatedControlButton extends StatefulWidget {
  final IconData icon;
  final Color color;
  final Color bgColor;
  final double size;
  final VoidCallback onTap;

  const AnimatedControlButton({
    super.key,
    required this.icon,
    required this.color,
    required this.bgColor,
    required this.size,
    required this.onTap,
  });

  @override
  State<AnimatedControlButton> createState() => AnimatedControlButtonState();
}

class AnimatedControlButtonState extends State<AnimatedControlButton>
    with SingleTickerProviderStateMixin {
  late AnimationController _tapController;
  late Animation<double> _scaleAnimation;

  @override
  void initState() {
    super.initState();
    _tapController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 100),
    );
    _scaleAnimation = Tween<double>(
      begin: 1.0,
      end: 0.88,
    ).animate(CurvedAnimation(parent: _tapController, curve: Curves.easeInOut));
  }

  @override
  void dispose() {
    _tapController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTapDown: (_) => _tapController.forward(),
      onTapUp: (_) => _tapController.reverse(),
      onTapCancel: () => _tapController.reverse(),
      onTap: widget.onTap,
      child: ScaleTransition(
        scale: _scaleAnimation,
        child: Container(
          width: widget.size,
          height: widget.size,
          decoration: BoxDecoration(
            color: widget.bgColor,
            borderRadius: BorderRadius.circular(widget.size / 3),
          ),
          child: Icon(
            widget.icon,
            color: widget.color,
            size: widget.size * 0.5,
          ),
        ),
      ),
    );
  }
}

// ─── GRADIENT PROGRESS BAR ──────────────────────────────────────────────────

class GradientProgressBar extends StatefulWidget {
  final double progress;
  final bool isPaused;

  const GradientProgressBar({
    super.key,
    required this.progress,
    required this.isPaused,
  });

  @override
  State<GradientProgressBar> createState() => GradientProgressBarState();
}

class GradientProgressBarState extends State<GradientProgressBar>
    with SingleTickerProviderStateMixin {
  late AnimationController _shimmerController;

  @override
  void initState() {
    super.initState();
    _shimmerController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1500),
    );
    if (!widget.isPaused) {
      _shimmerController.repeat();
    }
  }

  @override
  void didUpdateWidget(GradientProgressBar oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.isPaused && _shimmerController.isAnimating) {
      _shimmerController.stop();
    } else if (!widget.isPaused && !_shimmerController.isAnimating) {
      _shimmerController.repeat();
    }
  }

  @override
  void dispose() {
    _shimmerController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final targetProgress = widget.progress.clamp(0.0, 1.0);
    return SizedBox(
      height: 6,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(3),
        child: Stack(
          children: [
            Container(
              decoration: BoxDecoration(
                color: Colors.white.withValues(alpha: 0.06),
                borderRadius: BorderRadius.circular(3),
              ),
            ),
            TweenAnimationBuilder<double>(
              tween: Tween<double>(begin: 0.0, end: targetProgress),
              duration: const Duration(milliseconds: 300),
              curve: Curves.easeOutCubic,
              builder: (context, animatedVal, child) {
                return FractionallySizedBox(
                  alignment: Alignment.centerLeft,
                  widthFactor: animatedVal.clamp(0.0, 1.0),
                  child: AnimatedBuilder(
                    animation: _shimmerController,
                    builder: (context, child) {
                      return Container(
                        decoration: BoxDecoration(
                          gradient: widget.isPaused
                              ? AppColors.downloadPausedGradient
                              : LinearGradient(
                                  colors: [
                                    Theme.of(context).colorScheme.primary,
                                    AppColors.secondary,
                                  ],
                                  begin: Alignment.centerLeft,
                                  end: Alignment.centerRight,
                                ),
                          borderRadius: BorderRadius.circular(3),
                        ),
                        foregroundDecoration: !widget.isPaused
                            ? BoxDecoration(
                                borderRadius: BorderRadius.circular(3),
                                gradient: LinearGradient(
                                  begin: Alignment(
                                    -1.0 + _shimmerController.value * 3,
                                    0,
                                  ),
                                  end: Alignment(
                                    -0.5 + _shimmerController.value * 3,
                                    0,
                                  ),
                                  colors: [
                                    Colors.transparent,
                                    Colors.white.withValues(alpha: 0.2),
                                    Colors.transparent,
                                  ],
                                ),
                              )
                            : null,
                      );
                    },
                  ),
                );
              },
            ),
          ],
        ),
      ),
    );
  }
}

// ─── PULSING ICON (Empty state) ─────────────────────────────────────────────

class PulsingIcon extends StatefulWidget {
  final IconData icon;
  final double size;
  final Color color;

  const PulsingIcon({
    super.key,
    required this.icon,
    required this.size,
    required this.color,
  });

  @override
  State<PulsingIcon> createState() => PulsingIconState();
}

class PulsingIconState extends State<PulsingIcon>
    with SingleTickerProviderStateMixin {
  late AnimationController _controller;
  late Animation<double> _scaleAnim;
  late Animation<double> _opacityAnim;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 2000),
    )..repeat(reverse: true);
    _scaleAnim = Tween<double>(
      begin: 0.92,
      end: 1.08,
    ).animate(CurvedAnimation(parent: _controller, curve: Curves.easeInOut));
    _opacityAnim = Tween<double>(
      begin: 0.25,
      end: 0.45,
    ).animate(CurvedAnimation(parent: _controller, curve: Curves.easeInOut));
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _controller,
      builder: (context, child) {
        return Transform.scale(
          scale: _scaleAnim.value,
          child: Icon(
            widget.icon,
            size: widget.size,
            color: widget.color.withValues(alpha: _opacityAnim.value),
          ),
        );
      },
    );
  }
}

// ─── DOWNLOADED SONG TILE (with swipe-to-delete) ────────────────────────────

class DownloadedSongTile extends StatefulWidget {
  final Song song;
  final int index;
  final PlayerProvider playerProvider;
  final List<Song> allDownloaded;

  const DownloadedSongTile({
    super.key,
    required this.song,
    required this.index,
    required this.playerProvider,
    required this.allDownloaded,
  });

  @override
  State<DownloadedSongTile> createState() => DownloadedSongTileState();
}

class DownloadedSongTileState extends State<DownloadedSongTile>
    with SingleTickerProviderStateMixin {
  late AnimationController _slideController;
  late Animation<Offset> _slideAnimation;
  DeleteType _deleteType = DeleteType.permanent;

  @override
  void initState() {
    super.initState();
    _slideController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 400),
    );
    final delay = math.min(widget.index * 0.08, 0.5);
    _slideAnimation =
        Tween<Offset>(begin: const Offset(0.15, 0), end: Offset.zero).animate(
          CurvedAnimation(
            parent: _slideController,
            curve: Interval(
              delay,
              math.min(delay + 0.5, 1.0),
              curve: Curves.easeOut,
            ),
          ),
        );
    _slideController.forward();
    _detectDeleteType();
  }

  Future<void> _detectDeleteType() async {
    final type = await widget.playerProvider.getDeleteType(widget.song);
    if (mounted) {
      setState(() {
        _deleteType = type;
      });
    }
  }

  @override
  void dispose() {
    _slideController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final isPermanent = _deleteType == DeleteType.permanent;
    final deleteColor = isPermanent ? Colors.redAccent : Colors.amber;
    final deleteLabel = isPermanent ? 'Delete Permanently' : 'Delete Memory';
    final deleteIcon = isPermanent
        ? Icons.delete_forever_rounded
        : Icons.link_off_rounded;

    return SlideTransition(
      position: _slideAnimation,
      child: FadeTransition(
        opacity: _slideController,
        child: Dismissible(
          key: ValueKey('dismiss_shared_${widget.song.videoId}'),
          direction: DismissDirection.endToStart,
          background: Container(
            margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
            decoration: BoxDecoration(
              color: deleteColor.withValues(alpha: 0.15),
              borderRadius: BorderRadius.circular(14),
            ),
            alignment: Alignment.centerRight,
            padding: const EdgeInsets.only(right: 24),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(deleteIcon, color: deleteColor, size: 24),
                const SizedBox(height: 4),
                Text(
                  deleteLabel,
                  style: TextStyle(
                    color: deleteColor.withValues(alpha: 0.8),
                    fontSize: 10,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
          ),
          confirmDismiss: (direction) async {
            return true;
          },
          onDismissed: (direction) {
            if (isPermanent) {
              widget.playerProvider.deleteSongPermanently(widget.song);
            } else {
              widget.playerProvider.deleteSongMemory(widget.song);
            }
            ScaffoldMessenger.of(context).clearSnackBars();
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: Row(
                  children: [
                    Icon(
                      isPermanent
                          ? Icons.delete_forever_rounded
                          : Icons.link_off_rounded,
                      color: deleteColor,
                      size: 16,
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        isPermanent
                            ? '"${widget.song.title}" permanently deleted'
                            : '"${widget.song.title}" removed from memory',
                        style: const TextStyle(color: Colors.white),
                      ),
                    ),
                  ],
                ),
                backgroundColor: AppColors.surface,
                behavior: SnackBarBehavior.floating,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
                duration: const Duration(seconds: 4),
                action: !isPermanent
                    ? SnackBarAction(
                        label: 'UNDO',
                        textColor: Theme.of(context).colorScheme.primary,
                        onPressed: () {
                          widget.playerProvider.undoDelete();
                        },
                      )
                    : null,
              ),
            );
          },
          child: SongTile(
            song: widget.song,
            index: widget.index,
            sourceTag: isPermanent ? 'downloaded' : 'local',
            onTap: () {
              widget.playerProvider.playPlaylist(
                widget.allDownloaded,
                startIndex: widget.index,
              );
            },
          ),
        ),
      ),
    );
  }
}

// ─── QUEUED DOWNLOAD TILE ───────────────────────────────────────────────────

class QueuedDownloadTile extends StatelessWidget {
  final DownloadItem item;
  final int index;
  final PlayerProvider playerProvider;

  const QueuedDownloadTile({
    super.key,
    required this.item,
    required this.index,
    required this.playerProvider,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 20, vertical: 4),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        color: AppColors.surfaceVariant.withValues(alpha: 0.3),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
          color: AppColors.downloadQueued.withValues(alpha: 0.2),
          width: 0.5,
        ),
      ),
      child: Row(
        children: [
          Container(
            width: 28,
            height: 28,
            decoration: BoxDecoration(
              color: AppColors.downloadQueued.withValues(alpha: 0.15),
              borderRadius: BorderRadius.circular(8),
            ),
            alignment: Alignment.center,
            child: Text(
              '${index + 1}',
              style: const TextStyle(
                color: AppColors.downloadQueued,
                fontSize: 12,
                fontWeight: FontWeight.bold,
              ),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  item.song.title,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 13,
                    fontWeight: FontWeight.w500,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                const SizedBox(height: 2),
                Text(
                  item.song.artist,
                  style: const TextStyle(
                    color: AppColors.textTertiary,
                    fontSize: 11,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
          ),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
            decoration: BoxDecoration(
              color: AppColors.downloadQueued.withValues(alpha: 0.1),
              borderRadius: BorderRadius.circular(8),
            ),
            child: const Text(
              'Waiting',
              style: TextStyle(
                color: AppColors.downloadQueued,
                fontSize: 10,
                fontWeight: FontWeight.w500,
              ),
            ),
          ),
          const SizedBox(width: 8),
          IconButton(
            icon: const Icon(
              Icons.close_rounded,
              color: AppColors.textTertiary,
              size: 18,
            ),
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(),
            onPressed: () => playerProvider.cancelDownload(item.song.videoId),
          ),
        ],
      ),
    );
  }
}

// ─── FAILED DOWNLOAD TILE ───────────────────────────────────────────────────

class FailedDownloadTile extends StatelessWidget {
  final DownloadItem item;
  final PlayerProvider playerProvider;

  const FailedDownloadTile({
    super.key,
    required this.item,
    required this.playerProvider,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 20, vertical: 4),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: AppColors.downloadFailed.withValues(alpha: 0.06),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
          color: AppColors.downloadFailed.withValues(alpha: 0.25),
          width: 0.5,
        ),
      ),
      child: Row(
        children: [
          const Icon(
            Icons.error_outline_rounded,
            color: AppColors.downloadFailed,
            size: 26,
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  item.song.title,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 13,
                    fontWeight: FontWeight.w500,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                const SizedBox(height: 3),
                Text(
                  'Failed after ${item.retryCount} attempt${item.retryCount > 1 ? 's' : ''}',
                  style: const TextStyle(
                    color: AppColors.downloadFailed,
                    fontSize: 10,
                  ),
                ),
              ],
            ),
          ),
          AnimatedControlButton(
            icon: Icons.refresh_rounded,
            color: AppColors.downloadFailed,
            bgColor: AppColors.downloadFailed.withValues(alpha: 0.12),
            size: 34,
            onTap: () => playerProvider.retryDownload(item.song),
          ),
          const SizedBox(width: 6),
          AnimatedControlButton(
            icon: Icons.close_rounded,
            color: AppColors.textTertiary,
            bgColor: AppColors.surfaceVariant.withValues(alpha: 0.3),
            size: 34,
            onTap: () => playerProvider.cancelDownload(item.song.videoId),
          ),
        ],
      ),
    );
  }
}
