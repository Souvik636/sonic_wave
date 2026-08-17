import 'dart:ui';
import 'dart:io';
import 'dart:async';
import 'dart:math' as math;
import 'package:audio_service/audio_service.dart';
import 'package:flutter/material.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:just_audio/just_audio.dart';
import 'package:provider/provider.dart';
import '../models/song.dart';
import '../providers/player_provider.dart';
import '../providers/settings_provider.dart';
import '../theme/app_colors.dart';
import '../widgets/animated_equalizer.dart';
import '../services/download_service.dart';
import '../widgets/song_album_art.dart';
import '../widgets/premium_interaction.dart';
import '../widgets/queue_sheet.dart';
import '../widgets/song_options_sheet.dart';
import '../widgets/sound_studio_editing_view.dart';
import 'package:google_fonts/google_fonts.dart';
import 'aurora_player_screen.dart';

class PlayerScreen extends StatefulWidget {
  const PlayerScreen({super.key});

  @override
  State<PlayerScreen> createState() => _PlayerScreenState();
}

class _PlayerScreenState extends State<PlayerScreen>
    with TickerProviderStateMixin {
  late AnimationController _rotationController;
  bool _showVolumeBar = false;
  Timer? _volumeHideTimer;
  final PageController _pageController = PageController();
  bool _isDraggingVolume = false;

  void _triggerVolumeBar() {
    if (!mounted) return;
    setState(() {
      _showVolumeBar = true;
    });
    _volumeHideTimer?.cancel();
    _volumeHideTimer = Timer(const Duration(seconds: 4), () {
      if (mounted) {
        setState(() {
          _showVolumeBar = false;
        });
      }
    });
  }

  late AnimationController _entranceController;
  late AnimationController _ambientController;
  late AnimationController _visualizerController;
  late Animation<double> _albumScale;
  late Animation<double> _controlsOpacity;
  late Animation<Offset> _controlsSlide;

  @override
  void initState() {
    super.initState();

    // Album art rotation (subtle vinyl effect)
    _rotationController = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 20),
    );

    // Entrance animations
    _entranceController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 700),
    );

    // Ambient mode background animation
    _ambientController = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 12),
    );
    _ambientController.repeat(reverse: true);

    // Visualizer repaint ticker. This drives ~60fps repaints ONLY; the actual
    // motion is a deterministic function of the real playback position sampled
    // each frame (see VisualSyncModel), not this controller's phase. Gated on
    // isPlaying below so it doesn't burn frames while paused.
    _visualizerController = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 1),
    );

    _albumScale = Tween<double>(begin: 0.7, end: 1.0).animate(
      CurvedAnimation(
        parent: _entranceController,
        curve: const Interval(0.0, 0.6, curve: Curves.easeOutBack),
      ),
    );

    _controlsOpacity = Tween<double>(begin: 0.0, end: 1.0).animate(
      CurvedAnimation(
        parent: _entranceController,
        curve: const Interval(0.3, 1.0, curve: Curves.easeOut),
      ),
    );

    _controlsSlide =
        Tween<Offset>(begin: const Offset(0, 0.15), end: Offset.zero).animate(
          CurvedAnimation(
            parent: _entranceController,
            curve: const Interval(0.3, 1.0, curve: Curves.easeOutCubic),
          ),
        );

    _entranceController.forward();

    // Start rotation based on playing state
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final provider = context.read<PlayerProvider>();
      if (provider.isPlaying) {
        _rotationController.repeat();
        _visualizerController.repeat();
      }
      provider.playingStream.listen((isPlaying) {
        if (mounted) {
          if (isPlaying) {
            _rotationController.repeat();
            _visualizerController.repeat();
          } else {
            _rotationController.stop();
            // One last repaint so the visualizer settles to its idle state.
            _visualizerController.stop();
            if (mounted) setState(() {});
          }
        }
      });
    });
  }

  @override
  void dispose() {
    _volumeHideTimer?.cancel();
    _rotationController.dispose();
    _entranceController.dispose();
    _ambientController.dispose();
    _visualizerController.dispose();
    _pageController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final screenWidth = MediaQuery.of(context).size.width;
    final screenHeight = MediaQuery.of(context).size.height;

    return Consumer<PlayerProvider>(
      builder: (context, playerProvider, _) {
        final song = playerProvider.currentSong;
        if (song == null) {
          return const Scaffold(body: Center(child: Text('No song playing')));
        }

        final isLocalOrDownloaded =
            song.isLocalFile ||
            playerProvider.downloadedSongs.any(
              (s) => s.videoId == song.videoId,
            );

        return Scaffold(
          body: Container(
            width: double.infinity,
            height: double.infinity,
            decoration: BoxDecoration(
              gradient: Provider.of<SettingsProvider>(context).playerGradient,
            ),
            child: Stack(
              children: [
                // Blurred background with dynamic ambient mode light leaks
                _buildBackground(
                  song,
                  Provider.of<SettingsProvider>(context).enableAmbientMode,
                ),

                // Horizontal PageView for Player (Page 0) and Song Metadata/Trimming Studio (Page 1)
                PageView(
                  controller: _pageController,
                  physics: isLocalOrDownloaded
                      ? const BouncingScrollPhysics()
                      : const NeverScrollableScrollPhysics(),
                  onPageChanged: (index) {
                    if (index == 1 && playerProvider.isPlaying) {
                      playerProvider.pause();
                    }
                  },
                  children: [
                    // PAGE 0: Main Player Screen
                    GestureDetector(
                      behavior: HitTestBehavior.translucent,
                      onVerticalDragStart: (details) {
                        final x = details.globalPosition.dx;
                        final y = details.globalPosition.dy;
                        if (x > screenWidth * 0.55 && y < screenHeight * 0.70) {
                          _isDraggingVolume = true;
                          _triggerVolumeBar();
                        } else {
                          _isDraggingVolume = false;
                        }
                      },
                      onVerticalDragUpdate: (details) {
                        if (_isDraggingVolume) {
                          _triggerVolumeBar();
                          final settings = Provider.of<SettingsProvider>(
                            context,
                            listen: false,
                          );
                          final double deltaVolume =
                              -details.primaryDelta! / 250.0;
                          final double newVolume =
                              (settings.volume + deltaVolume).clamp(0.0, 1.0);
                          settings.setVolume(newVolume);
                        }
                      },
                      onVerticalDragEnd: (details) {
                        _isDraggingVolume = false;
                      },
                      child: SafeArea(
                        child: Column(
                          children: [
                            // Top bar
                            _buildTopBar(context, song),

                            const Spacer(flex: 1),

                            // Album art
                            _buildAlbumArt(screenWidth, song),

                            const Spacer(flex: 1),

                            // Song info
                            _buildSongInfo(song),

                            const SizedBox(height: 8),

                            // Dynamic Visualizer Panel
                            _buildVisualizerPanel(playerProvider),

                            const SizedBox(height: 12),

                            // Progress bar
                            _buildProgressBar(playerProvider),

                            const SizedBox(height: 24),

                            // Controls
                            _buildControls(playerProvider),

                            const SizedBox(height: 16),

                            // Extra controls
                            _buildExtraControls(playerProvider),

                            const SizedBox(height: 30),
                          ],
                        ),
                      ),
                    ),

                    // PAGE 1: Modern Song Editing / Trimming Studio
                    SafeArea(
                      child: SoundStudioEditingView(
                        song: song,
                        pageController: _pageController,
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _buildTopBar(BuildContext context, Song song) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Stack(
        alignment: Alignment.center,
        children: [
          // Perfectly centered "NOW PLAYING" label
          Column(
            children: [
              Text(
                'NOW PLAYING',
                style: Theme.of(context).textTheme.labelSmall?.copyWith(
                  color: AppColors.textTertiary,
                  letterSpacing: 2,
                  fontSize: 10,
                ),
              ),
              const SizedBox(height: 2),
              AnimatedEqualizer(
                isPlaying: context.watch<PlayerProvider>().isPlaying,
                height: 12,
                barWidth: 2,
                barCount: 5,
                color: Theme.of(context).colorScheme.primary,
              ),
            ],
          ),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              IconButton(
                onPressed: () => Navigator.of(context).pop(),
                icon: const Icon(
                  Icons.keyboard_arrow_down_rounded,
                  color: Colors.white,
                  size: 32,
                ),
              ),
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  // Toggle to Aurora player
                  IconButton(
                    onPressed: () {
                      AppHaptics.selection();
                      Provider.of<SettingsProvider>(
                        context,
                        listen: false,
                      ).setPlayerStyle('aurora');
                      Navigator.pushReplacement(
                        context,
                        PageRouteBuilder(
                          pageBuilder: (_, _, _) => const AuroraPlayerScreen(),
                          transitionsBuilder: (_, anim, _, child) =>
                              FadeTransition(opacity: anim, child: child),
                          transitionDuration: const Duration(milliseconds: 300),
                        ),
                      );
                    },
                    tooltip: 'Switch to Aurora Player',
                    icon: const Icon(
                      Icons.flare_rounded,
                      color: Colors.white54,
                      size: 22,
                    ),
                  ),
                  IconButton(
                    onPressed: () => showSongOptionsSheet(context, song),
                    icon: const Icon(
                      Icons.more_vert_rounded,
                      color: Colors.white,
                      size: 24,
                    ),
                  ),
                ],
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildAlbumArt(double screenWidth, Song song) {
    final artSize = screenWidth * 0.70;
    final playerProvider = Provider.of<PlayerProvider>(context);

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          // Left Spacer of the same width as the right volume control to center the art perfectly
          const SizedBox(width: 44),

          Expanded(
            child: Center(
              child: GestureDetector(
                onHorizontalDragEnd: (details) {
                  if (details.primaryVelocity == null) return;
                  final provider = Provider.of<PlayerProvider>(
                    context,
                    listen: false,
                  );
                  if (details.primaryVelocity! < 0) {
                    // Swiped right-to-left -> Next song
                    AppHaptics.medium();
                    provider.skipNext();
                  } else if (details.primaryVelocity! > 0) {
                    // Swiped left-to-right -> Prev song
                    AppHaptics.medium();
                    provider.skipPrevious();
                  }
                },
                child: ScaleTransition(
                  scale: _albumScale,
                  child: Stack(
                    alignment: Alignment.center,
                    children: [
                      // Radial Circular Visualizer
                      if (Provider.of<SettingsProvider>(
                            context,
                          ).showVisualizer &&
                          Provider.of<SettingsProvider>(
                                context,
                              ).visualizerTheme ==
                              'circle')
                        AnimatedBuilder(
                          animation: _visualizerController,
                          builder: (context, child) {
                            final auraColors = _getAuraColors(song.videoId);
                            return SizedBox(
                              width: artSize,
                              height: artSize,
                              child: RepaintBoundary(
                                child: CustomPaint(
                                  painter: CircularVisualizerPainter(
                                    timeMs: playerProvider
                                        .position
                                        .inMilliseconds
                                        .toDouble(),
                                    seed: _songSeed(song),
                                    colors: auraColors,
                                    radius: artSize / 2,
                                    isPlaying: playerProvider.isPlaying,
                                    quality: visualizerQuality(context),
                                    bassMultiplier: (() {
                                      final settings =
                                          Provider.of<SettingsProvider>(
                                            context,
                                            listen: false,
                                          );
                                      if (settings.useCustomEqualizer &&
                                          settings
                                              .customEqualizerGains
                                              .isNotEmpty) {
                                        return (1.0 +
                                                (settings
                                                        .customEqualizerGains[0] /
                                                    12.0))
                                            .clamp(0.1, 2.5);
                                      }
                                      if (settings.soundEnhancer ==
                                          SoundEnhancer.bassBoost) {
                                        return 1.6;
                                      }
                                      if (settings.soundEnhancer ==
                                          SoundEnhancer.ambient3d) {
                                        return 1.3;
                                      }
                                      return 1.0;
                                    })(),
                                    vocalMultiplier: (() {
                                      final settings =
                                          Provider.of<SettingsProvider>(
                                            context,
                                            listen: false,
                                          );
                                      if (settings.useCustomEqualizer &&
                                          settings
                                                  .customEqualizerGains
                                                  .length >=
                                              3) {
                                        return (1.0 +
                                                (settings
                                                        .customEqualizerGains[2] /
                                                    12.0))
                                            .clamp(0.1, 2.5);
                                      }
                                      if (settings.soundEnhancer ==
                                          SoundEnhancer.vocal) {
                                        return 1.5;
                                      }
                                      if (settings.soundEnhancer ==
                                          SoundEnhancer.ambient3d) {
                                        return 0.8;
                                      }
                                      return 1.0;
                                    })(),
                                    trebleMultiplier: (() {
                                      final settings =
                                          Provider.of<SettingsProvider>(
                                            context,
                                            listen: false,
                                          );
                                      if (settings.useCustomEqualizer &&
                                          settings
                                                  .customEqualizerGains
                                                  .length >=
                                              5) {
                                        return (1.0 +
                                                (settings
                                                        .customEqualizerGains[4] /
                                                    12.0))
                                            .clamp(0.1, 2.5);
                                      }
                                      if (settings.soundEnhancer ==
                                          SoundEnhancer.trebleBoost) {
                                        return 1.6;
                                      }
                                      if (settings.soundEnhancer ==
                                          SoundEnhancer.ambient3d) {
                                        return 1.3;
                                      }
                                      return 1.0;
                                    })(),
                                  ),
                                ),
                              ),
                            );
                          },
                        ),

                      Stack(
                        clipBehavior: Clip.none,
                        alignment: Alignment.center,
                        children: [
                          Hero(
                            tag: 'player_album_art',
                            child: Container(
                              width: artSize,
                              height: artSize,
                              decoration: BoxDecoration(
                                shape: BoxShape.circle,
                                boxShadow: [
                                  BoxShadow(
                                    color: Theme.of(context).colorScheme.primary
                                        .withValues(alpha: 0.3),
                                    blurRadius: 40,
                                    spreadRadius: 5,
                                  ),
                                  BoxShadow(
                                    color: Colors.black.withValues(alpha: 0.4),
                                    blurRadius: 30,
                                    offset: const Offset(0, 15),
                                  ),
                                ],
                              ),
                              child: Stack(
                                alignment: Alignment.center,
                                children: [
                                  // 1. Rotating Cover Art Disk
                                  AnimatedBuilder(
                                    animation: _rotationController,
                                    builder: (context, child) {
                                      return RepaintBoundary(
                                        child: Transform.rotate(
                                          angle:
                                              _rotationController.value *
                                              2 *
                                              3.14159,
                                          child: child,
                                        ),
                                      );
                                    },
                                    child: ClipOval(
                                      child: AnimatedSwitcher(
                                        duration: const Duration(
                                          milliseconds: 450,
                                        ),
                                        switchInCurve: Curves.easeOut,
                                        switchOutCurve: Curves.easeIn,
                                        transitionBuilder: (child, anim) =>
                                            FadeTransition(
                                              opacity: anim,
                                              child: ScaleTransition(
                                                scale: Tween<double>(
                                                  begin: 1.06,
                                                  end: 1.0,
                                                ).animate(anim),
                                                child: child,
                                              ),
                                            ),
                                        child: SongAlbumArt(
                                          key: ValueKey(song.videoId),
                                          song: song,
                                          width: artSize,
                                          height: artSize,
                                          borderRadius: artSize / 2,
                                          fit: BoxFit.cover,
                                        ),
                                      ),
                                    ),
                                  ),

                                  // 2. Stationary Glossy Reflection & Grooves
                                  Positioned.fill(
                                    child: const IgnorePointer(
                                      child: CustomPaint(
                                        painter: VinylReflectionPainter(),
                                      ),
                                    ),
                                  ),

                                  // 3. Center Hole (vinyl look)
                                  Container(
                                    width: 24,
                                    height: 24,
                                    decoration: BoxDecoration(
                                      shape: BoxShape.circle,
                                      color: AppColors.background,
                                      border: Border.all(
                                        color: AppColors.surfaceVariant,
                                        width: 3.5,
                                      ),
                                      boxShadow: [
                                        BoxShadow(
                                          color: Colors.black.withValues(
                                            alpha: 0.5,
                                          ),
                                          blurRadius: 10,
                                        ),
                                      ],
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),

                          // 4. Animated Tonearm (Needle) anchored at top right
                          Positioned(
                            top: -30,
                            right: -10,
                            child: IgnorePointer(
                              child: AnimatedRotation(
                                turns: playerProvider.isPlaying ? 0.05 : -0.06,
                                alignment: const Alignment(
                                  0.0,
                                  -0.9,
                                ), // Anchor near top Center of box
                                duration: const Duration(milliseconds: 700),
                                curve: Curves.easeInOutCubic,
                                child: SizedBox(
                                  width: 80,
                                  height: 160,
                                  child: CustomPaint(
                                    painter: TonearmPainter(
                                      angle: playerProvider.isPlaying
                                          ? 0.05
                                          : -0.06,
                                    ),
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),

          // Sleek Vertical Volume Control on the right
          AnimatedContainer(
            duration: const Duration(milliseconds: 300),
            curve: Curves.easeOutCubic,
            transform: Matrix4.translationValues(_showVolumeBar ? 0 : 15, 0, 0),
            child: AnimatedOpacity(
              opacity: _showVolumeBar ? 1.0 : 0.0,
              duration: const Duration(milliseconds: 250),
              child: IgnorePointer(
                ignoring: !_showVolumeBar,
                child: SizedBox(
                  width: 44,
                  child: _buildVerticalVolume(context),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSongInfo(Song song) {
    return SlideTransition(
      position: _controlsSlide,
      child: FadeTransition(
        opacity: _controlsOpacity,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 36),
          child: Column(
            children: [
              Text(
                song.title,
                style: Theme.of(context).textTheme.headlineMedium?.copyWith(
                  color: Colors.white,
                  fontWeight: FontWeight.w700,
                ),
                textAlign: TextAlign.center,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
              const SizedBox(height: 8),
              Text(
                song.artist,
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  color: AppColors.textSecondary,
                  fontSize: 15,
                ),
                textAlign: TextAlign.center,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildProgressBar(PlayerProvider playerProvider) {
    return SlideTransition(
      position: _controlsSlide,
      child: FadeTransition(
        opacity: _controlsOpacity,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 32),
          child: StreamBuilder<Duration>(
            stream: playerProvider.positionStream,
            builder: (context, snapshot) {
              final position = snapshot.data ?? Duration.zero;
              final duration = playerProvider.duration;
              final progress = duration.inMilliseconds > 0
                  ? position.inMilliseconds / duration.inMilliseconds
                  : 0.0;

              return Column(
                children: [
                  SliderTheme(
                    data: SliderTheme.of(context).copyWith(
                      trackHeight: 4,
                      thumbShape: const RoundSliderThumbShape(
                        enabledThumbRadius: 7,
                      ),
                      overlayShape: const RoundSliderOverlayShape(
                        overlayRadius: 16,
                      ),
                      activeTrackColor: Theme.of(context).colorScheme.primary,
                      inactiveTrackColor: Colors.white.withValues(alpha: 0.15),
                      thumbColor: Colors.white,
                      overlayColor: Theme.of(
                        context,
                      ).colorScheme.primary.withValues(alpha: 0.2),
                    ),
                    child: Slider(
                      value: progress.clamp(0.0, 1.0),
                      onChanged: (value) {
                        final newPosition = Duration(
                          milliseconds: (value * duration.inMilliseconds)
                              .toInt(),
                        );
                        playerProvider.seek(newPosition);
                      },
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 20),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Text(
                          _formatDuration(position),
                          style: Theme.of(context).textTheme.bodySmall
                              ?.copyWith(
                                color: AppColors.textTertiary,
                                fontSize: 12,
                              ),
                        ),
                        Text(
                          _formatDuration(duration),
                          style: Theme.of(context).textTheme.bodySmall
                              ?.copyWith(
                                color: AppColors.textTertiary,
                                fontSize: 12,
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
      ),
    );
  }

  Widget _buildControls(PlayerProvider playerProvider) {
    return SlideTransition(
      position: _controlsSlide,
      child: FadeTransition(
        opacity: _controlsOpacity,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 32),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
            children: [
              // Shuffle
              _buildControlButton(
                icon: Icons.shuffle_rounded,
                size: 24,
                isActive: playerProvider.isShuffled,
                onTap: playerProvider.toggleShuffle,
              ),

              // Previous
              _buildControlButton(
                icon: Icons.skip_previous_rounded,
                size: 36,
                haptic: HapticStyle.medium,
                onTap: playerProvider.skipPrevious,
              ),

              // Play/Pause
              _PlayPauseMainButton(playerProvider: playerProvider),

              // Next
              _buildControlButton(
                icon: Icons.skip_next_rounded,
                size: 36,
                haptic: HapticStyle.medium,
                onTap: playerProvider.skipNext,
              ),

              // Repeat
              _buildControlButton(
                icon: playerProvider.repeatMode == AudioServiceRepeatMode.one
                    ? Icons.repeat_one_rounded
                    : Icons.repeat_rounded,
                size: 24,
                isActive:
                    playerProvider.repeatMode != AudioServiceRepeatMode.none,
                onTap: playerProvider.cycleRepeatMode,
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildControlButton({
    required IconData icon,
    required double size,
    bool isActive = false,
    VoidCallback? onTap,
    HapticStyle haptic = HapticStyle.selection,
  }) {
    final activeColor = Theme.of(context).colorScheme.primary;
    final inactiveColor = Colors.white.withValues(alpha: 0.8);
    return PremiumTap(
      onTap: onTap,
      haptic: haptic,
      pressedScale: 0.82,
      // Smoothly cross-fade the icon colour when the active state toggles
      // (shuffle / repeat) instead of the old instant flip.
      child: Padding(
        padding: const EdgeInsets.all(6),
        child: TweenAnimationBuilder<Color?>(
          duration: const Duration(milliseconds: 250),
          curve: Curves.easeOut,
          tween: ColorTween(
            begin: isActive ? activeColor : inactiveColor,
            end: isActive ? activeColor : inactiveColor,
          ),
          builder: (context, color, _) => Icon(icon, color: color, size: size),
        ),
      ),
    );
  }

  Widget _buildExtraControls(PlayerProvider playerProvider) {
    final song = playerProvider.currentSong;
    final isFav = song != null
        ? playerProvider.isFavorite(song.videoId)
        : false;

    return FadeTransition(
      opacity: _controlsOpacity,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 40),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            IconButton(
              onPressed: () {
                if (song != null) {
                  playerProvider.toggleFavorite(song);
                }
              },
              icon: Icon(
                isFav ? Icons.favorite_rounded : Icons.favorite_border_rounded,
                color: isFav
                    ? Theme.of(context).colorScheme.primary
                    : AppColors.textTertiary,
                size: 22,
              ),
            ),
            IconButton(
              onPressed: () => _showSpeedSelector(context, playerProvider),
              icon: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(
                    Icons.speed_rounded,
                    color: AppColors.textTertiary,
                    size: 20,
                  ),
                  const SizedBox(width: 4),
                  Text(
                    '${playerProvider.playbackSpeed.toStringAsFixed(2).replaceAll(RegExp(r'\.00$'), '').replaceAll(RegExp(r'0$'), '')}x',
                    style: GoogleFonts.inter(
                      color: AppColors.textTertiary,
                      fontSize: 12,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ],
              ),
            ),
            IconButton(
              onPressed: () => showQueueSheet(context, playerProvider),
              icon: const Icon(
                Icons.queue_music_rounded,
                color: AppColors.textTertiary,
                size: 22,
              ),
            ),
            Builder(
              builder: (context) {
                final currentSong = playerProvider.currentSong;
                if (currentSong == null) return const SizedBox.shrink();

                final isDownloaded = playerProvider.downloadedSongs.any(
                  (s) => s.videoId == currentSong.videoId,
                );
                final progress =
                    playerProvider.downloadProgress[currentSong.videoId];
                final status = playerProvider.getDownloadStatus(
                  currentSong.videoId,
                );
                final isDownloading = progress != null || status != null;

                if (isDownloading) {
                  String label = '0%';
                  if (status == DownloadStatus.queued) {
                    label = 'Queued';
                  } else if (status == DownloadStatus.paused) {
                    label = 'Paused';
                  } else if (status == DownloadStatus.retrying) {
                    label = 'Retry';
                  } else if (progress != null) {
                    label = '${(progress * 100).toInt()}%';
                  }

                  return SizedBox(
                    width: 48,
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        SizedBox(
                          width: 14,
                          height: 14,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            value:
                                (status == DownloadStatus.paused ||
                                    status == DownloadStatus.queued)
                                ? 0.0
                                : null,
                            valueColor: AlwaysStoppedAnimation<Color>(
                              Theme.of(context).colorScheme.primary,
                            ),
                          ),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          label,
                          style: GoogleFonts.inter(
                            color: Theme.of(context).colorScheme.primary,
                            fontSize: 9,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ],
                    ),
                  );
                }

                if (isDownloaded) {
                  return IconButton(
                    onPressed: null,
                    icon: Icon(
                      Icons.download_done_rounded,
                      color: Theme.of(context).colorScheme.primary,
                      size: 22,
                    ),
                  );
                }

                return IconButton(
                  onPressed: () => playerProvider.downloadSong(
                    currentSong,
                    context: context,
                  ),
                  icon: const Icon(
                    Icons.download_rounded,
                    color: AppColors.textTertiary,
                    size: 22,
                  ),
                );
              },
            ),
          ],
        ),
      ),
    );
  }

  void _showSpeedSelector(BuildContext context, PlayerProvider playerProvider) {
    showModalBottomSheet(
      context: context,
      backgroundColor: AppColors.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (context) {
        final speeds = [0.5, 0.75, 1.0, 1.25, 1.5, 2.0];
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 20),
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
                Text(
                  'Playback Speed',
                  style: Theme.of(context).textTheme.titleLarge?.copyWith(
                    fontWeight: FontWeight.bold,
                    color: Colors.white,
                  ),
                ),
                const SizedBox(height: 12),
                ...speeds.map((speed) {
                  final isSelected = playerProvider.playbackSpeed == speed;
                  return ListTile(
                    contentPadding: const EdgeInsets.symmetric(horizontal: 24),
                    title: Text(
                      '${speed}x',
                      style: GoogleFonts.inter(
                        color: isSelected
                            ? Theme.of(context).colorScheme.primary
                            : Colors.white,
                        fontWeight: isSelected
                            ? FontWeight.bold
                            : FontWeight.normal,
                      ),
                    ),
                    trailing: isSelected
                        ? Icon(
                            Icons.check_rounded,
                            color: Theme.of(context).colorScheme.primary,
                          )
                        : null,
                    onTap: () {
                      playerProvider.setPlaybackSpeed(speed);
                      Navigator.pop(context);
                    },
                  );
                }),
              ],
            ),
          ),
        );
      },
    );
  }

  String _formatDuration(Duration duration) {
    final minutes = duration.inMinutes;
    final seconds = duration.inSeconds % 60;
    return '$minutes:${seconds.toString().padLeft(2, '0')}';
  }

  Widget _buildBackground(Song song, bool enableAmbientMode) {
    final auraColors = _getAuraColors(song.videoId);
    final primary = auraColors[0];
    final secondary = auraColors[1];
    final tertiary = auraColors[2];

    return Stack(
      children: [
        // Blurred base image
        Positioned.fill(
          child: song.highResThumbnailUrl.startsWith('http')
              ? CachedNetworkImage(
                  imageUrl: song.highResThumbnailUrl,
                  fit: BoxFit.cover,
                  memCacheWidth: 200,
                  memCacheHeight: 200,
                  placeholder: (context, url) => const SizedBox.shrink(),
                  errorWidget: (context, url, error) => const SizedBox.shrink(),
                  imageBuilder: (context, imageProvider) {
                    return Container(
                      decoration: BoxDecoration(
                        image: DecorationImage(
                          image: imageProvider,
                          fit: BoxFit.cover,
                        ),
                      ),
                    );
                  },
                )
              : (song.thumbnailUrl.isNotEmpty &&
                    File(song.thumbnailUrl).existsSync())
              ? Image.file(
                  File(song.thumbnailUrl),
                  fit: BoxFit.cover,
                  errorBuilder: (context, error, stackTrace) =>
                      const SizedBox.shrink(),
                )
              : const SizedBox.shrink(),
        ),

        // Dynamic "Aura Flow" ambient mode light leaks
        if (enableAmbientMode)
          Positioned.fill(
            child: AnimatedBuilder(
              animation: _ambientController,
              builder: (context, child) {
                final val = _ambientController.value;
                return Stack(
                  children: [
                    // Glow 1: Moving Top-Left to Center
                    Positioned(
                      left: -200 + val * 250,
                      top: -150 + val * 150,
                      child: Container(
                        width: 450 + val * 100,
                        height: 450 + val * 100,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: primary.withValues(alpha: 0.35),
                        ),
                      ),
                    ),
                    // Glow 2: Moving Bottom-Right to Center
                    Positioned(
                      right: -220 - val * 250,
                      bottom: -180 - val * 150,
                      child: Container(
                        width: 480 - val * 80,
                        height: 480 - val * 80,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: secondary.withValues(alpha: 0.30),
                        ),
                      ),
                    ),
                    // Glow 3: Pulsing Mid-Center
                    Positioned(
                      left: 50 + val * 50,
                      top: 150 + val * 80,
                      child: Container(
                        width: 300,
                        height: 300,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: tertiary.withValues(alpha: 0.15 + (val * 0.1)),
                        ),
                      ),
                    ),
                  ],
                );
              },
            ),
          ),

        // Massive blur layer to blend everything organically
        Positioned.fill(
          child: BackdropFilter(
            filter: ImageFilter.blur(sigmaX: 65, sigmaY: 65),
            child: Container(color: Colors.black.withValues(alpha: 0.65)),
          ),
        ),
      ],
    );
  }

  Widget _buildVerticalVolume(BuildContext context) {
    return Consumer<SettingsProvider>(
      builder: (context, settings, _) {
        final double volume = settings.volume;
        return FadeTransition(
          opacity: _controlsOpacity,
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              IconButton(
                icon: Icon(
                  volume == 0
                      ? Icons.volume_off_rounded
                      : volume < 0.4
                      ? Icons.volume_down_rounded
                      : Icons.volume_up_rounded,
                  color: Colors.white70,
                  size: 18,
                ),
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints(),
                onPressed: () {
                  settings.setVolume(volume > 0 ? 0.0 : 0.8);
                  _triggerVolumeBar();
                },
              ),
              const SizedBox(height: 10),
              SizedBox(
                height: 140,
                width: 24,
                child: RotatedBox(
                  quarterTurns: 3,
                  child: SliderTheme(
                    data: SliderTheme.of(context).copyWith(
                      trackHeight: 3.5,
                      thumbShape: const RoundSliderThumbShape(
                        enabledThumbRadius: 6,
                      ),
                      overlayShape: const RoundSliderOverlayShape(
                        overlayRadius: 10,
                      ),
                      activeTrackColor: Theme.of(context).colorScheme.primary,
                      inactiveTrackColor: Colors.white.withValues(alpha: 0.15),
                      thumbColor: Colors.white,
                      overlayColor: Theme.of(
                        context,
                      ).colorScheme.primary.withValues(alpha: 0.2),
                    ),
                    child: Slider(
                      value: volume,
                      min: 0.0,
                      max: 1.0,
                      onChanged: (val) {
                        settings.setVolume(val);
                        _triggerVolumeBar();
                      },
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 10),
              Text(
                '${(volume * 100).toInt()}%',
                style: const TextStyle(
                  color: Colors.white70,
                  fontSize: 10,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  /// Stable per-song seed for the visualizers — deterministic (no Random), so
  /// the same song always animates identically and every visualizer shares it.
  int _songSeed(Song song) => song.videoId.hashCode ^ song.title.hashCode;

  List<Color> _getAuraColors(String videoId) {
    final int hash = videoId.hashCode;
    final double hue1 = (hash % 360).toDouble();
    final double hue2 = ((hash + 120) % 360).toDouble();
    final double hue3 = ((hash + 240) % 360).toDouble();

    return [
      HSVColor.fromAHSV(1.0, hue1, 0.70, 0.85).toColor(),
      HSVColor.fromAHSV(1.0, hue2, 0.65, 0.75).toColor(),
      HSVColor.fromAHSV(1.0, hue3, 0.60, 0.80).toColor(),
    ];
  }

  Widget _buildVisualizerPanel(PlayerProvider playerProvider) {
    final settings = Provider.of<SettingsProvider>(context);
    if (!settings.showVisualizer) return const SizedBox.shrink();

    final theme = settings.visualizerTheme;
    final isPlaying = playerProvider.isPlaying;
    final song = playerProvider.currentSong;
    if (song == null) return const SizedBox.shrink();
    final auraColors = _getAuraColors(song.videoId);

    return SlideTransition(
      position: _controlsSlide,
      child: FadeTransition(
        opacity: _controlsOpacity,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 36),
          child: GestureDetector(
            onTap: () {
              final themes = ['bars', 'circle', 'waveform'];
              final nextIdx = (themes.indexOf(theme) + 1) % themes.length;
              settings.setVisualizerTheme(themes[nextIdx]);
            },
            child: Container(
              width: double.infinity,
              height: 48,
              color: Colors.transparent,
              child: AnimatedBuilder(
                animation: _visualizerController,
                builder: (context, child) {
                  final gains = settings.customEqualizerGains;
                  final useCustom = settings.useCustomEqualizer;
                  final enhancer = settings.soundEnhancer;

                  double bassMult = 1.0;
                  double vocalMult = 1.0;
                  double trebleMult = 1.0;

                  if (useCustom && gains.length >= 5) {
                    bassMult = 1.0 + (gains[0] / 12.0);
                    vocalMult = 1.0 + (gains[2] / 12.0);
                    trebleMult = 1.0 + (gains[4] / 12.0);
                  } else {
                    switch (enhancer) {
                      case SoundEnhancer.none:
                        break;
                      case SoundEnhancer.bassBoost:
                        bassMult = 1.6;
                        break;
                      case SoundEnhancer.trebleBoost:
                        trebleMult = 1.6;
                        break;
                      case SoundEnhancer.vocal:
                        vocalMult = 1.5;
                        break;
                      case SoundEnhancer.ambient3d:
                        bassMult = 1.3;
                        vocalMult = 0.8;
                        trebleMult = 1.3;
                        break;
                      // Extended genre presets — use EQ curve only, no visualizer mods
                      case SoundEnhancer.electronic:
                      case SoundEnhancer.rockMetal:
                      case SoundEnhancer.hipHop:
                      case SoundEnhancer.pop:
                      case SoundEnhancer.acoustic:
                      case SoundEnhancer.jazzBlues:
                      case SoundEnhancer.nightMode:
                        break;
                    }
                  }
                  bassMult = bassMult.clamp(0.1, 2.5);
                  vocalMult = vocalMult.clamp(0.1, 2.5);
                  trebleMult = trebleMult.clamp(0.1, 2.5);

                  final double timeMs = playerProvider.position.inMilliseconds
                      .toDouble();
                  final int seed = _songSeed(song);
                  final int quality = visualizerQuality(context);

                  if (theme == 'waveform') {
                    return RepaintBoundary(
                      child: CustomPaint(
                        painter: FluidWaveformPainter(
                          timeMs: timeMs,
                          seed: seed,
                          colors: auraColors,
                          isPlaying: isPlaying,
                          quality: quality,
                          bassMultiplier: bassMult,
                          vocalMultiplier: vocalMult,
                          trebleMultiplier: trebleMult,
                        ),
                      ),
                    );
                  } else if (theme == 'circle') {
                    return const SizedBox.shrink();
                  } else {
                    return RepaintBoundary(
                      child: CustomPaint(
                        painter: BarsVisualizerPainter(
                          timeMs: timeMs,
                          seed: seed,
                          colors: auraColors,
                          isPlaying: isPlaying,
                          quality: quality,
                          bassMultiplier: bassMult,
                          vocalMultiplier: vocalMult,
                          trebleMultiplier: trebleMult,
                        ),
                      ),
                    );
                  }
                },
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _PlayPauseMainButton extends StatefulWidget {
  final PlayerProvider playerProvider;

  const _PlayPauseMainButton({required this.playerProvider});

  @override
  State<_PlayPauseMainButton> createState() => _PlayPauseMainButtonState();
}

class _PlayPauseMainButtonState extends State<_PlayPauseMainButton>
    with TickerProviderStateMixin {
  late AnimationController _iconController;
  late AnimationController _scaleController;
  late Animation<double> _scaleAnimation;

  @override
  void initState() {
    super.initState();
    _iconController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 300),
      value: widget.playerProvider.isPlaying ? 1.0 : 0.0,
    );

    _scaleController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 100),
    );
    _scaleAnimation = Tween<double>(begin: 1.0, end: 0.9).animate(
      CurvedAnimation(parent: _scaleController, curve: Curves.easeInOut),
    );
  }

  @override
  void dispose() {
    _iconController.dispose();
    _scaleController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<bool>(
      stream: widget.playerProvider.playingStream,
      builder: (context, snapshot) {
        final isPlaying = snapshot.data ?? false;
        if (isPlaying) {
          _iconController.forward();
        } else {
          _iconController.reverse();
        }

        return GestureDetector(
          onTapDown: (_) => _scaleController.forward(),
          onTapUp: (_) {
            _scaleController.reverse();
            AppHaptics.light();
            widget.playerProvider.togglePlayPause();
          },
          onTapCancel: () => _scaleController.reverse(),
          child: ScaleTransition(
            scale: _scaleAnimation,
            child: Container(
              width: 72,
              height: 72,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                gradient: Provider.of<SettingsProvider>(context).accentGradient,
                boxShadow: [
                  BoxShadow(
                    color: Theme.of(
                      context,
                    ).colorScheme.primary.withValues(alpha: 0.5),
                    blurRadius: 20,
                    spreadRadius: 2,
                  ),
                ],
              ),
              child: Center(
                child: StreamBuilder<ProcessingState>(
                  stream: widget.playerProvider.processingStateStream,
                  builder: (context, stateSnapshot) {
                    final state = stateSnapshot.data ?? ProcessingState.idle;
                    final bool loading =
                        state == ProcessingState.loading ||
                        state == ProcessingState.buffering;
                    return AnimatedSwitcher(
                      duration: const Duration(milliseconds: 250),
                      transitionBuilder: (child, anim) => FadeTransition(
                        opacity: anim,
                        child: ScaleTransition(scale: anim, child: child),
                      ),
                      child: loading
                          ? const SizedBox(
                              key: ValueKey('loading'),
                              width: 28,
                              height: 28,
                              child: CircularProgressIndicator(
                                color: Colors.white,
                                strokeWidth: 2.5,
                              ),
                            )
                          : AnimatedIcon(
                              key: const ValueKey('icon'),
                              icon: AnimatedIcons.play_pause,
                              progress: _iconController,
                              color: Colors.white,
                              size: 36,
                            ),
                    );
                  },
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

/// Shared, deterministic sync model for every visualizer.
///
/// The old visualizers mixed a free-running `AnimationController` phase (unrelated
/// to the audio) plus `Random()` into their motion — which is why they felt random
/// and drifted out of sync. `just_audio` exposes no FFT here, but `player.position`
/// is smoothly interpolated, so this model derives ALL motion purely from the real
/// playback [timeMs] + a stable per-song [seed]. Same seed + same time → same output,
/// and all three visualizers read the identical band energies so they move together
/// with the vocals / bass / instruments / beat instead of independently.
class VisualSyncModel {
  final int seed;
  final double timeMs;
  final bool isPlaying;
  final double bassMultiplier;
  final double vocalMultiplier;
  final double trebleMultiplier;

  late final double _bpm;
  late final double _s1;
  late final double _s2;
  late final double _s3;
  late final double _t; // seconds, smooth
  late final double _beatPhase; // in beats

  late final double beat; // 0..1 pulse locked to the beat ("bits")
  late final double kick; // 0..1 sharp punchy on-beat bass hit
  late final double sub; // 0..1 deep sub-bass swell (every 2 beats)
  late final double bass; // 0..~1.6 heavy low end
  late final double vocal; // 0..~1.5 mid / voice
  late final double treble; // 0..~1.5 highs / cymbals
  late final double air; // 0..~1.3 very-high shimmer above treble ("sparkle")
  late final double energy; // 0..~1.3 overall combined level
  late final int beatCount; // integer beat index since start of the song
  late final double barPhase; // 0..1 progress through the 4-beat musical bar
  late final double barPulse; // 0..1 structural downbeat pulse (fires each bar)
  late final double rotation; // radians, continuous & smooth
  late final double hue; // 0..1 smooth colour cycle (NOT random)
  late final double peakHue; // 0..1 secondary hue for gradient highlight depth
  late final double bassGlow; // 0..1 bass energy that drives colour brightness

  VisualSyncModel({
    required this.seed,
    required this.timeMs,
    required this.isPlaying,
    this.bassMultiplier = 1.0,
    this.vocalMultiplier = 1.0,
    this.trebleMultiplier = 1.0,
  }) {
    // Stable per-song constants (deterministic hash of the seed — no Random).
    _bpm = 90 + (seed.abs() % 61).toDouble(); // 90..150 BPM, fixed per song
    _s1 = ((seed.abs() % 1000) / 1000.0) * 2 * math.pi;
    _s2 = (((seed.abs() >> 3) % 1000) / 1000.0) * 2 * math.pi;
    _s3 = (((seed.abs() >> 7) % 1000) / 1000.0) * 2 * math.pi;

    _t = timeMs / 1000.0;
    final double bps = _bpm / 60.0;
    _beatPhase = _t * bps;

    if (!isPlaying) {
      beat = 0.0;
      kick = 0.0;
      sub = 0.05;
      bass = 0.06;
      vocal = 0.05;
      treble = 0.04;
      air = 0.04;
      energy = 0.05;
      beatCount = 0;
      barPhase = 0.0;
      barPulse = 0.0;
      rotation = 0.0;
      hue = (_t / 30.0) % 1.0;
      peakHue = (hue + 0.5) % 1.0;
      bassGlow = 0.0;
      return;
    }

    // Beat: sharp attack + smooth decay, locked to the timeline (the "bits").
    final double frac = _beatPhase - _beatPhase.floorToDouble();
    beat = math.exp(-3.2 * frac);

    // Kick: a much punchier, faster-decaying hit on every beat — the transient
    // that drives the "bass interaction" (glow flashes, shockwaves, pops).
    kick = math.exp(-7.5 * frac);

    // Sub-bass: a slow, deep swell on a 2-beat cadence (the body under the kick).
    final double subPhase = _beatPhase * 0.5;
    final double subFrac = subPhase - subPhase.floorToDouble();
    sub = (0.35 + 0.65 * math.exp(-2.0 * subFrac)).clamp(0.0, 1.0);

    // Bass: heavy — combines the slow swell, the beat body and the punchy kick.
    final double swell = 0.5 + 0.5 * math.sin(_t * 0.8 + _s1);
    bass = ((0.28 * swell + 0.30 * sub + 0.42 * beat) * bassMultiplier).clamp(
      0.0,
      1.6,
    );

    // Vocal / mid: smooth undulation on a half-beat cadence.
    final double v1 = 0.5 + 0.5 * math.sin(_beatPhase * math.pi + _s2);
    final double v2 = 0.5 + 0.5 * math.sin(_t * 2.3 + _s3);
    vocal = ((0.55 * v1 + 0.45 * v2) * vocalMultiplier).clamp(0.0, 1.5);

    // Treble: quick, gentle shimmer at 4× the beat.
    final double tr = 0.5 + 0.5 * math.sin(_beatPhase * 4 * math.pi + _s1 * 2);
    treble = ((0.4 + 0.6 * tr) * trebleMultiplier).clamp(0.0, 1.5);

    // Air: very-high sparkle at 8× the beat — the top-end shimmer above treble.
    final double airOsc =
        0.5 + 0.5 * math.sin(_beatPhase * 8 * math.pi + _s2 * 3);
    air = ((0.3 + 0.7 * airOsc) * trebleMultiplier).clamp(0.0, 1.3);

    // Overall energy — a believable RMS used for global brightness / breathing.
    energy = (0.48 * bass + 0.30 * vocal + 0.14 * treble + 0.08 * air).clamp(
      0.0,
      1.3,
    );

    // Musical structure: a 4-beat bar. [beatCount] is the running beat index,
    // [barPhase] sweeps 0→1 across each bar and [barPulse] fires on the downbeat
    // — a slow structural pulse layered under the per-beat "bits".
    beatCount = _beatPhase.floor();
    barPhase = (_beatPhase / 4.0) % 1.0;
    barPulse = math.exp(-3.0 * barPhase);

    // Continuous smooth rotation — base drift + a touch of beat energy.
    rotation = _t * 0.35 + _beatPhase * 0.02;

    // Colour cycle: smooth, position-driven, ~24s per full sweep.
    hue = (_t / 24.0) % 1.0;

    // Secondary "peak" hue — offset ~complementary and shimmering with air — so
    // painters can build two-tone gradients with real depth at the highlights.
    peakHue = (hue + 0.5 + 0.05 * air) % 1.0;

    // Bass glow: the punchy signal that colours react to — brightens the palette
    // and fires the glow / shockwaves on every kick.
    bassGlow = (0.5 * bass + 0.5 * kick).clamp(0.0, 1.0);
  }

  /// Band energy for a normalized position [n] in [0,1] across any axis
  /// (bar row, wave x, or circle angle). Bass occupies 0–0.25, vocals the
  /// middle 0.25–0.75, treble 0.75–1 — the SAME mapping in every visualizer.
  double sample(double n) {
    if (!isPlaying) return 0.05;
    return _sampleAt(n, _t);
  }

  /// Stateless band-energy core: [n]'s energy evaluated at an arbitrary time
  /// [t]. Shared by [sample] (evaluated at "now") and [sampleSmooth] (evaluated
  /// across the recent past to build an attack/decay envelope).
  double _sampleAt(double n, double t) {
    final double bp = t * (_bpm / 60.0);
    final double frac = bp - bp.floorToDouble();
    final double bt = math.exp(-3.2 * frac);
    final double swell = 0.5 + 0.5 * math.sin(t * 0.8 + _s1);
    final double subPhase = bp * 0.5;
    final double subFrac = subPhase - subPhase.floorToDouble();
    final double sb = 0.35 + 0.65 * math.exp(-2.0 * subFrac);
    final double bassE =
        ((0.28 * swell + 0.30 * sb + 0.42 * bt) * bassMultiplier).clamp(
          0.0,
          1.6,
        );
    final double v1 = 0.5 + 0.5 * math.sin(bp * math.pi + _s2);
    final double v2 = 0.5 + 0.5 * math.sin(t * 2.3 + _s3);
    final double vocalE = ((0.55 * v1 + 0.45 * v2) * vocalMultiplier).clamp(
      0.0,
      1.5,
    );
    final double tr = 0.5 + 0.5 * math.sin(bp * 4 * math.pi + _s1 * 2);
    final double trebleE = ((0.4 + 0.6 * tr) * trebleMultiplier).clamp(
      0.0,
      1.5,
    );
    if (n < 0.25) {
      final double local = 0.5 + 0.5 * math.sin(n * 12 + _s1 + t * 2.0);
      return (0.15 + 0.85 * bassE) * (0.6 + 0.4 * local);
    } else if (n < 0.75) {
      final double local = 0.5 + 0.5 * math.sin(n * 18 + _s2 + t * 3.0);
      return (0.12 + 0.60 * vocalE) * (0.6 + 0.4 * local);
    } else {
      final double local = 0.5 + 0.5 * math.sin(n * 40 + _s3 + t * 6.0);
      return (0.10 + 0.70 * trebleE) * (0.5 + 0.5 * local);
    }
  }

  /// Like [sample] but with a fast-attack / slow-decay envelope so elements
  /// glide instead of snapping. Stateless: instant attack from the current
  /// value, plus an exponentially-decayed peak-hold over the recent past for a
  /// smooth fall. Costs a few extra evals — use it for sparse elements (bars),
  /// not the dense per-pixel wave / 120-line circle.
  double sampleSmooth(double n) {
    if (!isPlaying) return 0.05;
    double env = _sampleAt(n, _t); // instant attack
    const int steps = 5;
    const double dt = 0.05; // 50 ms per look-back step
    const double decayPerSec = 5.5; // fall speed
    for (int k = 1; k <= steps; k++) {
      final double past =
          _sampleAt(n, _t - k * dt) * math.exp(-decayPerSec * (k * dt));
      if (past > env) env = past;
    }
    return env;
  }

  /// Like [sampleSmooth] but with a much slower fall — a classic "peak-hold"
  /// that jumps instantly to a new peak and drifts down slowly. Used for the
  /// falling caps that hover above the bars. Stateless: derived from the recent
  /// past of the deterministic band model, so it needs no cross-frame memory.
  double samplePeak(double n) {
    if (!isPlaying) return 0.05;
    double env = _sampleAt(n, _t);
    const int steps = 16;
    const double dt = 0.05; // 50 ms per look-back step (0.8 s window)
    const double decayPerSec = 1.7; // slow fall — the "hold"
    for (int k = 1; k <= steps; k++) {
      final double past =
          _sampleAt(n, _t - k * dt) * math.exp(-decayPerSec * (k * dt));
      if (past > env) env = past;
    }
    return env;
  }

  /// Deterministic fractal noise: summed octaves of sine (fBm-style) in about
  /// [-1, 1]. Gives the waveform organic, layered motion — "more noise" — while
  /// staying fully repeatable (NO `Random`). [x] is the spatial coordinate,
  /// [t] time, [s] a per-layer phase seed so layers don't overlap identically.
  double fbm(double x, double t, double s) {
    double sum = 0.0;
    double amp = 0.62;
    double freq = 1.0;
    double norm = 0.0;
    for (int o = 0; o < 4; o++) {
      sum += amp * math.sin(x * freq + t * (0.9 + 0.45 * o) + s * (o + 1));
      norm += amp;
      freq *= 2.03; // slightly inharmonic → richer, less "ringy"
      amp *= 0.55;
    }
    return norm == 0 ? 0.0 : sum / norm; // normalized to ~[-1, 1]
  }

  /// Secondary highlight colour derived from [peakHue] — the bright "peak" end
  /// of a two-tone gradient, shimmering a touch with the air band for depth.
  Color get peakColor => HSVColor.fromAHSV(
    1.0,
    (peakHue * 360) % 360,
    0.60,
    (0.80 + 0.20 * air).clamp(0.0, 1.0),
  ).toColor();

  /// Colours cycled by [hue], reused by every painter for a consistent palette.
  List<Color> shiftColors(List<Color> colors) {
    return colors.map((c) {
      final hsv = HSVColor.fromColor(c);
      return hsv.withHue((hsv.hue + hue * 360) % 360).toColor();
    }).toList();
  }

  /// Premium palette that ALSO reacts to the bass: on top of the smooth hue
  /// cycle, [bassGlow] nudges the hue, lifts saturation and — most visibly —
  /// brightens the colour on every kick. This is the "colour changes with the
  /// bass" behaviour shared by all three visualizers.
  List<Color> dynamicColors(List<Color> colors) {
    final double g = bassGlow;
    return colors.map((c) {
      final hsv = HSVColor.fromColor(c);
      final double newHue = (hsv.hue + hue * 360 + g * 20.0) % 360;
      final double newSat = (hsv.saturation * (0.9 + 0.1 * g)).clamp(0.0, 1.0);
      final double newVal = (hsv.value * (0.82 + 0.4 * g)).clamp(0.0, 1.0);
      return HSVColor.fromAHSV(hsv.alpha, newHue, newSat, newVal).toColor();
    }).toList();
  }
}

/// Device-derived detail tier so rendering stays smooth & lag-free everywhere.
/// 0 = low-end, 1 = mid, 2 = high-end.
int visualizerQuality(BuildContext context) {
  final mq = MediaQuery.of(context);
  final double physicalWidth = mq.size.width * mq.devicePixelRatio;
  if (physicalWidth >= 1300) return 2;
  if (physicalWidth >= 850) return 1;
  return 0;
}

class BarsVisualizerPainter extends CustomPainter {
  final double timeMs;
  final int seed;
  final List<Color> colors;
  final bool isPlaying;
  final int quality;
  final double bassMultiplier;
  final double vocalMultiplier;
  final double trebleMultiplier;

  BarsVisualizerPainter({
    required this.timeMs,
    required this.seed,
    required this.colors,
    required this.isPlaying,
    required this.quality,
    this.bassMultiplier = 1.0,
    this.vocalMultiplier = 1.0,
    this.trebleMultiplier = 1.0,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final model = VisualSyncModel(
      seed: seed,
      timeMs: timeMs,
      isPlaying: isPlaying,
      bassMultiplier: bassMultiplier,
      vocalMultiplier: vocalMultiplier,
      trebleMultiplier: trebleMultiplier,
    );

    // Bar count scales with the device tier for smoothness on low-end phones.
    final int barCount = quality == 2 ? 48 : (quality == 1 ? 36 : 26);
    final double spacing = 3.0;
    final double width = (size.width - (barCount - 1) * spacing) / barCount;

    // Bass-reactive palette — colour brightens & shifts on every kick.
    final shiftedColors = model.dynamicColors(colors);
    final Color accent = shiftedColors.isNotEmpty
        ? shiftedColors.first
        : Colors.white;
    final double midY = size.height / 2;

    final Paint glowPaint = Paint()..style = PaintingStyle.fill;
    final Paint corePaint = Paint()..style = PaintingStyle.fill;

    if (shiftedColors.isNotEmpty) {
      // Fold the secondary peak colour into the gradient for two-tone depth.
      final gradientColors = [
        ...shiftedColors,
        model.peakColor,
        shiftedColors.first,
      ];
      final shaderRect = Rect.fromLTWH(0, 0, size.width, size.height);
      glowPaint.shader = LinearGradient(
        colors: gradientColors
            .map((c) => c.withValues(alpha: 0.20 + 0.28 * model.bassGlow))
            .toList(),
      ).createShader(shaderRect);
      corePaint.shader = LinearGradient(
        colors: gradientColors,
      ).createShader(shaderRect);
    } else {
      glowPaint.color = Colors.white.withValues(alpha: 0.20);
      corePaint.color = Colors.white;
    }

    // A soft baseline that swells with the bass and flashes on the downbeat —
    // anchors the spectrum and adds the 4-beat structural pulse.
    if (isPlaying) {
      final double baseGlow = (model.bassGlow + 0.4 * model.barPulse).clamp(
        0.0,
        1.0,
      );
      final Paint basePaint = Paint()
        ..color = accent.withValues(alpha: 0.10 + 0.35 * baseGlow)
        ..strokeWidth = 1.0 + 2.5 * baseGlow
        ..strokeCap = StrokeCap.round
        ..maskFilter = MaskFilter.blur(BlurStyle.normal, 1.0 + 4.0 * baseGlow);
      canvas.drawLine(Offset(0, midY), Offset(size.width, midY), basePaint);
    }

    final Paint capPaint = Paint()..style = PaintingStyle.fill;

    for (int i = 0; i < barCount; i++) {
      final double n = barCount == 1 ? 0.0 : i / (barCount - 1);
      // Smoothed band energy (attack/decay) → bars glide instead of snapping.
      final double factor = isPlaying
          ? (0.06 + 0.9 * model.sampleSmooth(n)).clamp(0.06, 1.0)
          : 0.06;

      // Centre-anchored, mirrored spectrum → the premium symmetric equalizer.
      final double half = (midY * factor);
      final double x = i * (width + spacing);

      final rrect = RRect.fromRectAndRadius(
        Rect.fromLTWH(x, midY - half, width, half * 2),
        Radius.circular(width / 2),
      );

      if (quality > 0) {
        canvas.drawRRect(rrect.inflate(1.5 + 2.0 * model.bassGlow), glowPaint);
      }
      canvas.drawRRect(rrect, corePaint);

      // Bright peak caps — the treble/air shimmer picks them out, and they lean
      // toward the peak colour on the bass for a lit, premium accent.
      if (quality > 0 && isPlaying) {
        final Color capColor = Color.lerp(
          model.peakColor,
          Colors.white,
          (0.3 + 0.4 * model.bassGlow + 0.2 * model.air).clamp(0.0, 1.0),
        )!;
        capPaint.color = capColor.withValues(alpha: 0.85);
        final double capR =
            (width / 2) * (0.85 + 0.4 * model.beat + 0.25 * model.air);
        canvas.drawCircle(Offset(x + width / 2, midY - half), capR, capPaint);
        canvas.drawCircle(Offset(x + width / 2, midY + half), capR, capPaint);
      }

      // Falling peak-hold markers — a bright cap that leaps to each new peak and
      // then drifts down slowly (the classic equalizer "peak meter"). It floats
      // above the live bar, so there is always visible motion even between hits.
      if (quality > 0 && isPlaying) {
        final double peak = (0.06 + 0.9 * model.samplePeak(n)).clamp(0.06, 1.0);
        final double peakHalf = midY * peak;
        const double capH = 2.5;
        final Paint peakPaint = Paint()
          ..style = PaintingStyle.fill
          ..color = Color.lerp(
            model.peakColor,
            Colors.white,
            0.55,
          )!.withValues(alpha: 0.9);
        canvas.drawRRect(
          RRect.fromRectAndRadius(
            Rect.fromLTWH(x, midY - peakHalf - capH, width, capH),
            const Radius.circular(capH / 2),
          ),
          peakPaint,
        );
        canvas.drawRRect(
          RRect.fromRectAndRadius(
            Rect.fromLTWH(x, midY + peakHalf, width, capH),
            const Radius.circular(capH / 2),
          ),
          peakPaint,
        );
      }
    }
  }

  @override
  bool shouldRepaint(covariant BarsVisualizerPainter oldDelegate) =>
      oldDelegate.timeMs != timeMs ||
      oldDelegate.isPlaying != isPlaying ||
      oldDelegate.seed != seed ||
      oldDelegate.quality != quality ||
      oldDelegate.bassMultiplier != bassMultiplier ||
      oldDelegate.vocalMultiplier != vocalMultiplier ||
      oldDelegate.trebleMultiplier != trebleMultiplier;
}

class CircularVisualizerPainter extends CustomPainter {
  final double timeMs;
  final int seed;
  final List<Color> colors;
  final double radius;
  final bool isPlaying;
  final int quality;
  final double bassMultiplier;
  final double vocalMultiplier;
  final double trebleMultiplier;

  CircularVisualizerPainter({
    required this.timeMs,
    required this.seed,
    required this.colors,
    required this.radius,
    required this.isPlaying,
    required this.quality,
    this.bassMultiplier = 1.0,
    this.vocalMultiplier = 1.0,
    this.trebleMultiplier = 1.0,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final model = VisualSyncModel(
      seed: seed,
      timeMs: timeMs,
      isPlaying: isPlaying,
      bassMultiplier: bassMultiplier,
      vocalMultiplier: vocalMultiplier,
      trebleMultiplier: trebleMultiplier,
    );

    // Line + particle counts scale with the device tier (smooth on low-end).
    final int lineCount = quality == 2 ? 120 : (quality == 1 ? 90 : 60);
    final double center = size.width / 2;

    // Bass-reactive palette — hue nudges and brightens on every kick.
    final shiftedColors = model.dynamicColors(colors);
    final Color accent = shiftedColors.isNotEmpty
        ? shiftedColors.first
        : Colors.white;

    final Paint glowPaint = Paint()
      ..strokeWidth = 9.0
      ..strokeCap = StrokeCap.round;
    final Paint corePaint = Paint()
      ..strokeWidth = 3.5
      ..strokeCap = StrokeCap.round;

    if (shiftedColors.isNotEmpty) {
      // Weave the secondary peak colour through the sweep for gradient depth.
      final gradientColors = [
        ...shiftedColors,
        model.peakColor,
        shiftedColors.first,
      ];
      final shaderRect = Rect.fromCircle(
        center: Offset(center, center),
        radius: radius * 1.6,
      );
      glowPaint.shader = SweepGradient(
        colors: gradientColors
            .map((c) => c.withValues(alpha: 0.22 + 0.20 * model.bassGlow))
            .toList(),
      ).createShader(shaderRect);
      corePaint.shader = SweepGradient(
        colors: gradientColors,
      ).createShader(shaderRect);
    } else {
      glowPaint.color = Colors.white.withValues(alpha: 0.20);
      corePaint.color = Colors.white;
    }

    canvas.save();
    canvas.translate(center, center);

    // 0. Bass halo — a big soft glow behind everything that swells on the kick.
    if (isPlaying) {
      final double haloR = radius * (1.05 + 0.28 * model.bassGlow);
      final Paint haloPaint = Paint()
        ..style = PaintingStyle.fill
        ..shader = RadialGradient(
          colors: [
            accent.withValues(alpha: 0.18 + 0.30 * model.bassGlow),
            accent.withValues(alpha: 0.0),
          ],
          stops: const [0.55, 1.0],
        ).createShader(Rect.fromCircle(center: Offset.zero, radius: haloR));
      canvas.drawCircle(Offset.zero, haloR, haloPaint);
    }

    // Smooth, continuous rotation from the shared model (no free-running phase).
    canvas.rotate(model.rotation);

    // 1. Inner ring pulsing with the beat + bass ("bits"), thickness tracks bass.
    final Paint circlePaint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.0 + 3.0 * model.bassGlow
      ..color = accent.withValues(alpha: 0.3 + 0.4 * model.bassGlow);
    final double currentRadius = radius + (14.0 * model.beat * bassMultiplier);
    canvas.drawCircle(Offset.zero, currentRadius, circlePaint);

    // 1b. Beat shockwaves — 2 rings that expand outward and fade on each beat.
    if (isPlaying && quality > 0) {
      for (int r = 0; r < 2; r++) {
        final double phase = ((model._beatPhase + r * 0.5) % 1.0);
        final double ringR = currentRadius + phase * (radius * 0.9);
        final double ringA = (1.0 - phase) * 0.5 * (0.5 + 0.5 * model.bassGlow);
        if (ringA <= 0.02) continue;
        canvas.drawCircle(
          Offset.zero,
          ringR,
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = 2.0
            ..color = accent.withValues(alpha: ringA),
        );
      }

      // 1c. Structural downbeat ring — a bigger, slower halo that expands once
      //     per 4-beat bar (barPulse), giving the visual a sense of song form.
      final double barR =
          currentRadius + (1.0 - model.barPulse) * (radius * 1.3);
      final double barA = model.barPulse * 0.45;
      if (barA > 0.02) {
        canvas.drawCircle(
          Offset.zero,
          barR,
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = 2.5 + 2.0 * model.barPulse
            ..color = model.peakColor.withValues(alpha: barA),
        );
      }
    }

    // 2. Radiating particles — emission speed & reach follow bass/kick energy.
    if (isPlaying && quality > 0) {
      final int particleCount = quality == 2 ? 34 : 22;
      final double flow = (model.timeMs / 1000.0) * 0.35;
      for (int p = 0; p < particleCount; p++) {
        final double pAngle =
            (p * 2 * math.pi) / particleCount + model.rotation * 0.4;
        final double progress = ((flow + p / particleCount) % 1.0);
        final double pRadius =
            currentRadius +
            12 +
            (progress *
                (70 + 40 * model.bass + 18 * model.vocal + 24 * model.kick));
        final double pSize = (4.2 - progress * 2.0) * (1.0 + 0.6 * model.kick);
        final double pOpacity =
            (0.55 + 0.4 * model.bassGlow) * (1.0 - progress);
        final double px = pRadius * math.cos(pAngle);
        final double py = pRadius * math.sin(pAngle);
        final Paint pPaint = Paint()
          ..style = PaintingStyle.fill
          ..color =
              (shiftedColors.isNotEmpty
                      ? shiftedColors[p % shiftedColors.length]
                      : Colors.white)
                  .withValues(alpha: pOpacity.clamp(0.0, 1.0));
        canvas.drawCircle(Offset(px, py), pSize, pPaint);
      }
    }

    // 3. Radial wave lines — every bar's length comes from the shared band model,
    //    so bass (lower arc), vocals (middle), treble (upper) all move in sync.
    //    A short inward stub adds depth for a fuller, premium look.
    for (int i = 0; i < lineCount; i++) {
      final double angle = (i * 2 * math.pi) / lineCount;
      // Mirror the spectrum across the vertical axis: n sweeps 0→1→0 around the
      // ring so the left and right halves are symmetric. Reads as a *calibrated*
      // audio ring (bass at the sides, treble at top/bottom) instead of a
      // scattered pattern — every bar is still a pure function of the band model.
      final double nSym = 1.0 - (2.0 * (i / lineCount) - 1.0).abs();
      final double factor = isPlaying
          ? (0.05 + 0.85 * model.sample(nSym))
          : 0.05;

      final double startR = currentRadius + 6;
      final double endR = currentRadius + 6 + (radius * factor);

      final double cosA = math.cos(angle);
      final double sinA = math.sin(angle);
      final double startX = startR * cosA;
      final double startY = startR * sinA;
      final double endX = endR * cosA;
      final double endY = endR * sinA;

      if (quality > 0) {
        canvas.drawLine(Offset(startX, startY), Offset(endX, endY), glowPaint);
      }
      canvas.drawLine(Offset(startX, startY), Offset(endX, endY), corePaint);

      // Inner-facing stubs (high-end only) — reach in with the bass for depth.
      if (quality == 2) {
        final double inR = currentRadius - 4 - (radius * 0.18 * factor);
        canvas.drawLine(
          Offset(startR * cosA, startR * sinA),
          Offset(inR * cosA, inR * sinA),
          corePaint,
        );
      }
    }

    // 4. Air sparkles — tiny high-frequency twinkles that ride the outer edge
    //    and flicker with the air/shimmer band. Pure top-end premium detail.
    if (isPlaying && quality > 0) {
      final int sparkleCount = quality == 2 ? 26 : 14;
      final double twinkle = model.timeMs / 1000.0 * 3.0;
      for (int s = 0; s < sparkleCount; s++) {
        final double a =
            (s * 2 * math.pi) / sparkleCount - model.rotation * 0.8;
        final double flick =
            0.5 + 0.5 * math.sin(twinkle + s * 1.7 + _sparkleSeed(s));
        final double sA = (model.air * flick - 0.35).clamp(0.0, 1.0);
        if (sA <= 0.02) continue;
        final double sr = currentRadius + radius * (0.55 + 0.4 * flick);
        canvas.drawCircle(
          Offset(sr * math.cos(a), sr * math.sin(a)),
          1.2 + 1.6 * flick,
          Paint()
            ..style = PaintingStyle.fill
            ..color = model.peakColor.withValues(alpha: 0.7 * sA),
        );
      }
    }

    canvas.restore();
  }

  // Stable per-sparkle phase offset so twinkles don't march in lock-step.
  double _sparkleSeed(int s) => ((seed.abs() >> (s % 12)) % 628) / 100.0;

  @override
  bool shouldRepaint(covariant CircularVisualizerPainter oldDelegate) =>
      oldDelegate.timeMs != timeMs ||
      oldDelegate.isPlaying != isPlaying ||
      oldDelegate.seed != seed ||
      oldDelegate.quality != quality ||
      oldDelegate.bassMultiplier != bassMultiplier ||
      oldDelegate.vocalMultiplier != vocalMultiplier ||
      oldDelegate.trebleMultiplier != trebleMultiplier;
}

class FluidWaveformPainter extends CustomPainter {
  final double timeMs;
  final int seed;
  final List<Color> colors;
  final bool isPlaying;
  final int quality;
  final double bassMultiplier;
  final double vocalMultiplier;
  final double trebleMultiplier;

  FluidWaveformPainter({
    required this.timeMs,
    required this.seed,
    required this.colors,
    required this.isPlaying,
    required this.quality,
    this.bassMultiplier = 1.0,
    this.vocalMultiplier = 1.0,
    this.trebleMultiplier = 1.0,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final model = VisualSyncModel(
      seed: seed,
      timeMs: timeMs,
      isPlaying: isPlaying,
      bassMultiplier: bassMultiplier,
      vocalMultiplier: vocalMultiplier,
      trebleMultiplier: trebleMultiplier,
    );

    final double midY = size.height / 2;
    final double height = size.height;
    final double width = size.width;
    // Coarser sampling on low-end devices keeps the wave buttery-smooth.
    final double step = quality == 2 ? 2.0 : (quality == 1 ? 3.0 : 5.0);

    // Bass-reactive palette — colours brighten & shift on every kick.
    final shiftedColors = model.dynamicColors(colors);
    final Color color1 = shiftedColors.isNotEmpty
        ? shiftedColors[0]
        : Colors.blue;
    final Color color2 = shiftedColors.length > 1
        ? shiftedColors[1]
        : Colors.purple;
    final Color color3 = shiftedColors.length > 2
        ? shiftedColors[2]
        : Colors.pink;

    final double t = model.timeMs / 1000.0;
    // Wave travel is tied to real time, and heights come from the band model —
    // so the three layers breathe with bass / vocals / treble, phase-locked.
    final double phase1 = t * 1.6;
    final double phase2 = t * 1.1;
    final double phase3 = t * 2.4;

    final shaderRect = Rect.fromLTWH(0, 0, width, height);

    // Bass glow underlay — a soft radial bloom from the centre line that swells
    // on every kick and flares once per bar (barPulse) for a lit-from-within,
    // song-structured body. Its colour leans toward the secondary peak hue.
    if (isPlaying && quality > 0) {
      final double bloomA =
          (0.10 + 0.28 * model.bassGlow + 0.14 * model.barPulse).clamp(
            0.0,
            0.6,
          );
      final Color bloomColor = Color.lerp(color1, model.peakColor, 0.35)!;
      final Paint bloom = Paint()
        ..style = PaintingStyle.fill
        ..shader = RadialGradient(
          center: Alignment.center,
          radius: 0.9,
          colors: [
            bloomColor.withValues(alpha: bloomA),
            bloomColor.withValues(alpha: 0.0),
          ],
        ).createShader(shaderRect);
      canvas.drawRect(shaderRect, bloom);
    }

    Paint fill(Color c, double a0, double a1) => Paint()
      ..style = PaintingStyle.fill
      ..shader = LinearGradient(
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
        colors: [
          c.withValues(alpha: a0),
          c.withValues(alpha: a1),
        ],
      ).createShader(shaderRect);

    // Builds one wave layer. [offset] shifts its centre line; [amp] is its peak
    // amplitude in px; [k1]/[k2] set spatial frequency; [phase] its scroll.
    // [mirror] flips it above the centre line and closes to the top edge, so a
    // faint reflected copy can be drawn for a symmetric, premium waveform.
    Path buildWave(
      double offset,
      double amp,
      double k1,
      double k2,
      double phase, {
      required bool closed,
      bool mirror = false,
    }) {
      final double dir = mirror ? -1.0 : 1.0;
      // Per-layer phase seed so the three layers use distinct — but fully
      // deterministic — noise fields (no Random).
      final double sPhase = seed * 0.0007 + k2 * 37.0;

      double waveY(double x) {
        final double n = width == 0 ? 0.0 : x / width;
        // Local band energy at this x → the wave still traces the spectrum.
        final double band = isPlaying ? model.sample(n) : 0.05;
        // Coherent fractal noise scrolling LEFT→RIGHT (a feature moves right as
        // the time-driven phase grows). NO end-taper: full amplitude edge-to-
        // edge, so the layers stay overlapped with no dead space at the sides.
        final double shape = isPlaying
            ? model.fbm(x * k1 - phase, phase * 0.12, sPhase)
            : math.sin(x * k1 - phase) * 0.3;
        return midY + offset * dir + dir * amp * (0.55 + 0.9 * band) * shape;
      }

      final Path p = Path();
      final double y0 = waveY(0);
      if (closed) {
        p.moveTo(0, mirror ? 0 : height);
        p.lineTo(0, y0);
      } else {
        p.moveTo(0, y0);
      }
      for (double x = step; x <= width; x += step) {
        p.lineTo(x, waveY(x));
      }
      if (closed) {
        p.lineTo(width, mirror ? 0 : height);
        p.close();
      }
      return p;
    }

    // Amplitudes get an extra push from the live bass glow so peaks punch harder.
    final double bassAmp =
        (isPlaying ? 34.0 : 3.0) *
        bassMultiplier *
        (1.0 + 0.5 * model.bassGlow);
    final double vocalAmp =
        (isPlaying ? 22.0 : 2.0) *
        vocalMultiplier *
        (1.0 + 0.3 * model.bassGlow);
    final double trebleAmp =
        (isPlaying ? 13.0 : 1.0) *
        trebleMultiplier *
        (1.0 + 0.2 * model.treble);

    // Faint mirrored reflection above the centre line (symmetry = premium feel).
    if (isPlaying && quality > 0) {
      canvas.drawPath(
        buildWave(0, bassAmp, 0.007, 0.013, phase1, closed: true, mirror: true),
        fill(color1, 0.0, 0.20),
      );
      canvas.drawPath(
        buildWave(
          4,
          vocalAmp,
          0.018,
          0.035,
          phase2,
          closed: true,
          mirror: true,
        ),
        fill(color2, 0.0, 0.14),
      );
    }

    // Fills
    canvas.drawPath(
      buildWave(0, bassAmp, 0.007, 0.013, phase1, closed: true),
      fill(color1, 0.45, 0.02),
    );
    canvas.drawPath(
      buildWave(4, vocalAmp, 0.018, 0.035, phase2, closed: true),
      fill(color2, 0.35, 0.01),
    );
    canvas.drawPath(
      buildWave(-6, trebleAmp, 0.07, 0.13, phase3, closed: true),
      fill(color3, 0.25, 0.0),
    );

    // Crisp border strokes on top — the bass line glows harder on the kick.
    canvas.drawPath(
      buildWave(0, bassAmp, 0.007, 0.013, phase1, closed: false),
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2.0 + 1.5 * model.bassGlow
        ..color = color1.withValues(alpha: 0.8)
        ..maskFilter = quality > 0
            ? MaskFilter.blur(BlurStyle.normal, 1.0 + 3.0 * model.bassGlow)
            : null,
    );
    canvas.drawPath(
      buildWave(4, vocalAmp, 0.018, 0.035, phase2, closed: false),
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.5
        ..color = color2.withValues(alpha: 0.7),
    );
    canvas.drawPath(
      buildWave(-6, trebleAmp, 0.07, 0.13, phase3, closed: false),
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.0
        ..color = color3.withValues(alpha: 0.5),
    );

    // Air shimmer highlight — a thin, fast top line in the secondary peak colour
    // whose brightness flickers with the air band, adding crisp gradient depth.
    if (isPlaying && quality > 0) {
      final double airTrebleAmp = trebleAmp * 1.15;
      canvas.drawPath(
        buildWave(-6, airTrebleAmp, 0.11, 0.22, phase3 * 1.6, closed: false),
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.0
          ..color = model.peakColor.withValues(
            alpha: (0.25 + 0.55 * model.air).clamp(0.0, 0.9),
          ),
      );
    }
  }

  @override
  bool shouldRepaint(covariant FluidWaveformPainter oldDelegate) =>
      oldDelegate.timeMs != timeMs ||
      oldDelegate.isPlaying != isPlaying ||
      oldDelegate.seed != seed ||
      oldDelegate.quality != quality ||
      oldDelegate.bassMultiplier != bassMultiplier ||
      oldDelegate.vocalMultiplier != vocalMultiplier ||
      oldDelegate.trebleMultiplier != trebleMultiplier;
}

class VinylReflectionPainter extends CustomPainter {
  const VinylReflectionPainter();

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final radius = size.width / 2;

    // Paint concentric groove lines
    final groovePaint = Paint()
      ..style = PaintingStyle.stroke
      ..color = Colors.white.withValues(alpha: 0.04)
      ..strokeWidth = 1.0;

    for (double r = radius * 0.25; r < radius; r += 6.0) {
      canvas.drawCircle(center, r, groovePaint);
    }

    // Paint glossy reflection wedges (two opposite cones of light)
    final shinePaint = Paint()
      ..shader = RadialGradient(
        colors: [
          Colors.white.withValues(alpha: 0.15),
          Colors.white.withValues(alpha: 0.05),
          Colors.transparent,
        ],
        stops: const [0.0, 0.45, 1.0],
      ).createShader(Rect.fromCircle(center: center, radius: radius));

    final path = Path()
      ..moveTo(center.dx, center.dy)
      ..lineTo(center.dx - radius * 0.7, center.dy - radius * 0.7)
      ..lineTo(center.dx - radius * 0.3, center.dy - radius * 0.95)
      ..close()
      ..moveTo(center.dx, center.dy)
      ..lineTo(center.dx + radius * 0.7, center.dy + radius * 0.7)
      ..lineTo(center.dx + radius * 0.3, center.dy + radius * 0.95)
      ..close();

    canvas.drawPath(path, shinePaint);
  }

  @override
  bool shouldRepaint(covariant VinylReflectionPainter oldDelegate) => false;
}

class TonearmPainter extends CustomPainter {
  final double angle;

  const TonearmPainter({required this.angle});

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color =
          const Color(0xFFDCDCDC) // Metallic silver
      ..strokeWidth = 3.5
      ..strokeCap = StrokeCap.round
      ..style = PaintingStyle.stroke;

    final darkPaint = Paint()
      ..color = const Color(0xFF1E1E2E)
      ..style = PaintingStyle.fill;

    // Pivot center of base aligned to topCenter of box
    final pivot = Offset(size.width / 2, 16);

    // Anchor base rings (3D look)
    canvas.drawCircle(
      pivot,
      14,
      Paint()
        ..color = Colors.black26
        ..style = PaintingStyle.fill,
    );
    canvas.drawCircle(pivot, 12, darkPaint);
    canvas.drawCircle(
      pivot,
      12,
      Paint()
        ..color = const Color(0xFF444454)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2,
    );
    canvas.drawCircle(
      pivot,
      6,
      Paint()
        ..color = const Color(0xFF888898)
        ..style = PaintingStyle.fill,
    );

    // Curved metallic rod starting from pivot
    final path = Path()
      ..moveTo(pivot.dx, pivot.dy)
      ..quadraticBezierTo(
        pivot.dx + 25,
        pivot.dy + size.height * 0.35,
        pivot.dx + 12,
        pivot.dy + size.height * 0.75,
      )
      ..lineTo(pivot.dx + 6, pivot.dy + size.height * 0.88);
    canvas.drawPath(path, paint);

    // Cartridge/Headshell (dark rectangular block at the end)
    final cartridgePaint = Paint()
      ..color = const Color(0xFF161622)
      ..style = PaintingStyle.fill;

    canvas.save();
    canvas.translate(pivot.dx + 6, pivot.dy + size.height * 0.88);
    canvas.rotate(0.25); // Cartridge offset angle

    // Draw cartridge shadow & block
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        const Rect.fromLTWH(-6, 0, 12, 22),
        const Radius.circular(3),
      ),
      cartridgePaint,
    );
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        const Rect.fromLTWH(-6, 0, 12, 22),
        const Radius.circular(3),
      ),
      Paint()
        ..color = const Color(0xFF555565)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.0,
    );

    // Stylus needle tip highlight (vibrant red dot)
    canvas.drawCircle(
      const Offset(0, 18),
      2.2,
      Paint()
        ..color = const Color(0xFFFF3B30)
        ..style = PaintingStyle.fill,
    );
    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant TonearmPainter oldDelegate) =>
      oldDelegate.angle != angle;
}
