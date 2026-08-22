import 'dart:io';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:provider/provider.dart';

import '../models/song.dart';
import '../providers/player_provider.dart';
import '../providers/settings_provider.dart';
import '../services/download_service.dart';
import '../services/lyrics_service.dart';
import '../theme/app_colors.dart';
import 'animated_equalizer.dart';
import 'glassmorphic_card.dart';
import 'app_toast.dart';
import 'storage_operation_dialog.dart';
import '../screens/sound_studio_screen.dart';
import 'audiophile_signal_path_sheet.dart';
import 'parametric_eq_view.dart';
import 'ambient_soundscape_sheet.dart';

/// Shared "three-dot" song options sheet used by both the Classic and Aurora
/// player screens: Sleep Timer, Sound Enhancer, Lyrics, Download and
/// Detailed Info & Metadata.
void showSongOptionsSheet(BuildContext context, Song song) {
  showModalBottomSheet(
    context: context,
    backgroundColor: Colors.transparent,
    barrierColor: Colors.black.withValues(alpha: 0.5),
    isScrollControlled: true,
    builder: (context) {
      return GlassmorphicCard(
        borderRadius: 24,
        padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Header
            Row(
              children: [
                ClipRRect(
                  borderRadius: BorderRadius.circular(8),
                  child: song.thumbnailUrl.startsWith('http')
                      ? CachedNetworkImage(
                          imageUrl: song.thumbnailUrl,
                          width: 50,
                          height: 50,
                          fit: BoxFit.cover,
                        )
                      : Image.file(
                          File(song.thumbnailUrl),
                          width: 50,
                          height: 50,
                          fit: BoxFit.cover,
                        ),
                ),
                const SizedBox(width: 16),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        song.title,
                        style: const TextStyle(
                          color: Colors.white,
                          fontWeight: FontWeight.bold,
                          fontSize: 16,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      Text(
                        song.artist,
                        style: const TextStyle(
                          color: AppColors.textSecondary,
                          fontSize: 13,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
                  ),
                ),
              ],
            ),
            const Divider(height: 32, color: AppColors.divider),

            // Option 1: Sleep Timer
            _buildOptionTile(
              icon: Icons.timer_rounded,
              title: 'Sleep Timer',
              subtitle: context.watch<PlayerProvider>().sleepAfterCurrentTrack
                  ? 'Active: stops after this song'
                  : context.watch<PlayerProvider>().sleepTimerMinutes > 0
                      ? 'Active: ${context.watch<PlayerProvider>().sleepTimerMinutes}m left'
                      : 'Not active',
              onTap: () {
                Navigator.pop(context);
                _showSleepTimerPicker(context);
              },
            ),

            // Option 2: Acoustic Equalizer Presets
            _buildOptionTile(
              icon: Icons.equalizer_rounded,
              title: 'Acoustic Sound Enhancer',
              subtitle:
                  'Preset: ${_getSoundEnhancerName(context.read<SettingsProvider>().soundEnhancer)}',
              onTap: () {
                Navigator.pop(context);
                _showSoundEnhancerPicker(context);
              },
            ),

            // Option 3: Lyrics
            _buildOptionTile(
              icon: Icons.lyrics_rounded,
              title: 'View Lyrics',
              subtitle: 'Karaoke sync mode',
              onTap: () {
                Navigator.pop(context);
                _showLyricsDialog(context, song);
              },
            ),

            // Option 3b: Parametric Equalizer (PEQ)
            _buildOptionTile(
              icon: Icons.tune_rounded,
              title: 'Parametric Equalizer (PEQ)',
              subtitle: '5-band interactive Bézier spline',
              onTap: () {
                Navigator.pop(context);
                ParametricEqView.show(context);
              },
            ),

            // Option 3c: Audiophile Signal Path
            _buildOptionTile(
              icon: Icons.stream_rounded,
              title: 'Audiophile Signal Path',
              subtitle: 'Bit-perfect DAC & stream telemetry',
              onTap: () {
                Navigator.pop(context);
                AudiophileSignalPathSheet.show(context, song);
              },
            ),

            // Option 3d: Ambient Soundscape Layer
            _buildOptionTile(
              icon: Icons.cloud_queue_rounded,
              title: 'Ambient Soundscape Layer',
              subtitle: 'Mix rain, ocean, cafe & binaural sounds',
              onTap: () {
                Navigator.pop(context);
                AmbientSoundscapeSheet.show(context);
              },
            ),

            // Option 4: Move to Album & Download Actions
            Consumer<PlayerProvider>(
              builder: (context, provider, _) {
                if (song.isLiveRadio) {
                  return _buildOptionTile(
                    icon: Icons.radio_rounded,
                    title: 'Live Radio Stream',
                    subtitle: 'Continuous broadcast (Cannot download)',
                    onTap: () {
                      Navigator.pop(context);
                      AppToast.show(
                        context,
                        'Live radio streams cannot be downloaded for offline playback',
                        type: ToastType.info,
                        icon: Icons.radio_rounded,
                      );
                    },
                  );
                }

                final isDownloaded = provider.downloadedSongs
                    .any((s) => s.videoId == song.videoId);
                final isLocalFile = song.isLocalFile ||
                    (song.filePath != null && song.filePath!.isNotEmpty && File(song.filePath!).existsSync()) ||
                    song.videoId.startsWith('/') ||
                    song.videoId.startsWith('file://') ||
                    song.videoId.startsWith('content://');
                final downloadProgress = provider.downloadProgress[song.videoId];
                final downloadStatus = provider.getDownloadStatus(song.videoId);
                final isDownloading =
                    downloadProgress != null || downloadStatus != null;

                if (isDownloading) {
                  String title = 'Downloading...';
                  String subtitle =
                      '${((downloadProgress ?? 0.0) * 100).toInt()}% completed';

                  if (downloadStatus == DownloadStatus.queued) {
                    title = 'Queued in downloads';
                    subtitle = 'Waiting for other downloads...';
                  } else if (downloadStatus == DownloadStatus.paused) {
                    title = 'Download Paused';
                    subtitle =
                        '${((downloadProgress ?? 0.0) * 100).toInt()}% completed';
                  } else if (downloadStatus == DownloadStatus.retrying) {
                    title = 'Retrying Download...';
                    subtitle = 'Please wait...';
                  }

                  return _buildOptionTile(
                    icon: downloadStatus == DownloadStatus.paused
                        ? Icons.pause_circle_outline_rounded
                        : Icons.downloading_rounded,
                    title: title,
                    subtitle: subtitle,
                    onTap: () {},
                  );
                } else if (!isLocalFile && !isDownloaded) {
                  // Online streaming audio: "Download & Move to Album" + "Download for Offline"
                  return Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      _buildOptionTile(
                        icon: Icons.create_new_folder_rounded,
                        title: 'Download & Move to Album',
                        subtitle: 'Save directly into custom or folder album',
                        onTap: () {
                          Navigator.pop(context);
                          _showAlbumSelectionSheet(context, song, isDownloadAndMove: true);
                        },
                      ),
                      _buildOptionTile(
                        icon: Icons.download_for_offline_rounded,
                        title: 'Download for Offline',
                        subtitle: 'Save to offline library',
                        onTap: () {
                          Navigator.pop(context);
                          provider.downloadSong(song, context: context);
                        },
                      ),
                    ],
                  );
                } else {
                  // Local drive music / already downloaded music: Only "Move to Album" (+ "Remove Download" if downloaded)
                  final currentAlbum = song.albumFolderName;
                  return Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      _buildOptionTile(
                        icon: Icons.drive_file_move_rounded,
                        title: 'Move to Album',
                        subtitle: currentAlbum != null && currentAlbum.isNotEmpty
                            ? 'In: $currentAlbum • Change destination'
                            : 'Organize into custom or folder album',
                        onTap: () {
                          Navigator.pop(context);
                          _showAlbumSelectionSheet(context, song, isDownloadAndMove: false);
                        },
                      ),
                      if (isDownloaded)
                        _buildOptionTile(
                          icon: Icons.delete_outline_rounded,
                          title: 'Remove Download',
                          subtitle: 'Delete from app storage',
                          onTap: () {
                            Navigator.pop(context);
                            provider.deleteDownload(song.videoId);
                          },
                        ),
                    ],
                  );
                }
              },
            ),

            // Option 5: Song Details
            _buildOptionTile(
              icon: Icons.info_outline_rounded,
              title: 'Detailed Info & Metadata',
              subtitle: 'Codec, stream source & resolutions',
              onTap: () {
                Navigator.pop(context);
                _showMetadataDialog(context, song);
              },
            ),
            const SizedBox(height: 20),
          ],
        ),
      );
    },
  );
}

Widget _buildOptionTile({
  required IconData icon,
  required String title,
  required String subtitle,
  required VoidCallback onTap,
}) {
  return ListTile(
    leading: Container(
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.05),
        shape: BoxShape.circle,
      ),
      child: Icon(icon, color: Colors.white, size: 20),
    ),
    title: Text(
      title,
      style: const TextStyle(
          color: Colors.white, fontSize: 15, fontWeight: FontWeight.w600),
    ),
    subtitle: Text(
      subtitle,
      style: const TextStyle(color: AppColors.textTertiary, fontSize: 12),
    ),
    trailing:
        const Icon(Icons.chevron_right_rounded, color: AppColors.textTertiary),
    contentPadding: EdgeInsets.zero,
    onTap: onTap,
  );
}

void _showSleepTimerPicker(BuildContext context) {
  final playerProvider = context.read<PlayerProvider>();
  double customMinutes = playerProvider.sleepTimerMinutes > 0
      ? playerProvider.sleepTimerMinutes.toDouble()
      : 30.0;

  showModalBottomSheet(
    context: context,
    backgroundColor: AppColors.surface,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
    ),
    builder: (context) {
      return StatefulBuilder(
        builder: (context, setModalState) {
          final activeMinutes = context.watch<PlayerProvider>().sleepTimerMinutes;

          return Container(
            padding: EdgeInsets.only(
              left: 24,
              right: 24,
              top: 24,
              bottom: 24 + MediaQuery.of(context).padding.bottom,
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Header
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text(
                      'Sleep Timer',
                      style: GoogleFonts.outfit(
                        fontSize: 22,
                        fontWeight: FontWeight.bold,
                        color: Colors.white,
                      ),
                    ),
                    if (activeMinutes > 0)
                      Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 10, vertical: 4),
                        decoration: BoxDecoration(
                          color: Theme.of(context)
                              .colorScheme
                              .primary
                              .withValues(alpha: 0.15),
                          borderRadius: BorderRadius.circular(20),
                        ),
                        child: Text(
                          'Active: ${activeMinutes}m left',
                          style: GoogleFonts.inter(
                            fontSize: 12,
                            color: Theme.of(context).colorScheme.primaryLight,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ),
                  ],
                ),
                const SizedBox(height: 8),
                Text(
                  'Fade out volume and stop playback automatically.',
                  style: GoogleFonts.inter(
                    fontSize: 13,
                    color: AppColors.textSecondary,
                  ),
                ),
                const SizedBox(height: 20),

                // "End of track" mode — stop when the current song finishes
                Consumer<PlayerProvider>(
                  builder: (context, provider, _) {
                    final active = provider.sleepAfterCurrentTrack;
                    return GestureDetector(
                      onTap: () {
                        setModalState(() {
                          provider.setSleepAfterCurrentTrack(!active);
                        });
                      },
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 14, vertical: 12),
                        decoration: BoxDecoration(
                          color: active
                              ? Theme.of(context)
                                  .colorScheme
                                  .primary
                                  .withValues(alpha: 0.12)
                              : AppColors.surfaceLight,
                          borderRadius: BorderRadius.circular(14),
                          border: Border.all(
                            color: active
                                ? Theme.of(context).colorScheme.primary
                                : Colors.transparent,
                            width: 1.5,
                          ),
                        ),
                        child: Row(
                          children: [
                            Icon(
                              Icons.music_off_rounded,
                              size: 20,
                              color: active
                                  ? Theme.of(context).colorScheme.primaryLight
                                  : Colors.white54,
                            ),
                            const SizedBox(width: 12),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    'Stop at end of track',
                                    style: GoogleFonts.inter(
                                      fontSize: 14,
                                      fontWeight: FontWeight.w600,
                                      color: active
                                          ? Theme.of(context)
                                              .colorScheme
                                              .primaryLight
                                          : Colors.white,
                                    ),
                                  ),
                                  Text(
                                    'Finish the current song, then pause',
                                    style: GoogleFonts.inter(
                                      fontSize: 11,
                                      color: AppColors.textTertiary,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            Switch(
                              value: active,
                              activeThumbColor:
                                  Theme.of(context).colorScheme.primary,
                              onChanged: (v) {
                                setModalState(() {
                                  provider.setSleepAfterCurrentTrack(v);
                                });
                              },
                            ),
                          ],
                        ),
                      ),
                    );
                  },
                ),
                const SizedBox(height: 20),

                // Quick presets row
                Text(
                  'QUICK PRESETS',
                  style: GoogleFonts.inter(
                    fontSize: 11,
                    fontWeight: FontWeight.w800,
                    color: AppColors.textTertiary,
                    letterSpacing: 1.0,
                  ),
                ),
                const SizedBox(height: 12),
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    _buildPresetChip(context, 'Off', 0, playerProvider,
                        setModalState, () {
                      customMinutes = 30.0;
                    }),
                    _buildPresetChip(context, '15m', 15, playerProvider,
                        setModalState, () {
                      customMinutes = 15.0;
                    }),
                    _buildPresetChip(context, '30m', 30, playerProvider,
                        setModalState, () {
                      customMinutes = 30.0;
                    }),
                    _buildPresetChip(context, '45m', 45, playerProvider,
                        setModalState, () {
                      customMinutes = 45.0;
                    }),
                    _buildPresetChip(context, '60m', 60, playerProvider,
                        setModalState, () {
                      customMinutes = 60.0;
                    }),
                  ],
                ),
                const SizedBox(height: 28),

                // Slider area for custom time
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text(
                      'CUSTOM DURATION',
                      style: GoogleFonts.inter(
                        fontSize: 11,
                        fontWeight: FontWeight.w800,
                        color: AppColors.textTertiary,
                        letterSpacing: 1.0,
                      ),
                    ),
                    Text(
                      '${customMinutes.round()} mins',
                      style: GoogleFonts.outfit(
                        fontSize: 16,
                        fontWeight: FontWeight.bold,
                        color: Theme.of(context).colorScheme.primaryLight,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                SliderTheme(
                  data: SliderTheme.of(context).copyWith(
                    activeTrackColor: Theme.of(context).colorScheme.primary,
                    inactiveTrackColor: AppColors.surfaceLight,
                    thumbColor: Colors.white,
                    overlayColor: Theme.of(context)
                        .colorScheme
                        .primary
                        .withValues(alpha: 0.2),
                    valueIndicatorColor: Theme.of(context).colorScheme.primary,
                    valueIndicatorTextStyle:
                        const TextStyle(color: Colors.white),
                  ),
                  child: Slider(
                    value: customMinutes,
                    min: 1.0,
                    max: 120.0,
                    divisions: 119,
                    label: '${customMinutes.round()}m',
                    onChanged: (val) {
                      setModalState(() {
                        customMinutes = val;
                      });
                    },
                  ),
                ),
                const SizedBox(height: 24),

                // Set Timer Button
                GestureDetector(
                  onTap: () {
                    final mins = customMinutes.round();
                    playerProvider.setSleepTimer(mins);
                    Navigator.pop(context);
                    AppToast.show(
                      context,
                      'Sleep timer set for $mins minutes',
                      type: ToastType.info,
                      icon: Icons.timer_rounded,
                    );
                  },
                  child: Builder(builder: (context) {
                    final settings =
                        Provider.of<SettingsProvider>(context, listen: false);
                    return Container(
                      width: double.infinity,
                      padding: const EdgeInsets.symmetric(vertical: 14),
                      decoration: BoxDecoration(
                        gradient: settings.accentGradient,
                        borderRadius: BorderRadius.circular(12),
                        boxShadow: [
                          BoxShadow(
                            color:
                                settings.accentColor.withValues(alpha: 0.3),
                            blurRadius: 12,
                            offset: const Offset(0, 4),
                          ),
                        ],
                      ),
                      alignment: Alignment.center,
                      child: Text(
                        'Apply Sleep Timer',
                        style: GoogleFonts.inter(
                          fontSize: 15,
                          fontWeight: FontWeight.bold,
                          color: Colors.white,
                        ),
                      ),
                    );
                  }),
                ),
              ],
            ),
          );
        },
      );
    },
  );
}

Widget _buildPresetChip(
  BuildContext context,
  String label,
  int minutes,
  PlayerProvider provider,
  StateSetter setModalState,
  VoidCallback onSelect,
) {
  final isSelected = provider.sleepTimerMinutes == minutes;
  return GestureDetector(
    onTap: () {
      setModalState(() {
        provider.setSleepTimer(minutes);
        onSelect();
      });
    },
    child: Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
      decoration: BoxDecoration(
        color: isSelected
            ? Theme.of(context).colorScheme.primary.withValues(alpha: 0.15)
            : AppColors.surfaceLight,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(
          color: isSelected
              ? Theme.of(context).colorScheme.primary
              : Colors.transparent,
          width: 1.5,
        ),
      ),
      child: Text(
        label,
        style: GoogleFonts.inter(
          fontSize: 13,
          fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
          color: isSelected
              ? Theme.of(context).colorScheme.primaryLight
              : Colors.white70,
        ),
      ),
    ),
  );
}

void _showSoundEnhancerPicker(BuildContext context) {
  Navigator.push(
    context,
    MaterialPageRoute(builder: (_) => const SoundStudioScreen()),
  );
}

String _getSoundEnhancerName(SoundEnhancer enhancer) {
  switch (enhancer) {
    case SoundEnhancer.none:
      return 'Off';
    case SoundEnhancer.bassBoost:
      return 'Bass Boost';
    case SoundEnhancer.trebleBoost:
      return 'Treble Boost';
    case SoundEnhancer.vocal:
      return 'Vocal';
    case SoundEnhancer.ambient3d:
      return '3D Surround';
    case SoundEnhancer.electronic:
      return 'Electronic';
    case SoundEnhancer.rockMetal:
      return 'Rock / Metal';
    case SoundEnhancer.hipHop:
      return 'Hip-Hop';
    case SoundEnhancer.pop:
      return 'Pop';
    case SoundEnhancer.acoustic:
      return 'Acoustic';
    case SoundEnhancer.jazzBlues:
      return 'Jazz / Blues';
    case SoundEnhancer.nightMode:
      return 'Night Mode';
  }
}

void _showLyricsDialog(BuildContext context, Song song) {
  final playerProvider = context.read<PlayerProvider>();
  final lyricsFuture = LyricsService().getLyricsForSong(song);
  final ScrollController lyricScrollController = ScrollController();

  showModalBottomSheet(
    context: context,
    backgroundColor: Colors.transparent,
    barrierColor: Colors.black.withValues(alpha: 0.7),
    isScrollControlled: true,
    builder: (context) {
      final screenHeight = MediaQuery.of(context).size.height;
      int lastActiveIndex = -1;

      return StatefulBuilder(
        builder: (context, setModalState) {
          return GlassmorphicCard(
            borderRadius: 24,
            height: screenHeight * 0.75,
            padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 20),
            child: Column(
              children: [
                // Header indicator
                Center(
                  child: Container(
                    width: 40,
                    height: 4,
                    decoration: BoxDecoration(
                      color: Colors.white24,
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                ),
                const SizedBox(height: 16),

                // Karaoke Toggle & Title
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    const SizedBox(width: 48), // Spacer to balance the right icon
                    Expanded(
                      child: Column(
                        children: [
                          Text(
                            song.title,
                            style: const TextStyle(
                                color: Colors.white,
                                fontWeight: FontWeight.bold,
                                fontSize: 18),
                            textAlign: TextAlign.center,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                          Text(
                            song.artist,
                            style: const TextStyle(
                                color: AppColors.textTertiary, fontSize: 13),
                            textAlign: TextAlign.center,
                          ),
                        ],
                      ),
                    ),
                    IconButton(
                      onPressed: () {
                        setModalState(() {
                          playerProvider.toggleKaraokeMode();
                        });
                      },
                      icon: Icon(
                        playerProvider.isKaraokeMode
                            ? Icons.mic_rounded
                            : Icons.mic_external_off_rounded,
                        color: playerProvider.isKaraokeMode
                            ? Theme.of(context).colorScheme.primary
                            : Colors.white38,
                        size: 22,
                      ),
                      tooltip: 'Karaoke Vocal Attenuator',
                    ),
                  ],
                ),
                const SizedBox(height: 10),

                // Animated Equalizer to show live state
                StreamBuilder<bool>(
                  stream: playerProvider.playingStream,
                  builder: (context, playingSnapshot) {
                    final isPlaying = playingSnapshot.data ?? false;
                    return AnimatedEqualizer(
                      isPlaying: isPlaying,
                      height: 14,
                      barWidth: 2.5,
                      barCount: 5,
                      color: Theme.of(context).colorScheme.primary,
                    );
                  },
                ),
                const Divider(height: 24, color: AppColors.divider),

                // Scrolling Lyrics list
                Expanded(
                  child: FutureBuilder<List<LyricEntry>>(
                    future: lyricsFuture,
                    builder: (context, lyricsSnapshot) {
                      if (lyricsSnapshot.connectionState ==
                          ConnectionState.waiting) {
                        return const Center(
                          child: CircularProgressIndicator(),
                        );
                      }
                      if (lyricsSnapshot.hasError ||
                          !lyricsSnapshot.hasData ||
                          lyricsSnapshot.data!.isEmpty) {
                        return const Center(
                          child: Text(
                            'Could not load lyrics',
                            style: TextStyle(color: AppColors.textTertiary),
                          ),
                        );
                      }
                      final lyricEntries = lyricsSnapshot.data!;

                      return StreamBuilder<Duration>(
                        stream: playerProvider.positionStream,
                        builder: (context, positionSnapshot) {
                          final position =
                              positionSnapshot.data ?? Duration.zero;

                          // Determine active index
                          int activeIndex = -1;
                          for (int i = 0; i < lyricEntries.length; i++) {
                            if (position >= lyricEntries[i].time) {
                              activeIndex = i;
                            } else {
                              break;
                            }
                          }

                          // Auto-scroll to active lyric only when index changes
                          if (activeIndex != -1 &&
                              activeIndex != lastActiveIndex &&
                              lyricScrollController.hasClients) {
                            lastActiveIndex = activeIndex;
                            WidgetsBinding.instance.addPostFrameCallback((_) {
                              if (lyricScrollController.hasClients) {
                                lyricScrollController.animateTo(
                                  (activeIndex * 55.0) - (screenHeight * 0.25),
                                  duration: const Duration(milliseconds: 300),
                                  curve: Curves.easeOut,
                                );
                              }
                            });
                          }

                          return ListView.builder(
                            controller: lyricScrollController,
                            physics: const BouncingScrollPhysics(),
                            itemCount: lyricEntries.length,
                            itemBuilder: (context, index) {
                              final isPassed = index < activeIndex;
                              final isActive = index == activeIndex;

                              return AnimatedOpacity(
                                duration: const Duration(milliseconds: 300),
                                opacity:
                                    isActive ? 1.0 : (isPassed ? 0.4 : 0.25),
                                child: GestureDetector(
                                  onTap: () {
                                    playerProvider
                                        .seek(lyricEntries[index].time);
                                  },
                                  child: Container(
                                    height: 55,
                                    alignment: Alignment.center,
                                    padding: const EdgeInsets.symmetric(
                                        vertical: 4),
                                    child: Text(
                                      lyricEntries[index].text,
                                      style: TextStyle(
                                        color: isActive
                                            ? Theme.of(context)
                                                .colorScheme
                                                .primary
                                            : Colors.white,
                                        fontSize: isActive ? 18 : 15,
                                        fontWeight: isActive
                                            ? FontWeight.bold
                                            : FontWeight.w500,
                                        shadows: isActive
                                            ? [
                                                Shadow(
                                                  color: Theme.of(context)
                                                      .colorScheme
                                                      .primary
                                                      .withValues(alpha: 0.6),
                                                  blurRadius: 10,
                                                )
                                              ]
                                            : null,
                                      ),
                                      textAlign: TextAlign.center,
                                    ),
                                  ),
                                ),
                              );
                            },
                          );
                        },
                      );
                    },
                  ),
                ),

                const SizedBox(height: 10),
                const Text(
                  'Lyrics synced perfectly with SonicWave Karaoke',
                  style: TextStyle(
                      color: Colors.white38,
                      fontSize: 10,
                      fontStyle: FontStyle.italic),
                ),
                const SizedBox(height: 10),
              ],
            ),
          );
        },
      );
    },
  );
}

void _showMetadataDialog(BuildContext context, Song song) {
  showDialog(
    context: context,
    builder: (context) {
      return AlertDialog(
        backgroundColor: AppColors.surface,
        title:
            const Text('Song Metadata', style: TextStyle(color: Colors.white)),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _buildMetaRow('Title', song.title),
            _buildMetaRow('Artist', song.artist),
            _buildMetaRow('Video ID', song.videoId),
            _buildMetaRow('Duration', _formatDuration(song.duration)),
            _buildMetaRow('Stream Source', 'YouTube (Ad-Free)'),
            _buildMetaRow('Bitrate', '128 kbps (AAC/Opus)'),
            _buildMetaRow('Service Pipeline', 'just_audio / audio_service'),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Close'),
          ),
        ],
      );
    },
  );
}

Widget _buildMetaRow(String label, String value) {
  return Padding(
    padding: const EdgeInsets.symmetric(vertical: 6.0),
    child: RichText(
      text: TextSpan(
        children: [
          TextSpan(
            text: '$label: ',
            style: const TextStyle(
                color: AppColors.textTertiary,
                fontWeight: FontWeight.bold,
                fontSize: 13),
          ),
          TextSpan(
            text: value,
            style: const TextStyle(color: Colors.white70, fontSize: 13),
          ),
        ],
      ),
    ),
  );
}

String _formatDuration(Duration duration) {
  final minutes = duration.inMinutes;
  final seconds = duration.inSeconds % 60;
  return '$minutes:${seconds.toString().padLeft(2, '0')}';
}

/// Dynamic Album Picker sheet allowing the user to select an existing album
/// or create a new one on-the-fly to download/move the song into.
void _showAlbumSelectionSheet(
  BuildContext context,
  Song song, {
  required bool isDownloadAndMove,
}) {
  showModalBottomSheet(
    context: context,
    backgroundColor: Colors.transparent,
    barrierColor: Colors.black.withValues(alpha: 0.6),
    isScrollControlled: true,
    builder: (ctx) {
      return Consumer<PlayerProvider>(
        builder: (context, provider, _) {
          final albums = provider.albums;
          final primaryColor = Theme.of(context).colorScheme.primary;

          return GlassmorphicCard(
            borderRadius: 24,
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
            child: SafeArea(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // Drag Handle
                  Center(
                    child: Container(
                      width: 40,
                      height: 4,
                      decoration: BoxDecoration(
                        color: AppColors.textTertiary.withValues(alpha: 0.3),
                        borderRadius: BorderRadius.circular(2),
                      ),
                    ),
                  ),
                  const SizedBox(height: 16),

                  // Header
                  Row(
                    children: [
                      Container(
                        padding: const EdgeInsets.all(10),
                        decoration: BoxDecoration(
                          color: primaryColor.withValues(alpha: 0.15),
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: Icon(
                          isDownloadAndMove
                              ? Icons.create_new_folder_rounded
                              : Icons.drive_file_move_rounded,
                          color: primaryColor,
                          size: 22,
                        ),
                      ),
                      const SizedBox(width: 14),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              isDownloadAndMove
                                  ? 'Download & Move to Album'
                                  : 'Move to Album',
                              style: GoogleFonts.outfit(
                                fontSize: 18,
                                fontWeight: FontWeight.bold,
                                color: Colors.white,
                              ),
                            ),
                            Text(
                              song.title,
                              style: const TextStyle(
                                fontSize: 12,
                                color: AppColors.textSecondary,
                              ),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 14),
                  const Divider(height: 1, color: AppColors.divider),
                  const SizedBox(height: 12),

                  // "+ Create New Album" Action Tile
                  Material(
                    color: Colors.transparent,
                    child: InkWell(
                      borderRadius: BorderRadius.circular(14),
                      onTap: () {
                        Navigator.pop(ctx);
                        _showCreateAlbumDialog(
                          context,
                          song,
                          isDownloadAndMove: isDownloadAndMove,
                        );
                      },
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 14,
                          vertical: 12,
                        ),
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(14),
                          border: Border.all(
                            color: primaryColor.withValues(alpha: 0.4),
                            width: 1.2,
                          ),
                          color: primaryColor.withValues(alpha: 0.08),
                        ),
                        child: Row(
                          children: [
                            Icon(
                              Icons.add_circle_outline_rounded,
                              color: primaryColor,
                              size: 22,
                            ),
                            const SizedBox(width: 12),
                            Text(
                              'Create New Album',
                              style: GoogleFonts.inter(
                                fontSize: 14,
                                fontWeight: FontWeight.w600,
                                color: Colors.white,
                              ),
                            ),
                            const Spacer(),
                            Icon(
                              Icons.chevron_right_rounded,
                              color: primaryColor.withValues(alpha: 0.7),
                              size: 18,
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: 12),

                  // Album List
                  if (albums.isEmpty)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 24),
                      child: Center(
                        child: Text(
                          'No existing albums. Create one above!',
                          style: GoogleFonts.inter(
                            fontSize: 13,
                            color: AppColors.textTertiary,
                          ),
                        ),
                      ),
                    )
                  else
                    ConstrainedBox(
                      constraints: BoxConstraints(
                        maxHeight: MediaQuery.of(context).size.height * 0.42,
                      ),
                      child: ListView.separated(
                        shrinkWrap: true,
                        itemCount: albums.length,
                        separatorBuilder: (ctx, i) => const SizedBox(height: 6),
                        itemBuilder: (context, index) {
                          final album = albums[index];
                          final isCurrentAlbum =
                              song.albumFolderName == album.name;

                          return Material(
                            color: Colors.transparent,
                            child: ListTile(
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(12),
                              ),
                              tileColor: isCurrentAlbum
                                  ? primaryColor.withValues(alpha: 0.1)
                                  : AppColors.surfaceLight.withValues(
                                      alpha: 0.5,
                                    ),
                              contentPadding: const EdgeInsets.symmetric(
                                horizontal: 12,
                                vertical: 4,
                              ),
                              leading: ClipRRect(
                                borderRadius: BorderRadius.circular(8),
                                child: Container(
                                  width: 44,
                                  height: 44,
                                  color: AppColors.surfaceLight,
                                  child: album.coverImagePath != null &&
                                          File(album.coverImagePath!).existsSync()
                                      ? Image.file(
                                          File(album.coverImagePath!),
                                          fit: BoxFit.cover,
                                        )
                                      : Center(
                                          child: Icon(
                                            album.isFolderBased
                                                ? Icons.folder_rounded
                                                : Icons.album_rounded,
                                            color: album.isFolderBased
                                                ? Colors.amberAccent
                                                : primaryColor,
                                            size: 22,
                                          ),
                                        ),
                                ),
                              ),
                              title: Text(
                                album.name,
                                style: GoogleFonts.inter(
                                  fontSize: 14,
                                  fontWeight: FontWeight.w600,
                                  color: Colors.white,
                                ),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                              subtitle: Text(
                                '${album.songCount} songs • ${album.isFolderBased ? "Folder Album" : "Custom Album"}',
                                style: const TextStyle(
                                  fontSize: 11,
                                  color: AppColors.textTertiary,
                                ),
                              ),
                              trailing: isCurrentAlbum
                                  ? Icon(
                                      Icons.check_circle_rounded,
                                      color: primaryColor,
                                      size: 20,
                                    )
                                  : const Icon(
                                      Icons.arrow_forward_ios_rounded,
                                      color: AppColors.textTertiary,
                                      size: 14,
                                    ),
                              onTap: () async {
                                 Navigator.pop(ctx);
                                 if (isDownloadAndMove) {
                                   provider.downloadAndAddToAlbum(
                                     song,
                                     album.id,
                                     context: context,
                                   );
                                 } else {
                                   // Local or downloaded file move/copy/bookmark
                                   final sourcePath = song.filePath ?? (song.isLocalFile ? song.videoId : null);
                                   final hasLocalFile = sourcePath != null && File(sourcePath).existsSync();

                                   if (hasLocalFile) {
                                     final op = await showStorageOperationDialog(context);
                                     if (op == null) return;

                                     final success = await provider.moveSongToAnotherAlbumFolder(
                                       song,
                                       album.id,
                                       physicalMove: op.physicalMove,
                                       isCopyMode: op.isCopyMode,
                                     );
                                     if (context.mounted) {
                                       final label = op.isCopyMode
                                           ? 'Copied to "${album.name}"'
                                           : (op.physicalMove
                                               ? 'Moved to "${album.name}"'
                                               : 'Added to "${album.name}"');
                                       AppToast.show(
                                         context,
                                         success ? label : 'Failed operation for "${album.name}"',
                                         type: success ? ToastType.success : ToastType.error,
                                         icon: Icons.album_rounded,
                                       );
                                     }
                                   } else {
                                     await provider.addSongToAlbum(
                                       album.id,
                                       song,
                                     );
                                     if (context.mounted) {
                                       AppToast.show(
                                         context,
                                         'Added "${song.title}" to "${album.name}"',
                                         type: ToastType.success,
                                         icon: Icons.album_rounded,
                                       );
                                     }
                                   }
                                 }
                               },
                            ),
                          );
                        },
                      ),
                    ),
                  const SizedBox(height: 10),
                ],
              ),
            ),
          );
        },
      );
    },
  );
}

void _showCreateAlbumDialog(
  BuildContext context,
  Song song, {
  required bool isDownloadAndMove,
}) {
  final textController = TextEditingController();
  final primaryColor = Theme.of(context).colorScheme.primary;

  showDialog(
    context: context,
    builder: (dialogCtx) {
      return AlertDialog(
        backgroundColor: AppColors.surface,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: Row(
          children: [
            Icon(
              Icons.create_new_folder_rounded,
              color: primaryColor,
              size: 24,
            ),
            const SizedBox(width: 10),
            Text(
              'New Album',
              style: GoogleFonts.outfit(
                fontSize: 18,
                fontWeight: FontWeight.bold,
                color: Colors.white,
              ),
            ),
          ],
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              isDownloadAndMove
                  ? 'Create an album to download "${song.title}" into:'
                  : 'Create an album to move "${song.title}" into:',
              style: const TextStyle(
                fontSize: 13,
                color: AppColors.textSecondary,
              ),
            ),
            const SizedBox(height: 14),
            TextField(
              controller: textController,
              autofocus: true,
              style: const TextStyle(color: Colors.white, fontSize: 15),
              decoration: InputDecoration(
                hintText: 'Album name',
                hintStyle: const TextStyle(color: AppColors.textTertiary),
                filled: true,
                fillColor: AppColors.surfaceLight,
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide: BorderSide.none,
                ),
                contentPadding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 12,
                ),
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogCtx),
            child: const Text(
              'Cancel',
              style: TextStyle(color: AppColors.textTertiary),
            ),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
              backgroundColor: primaryColor,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12),
              ),
            ),
            onPressed: () async {
              final name = textController.text.trim();
              if (name.isEmpty) return;
              final provider = context.read<PlayerProvider>();
              if (provider.isAlbumNameReserved(name)) {
                AppToast.show(
                  context,
                  '"$name" is a reserved system name and cannot be used.',
                  type: ToastType.error,
                  icon: Icons.block_rounded,
                );
                return;
              }
              if (provider.isAlbumNameDuplicate(name)) {
                AppToast.show(
                  context,
                  'An album named "$name" already exists.',
                  type: ToastType.error,
                  icon: Icons.warning_amber_rounded,
                );
                return;
              }
              Navigator.pop(dialogCtx);
              if (isDownloadAndMove) {
                final newAlbum = await provider.createAlbum(name);
                if (!context.mounted) return;
                provider.downloadAndAddToAlbum(
                  song,
                  newAlbum.id,
                  context: context,
                );
              } else {
                final sourcePath = song.filePath ?? (song.isLocalFile ? song.videoId : null);
                final hasLocalFile = sourcePath != null && File(sourcePath).existsSync();

                if (hasLocalFile) {
                  final op = await showStorageOperationDialog(context);
                  if (op == null) return;

                  final newAlbum = await provider.createAlbum(name);
                  final success = await provider.moveSongToAnotherAlbumFolder(
                    song,
                    newAlbum.id,
                    physicalMove: op.physicalMove,
                    isCopyMode: op.isCopyMode,
                  );
                  if (context.mounted) {
                    final label = op.isCopyMode
                        ? 'Created folder & copied to "$name"'
                        : (op.physicalMove
                            ? 'Created folder & moved to "$name"'
                            : 'Created album "$name"');
                    AppToast.show(
                      context,
                      success ? label : 'Failed operation for "$name"',
                      type: success ? ToastType.success : ToastType.error,
                      icon: Icons.album_rounded,
                    );
                  }
                } else {
                  final newAlbum = await provider.createAlbum(name);
                  await provider.addSongToAlbum(newAlbum.id, song);
                  if (context.mounted) {
                    AppToast.show(
                      context,
                      'Created album "$name"',
                      type: ToastType.success,
                      icon: Icons.album_rounded,
                    );
                  }
                }
              }
            },
            child: const Text(
              'Create & Move',
              style: TextStyle(
                color: Colors.white,
                fontWeight: FontWeight.bold,
              ),
            ),
          ),
        ],
      );
    },
  );
}
