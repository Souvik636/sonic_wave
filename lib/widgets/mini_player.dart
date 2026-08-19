import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:just_audio/just_audio.dart';
import 'package:audio_service/audio_service.dart';
import '../models/song.dart';
import '../providers/player_provider.dart';
import '../providers/settings_provider.dart';
import '../screens/player_screen.dart';
import '../screens/aurora_player_screen.dart';
import 'song_album_art.dart';
import 'premium_interaction.dart';
import 'shared_link_download_card.dart';
import '../theme/app_colors.dart';

/// Premium, interactive MiniPlayer widget with glassmorphism, smooth animations,
/// reactive audio visualizer waves, expandable control panel, and Samsung One UI
/// style swipeable multi-card deck supporting shared downloads.
class MiniPlayer extends StatefulWidget {
  const MiniPlayer({super.key});

  @override
  State<MiniPlayer> createState() => _MiniPlayerState();
}

class _MiniPlayerState extends State<MiniPlayer> with TickerProviderStateMixin {
  late AnimationController _slideController;
  late Animation<Offset> _slideAnimation;
  late AnimationController _deckSwapController;
  bool _isExpanded = false;
  bool _pressed = false;
  int _activeDeckIndex = 0; // 0 = Now Playing, 1 = Shared Download
  double _verticalDragOffset = 0.0;
  double _horizontalDragOffset = 0.0;
  SharedDownloadPhase? _lastSeenDownloadPhase;

  @override
  void initState() {
    super.initState();
    _slideController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 400),
    );
    _slideAnimation = Tween<Offset>(
      begin: const Offset(0, 1),
      end: Offset.zero,
    ).animate(CurvedAnimation(
      parent: _slideController,
      curve: Curves.easeOutCubic,
    ));
    _slideController.forward();

    _deckSwapController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 280),
    );
  }

  @override
  void dispose() {
    _slideController.dispose();
    _deckSwapController.dispose();
    super.dispose();
  }

  String _formatDuration(Duration d) {
    final minutes = d.inMinutes.remainder(60).toString().padLeft(2, '0');
    final seconds = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    return '$minutes:$seconds';
  }

  void _openFullPlayer() {
    AppHaptics.light();
    final style = Provider.of<SettingsProvider>(context, listen: false).playerStyle;
    final Widget screen = style == 'aurora'
        ? const AuroraPlayerScreen()
        : const PlayerScreen();
    Navigator.of(context).push(
      PageRouteBuilder(
        pageBuilder: (context, animation, secondaryAnimation) => screen,
        transitionsBuilder: (context, animation, secondaryAnimation, child) {
          return FadeTransition(
            opacity: animation,
            child: child,
          );
        },
        transitionDuration: const Duration(milliseconds: 350),
      ),
    );
  }

  void _swapDeck() {
    AppHaptics.selection();
    _deckSwapController.forward(from: 0.0);
    setState(() {
      _activeDeckIndex = 1 - _activeDeckIndex;
      _verticalDragOffset = 0.0;
    });
  }

  @override
  Widget build(BuildContext context) {
    final primaryColor = Theme.of(context).colorScheme.primary;

    return Consumer<PlayerProvider>(
      builder: (context, playerProvider, _) {
        final song = playerProvider.currentSong ?? playerProvider.loadingSong;
        final sharedDownload = playerProvider.sharedDownload;

        if (song == null && sharedDownload == null) {
          return const SizedBox.shrink();
        }

        // Automatically flip to download card when a new download starts/changes
        if (sharedDownload != null &&
            sharedDownload.phase != _lastSeenDownloadPhase) {
          _lastSeenDownloadPhase = sharedDownload.phase;
          if (sharedDownload.phase == SharedDownloadPhase.resolving ||
              sharedDownload.phase == SharedDownloadPhase.downloading) {
            _activeDeckIndex = 1;
          }
        }
        if (sharedDownload == null && _activeDeckIndex == 1) {
          _activeDeckIndex = 0;
          _lastSeenDownloadPhase = null;
        }

        final isDualMode = song != null && sharedDownload != null;
        final activeIndex = isDualMode ? _activeDeckIndex : (song != null ? 0 : 1);

        return SlideTransition(
          position: _slideAnimation,
          child: GestureDetector(
            onHorizontalDragStart: (_) {
              setState(() => _horizontalDragOffset = 0.0);
            },
            onHorizontalDragUpdate: (details) {
              if (activeIndex == 0 && details.primaryDelta != null) {
                setState(() {
                  _horizontalDragOffset = (_horizontalDragOffset + details.primaryDelta!).clamp(-90.0, 90.0);
                });
              }
            },
            onHorizontalDragEnd: (details) {
              if (activeIndex == 0) {
                final vel = details.primaryVelocity ?? 0;
                if (_horizontalDragOffset < -35 || vel < -180) {
                  // Swiped Left -> Skip Next
                  AppHaptics.medium();
                  playerProvider.skipNext();
                } else if (_horizontalDragOffset > 35 || vel > 180) {
                  // Swiped Right -> Skip Previous
                  AppHaptics.medium();
                  playerProvider.skipPrevious();
                }
                setState(() => _horizontalDragOffset = 0.0);
              }
            },
            onVerticalDragStart: (_) {
              if (isDualMode) {
                setState(() => _verticalDragOffset = 0.0);
              }
            },
            onVerticalDragUpdate: (details) {
              if (isDualMode) {
                setState(() {
                  _verticalDragOffset += details.primaryDelta!;
                });
                return;
              }
              if (details.primaryDelta! < -6 && !_isExpanded) {
                setState(() => _isExpanded = true);
                AppHaptics.selection();
              } else if (details.primaryDelta! > 6 && _isExpanded) {
                setState(() => _isExpanded = false);
                AppHaptics.selection();
              }
            },
            onVerticalDragEnd: (details) {
              if (isDualMode) {
                final vel = details.primaryVelocity ?? 0;
                if (_verticalDragOffset.abs() > 20 || vel.abs() > 120) {
                  _swapDeck();
                } else {
                  setState(() => _verticalDragOffset = 0.0);
                }
              }
            },
            onDoubleTap: activeIndex == 0
                ? () {
                    AppHaptics.light();
                    playerProvider.togglePlayPause();
                  }
                : null,
            onTapDown: (_) => setState(() => _pressed = true),
            onTapUp: (_) => setState(() => _pressed = false),
            onTapCancel: () => setState(() => _pressed = false),
            onTap: activeIndex == 0 ? _openFullPlayer : null,
            child: AnimatedScale(
              scale: _pressed ? 0.985 : 1.0,
              duration: const Duration(milliseconds: 120),
              curve: Curves.easeOut,
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 300),
                curve: Curves.easeOutCubic,
                margin: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                child: isDualMode
                    ? Stack(
                        clipBehavior: Clip.none,
                        children: [
                          // Back Peek Card (Samsung Wallet / Nav bar style)
                          Positioned(
                            top: -6,
                            left: 12,
                            right: 12,
                            height: 60,
                            child: GestureDetector(
                              onTap: _swapDeck,
                              child: Container(
                                decoration: BoxDecoration(
                                  color: AppColors.surface.withValues(alpha: 0.60),
                                  borderRadius: BorderRadius.circular(16),
                                  border: Border.all(
                                    color: (activeIndex == 0
                                            ? AppColors.primary
                                            : primaryColor)
                                        .withValues(alpha: 0.25),
                                    width: 0.8,
                                  ),
                                ),
                              ),
                            ),
                          ),
                          // Front Active Card with smooth swipe translation
                          Transform.translate(
                            offset: Offset(0, _verticalDragOffset.clamp(-30.0, 30.0)),
                            child: AnimatedSwitcher(
                              duration: const Duration(milliseconds: 300),
                              switchInCurve: Curves.easeOutCubic,
                              switchOutCurve: Curves.easeInCubic,
                              transitionBuilder: (child, animation) {
                                return SlideTransition(
                                  position: Tween<Offset>(
                                    begin: const Offset(0, 0.25),
                                    end: Offset.zero,
                                  ).animate(animation),
                                  child: FadeTransition(
                                    opacity: animation,
                                    child: ScaleTransition(
                                      scale: Tween<double>(begin: 0.95, end: 1.0)
                                          .animate(animation),
                                      child: child,
                                    ),
                                  ),
                                );
                              },
                              child: activeIndex == 0
                                  ? KeyedSubtree(
                                      key: const ValueKey('deck_now_playing'),
                                      child: _buildNowPlayingContent(
                                        context,
                                        song,
                                        playerProvider,
                                        primaryColor,
                                        isDualMode: true,
                                      ),
                                    )
                                  : KeyedSubtree(
                                      key: const ValueKey('deck_shared_download'),
                                      child: SharedDownloadCardSurface(
                                        status: sharedDownload,
                                        isDeckMode: true,
                                        onToggleDeck: _swapDeck,
                                        activeIndex: _activeDeckIndex,
                                      ),
                                    ),
                            ),
                          ),
                        ],
                      )
                    : (song != null
                        ? Transform.translate(
                            offset: Offset(_horizontalDragOffset, 0),
                            child: _buildNowPlayingContent(
                              context,
                              song,
                              playerProvider,
                              primaryColor,
                              isDualMode: false,
                            ),
                          )
                        : SharedDownloadCardSurface(
                            status: sharedDownload!,
                            isDeckMode: false,
                          )),
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _buildNowPlayingContent(
    BuildContext context,
    Song song,
    PlayerProvider playerProvider,
    Color primaryColor, {
    required bool isDualMode,
  }) {
    final isLoading = playerProvider.isBuffering || playerProvider.loadingSong != null;
    final isPlaying = playerProvider.isPlaying;
    final isFav = playerProvider.isFavorite(song.videoId);

    // Find next song in queue if available
    Song? nextSong;
    if (playerProvider.playlist.isNotEmpty &&
        playerProvider.currentIndex >= 0 &&
        playerProvider.currentIndex + 1 < playerProvider.playlist.length) {
      nextSong = playerProvider.playlist[playerProvider.currentIndex + 1];
    }

    return ClipRRect(
      borderRadius: BorderRadius.circular(_isExpanded ? 24 : 20),
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 25, sigmaY: 25),
        child: Container(
          decoration: BoxDecoration(
            color: AppColors.surface.withValues(alpha: 0.90),
            borderRadius: BorderRadius.circular(_isExpanded ? 24 : 20),
            border: Border.all(
              color: isPlaying
                  ? primaryColor.withValues(alpha: 0.35)
                  : AppColors.glassBorder,
              width: 0.9,
            ),
            boxShadow: [
              BoxShadow(
                color: primaryColor.withValues(alpha: isPlaying ? 0.22 : 0.10),
                blurRadius: 28,
                spreadRadius: 0,
                offset: const Offset(0, -4),
              ),
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.45),
                blurRadius: 18,
                offset: const Offset(0, 8),
              ),
            ],
          ),
          child: AnimatedSize(
            duration: const Duration(milliseconds: 300),
            curve: Curves.easeOutCubic,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                // Top Drag Handle & Progress Bar
                Stack(
                  children: [
                    // Progress line at top
                    StreamBuilder<Duration>(
                      stream: playerProvider.positionStream,
                      builder: (context, snapshot) {
                        final pos = snapshot.data ?? playerProvider.position;
                        final total = playerProvider.duration;
                        final progress = total.inMilliseconds > 0
                            ? (pos.inMilliseconds / total.inMilliseconds).clamp(0.0, 1.0)
                            : 0.0;

                        return AnimatedContainer(
                          duration: const Duration(milliseconds: 150),
                          height: 3.5,
                          width: MediaQuery.of(context).size.width * progress,
                          decoration: BoxDecoration(
                            gradient: LinearGradient(
                              colors: [
                                primaryColor.withValues(alpha: 0.6),
                                primaryColor,
                              ],
                            ),
                            borderRadius: const BorderRadius.only(
                              topRight: Radius.circular(2),
                              bottomRight: Radius.circular(2),
                            ),
                            boxShadow: [
                              BoxShadow(
                                color: primaryColor.withValues(alpha: 0.7),
                                blurRadius: 8,
                              ),
                            ],
                          ),
                        );
                      },
                    ),

                    // Top Drag Pill Indicator / Deck Switcher
                    Center(
                      child: isDualMode
                          ? GestureDetector(
                              onTap: () {
                                setState(() => _activeDeckIndex = 1);
                                AppHaptics.selection();
                              },
                              child: Container(
                                margin: const EdgeInsets.only(top: 6, bottom: 2),
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 8,
                                  vertical: 2,
                                ),
                                child: Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    Container(
                                      width: _activeDeckIndex == 0 ? 16 : 5,
                                      height: 3.5,
                                      decoration: BoxDecoration(
                                        color: _activeDeckIndex == 0
                                            ? primaryColor
                                            : Colors.white24,
                                        borderRadius: BorderRadius.circular(2),
                                      ),
                                    ),
                                    const SizedBox(width: 4),
                                    Container(
                                      width: _activeDeckIndex == 1 ? 16 : 5,
                                      height: 3.5,
                                      decoration: BoxDecoration(
                                        color: _activeDeckIndex == 1
                                            ? primaryColor
                                            : Colors.white24,
                                        borderRadius: BorderRadius.circular(2),
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            )
                          : Container(
                              margin: const EdgeInsets.only(top: 6, bottom: 2),
                              width: 34,
                              height: 4,
                              decoration: BoxDecoration(
                                color: AppColors.textTertiary.withValues(alpha: 0.45),
                                borderRadius: BorderRadius.circular(2),
                              ),
                            ),
                    ),
                  ],
                ),

                            // Main Header Row (Compact & Expanded Header)
                            Padding(
                              padding: const EdgeInsets.fromLTRB(10, 4, 8, 8),
                              child: Row(
                                children: [
                                  // Album Art with glowing pulse ring
                                  Hero(
                                    tag: 'player_album_art',
                                    child: AnimatedContainer(
                                      duration: const Duration(milliseconds: 250),
                                      width: _isExpanded ? 54 : 46,
                                      height: _isExpanded ? 54 : 46,
                                      decoration: BoxDecoration(
                                        borderRadius: BorderRadius.circular(14),
                                        boxShadow: [
                                          BoxShadow(
                                            color: primaryColor.withValues(alpha: isPlaying ? 0.35 : 0.15),
                                            blurRadius: isPlaying ? 12 : 6,
                                            offset: const Offset(0, 3),
                                          ),
                                        ],
                                      ),
                                      child: ClipRRect(
                                        borderRadius: BorderRadius.circular(14),
                                        child: SongAlbumArt(
                                          song: song,
                                          borderRadius: 14,
                                          fit: BoxFit.cover,
                                        ),
                                      ),
                                    ),
                                  ),
                                  const SizedBox(width: 12),

                                  // Song Info & Animated Visualizer
                                  Expanded(
                                    child: Column(
                                      mainAxisAlignment: MainAxisAlignment.center,
                                      crossAxisAlignment: CrossAxisAlignment.start,
                                      children: [
                                        Row(
                                          children: [
                                            Expanded(
                                              child: Text(
                                                song.title,
                                                style: Theme.of(context).textTheme.titleSmall?.copyWith(
                                                      fontSize: 13.5,
                                                      fontWeight: FontWeight.w700,
                                                      color: AppColors.textPrimary,
                                                      letterSpacing: 0.1,
                                                    ),
                                                maxLines: 1,
                                                overflow: TextOverflow.ellipsis,
                                              ),
                                            ),
                                            if (isLoading) ...[
                                              const SizedBox(width: 6),
                                              SizedBox(
                                                width: 14,
                                                height: 14,
                                                child: CircularProgressIndicator(
                                                  strokeWidth: 1.8,
                                                  color: primaryColor,
                                                ),
                                              ),
                                            ] else if (isPlaying) ...[
                                              const SizedBox(width: 6),
                                              _AnimatedEqualizerBars(
                                                isPlaying: isPlaying,
                                                color: primaryColor,
                                              ),
                                            ],
                                          ],
                                        ),
                                        const SizedBox(height: 2),
                                        Text(
                                          isLoading && playerProvider.loadingSong != null
                                              ? 'Fetching audio stream...'
                                              : song.artist,
                                          style: Theme.of(context).textTheme.bodySmall?.copyWith(
                                                fontSize: 11,
                                                fontWeight: FontWeight.w500,
                                                color: isLoading ? primaryColor : AppColors.textTertiary,
                                              ),
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                        ),
                                      ],
                                    ),
                                  ),

                                  const SizedBox(width: 4),

                                  // Header Action Buttons (NO DUPLICATES!)
                                  // When collapsed: Play/Pause, Skip Next, Expand Arrow, Close
                                  // When expanded: Full Screen Button, Collapse Arrow, Close
                                  AnimatedSwitcher(
                                    duration: const Duration(milliseconds: 200),
                                    transitionBuilder: (child, anim) => FadeTransition(
                                      opacity: anim,
                                      child: ScaleTransition(scale: anim, child: child),
                                    ),
                                    child: _isExpanded
                                        ? Row(
                                            key: const ValueKey('expanded_header_actions'),
                                            mainAxisSize: MainAxisSize.min,
                                            children: [
                                              // Full screen player shortcut button
                                              IconButton(
                                                onPressed: _openFullPlayer,
                                                icon: const Icon(
                                                  Icons.fullscreen_rounded,
                                                  color: AppColors.textSecondary,
                                                  size: 24,
                                                ),
                                                visualDensity: VisualDensity.compact,
                                                padding: EdgeInsets.zero,
                                                constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
                                                tooltip: 'Open Full Player',
                                              ),
                                              const SizedBox(width: 2),

                                              // Collapse Arrow Button
                                              IconButton(
                                                onPressed: () {
                                                  AppHaptics.selection();
                                                  setState(() => _isExpanded = false);
                                                },
                                                icon: const Icon(
                                                  Icons.keyboard_arrow_down_rounded,
                                                  color: AppColors.textSecondary,
                                                  size: 24,
                                                ),
                                                visualDensity: VisualDensity.compact,
                                                padding: EdgeInsets.zero,
                                                constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
                                                tooltip: 'Collapse',
                                              ),
                                              const SizedBox(width: 2),

                                              // Stop / Close Button
                                              _buildCloseButton(playerProvider),
                                            ],
                                          )
                                        : Row(
                                            key: const ValueKey('collapsed_header_actions'),
                                            mainAxisSize: MainAxisSize.min,
                                            children: [
                                              // Play / Pause button
                                              _PlayPauseButton(playerProvider: playerProvider),

                                              const SizedBox(width: 2),

                                              // Skip Next button
                                              IconButton(
                                                onPressed: () {
                                                  AppHaptics.medium();
                                                  playerProvider.skipNext();
                                                },
                                                icon: const Icon(
                                                  Icons.skip_next_rounded,
                                                  color: AppColors.textSecondary,
                                                  size: 24,
                                                ),
                                                visualDensity: VisualDensity.compact,
                                                padding: EdgeInsets.zero,
                                                constraints: const BoxConstraints(minWidth: 34, minHeight: 34),
                                                tooltip: 'Next',
                                              ),

                                              const SizedBox(width: 2),

                                              // Expand Arrow Button
                                              IconButton(
                                                onPressed: () {
                                                  AppHaptics.selection();
                                                  setState(() => _isExpanded = true);
                                                },
                                                icon: const Icon(
                                                  Icons.keyboard_arrow_up_rounded,
                                                  color: AppColors.textSecondary,
                                                  size: 24,
                                                ),
                                                visualDensity: VisualDensity.compact,
                                                padding: EdgeInsets.zero,
                                                constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
                                                tooltip: 'Expand Controls',
                                              ),

                                              const SizedBox(width: 2),

                                              // Stop / Close Button
                                              _buildCloseButton(playerProvider),
                                            ],
                                          ),
                                  ),
                                ],
                              ),
                            ),

                            // Expanded Controls Section
                            if (_isExpanded) ...[
                              const Divider(height: 1, color: AppColors.glassBorder),

                              // Interactive Seek Slider with timestamps
                              Padding(
                                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
                                child: StreamBuilder<Duration>(
                                  stream: playerProvider.positionStream,
                                  builder: (context, snapshot) {
                                    final pos = snapshot.data ?? playerProvider.position;
                                    final dur = playerProvider.duration;
                                    final maxMs = dur.inMilliseconds > 0 ? dur.inMilliseconds.toDouble() : 1.0;
                                    final currentMs = pos.inMilliseconds.toDouble().clamp(0.0, maxMs);

                                    return Column(
                                      children: [
                                        SliderTheme(
                                          data: SliderTheme.of(context).copyWith(
                                            trackHeight: 4,
                                            thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 7),
                                            overlayShape: const RoundSliderOverlayShape(overlayRadius: 14),
                                            activeTrackColor: primaryColor,
                                            inactiveTrackColor: AppColors.surfaceVariant,
                                            thumbColor: Colors.white,
                                          ),
                                          child: Slider(
                                            value: currentMs,
                                            max: maxMs,
                                            onChanged: (val) {
                                              playerProvider.seek(Duration(milliseconds: val.toInt()));
                                            },
                                          ),
                                        ),
                                        Padding(
                                          padding: const EdgeInsets.symmetric(horizontal: 6),
                                          child: Row(
                                            mainAxisAlignment: MainAxisAlignment.spaceBetween,
                                            children: [
                                              Text(
                                                _formatDuration(pos),
                                                style: TextStyle(
                                                  fontSize: 10.5,
                                                  fontWeight: FontWeight.w600,
                                                  color: AppColors.textSecondary,
                                                ),
                                              ),
                                              Text(
                                                _formatDuration(dur),
                                                style: TextStyle(
                                                  fontSize: 10.5,
                                                  fontWeight: FontWeight.w600,
                                                  color: AppColors.textSecondary,
                                                ),
                                              ),
                                            ],
                                          ),
                                        ),
                                      ],
                                    );
                                  },
                                ),
                              ),

                              // Full Control Row (Shuffle, Skip Prev, Hero Play/Pause, Skip Next, Repeat)
                              Padding(
                                padding: const EdgeInsets.fromLTRB(16, 2, 16, 8),
                                child: Row(
                                  mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                                  children: [
                                    // Shuffle
                                    PremiumTap(
                                      onTap: () {
                                        AppHaptics.light();
                                        playerProvider.toggleShuffle();
                                      },
                                      child: Icon(
                                        Icons.shuffle_rounded,
                                        color: playerProvider.isShuffled ? primaryColor : AppColors.textTertiary,
                                        size: 22,
                                      ),
                                    ),

                                    // Skip Previous
                                    PremiumTap(
                                      onTap: () {
                                        AppHaptics.medium();
                                        playerProvider.skipPrevious();
                                      },
                                      child: const Icon(
                                        Icons.skip_previous_rounded,
                                        color: AppColors.textPrimary,
                                        size: 28,
                                      ),
                                    ),

                                    // Hero Floating Play/Pause Button
                                    PremiumTap(
                                      onTap: () {
                                        AppHaptics.light();
                                        playerProvider.togglePlayPause();
                                      },
                                      pressedScale: 0.90,
                                      child: Container(
                                        width: 50,
                                        height: 50,
                                        decoration: BoxDecoration(
                                          shape: BoxShape.circle,
                                          gradient: LinearGradient(
                                            colors: [
                                              primaryColor,
                                              primaryColor.withValues(alpha: 0.75),
                                            ],
                                            begin: Alignment.topLeft,
                                            end: Alignment.bottomRight,
                                          ),
                                          boxShadow: [
                                            BoxShadow(
                                              color: primaryColor.withValues(alpha: 0.45),
                                              blurRadius: 14,
                                              spreadRadius: 1,
                                              offset: const Offset(0, 3),
                                            ),
                                          ],
                                        ),
                                        child: AnimatedSwitcher(
                                          duration: const Duration(milliseconds: 180),
                                          child: Icon(
                                            isPlaying ? Icons.pause_rounded : Icons.play_arrow_rounded,
                                            key: ValueKey(isPlaying),
                                            color: Colors.white,
                                            size: 30,
                                          ),
                                        ),
                                      ),
                                    ),

                                    // Skip Next
                                    PremiumTap(
                                      onTap: () {
                                        AppHaptics.medium();
                                        playerProvider.skipNext();
                                      },
                                      child: const Icon(
                                        Icons.skip_next_rounded,
                                        color: AppColors.textPrimary,
                                        size: 28,
                                      ),
                                    ),

                                    // Repeat Mode
                                    PremiumTap(
                                      onTap: () {
                                        AppHaptics.light();
                                        playerProvider.cycleRepeatMode();
                                      },
                                      child: Icon(
                                        playerProvider.repeatMode == AudioServiceRepeatMode.one
                                            ? Icons.repeat_one_rounded
                                            : Icons.repeat_rounded,
                                        color: playerProvider.repeatMode != AudioServiceRepeatMode.none
                                            ? primaryColor
                                            : AppColors.textTertiary,
                                        size: 22,
                                      ),
                                    ),
                                  ],
                                ),
                              ),

                              // Quick Action Footer Bar (Favorite, Up Next Chip, Full Screen)
                              Padding(
                                padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
                                child: Container(
                                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                                  decoration: BoxDecoration(
                                    color: Colors.black.withValues(alpha: 0.25),
                                    borderRadius: BorderRadius.circular(14),
                                    border: Border.all(
                                      color: Colors.white.withValues(alpha: 0.05),
                                    ),
                                  ),
                                  child: Row(
                                    children: [
                                      // Like / Favorite Toggle
                                      PremiumTap(
                                        onTap: () {
                                          AppHaptics.light();
                                          playerProvider.toggleFavorite(song);
                                        },
                                        child: Row(
                                          mainAxisSize: MainAxisSize.min,
                                          children: [
                                            Icon(
                                              isFav ? Icons.favorite_rounded : Icons.favorite_border_rounded,
                                              color: isFav ? Colors.redAccent : AppColors.textTertiary,
                                              size: 18,
                                            ),
                                            const SizedBox(width: 4),
                                            Text(
                                              isFav ? 'Liked' : 'Like',
                                              style: TextStyle(
                                                fontSize: 11,
                                                fontWeight: FontWeight.w600,
                                                color: isFav ? Colors.redAccent : AppColors.textTertiary,
                                              ),
                                            ),
                                          ],
                                        ),
                                      ),

                                      const Spacer(),

                                      // Up Next preview badge or Full View button
                                      if (nextSong != null) ...[
                                        Icon(Icons.queue_music_rounded, color: primaryColor, size: 14),
                                        const SizedBox(width: 4),
                                        ConstrainedBox(
                                          constraints: const BoxConstraints(maxWidth: 130),
                                          child: Text(
                                            'Next: ${nextSong.title}',
                                            style: TextStyle(
                                              fontSize: 10.5,
                                              fontWeight: FontWeight.w500,
                                              color: AppColors.textSecondary,
                                            ),
                                            maxLines: 1,
                                            overflow: TextOverflow.ellipsis,
                                          ),
                                        ),
                                      ] else ...[
                                        PremiumTap(
                                          onTap: _openFullPlayer,
                                          child: Row(
                                            mainAxisSize: MainAxisSize.min,
                                            children: [
                                              Text(
                                                'Open Player',
                                                style: TextStyle(
                                                  fontSize: 11,
                                                  fontWeight: FontWeight.w600,
                                                  color: primaryColor,
                                                ),
                                              ),
                                              const SizedBox(width: 2),
                                              Icon(Icons.open_in_full_rounded, color: primaryColor, size: 13),
                                            ],
                                          ),
                                        ),
                                      ],
                                  ],
                                ),
                              ),
                            ),
                          ],
                        ],
                      ),
                    ),
                  ),
                ),
              );
  }

  Widget _buildCloseButton(PlayerProvider playerProvider) {
    return Container(
      decoration: BoxDecoration(
        color: Colors.redAccent.withValues(alpha: 0.12),
        shape: BoxShape.circle,
      ),
      child: IconButton(
        onPressed: () {
          AppHaptics.medium();
          playerProvider.stop();
        },
        icon: const Icon(
          Icons.close_rounded,
          color: Colors.redAccent,
          size: 18,
        ),
        visualDensity: VisualDensity.compact,
        padding: EdgeInsets.zero,
        constraints: const BoxConstraints(minWidth: 30, minHeight: 30),
        tooltip: 'Stop & Close',
      ),
    );
  }
}

/// Compact morphing Play/Pause button for collapsed header
class _PlayPauseButton extends StatefulWidget {
  final PlayerProvider playerProvider;

  const _PlayPauseButton({required this.playerProvider});

  @override
  State<_PlayPauseButton> createState() => _PlayPauseButtonState();
}

class _PlayPauseButtonState extends State<_PlayPauseButton> with SingleTickerProviderStateMixin {
  late AnimationController _animController;

  @override
  void initState() {
    super.initState();
    _animController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 250),
      value: widget.playerProvider.isPlaying ? 1.0 : 0.0,
    );
  }

  @override
  void didUpdateWidget(_PlayPauseButton oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.playerProvider.isPlaying) {
      _animController.forward();
    } else {
      _animController.reverse();
    }
  }

  @override
  void dispose() {
    _animController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<ProcessingState>(
      stream: widget.playerProvider.processingStateStream,
      builder: (context, stateSnapshot) {
        final state = stateSnapshot.data ?? ProcessingState.idle;
        if (state == ProcessingState.loading || state == ProcessingState.buffering || widget.playerProvider.loadingSong != null) {
          return SizedBox(
            width: 34,
            height: 34,
            child: Padding(
              padding: const EdgeInsets.all(7.0),
              child: CircularProgressIndicator(
                color: Theme.of(context).colorScheme.primary,
                strokeWidth: 2.2,
              ),
            ),
          );
        }

        return StreamBuilder<bool>(
          stream: widget.playerProvider.playingStream,
          builder: (context, snapshot) {
            final isPlaying = snapshot.data ?? widget.playerProvider.isPlaying;
            if (isPlaying) {
              _animController.forward();
            } else {
              _animController.reverse();
            }

            return IconButton(
              onPressed: () {
                AppHaptics.light();
                widget.playerProvider.togglePlayPause();
              },
              icon: AnimatedIcon(
                icon: AnimatedIcons.play_pause,
                progress: _animController,
                color: AppColors.textPrimary,
                size: 26,
              ),
              visualDensity: VisualDensity.compact,
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints(
                minWidth: 34,
                minHeight: 34,
              ),
            );
          },
        );
      },
    );
  }
}

/// Animated 3-bar equalizer visualizer widget next to song title
class _AnimatedEqualizerBars extends StatefulWidget {
  final bool isPlaying;
  final Color color;

  const _AnimatedEqualizerBars({
    required this.isPlaying,
    required this.color,
  });

  @override
  State<_AnimatedEqualizerBars> createState() => _AnimatedEqualizerBarsState();
}

class _AnimatedEqualizerBarsState extends State<_AnimatedEqualizerBars>
    with SingleTickerProviderStateMixin {
  late AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 600),
    );
    if (widget.isPlaying) {
      _controller.repeat(reverse: true);
    }
  }

  @override
  void didUpdateWidget(covariant _AnimatedEqualizerBars oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.isPlaying && !_controller.isAnimating) {
      _controller.repeat(reverse: true);
    } else if (!widget.isPlaying && _controller.isAnimating) {
      _controller.stop();
    }
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
      builder: (context, _) {
        final val = _controller.value;
        return SizedBox(
          height: 12,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              _bar(4 + (val * 7)),
              const SizedBox(width: 2),
              _bar(11 - (val * 6)),
              const SizedBox(width: 2),
              _bar(5 + (val * 6)),
            ],
          ),
        );
      },
    );
  }

  Widget _bar(double height) {
    return Container(
      width: 2.5,
      height: widget.isPlaying ? height : 3,
      decoration: BoxDecoration(
        color: widget.color,
        borderRadius: BorderRadius.circular(1.5),
      ),
    );
  }
}
