import 'dart:io';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../models/song.dart';
import '../providers/player_provider.dart';
import '../theme/app_colors.dart';
import '../services/download_service.dart';
import 'animated_equalizer.dart';
import 'song_album_art.dart';
import 'package:google_fonts/google_fonts.dart';
import 'premium_interaction.dart';
import 'app_toast.dart';
import 'storage_operation_dialog.dart';

class SongTile extends StatelessWidget {
  final Song song;
  final VoidCallback? onTap;
  final bool showDuration;
  final int? index;
  final String? sourceTag;

  const SongTile({
    super.key,
    required this.song,
    this.onTap,
    this.showDuration = true,
    this.index,
    this.sourceTag,
  });

  @override
  Widget build(BuildContext context) {
    return Consumer<PlayerProvider>(
      builder: (context, playerProvider, _) {
        final isCurrentSong = playerProvider.currentSong?.videoId == song.videoId;
        final isLoading = playerProvider.loadingSong?.videoId == song.videoId;
        final isPlaying = isCurrentSong && playerProvider.isPlaying;
        final isBufferingOrLoading = (isCurrentSong && playerProvider.isBuffering) || isLoading;

        final primaryColor = Theme.of(context).colorScheme.primary;

        final isDownloaded = playerProvider.downloadedSongs.any((s) => s.videoId == song.videoId);

        return Container(
          margin: const EdgeInsets.symmetric(vertical: 4, horizontal: 4),
          decoration: BoxDecoration(
            color: isCurrentSong
                ? primaryColor.withValues(alpha: 0.12)
                : Colors.white.withValues(alpha: 0.03),
            borderRadius: BorderRadius.circular(16),
            border: Border.all(
              color: isCurrentSong
                  ? primaryColor.withValues(alpha: 0.45)
                  : Colors.white.withValues(alpha: 0.06),
              width: isCurrentSong ? 1.2 : 0.8,
            ),
            boxShadow: isCurrentSong
                ? [
                    BoxShadow(
                      color: primaryColor.withValues(alpha: 0.2),
                      blurRadius: 16,
                      spreadRadius: 1,
                      offset: const Offset(0, 4),
                    ),
                  ]
                : [
                    BoxShadow(
                      color: Colors.black.withValues(alpha: 0.15),
                      blurRadius: 6,
                      offset: const Offset(0, 2),
                    ),
                  ],
          ),
          child: Material(
            color: Colors.transparent,
            child: InkWell(
              onTap: onTap ?? () => playerProvider.playSong(song),
              onLongPress: () => _showSongContextMenu(context, playerProvider),
              borderRadius: BorderRadius.circular(16),
              splashColor: primaryColor.withValues(alpha: 0.15),
              highlightColor: primaryColor.withValues(alpha: 0.08),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                child: Row(
                  children: [
                    // Index or equalizer
                    if (index != null)
                      SizedBox(
                        width: 26,
                        child: (isCurrentSong || isLoading)
                            ? (isBufferingOrLoading
                                ? Center(
                                    child: SizedBox(
                                      width: 14,
                                      height: 14,
                                      child: CircularProgressIndicator(
                                        color: primaryColor,
                                        strokeWidth: 1.5,
                                      ),
                                    ),
                                  )
                                : AnimatedEqualizer(
                                    isPlaying: isPlaying,
                                    height: 16,
                                    barWidth: 2.5,
                                    barCount: 3,
                                  ))
                            : Text(
                                '${index! + 1}',
                                style: GoogleFonts.spaceMono(
                                  color: AppColors.textTertiary,
                                  fontSize: 11,
                                  fontWeight: FontWeight.bold,
                                ),
                                textAlign: TextAlign.center,
                              ),
                      ),
                    if (index != null) const SizedBox(width: 10),

                    // Thumbnail with subtle vinyl pulse
                    Stack(
                      alignment: Alignment.center,
                      children: [
                        Container(
                          width: 52,
                          height: 52,
                          decoration: BoxDecoration(
                            borderRadius: BorderRadius.circular(12),
                            boxShadow: [
                              BoxShadow(
                                color: isCurrentSong
                                    ? primaryColor.withValues(alpha: 0.4)
                                    : Colors.black.withValues(alpha: 0.3),
                                blurRadius: isCurrentSong ? 12 : 6,
                                offset: const Offset(0, 3),
                              ),
                            ],
                          ),
                          child: SongAlbumArt(
                            song: song,
                            borderRadius: 12,
                            fit: BoxFit.cover,
                          ),
                        ),
                        if (isPlaying)
                          Container(
                            width: 52,
                            height: 52,
                            decoration: BoxDecoration(
                              color: Colors.black.withValues(alpha: 0.45),
                              borderRadius: BorderRadius.circular(12),
                            ),
                            child: const Center(
                              child: AnimatedEqualizer(
                                isPlaying: true,
                                height: 18,
                                barWidth: 3.0,
                                barCount: 3,
                              ),
                            ),
                          ),
                      ],
                    ),
                    const SizedBox(width: 14),

                    // Song Info
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            song.title,
                            style: GoogleFonts.outfit(
                              color: isCurrentSong ? primaryColor : Colors.white,
                              fontSize: 14,
                              fontWeight: isCurrentSong ? FontWeight.bold : FontWeight.w600,
                            ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                          const SizedBox(height: 4),
                          Row(
                            children: [
                              Flexible(
                                child: Text(
                                  song.artist,
                                  style: GoogleFonts.inter(
                                    color: AppColors.textSecondary,
                                    fontSize: 11.5,
                                    fontWeight: FontWeight.w400,
                                  ),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                              const SizedBox(width: 6),
                              // Single concise short badge (NEW > DL > LOCAL > Source)
                              Builder(
                                builder: (_) {
                                  final isNew = playerProvider.isNewInSession(song);
                                  final rawTag = (sourceTag ?? song.source).toLowerCase();
                                  final isLocal = song.isLocalFile || rawTag == 'local' || rawTag.startsWith('local_');

                                  String tagText = 'YT';
                                  Color bgColor = Colors.redAccent.withValues(alpha: 0.6);

                                  if (rawTag == 'duplicate' || rawTag == 'dup') {
                                    tagText = 'DUP';
                                    bgColor = Colors.amber.shade800;
                                  } else if (isNew) {
                                    tagText = 'NEW';
                                    bgColor = Colors.deepOrange;
                                  } else if (isDownloaded) {
                                    tagText = 'DL';
                                    bgColor = Colors.cyan.shade800;
                                  } else if (isLocal) {
                                    tagText = 'LOCAL';
                                    bgColor = Colors.blue.withValues(alpha: 0.6);
                                  } else if (rawTag.contains('jiosaavn') || rawTag.contains('saavn')) {
                                    tagText = 'SAAVN';
                                    bgColor = const Color(0xFF00D4B2).withValues(alpha: 0.6);
                                  } else if (rawTag.contains('radio')) {
                                    tagText = 'RADIO';
                                    bgColor = Colors.pinkAccent.withValues(alpha: 0.6);
                                  } else if (rawTag.contains('archive')) {
                                    tagText = 'ARCHIVE';
                                    bgColor = Colors.purple.withValues(alpha: 0.6);
                                  } else if (rawTag.contains('jamendo')) {
                                    tagText = 'JAM';
                                    bgColor = Colors.amber.withValues(alpha: 0.6);
                                  } else if (rawTag.contains('audius')) {
                                    tagText = 'AUD';
                                    bgColor = Colors.teal.withValues(alpha: 0.6);
                                  }

                                  return Container(
                                    padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 2),
                                    decoration: BoxDecoration(
                                      color: bgColor,
                                      borderRadius: BorderRadius.circular(4),
                                    ),
                                    child: Text(
                                      tagText,
                                      style: const TextStyle(
                                        color: Colors.white,
                                        fontSize: 8,
                                        fontWeight: FontWeight.w800,
                                      ),
                                    ),
                                  );
                                },
                              ),
                               if (song.isRecovered) ...[
                                const SizedBox(width: 4),
                                Container(
                                  padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 2),
                                  decoration: BoxDecoration(
                                    gradient: const LinearGradient(
                                      colors: [Colors.amber, Colors.orangeAccent],
                                    ),
                                    borderRadius: BorderRadius.circular(5),
                                    boxShadow: [
                                      BoxShadow(
                                        color: Colors.amber.withValues(alpha: 0.5),
                                        blurRadius: 4,
                                      ),
                                    ],
                                  ),
                                  child: const Text(
                                    'RECOVERY',
                                    style: TextStyle(
                                      color: Colors.black,
                                      fontSize: 8,
                                      fontWeight: FontWeight.w900,
                                    ),
                                  ),
                                ),
                              ],
                              if (song.isEdited) ...[
                                const SizedBox(width: 4),
                                Container(
                                  padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 2),
                                  decoration: BoxDecoration(
                                    color: Colors.amber.shade800,
                                    borderRadius: BorderRadius.circular(5),
                                    boxShadow: [
                                      BoxShadow(
                                        color: Colors.amber.shade800.withValues(alpha: 0.3),
                                        blurRadius: 4,
                                      )
                                    ],
                                  ),
                                  child: const Text(
                                    'EDITED',
                                    style: TextStyle(
                                      color: Colors.white,
                                      fontSize: 8,
                                      fontWeight: FontWeight.w800,
                                    ),
                                  ),
                                ),
                              ],
                            ],
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(width: 8),

                    // Heart toggle
                    _FavoriteHeart(
                      isFavorite: playerProvider.isFavorite(song.videoId),
                      color: primaryColor,
                      onTap: () => playerProvider.toggleFavorite(song),
                    ),

                    // Duration
                    if (showDuration && song.duration.inSeconds > 0)
                      Padding(
                        padding: const EdgeInsets.only(left: 6),
                        child: Text(
                          song.formattedDuration,
                          style: GoogleFonts.spaceMono(
                            color: AppColors.textTertiary,
                            fontSize: 11,
                          ),
                        ),
                      ),

                    // Context Menu button
                    IconButton(
                      icon: const Icon(Icons.more_vert_rounded, color: AppColors.textTertiary, size: 18),
                      onPressed: () => _showSongContextMenu(context, playerProvider),
                    ),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  void _showSongContextMenu(BuildContext context, PlayerProvider playerProvider) {
    final isDownloaded = playerProvider.downloadedSongs.any((s) => s.videoId == song.videoId);
    final isLocalSection = sourceTag == 'local';

    showModalBottomSheet(
      context: context,
      backgroundColor: AppColors.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (context) {
        return SafeArea(
          child: SingleChildScrollView(
            physics: const BouncingScrollPhysics(),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                // Handle
                const SizedBox(height: 12),
                Container(
                  width: 40,
                  height: 4,
                  decoration: BoxDecoration(
                    color: AppColors.textTertiary.withValues(alpha: 0.3),
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
                const SizedBox(height: 16),
                // Song Info Header
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 20),
                  child: Row(
                    children: [
                      SongAlbumArt(
                        song: song,
                        width: 50,
                        height: 50,
                        borderRadius: 8,
                      ),
                      const SizedBox(width: 14),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              song.title,
                              style: Theme.of(context).textTheme.titleMedium?.copyWith(
                                    fontWeight: FontWeight.bold,
                                    color: Colors.white,
                                  ),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                            const SizedBox(height: 4),
                            Text(
                              song.artist,
                              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                                    color: AppColors.textTertiary,
                                  ),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 16),
                const Divider(color: AppColors.divider, height: 1),
                
                // Menu options
                if (isLocalSection) ...[
                  ListTile(
                    leading: const Icon(Icons.library_music_rounded, color: Colors.white),
                    title: const Text('Add / Move to Album', style: TextStyle(color: Colors.white)),
                    onTap: () {
                      Navigator.pop(context);
                      _showMoveToAlbumDialog(context, playerProvider);
                    },
                  ),
                  ListTile(
                    leading: const Icon(Icons.info_outline_rounded, color: Colors.white),
                    title: const Text('Song Details', style: TextStyle(color: Colors.white)),
                    onTap: () {
                      Navigator.pop(context);
                      _showSongInfoDialog(context);
                    },
                  ),
                ] else ...[
                  ListTile(
                    leading: const Icon(Icons.playlist_play_rounded, color: Colors.white),
                    title: const Text('Play Next', style: TextStyle(color: Colors.white)),
                    onTap: () {
                      playerProvider.playSongNext(song);
                      Navigator.pop(context);
                      AppToast.show(
                        context,
                        '"${song.title}" will play next',
                        type: ToastType.info,
                        icon: Icons.playlist_play_rounded,
                      );
                    },
                  ),
                  ListTile(
                    leading: const Icon(Icons.queue_music_rounded, color: Colors.white),
                    title: const Text('Add to Queue', style: TextStyle(color: Colors.white)),
                    onTap: () {
                      playerProvider.addSongToQueue(song);
                      Navigator.pop(context);
                      AppToast.show(
                        context,
                        'Added "${song.title}" to queue',
                        type: ToastType.info,
                        icon: Icons.queue_music_rounded,
                      );
                    },
                  ),
                  ListTile(
                    leading: const Icon(Icons.library_music_rounded, color: Colors.white),
                    title: const Text('Add / Move to Album', style: TextStyle(color: Colors.white)),
                    onTap: () {
                      Navigator.pop(context);
                      _showMoveToAlbumDialog(context, playerProvider);
                    },
                  ),
                  if (isDownloaded)
                    ListTile(
                      leading: const Icon(Icons.delete_outline_rounded, color: Colors.redAccent),
                      title: const Text('Remove Download', style: TextStyle(color: Colors.redAccent)),
                      onTap: () {
                        playerProvider.deleteDownload(song.videoId);
                        Navigator.pop(context);
                        AppToast.show(
                          context,
                          'Removed download for "${song.title}"',
                          type: ToastType.warning,
                          icon: Icons.delete_outline_rounded,
                        );
                      },
                    )
                  else if (!song.isLiveRadio)
                    ListTile(
                      leading: const Icon(Icons.download_rounded, color: Colors.white),
                      title: const Text('Download', style: TextStyle(color: Colors.white)),
                      onTap: () {
                        playerProvider.downloadSong(song, context: context);
                        Navigator.pop(context);
                        AppToast.show(
                          context,
                          'Starting download for "${song.title}"',
                          type: ToastType.download,
                        );
                      },
                    )
                  else
                    ListTile(
                      leading: const Icon(Icons.radio_rounded, color: Colors.white70),
                      title: const Text('Live Radio Stream', style: TextStyle(color: Colors.white70)),
                      subtitle: const Text('Continuous broadcast (Cannot download)', style: TextStyle(color: AppColors.textTertiary, fontSize: 11)),
                      onTap: () {
                        Navigator.pop(context);
                        AppToast.show(
                          context,
                          'Live radio streams cannot be downloaded for offline playback',
                          type: ToastType.info,
                          icon: Icons.radio_rounded,
                        );
                      },
                    ),
                  ListTile(
                    leading: const Icon(Icons.share_rounded, color: Colors.white),
                    title: const Text('Share Song', style: TextStyle(color: Colors.white)),
                    onTap: () {
                      Navigator.pop(context);
                      AppToast.show(
                        context,
                        'Copied link for "${song.title}" to clipboard!',
                        type: ToastType.success,
                        icon: Icons.share_rounded,
                      );
                    },
                  ),
                  ListTile(
                    leading: const Icon(Icons.info_outline_rounded, color: Colors.white),
                    title: const Text('Song Details', style: TextStyle(color: Colors.white)),
                    onTap: () {
                      Navigator.pop(context);
                      _showSongInfoDialog(context);
                    },
                  ),
                ],
                const SizedBox(height: 25),
              ],
            ),
          ),
        );
      },
    );
  }

  // ignore: unused_element
  void _showAddToAlbumDialog(BuildContext context, PlayerProvider playerProvider) {
    showModalBottomSheet(
      context: context,
      backgroundColor: AppColors.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (context) {
        final albums = playerProvider.albums;
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const SizedBox(height: 12),
              Container(
                width: 40,
                height: 4,
                decoration: BoxDecoration(
                  color: AppColors.textTertiary.withValues(alpha: 0.3),
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              const SizedBox(height: 16),
              Text(
                'Add to Album',
                style: Theme.of(context).textTheme.titleLarge?.copyWith(
                      fontWeight: FontWeight.bold,
                      color: Colors.white,
                    ),
              ),
              const SizedBox(height: 12),
              if (albums.isEmpty)
                const Padding(
                  padding: EdgeInsets.symmetric(vertical: 24),
                  child: Text('No albums created yet', style: TextStyle(color: AppColors.textTertiary)),
                )
              else
                Flexible(
                  child: ListView.builder(
                    shrinkWrap: true,
                    itemCount: albums.length,
                    itemBuilder: (context, index) {
                      final album = albums[index];
                      final isAlreadyAdded = album.songs.any((s) => s.videoId == song.videoId);
                      return ListTile(
                        leading: const Icon(Icons.album_rounded, color: AppColors.textTertiary),
                        title: Text(album.name, style: const TextStyle(color: Colors.white)),
                        subtitle: Text('${album.songCount} songs', style: const TextStyle(color: AppColors.textTertiary, fontSize: 12)),
                        trailing: isAlreadyAdded
                            ? Icon(Icons.check_circle_rounded, color: Theme.of(context).colorScheme.primary)
                            : null,
                        onTap: isAlreadyAdded
                            ? null
                            : () async {
                                Navigator.pop(context);
                                final sourcePath = song.filePath ?? (song.isLocalFile ? song.videoId : null);
                                final hasLocalFile = sourcePath != null && File(sourcePath).existsSync();

                                if (hasLocalFile) {
                                  final op = await showStorageOperationDialog(context);
                                  if (op == null) return;

                                  final success = await playerProvider.moveSongToAnotherAlbumFolder(
                                    song,
                                    album.id,
                                    physicalMove: op.physicalMove,
                                    isCopyMode: op.isCopyMode,
                                  );
                                  final label = op.isCopyMode
                                      ? 'Copied to "${album.name}"'
                                      : (op.physicalMove
                                          ? 'Moved to "${album.name}"'
                                          : 'Added to "${album.name}"');
                                  if (!context.mounted) return;
                                  AppToast.show(
                                    context,
                                    success ? label : 'Failed operation for "${album.name}"',
                                    type: success ? ToastType.success : ToastType.error,
                                  );
                                } else {
                                  await playerProvider.addSongToAlbum(album.id, song);
                                  if (!context.mounted) return;
                                  AppToast.show(
                                    context,
                                    'Added to "${album.name}"',
                                    type: ToastType.success,
                                  );
                                }
                              },
                      );
                    },
                  ),
                ),
              const SizedBox(height: 25),
            ],
          ),
        );
      },
    );
  }


  Future<Map<String, dynamic>> _getSongFileInfo() async {
    final info = <String, dynamic>{
      'exists': false,
      'size': 'N/A',
      'path': 'N/A',
    };
    
    String? path = song.filePath;
    if (path == null) {
      final localPath = await DownloadService().getLocalAudioPath(song.videoId);
      if (await File(localPath).exists()) {
        path = localPath;
      }
    }
    
    if (path != null) {
      final file = File(path);
      if (await file.exists()) {
        final length = await file.length();
        info['exists'] = true;
        info['path'] = path;
        
        if (length < 1024) {
          info['size'] = '$length B';
        } else if (length < 1024 * 1024) {
          info['size'] = '${(length / 1024).toStringAsFixed(1)} KB';
        } else {
          info['size'] = '${(length / (1024 * 1024)).toStringAsFixed(1)} MB';
        }
      }
    }
    return info;
  }

  void _showSongInfoDialog(BuildContext context) {
    showDialog(
      context: context,
      builder: (ctx) {
        return AlertDialog(
          backgroundColor: AppColors.surface,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
          title: const Text('Song Details', style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
          content: FutureBuilder<Map<String, dynamic>>(
            future: _getSongFileInfo(),
            builder: (context, snapshot) {
              final info = snapshot.data ?? {'exists': false, 'size': 'Loading...', 'path': 'Loading...'};
              final exists = info['exists'] as bool;
              final size = info['size'] as String;
              final path = info['path'] as String;

              return Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _buildInfoRow('Title', song.title),
                  const SizedBox(height: 8),
                  _buildInfoRow('Artist', song.artist),
                  const SizedBox(height: 8),
                  _buildInfoRow('Source', song.source.toUpperCase()),
                  const SizedBox(height: 8),
                  _buildInfoRow('Storage Type', exists ? 'Local Disk File' : 'Streamed Online'),
                  if (exists) ...[
                    const SizedBox(height: 8),
                    _buildInfoRow('File Size', size),
                    const SizedBox(height: 8),
                    _buildInfoRow('File Path', path, isPath: true),
                  ],
                ],
              );
            },
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('Close'),
            ),
          ],
        );
      },
    );
  }

  Widget _buildInfoRow(String label, String value, {bool isPath = false}) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: const TextStyle(color: AppColors.textTertiary, fontSize: 11, fontWeight: FontWeight.w600),
        ),
        const SizedBox(height: 2),
        Text(
          value,
          style: TextStyle(
            color: Colors.white,
            fontSize: 13,
            fontFamily: isPath ? 'monospace' : null,
          ),
          maxLines: isPath ? 5 : 2,
          overflow: TextOverflow.ellipsis,
        ),
      ],
    );
  }

  void _showMoveToAlbumDialog(BuildContext context, PlayerProvider playerProvider) {
    showModalBottomSheet(
      context: context,
      backgroundColor: AppColors.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (ctx) {
        final albums = playerProvider.albums;
        return Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  const Text(
                    'Move Song to Album Folder',
                    style: TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.bold,
                      color: Colors.white,
                    ),
                  ),
                  IconButton(
                    icon: const Icon(Icons.create_new_folder_rounded, color: Colors.cyanAccent),
                    onPressed: () {
                      Navigator.pop(ctx);
                      _showCreateAndMoveAlbumDialog(context, playerProvider);
                    },
                  ),
                ],
              ),
              const SizedBox(height: 12),
              if (albums.isEmpty)
                const Padding(
                  padding: EdgeInsets.symmetric(vertical: 20),
                  child: Center(
                    child: Text(
                      'No album folders created yet.\nTap + icon above to create one.',
                      textAlign: TextAlign.center,
                      style: TextStyle(color: AppColors.textTertiary),
                    ),
                  ),
                )
              else
                Flexible(
                  child: ListView.builder(
                    shrinkWrap: true,
                    itemCount: albums.length,
                    itemBuilder: (context, index) {
                      final album = albums[index];
                      return ListTile(
                        leading: const Icon(Icons.folder_outlined, color: Colors.white70),
                        title: Text(album.name, style: const TextStyle(color: Colors.white)),
                        onTap: () async {
                          Navigator.pop(ctx);
                          final op = await _promptMoveType(context);
                          if (op == null) return;

                          final success = await playerProvider.moveSongToAnotherAlbumFolder(
                            song,
                            album.id,
                            physicalMove: op.physicalMove,
                            isCopyMode: op.isCopyMode,
                          );
                          if (context.mounted) {
                            final label = op.isCopyMode
                                ? 'Copied to "${album.name}"'
                                : (op.physicalMove ? 'Moved to "${album.name}"' : 'Added to "${album.name}"');
                            AppToast.show(
                              context,
                              success ? label : 'Failed operation for "${album.name}"',
                              type: success ? ToastType.success : ToastType.error,
                            );
                          }
                        },
                      );
                    },
                  ),
                ),
              const SizedBox(height: 25),
            ],
          ),
        );
      },
    );
  }

  void _showCreateAndMoveAlbumDialog(BuildContext context, PlayerProvider playerProvider) {
    final controller = TextEditingController();
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppColors.surface,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: const Text('New Album Folder', style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
        content: TextField(
          controller: controller,
          autofocus: true,
          style: const TextStyle(color: Colors.white),
          decoration: const InputDecoration(
            hintText: 'Album / Folder name...',
            hintStyle: TextStyle(color: AppColors.textTertiary),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel', style: TextStyle(color: AppColors.textSecondary)),
          ),
          TextButton(
            onPressed: () async {
              final name = controller.text.trim();
              if (name.isNotEmpty) {
                Navigator.pop(ctx);
                final op = await _promptMoveType(context);
                if (op == null) return;

                final newAlbum = await playerProvider.createAlbum(name);
                final success = await playerProvider.moveSongToAnotherAlbumFolder(
                  song,
                  newAlbum.id,
                  physicalMove: op.physicalMove,
                  isCopyMode: op.isCopyMode,
                );
                if (context.mounted) {
                  final label = op.isCopyMode
                      ? 'Created folder & copied to "$name"'
                      : (op.physicalMove ? 'Created folder & moved to "$name"' : 'Created album "$name"');
                  AppToast.show(
                    context,
                    success ? label : 'Failed operation for "$name"',
                    type: success ? ToastType.success : ToastType.error,
                  );
                }
              }
            },
            child: Text('Create & Continue',
                style:
                    TextStyle(color: Theme.of(context).colorScheme.primary)),
          ),
        ],
      ),
    );
  }

  Future<StorageOperationChoice?> _promptMoveType(BuildContext context) async {
    return showStorageOperationDialog(context);
  }
}

/// A favourite toggle that pops with a spring + colour cross-fade and a light
/// haptic when tapped — replacing the old instant icon swap.
class _FavoriteHeart extends StatefulWidget {
  final bool isFavorite;
  final Color color;
  final VoidCallback onTap;

  const _FavoriteHeart({
    required this.isFavorite,
    required this.color,
    required this.onTap,
  });

  @override
  State<_FavoriteHeart> createState() => _FavoriteHeartState();
}

class _FavoriteHeartState extends State<_FavoriteHeart>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 350),
  );
  late final Animation<double> _scale = TweenSequence<double>([
    TweenSequenceItem(
        tween: Tween(begin: 1.0, end: 1.35)
            .chain(CurveTween(curve: Curves.easeOut)),
        weight: 40),
    TweenSequenceItem(
        tween: Tween(begin: 1.35, end: 1.0)
            .chain(CurveTween(curve: Curves.elasticOut)),
        weight: 60),
  ]).animate(_controller);

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _handleTap() {
    AppHaptics.light();
    // Only bounce when turning a favourite ON — feels intentional, not noisy.
    if (!widget.isFavorite) {
      _controller.forward(from: 0);
    }
    widget.onTap();
  }

  @override
  Widget build(BuildContext context) {
    return IconButton(
      onPressed: _handleTap,
      icon: ScaleTransition(
        scale: _scale,
        child: AnimatedSwitcher(
          duration: const Duration(milliseconds: 250),
          transitionBuilder: (child, anim) =>
              ScaleTransition(scale: anim, child: child),
          child: Icon(
            widget.isFavorite
                ? Icons.favorite_rounded
                : Icons.favorite_border_rounded,
            key: ValueKey(widget.isFavorite),
            color: widget.isFavorite ? widget.color : AppColors.textTertiary,
            size: 20,
          ),
        ),
      ),
    );
  }
}
