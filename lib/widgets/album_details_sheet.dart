import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:provider/provider.dart';

import '../models/album.dart';
import '../models/song.dart';
import '../providers/player_provider.dart';
import '../theme/app_colors.dart';
import 'app_toast.dart';
import 'song_tile.dart';

/// Premium Album Details sheet for viewing, playing, and adding/removing songs in real time.
class AlbumDetailsSheet extends StatelessWidget {
  final String albumId;

  const AlbumDetailsSheet({super.key, required this.albumId});

  static void show(BuildContext context, String albumId) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => AlbumDetailsSheet(albumId: albumId),
    );
  }

  @override
  Widget build(BuildContext context) {
    final playerProvider = Provider.of<PlayerProvider>(context);
    final albums = playerProvider.albums;
    final albumIndex = albums.indexWhere((a) => a.id == albumId);

    if (albumIndex < 0) {
      return Container(
        height: 200,
        decoration: const BoxDecoration(
          color: AppColors.surface,
          borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
        ),
        child: const Center(
          child: Text('Album not found', style: TextStyle(color: Colors.white)),
        ),
      );
    }

    final album = albums[albumIndex];
    final primary = Theme.of(context).colorScheme.primary;

    return Container(
      height: MediaQuery.of(context).size.height * 0.85,
      decoration: BoxDecoration(
        color: AppColors.background,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(28)),
        border: Border.all(color: AppColors.glassBorder, width: 1),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.5),
            blurRadius: 30,
            spreadRadius: 5,
          ),
        ],
      ),
      child: Column(
        children: [
          // Drag handle
          Container(
            margin: const EdgeInsets.only(top: 12, bottom: 8),
            width: 40,
            height: 4,
            decoration: BoxDecoration(
              color: AppColors.textTertiary.withValues(alpha: 0.3),
              borderRadius: BorderRadius.circular(2),
            ),
          ),

          // Header Content
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 8, 20, 16),
            child: Column(
              children: [
                Row(
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: [
                    Container(
                      width: 56,
                      height: 56,
                      decoration: BoxDecoration(
                        gradient: LinearGradient(
                          colors: [
                            primary.withValues(alpha: 0.8),
                            primary.withValues(alpha: 0.4),
                          ],
                          begin: Alignment.topLeft,
                          end: Alignment.bottomRight,
                        ),
                        borderRadius: BorderRadius.circular(16),
                        boxShadow: [
                          BoxShadow(
                            color: primary.withValues(alpha: 0.3),
                            blurRadius: 12,
                            spreadRadius: 1,
                          ),
                        ],
                      ),
                      child: const Icon(
                        Icons.album_rounded,
                        color: Colors.white,
                        size: 28,
                      ),
                    ),
                    const SizedBox(width: 16),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            album.name,
                            style: GoogleFonts.outfit(
                              color: Colors.white,
                              fontSize: 20,
                              fontWeight: FontWeight.bold,
                            ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                          const SizedBox(height: 4),
                          Row(
                            children: [
                              Container(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 8,
                                  vertical: 2,
                                ),
                                decoration: BoxDecoration(
                                  color: primary.withValues(alpha: 0.15),
                                  borderRadius: BorderRadius.circular(6),
                                ),
                                child: Text(
                                  album.isFolderBased
                                      ? 'Physical Folder'
                                      : 'Custom Album',
                                  style: TextStyle(
                                    color: primary,
                                    fontSize: 10,
                                    fontWeight: FontWeight.bold,
                                  ),
                                ),
                              ),
                              const SizedBox(width: 8),
                              Text(
                                '${album.songs.length} tracks • ${album.formattedTotalSize}',
                                style: GoogleFonts.inter(
                                  color: AppColors.textTertiary,
                                  fontSize: 11.5,
                                ),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                    PopupMenuButton<String>(
                      icon: const Icon(
                        Icons.more_vert_rounded,
                        color: AppColors.textSecondary,
                      ),
                      color: AppColors.surface,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(14),
                      ),
                      onSelected: (val) {
                        if (val == 'rename') {
                          _showRenameDialog(context, playerProvider, album);
                        } else if (val == 'add') {
                          _showBulkSongPicker(context, playerProvider, album);
                        } else if (val == 'delete') {
                          _showDeleteDialog(context, playerProvider, album);
                        }
                      },
                      itemBuilder: (ctx) => [
                        const PopupMenuItem(
                          value: 'rename',
                          child: Row(
                            children: [
                              Icon(
                                Icons.edit_rounded,
                                color: Colors.white,
                                size: 18,
                              ),
                              SizedBox(width: 10),
                              Text(
                                'Rename Album',
                                style: TextStyle(color: Colors.white),
                              ),
                            ],
                          ),
                        ),
                        const PopupMenuItem(
                          value: 'add',
                          child: Row(
                            children: [
                              Icon(
                                Icons.add_rounded,
                                color: Colors.white,
                                size: 18,
                              ),
                              SizedBox(width: 10),
                              Text(
                                'Add Songs',
                                style: TextStyle(color: Colors.white),
                              ),
                            ],
                          ),
                        ),
                        const PopupMenuItem(
                          value: 'delete',
                          child: Row(
                            children: [
                              Icon(
                                Icons.delete_forever_rounded,
                                color: Colors.redAccent,
                                size: 18,
                              ),
                              SizedBox(width: 10),
                              Text(
                                'Delete Album',
                                style: TextStyle(color: Colors.redAccent),
                              ),
                            ],
                          ),
                        ),
                      ],
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
                const SizedBox(height: 16),

                // Quick Action Bar
                Row(
                  children: [
                    Expanded(
                      child: ElevatedButton.icon(
                        onPressed: album.songs.isEmpty
                            ? null
                            : () {
                                playerProvider.playPlaylist(
                                  album.songs,
                                  startIndex: 0,
                                );
                                AppToast.show(
                                  context,
                                  'Playing "${album.name}"',
                                  type: ToastType.success,
                                );
                              },
                        icon: const Icon(Icons.play_arrow_rounded, size: 18),
                        label: const Text('Play All'),
                        style: ElevatedButton.styleFrom(
                          backgroundColor: primary,
                          foregroundColor: Colors.white,
                          padding: const EdgeInsets.symmetric(vertical: 10),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(12),
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: OutlinedButton.icon(
                        onPressed: () {
                          _showBulkSongPicker(context, playerProvider, album);
                        },
                        icon: const Icon(Icons.add_rounded, size: 18),
                        label: const Text('Add Songs'),
                        style: OutlinedButton.styleFrom(
                          foregroundColor: Colors.white,
                          side: BorderSide(
                            color: primary.withValues(alpha: 0.6),
                          ),
                          padding: const EdgeInsets.symmetric(vertical: 10),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(12),
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),

          const Divider(height: 1, color: AppColors.divider),

          // Track List Section
          Expanded(
            child: album.songs.isEmpty
                ? Center(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          Icons.queue_music_rounded,
                          size: 48,
                          color: AppColors.textTertiary.withValues(alpha: 0.4),
                        ),
                        const SizedBox(height: 12),
                        Text(
                          'No songs in this album yet',
                          style: GoogleFonts.inter(
                            color: AppColors.textSecondary,
                            fontSize: 14,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                        const SizedBox(height: 8),
                        ElevatedButton.icon(
                          onPressed: () {
                            _showBulkSongPicker(context, playerProvider, album);
                          },
                          icon: const Icon(Icons.add_rounded, size: 16),
                          label: const Text('Add Songs Now'),
                          style: ElevatedButton.styleFrom(
                            backgroundColor: primary,
                            foregroundColor: Colors.white,
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(10),
                            ),
                          ),
                        ),
                      ],
                    ),
                  )
                : ListView.builder(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 8,
                    ),
                    itemCount: album.songs.length,
                    itemBuilder: (context, index) {
                      final song = album.songs[index];
                      return Dismissible(
                        key: ValueKey('${album.id}-${song.videoId}-$index'),
                        direction: DismissDirection.endToStart,
                        background: Container(
                          alignment: Alignment.centerRight,
                          padding: const EdgeInsets.only(right: 20),
                          decoration: BoxDecoration(
                            color: Colors.redAccent.withValues(alpha: 0.2),
                            borderRadius: BorderRadius.circular(12),
                          ),
                          child: const Icon(
                            Icons.delete_outline_rounded,
                            color: Colors.redAccent,
                          ),
                        ),
                        onDismissed: (_) {
                          playerProvider.removeSongFromAlbum(
                            album.id,
                            song.videoId,
                          );
                          AppToast.show(
                            context,
                            'Removed from album',
                            type: ToastType.info,
                          );
                        },
                        child: SongTile(
                          song: song,
                          index: index,
                          sourceTag: 'album',
                          onTap: () {
                            playerProvider.playPlaylist(
                              album.songs,
                              startIndex: index,
                            );
                          },
                          trailing: IconButton(
                            icon: const Icon(
                              Icons.remove_circle_outline_rounded,
                              color: AppColors.textTertiary,
                              size: 20,
                            ),
                            onPressed: () {
                              playerProvider.removeSongFromAlbum(
                                album.id,
                                song.videoId,
                              );
                              AppToast.show(
                                context,
                                'Removed "${song.title}"',
                                type: ToastType.info,
                              );
                            },
                          ),
                        ),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }

  void _showBulkSongPicker(
    BuildContext context,
    PlayerProvider playerProvider,
    UserAlbum album,
  ) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => _BulkSongPickerModal(album: album),
    );
  }

  void _showRenameDialog(
    BuildContext context,
    PlayerProvider playerProvider,
    UserAlbum album,
  ) {
    final controller = TextEditingController(text: album.name);
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppColors.surface,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: const Text(
          'Rename Album',
          style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
        ),
        content: TextField(
          controller: controller,
          autofocus: true,
          style: const TextStyle(color: Colors.white),
          decoration: InputDecoration(
            hintText: 'New album name...',
            hintStyle: const TextStyle(
              color: AppColors.textTertiary,
              fontSize: 12,
            ),
            filled: true,
            fillColor: AppColors.surfaceVariant.withValues(alpha: 0.5),
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(12),
              borderSide: BorderSide.none,
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text(
              'Cancel',
              style: TextStyle(color: AppColors.textSecondary),
            ),
          ),
          ElevatedButton(
            onPressed: () async {
              final newName = controller.text.trim();
              if (newName.isNotEmpty && newName != album.name) {
                Navigator.pop(ctx);
                await playerProvider.renameAlbum(album.id, newName);
                if (context.mounted) {
                  AppToast.show(
                    context,
                    'Renamed album to "$newName"',
                    type: ToastType.success,
                  );
                }
              }
            },
            style: ElevatedButton.styleFrom(
              backgroundColor: Theme.of(context).colorScheme.primary,
              foregroundColor: Colors.white,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(10),
              ),
            ),
            child: const Text('Save'),
          ),
        ],
      ),
    );
  }

  void _showDeleteDialog(
    BuildContext context,
    PlayerProvider playerProvider,
    UserAlbum album,
  ) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppColors.surface,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: Text(
          'Delete "${album.name}"?',
          style: const TextStyle(
            color: Colors.white,
            fontWeight: FontWeight.bold,
          ),
        ),
        content: Text(
          album.isFolderBased
              ? 'This physical album folder and its index will be deleted. Audio files can be moved to recovery backup.'
              : 'Are you sure you want to delete this custom album? Audio files on disk will remain intact.',
          style: const TextStyle(color: AppColors.textSecondary, fontSize: 13),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text(
              'Cancel',
              style: TextStyle(color: AppColors.textSecondary),
            ),
          ),
          ElevatedButton(
            onPressed: () async {
              Navigator.pop(ctx); // Close dialog
              Navigator.pop(context); // Close sheet
              await playerProvider.deleteAlbumWithProtection(
                album.id,
                moveToRecovery: true,
              );
              if (context.mounted) {
                AppToast.show(
                  context,
                  'Deleted album "${album.name}"',
                  type: ToastType.warning,
                );
              }
            },
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.redAccent,
              foregroundColor: Colors.white,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(10),
              ),
            ),
            child: const Text('Delete Album'),
          ),
        ],
      ),
    );
  }
}

/// Interactive Multi-Select Song Picker for adding songs to an album in real-time.
class _BulkSongPickerModal extends StatefulWidget {
  final UserAlbum album;

  const _BulkSongPickerModal({required this.album});

  @override
  State<_BulkSongPickerModal> createState() => _BulkSongPickerModalState();
}

class _BulkSongPickerModalState extends State<_BulkSongPickerModal> {
  final TextEditingController _searchController = TextEditingController();
  final Set<String> _selectedVideoIds = {};
  String _query = '';

  @override
  void initState() {
    super.initState();
    for (final s in widget.album.songs) {
      _selectedVideoIds.add(s.videoId);
    }
    _searchController.addListener(() {
      setState(() => _query = _searchController.text.trim().toLowerCase());
    });
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final playerProvider = Provider.of<PlayerProvider>(context);
    final allAvailable = playerProvider.localSongsMerged;
    final primary = Theme.of(context).colorScheme.primary;

    List<Song> filtered = allAvailable;
    if (_query.isNotEmpty) {
      filtered = allAvailable
          .where(
            (s) =>
                s.title.toLowerCase().contains(_query) ||
                s.artist.toLowerCase().contains(_query),
          )
          .toList();
    }

    final newlySelectedCount =
        _selectedVideoIds.length - widget.album.songs.length;

    return Container(
      height: MediaQuery.of(context).size.height * 0.8,
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
        border: Border.all(color: AppColors.glassBorder, width: 1),
      ),
      child: Column(
        children: [
          // Drag handle & title
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
            child: Column(
              children: [
                Container(
                  width: 36,
                  height: 4,
                  decoration: BoxDecoration(
                    color: AppColors.textTertiary.withValues(alpha: 0.3),
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
                const SizedBox(height: 12),
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text(
                      'Add Songs to "${widget.album.name}"',
                      style: GoogleFonts.outfit(
                        color: Colors.white,
                        fontSize: 16,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    TextButton(
                      onPressed: () {
                        setState(() {
                          if (_selectedVideoIds.length == allAvailable.length) {
                            _selectedVideoIds.clear();
                          } else {
                            _selectedVideoIds.addAll(
                              allAvailable.map((s) => s.videoId),
                            );
                          }
                        });
                      },
                      child: Text(
                        _selectedVideoIds.length == allAvailable.length
                            ? 'Deselect All'
                            : 'Select All',
                        style: TextStyle(color: primary, fontSize: 12),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 8),

                // Search Input
                TextField(
                  controller: _searchController,
                  style: const TextStyle(color: Colors.white, fontSize: 13),
                  decoration: InputDecoration(
                    hintText: 'Search songs to add...',
                    hintStyle: const TextStyle(
                      color: AppColors.textTertiary,
                      fontSize: 12,
                    ),
                    prefixIcon: const Icon(
                      Icons.search_rounded,
                      color: AppColors.textTertiary,
                      size: 18,
                    ),
                    filled: true,
                    fillColor: AppColors.surfaceVariant.withValues(alpha: 0.4),
                    contentPadding: const EdgeInsets.symmetric(
                      horizontal: 14,
                      vertical: 10,
                    ),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(12),
                      borderSide: BorderSide.none,
                    ),
                  ),
                ),
              ],
            ),
          ),

          const Divider(height: 1, color: AppColors.divider),

          // Songs Checklist
          Expanded(
            child: ListView.builder(
              padding: const EdgeInsets.symmetric(vertical: 6),
              itemCount: filtered.length,
              itemBuilder: (context, index) {
                final song = filtered[index];
                final isSelected = _selectedVideoIds.contains(song.videoId);

                return CheckboxListTile(
                  value: isSelected,
                  activeColor: primary,
                  checkboxShape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(4),
                  ),
                  onChanged: (val) {
                    setState(() {
                      if (val == true) {
                        _selectedVideoIds.add(song.videoId);
                      } else {
                        _selectedVideoIds.remove(song.videoId);
                      }
                    });
                  },
                  title: Text(
                    song.title,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  subtitle: Text(
                    '${song.artist} • ${song.formattedDuration}',
                    style: const TextStyle(
                      color: AppColors.textTertiary,
                      fontSize: 11,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                );
              },
            ),
          ),

          // Action Button
          Padding(
            padding: const EdgeInsets.all(16),
            child: SizedBox(
              width: double.infinity,
              child: ElevatedButton(
                onPressed: () async {
                  final selectedSongs = allAvailable
                      .where((s) => _selectedVideoIds.contains(s.videoId))
                      .toList();
                  await playerProvider.addSongsToAlbum(
                    widget.album.id,
                    selectedSongs,
                  );
                  if (context.mounted) {
                    Navigator.pop(context);
                    AppToast.show(
                      context,
                      newlySelectedCount > 0
                          ? 'Added $newlySelectedCount song(s) to "${widget.album.name}"'
                          : 'Album updated',
                      type: ToastType.success,
                    );
                  }
                },
                style: ElevatedButton.styleFrom(
                  backgroundColor: primary,
                  foregroundColor: Colors.white,
                  padding: const EdgeInsets.symmetric(vertical: 14),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(14),
                  ),
                ),
                child: Text(
                  newlySelectedCount > 0
                      ? 'Add $newlySelectedCount Selected Song(s)'
                      : 'Save Album Tracklist',
                  style: const TextStyle(
                    fontWeight: FontWeight.bold,
                    fontSize: 14,
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
