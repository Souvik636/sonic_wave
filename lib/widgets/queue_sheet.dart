import 'dart:io';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';

import '../models/song.dart';
import '../providers/player_provider.dart';
import '../theme/app_colors.dart';
import 'animated_equalizer.dart';
import 'premium_interaction.dart';

/// Queue bottom sheet shared by the player screens.
/// - Tap a song to jump playback straight to it.
/// - Long-press the handle (or anywhere on the tile) and drag to reorder.
/// - Swipe a tile left to remove it from the queue.
void showQueueSheet(BuildContext context, PlayerProvider playerProvider) {
  showModalBottomSheet(
    context: context,
    backgroundColor: AppColors.surface,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
    ),
    builder: (context) {
      return AnimatedBuilder(
        animation: playerProvider,
        builder: (context, _) {
          final playlist = playerProvider.playlist;
          return Container(
            padding: const EdgeInsets.only(top: 12),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                // Handle
                Container(
                  width: 40,
                  height: 4,
                  decoration: BoxDecoration(
                    color: AppColors.textTertiary.withValues(alpha: 0.3),
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
                const SizedBox(height: 16),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 20),
                  child: Row(
                    children: [
                      Text(
                        'Queue',
                        style: Theme.of(context).textTheme.headlineMedium,
                      ),
                      const Spacer(),
                      Text(
                        '${playlist.length} songs',
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 4),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 20),
                  child: Align(
                    alignment: Alignment.centerLeft,
                    child: Text(
                      'Drag to reorder · swipe left to remove',
                      style: TextStyle(
                        color: AppColors.textTertiary.withValues(alpha: 0.7),
                        fontSize: 11,
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 8),
                Flexible(
                  child: ReorderableListView.builder(
                    shrinkWrap: true,
                    padding: const EdgeInsets.only(bottom: 20),
                    itemCount: playlist.length,
                    // ignore: deprecated_member_use
                    onReorder: (oldIndex, newIndex) {
                      // ReorderableListView reports the insertion slot, which
                      // is one past the target when moving an item down.
                      if (newIndex > oldIndex) newIndex--;
                      AppHaptics.selection();
                      playerProvider.reorderQueue(oldIndex, newIndex);
                    },
                    proxyDecorator: (child, index, animation) {
                      return Material(
                        color: Colors.transparent,
                        child: DecoratedBox(
                          decoration: BoxDecoration(
                            color: AppColors.surfaceVariant,
                            borderRadius: BorderRadius.circular(12),
                            boxShadow: [
                              BoxShadow(
                                color: Colors.black.withValues(alpha: 0.4),
                                blurRadius: 12,
                              ),
                            ],
                          ),
                          child: child,
                        ),
                      );
                    },
                    itemBuilder: (context, index) {
                      final song = playlist[index];
                      final isCurrent = index == playerProvider.currentIndex;
                      return Dismissible(
                        key: ValueKey('queue_${song.videoId}_$index'),
                        direction: isCurrent
                            ? DismissDirection.none
                            : DismissDirection.endToStart,
                        background: Container(
                          alignment: Alignment.centerRight,
                          padding: const EdgeInsets.only(right: 24),
                          color: Colors.redAccent.withValues(alpha: 0.25),
                          child: const Icon(
                            Icons.delete_outline_rounded,
                            color: Colors.redAccent,
                            size: 22,
                          ),
                        ),
                        onDismissed: (_) {
                          AppHaptics.medium();
                          playerProvider.removeFromPlaylist(index);
                        },
                        child: _QueueTile(
                          song: song,
                          index: index,
                          isCurrent: isCurrent,
                          onTap: () {
                            if (!isCurrent) {
                              AppHaptics.selection();
                              playerProvider.playQueueItem(index);
                            }
                          },
                        ),
                      );
                    },
                  ),
                ),
              ],
            ),
          );
        },
      );
    },
  );
}

class _QueueTile extends StatelessWidget {
  final Song song;
  final int index;
  final bool isCurrent;
  final VoidCallback onTap;

  const _QueueTile({
    required this.song,
    required this.index,
    required this.isCurrent,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return ListTile(
      onTap: onTap,
      leading: Container(
        width: 44,
        height: 44,
        decoration: BoxDecoration(borderRadius: BorderRadius.circular(8)),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(8),
          child: song.thumbnailUrl.startsWith('http')
              ? CachedNetworkImage(
                  imageUrl: song.thumbnailUrl,
                  fit: BoxFit.cover,
                  placeholder: (context, url) =>
                      Container(color: AppColors.surfaceVariant),
                  errorWidget: (context, url, error) =>
                      Container(color: AppColors.surfaceVariant),
                )
              : (song.thumbnailUrl.isNotEmpty &&
                    File(song.thumbnailUrl).existsSync())
              ? Image.file(
                  File(song.thumbnailUrl),
                  fit: BoxFit.cover,
                  errorBuilder: (context, error, stackTrace) =>
                      Container(color: AppColors.surfaceVariant),
                )
              : Container(
                  color: AppColors.surfaceVariant,
                  child: const Icon(
                    Icons.music_note_rounded,
                    color: AppColors.textTertiary,
                    size: 18,
                  ),
                ),
        ),
      ),
      title: Text(
        song.title,
        style: TextStyle(
          color: isCurrent
              ? Theme.of(context).colorScheme.primary
              : AppColors.textPrimary,
          fontSize: 14,
          fontWeight: isCurrent ? FontWeight.w600 : FontWeight.w400,
        ),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      subtitle: Text(
        song.artist,
        style: const TextStyle(color: AppColors.textTertiary, fontSize: 12),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (isCurrent)
            const AnimatedEqualizer(height: 16, barWidth: 2, barCount: 3)
          else
            Text(
              song.formattedDuration,
              style: const TextStyle(
                color: AppColors.textTertiary,
                fontSize: 12,
              ),
            ),
          const SizedBox(width: 8),
          ReorderableDragStartListener(
            index: index,
            child: const Icon(
              Icons.drag_handle_rounded,
              color: AppColors.textTertiary,
              size: 20,
            ),
          ),
        ],
      ),
    );
  }
}
