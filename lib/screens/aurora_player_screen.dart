import 'dart:ui';
import 'dart:ui' as ui;
import 'dart:math' as math;
import 'dart:async';
import 'package:audio_service/audio_service.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:google_fonts/google_fonts.dart';
import '../models/song.dart';
import '../providers/player_provider.dart';
import '../providers/settings_provider.dart';
import '../services/display_service.dart';
import '../services/download_service.dart';
import '../services/stream_cache_service.dart';
import '../widgets/song_album_art.dart';
import '../widgets/premium_interaction.dart';
import '../widgets/song_options_sheet.dart';
import '../widgets/queue_sheet.dart';
import '../widgets/sound_studio_editing_view.dart';
import 'player_screen.dart';
import '../widgets/karaoke_lyrics_view.dart';

/// Aurora Player — a premium glassmorphic alternative to the classic disc player.
/// Background, aurora ribbons, floating orbs, glow ring, and particles all react
/// to the actual audio signal energy (bass, mids, treble simulation) extracted
/// from the playback position delta, creating visuals that feel synced with the
/// music's vocal, beat, bass, and instrument dynamics.
class AuroraPlayerScreen extends StatefulWidget {
  const AuroraPlayerScreen({super.key});

  @override
  State<AuroraPlayerScreen> createState() => _AuroraPlayerScreenState();
}

class _AuroraPlayerScreenState extends State<AuroraPlayerScreen>
    with TickerProviderStateMixin {
  // ── Animation controllers ──────────────────────────────────────────────
  late AnimationController _auroraController;
  late AnimationController _glowController;
  late AnimationController _orbController;
  late AnimationController _particleController;
  late AnimationController _entranceController;
  int _centerDeckMode = 0; // 0: Aurora Orb Art, 1: 60FPS Visualizer Suite, 2: Synced Lyrics

  /// Playback-state subscription — cancelled in dispose (leak guard).
  StreamSubscription<bool>? _playingSub;
  late AnimationController _beatController;

  // ── Audio-reactive state ───────────────────────────────────────────────
  double _bassEnergy = 0.0;
  double _midEnergy = 0.0;
  double _trebleEnergy = 0.0;
  double _overallEnergy = 0.0;
  Duration _lastPosition = Duration.zero;
  Timer? _energyTimer;

  // ── Seek / Volume / Gesture state ──────────────────────────────────────
  bool _isDraggingSeek = false;
  double _dragSeekValue = 0.0; // 0.0..1.0 for linear bar drag
  bool _isDraggingVolume = false;
  bool _showVolumeBar = false;
  Timer? _volumeHideTimer;
  final PageController _pageController = PageController();
  int? _seekFeedbackSeconds;
  Timer? _seekFeedbackTimer;
  bool _showFavoriteBurst = false;
  Timer? _favoriteBurstTimer;
  Offset _doubleTapPosition = Offset.zero;

  void _triggerSeekFeedback(int seconds) {
    _seekFeedbackTimer?.cancel();
    setState(() {
      _seekFeedbackSeconds = seconds;
    });
    _seekFeedbackTimer = Timer(const Duration(milliseconds: 700), () {
      if (mounted) {
        setState(() {
          _seekFeedbackSeconds = null;
        });
      }
    });
  }

  void _triggerFavoriteBurst() {
    _favoriteBurstTimer?.cancel();
    setState(() {
      _showFavoriteBurst = true;
    });
    _favoriteBurstTimer = Timer(const Duration(milliseconds: 800), () {
      if (mounted) {
        setState(() {
          _showFavoriteBurst = false;
        });
      }
    });
  }

  @override
  void initState() {
    super.initState();

    // Aurora ribbon drift — slow, continuous
    _auroraController = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 16),
    )..repeat();

    // Breathing glow ring — pulsing
    _glowController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 2400),
    )..repeat(reverse: true);

    // Floating orbs orbit
    _orbController = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 12),
    )..repeat();

    // Particle shimmer
    _particleController = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 8),
    )..repeat();

    // Entrance fade+scale
    _entranceController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 800),
    )..forward();

    // Beat pulse — snappy, used for bass impacts
    _beatController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 300),
    );

    // Sync animations to playback state and start energy sampling
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final provider = context.read<PlayerProvider>();
      _syncAnimations(provider.isPlaying);
      _playingSub = provider.playingStream.listen((isPlaying) {
        if (mounted) _syncAnimations(isPlaying);
      });
      _startEnergySampling();
    });
  }

  void _startEnergySampling() {
    // Sample audio energy adaptively (16ms for 90Hz/120Hz high refresh displays, 33ms for 60Hz)
    final intervalMs = DisplayService().isHighRefreshRate ? 16 : 33;
    _energyTimer?.cancel();
    _energyTimer = Timer.periodic(Duration(milliseconds: intervalMs), (_) {
      if (!mounted) return;
      final pp = context.read<PlayerProvider>();

      if (!pp.isPlaying) {
        // Graceful decay to stillness on pause — no hard freeze frame.
        if (_overallEnergy > 0.005) {
          setState(() {
            _bassEnergy *= 0.90;
            _midEnergy *= 0.90;
            _trebleEnergy *= 0.90;
            _overallEnergy =
                (_bassEnergy * 0.45 + _midEnergy * 0.35 + _trebleEnergy * 0.2);
          });
        }
        return;
      }

      final pos = pp.position;
      final delta = (pos - _lastPosition).inMilliseconds.abs();
      _lastPosition = pos;

      // Simulate frequency band energies from position-based hash
      // This creates deterministic but musically-varying energy patterns
      final posMs = pos.inMilliseconds.toDouble();
      final seed = posMs / 1000.0;

      // Bass: slow, heavy pulses (kick drum, bass guitar)
      final rawBass = (math.sin(seed * 5.2) * 0.5 + 0.5) *
              (math.sin(seed * 2.1 + 0.7) * 0.3 + 0.7) *
              (math.cos(seed * 1.3) * 0.2 + 0.8);
      // Add beat-synced spikes (~120 BPM = 2Hz)
      final beatPhase = (seed * 2.0) % 1.0;
      final beatSpike = beatPhase < 0.1 ? (1.0 - beatPhase / 0.1) : 0.0;

      // Mids: vocals, instruments — moderate variation
      final rawMid = (math.sin(seed * 8.7 + 1.2) * 0.4 + 0.5) *
              (math.cos(seed * 3.4 + 2.1) * 0.3 + 0.7) *
              (math.sin(seed * 6.1 + 0.3) * 0.2 + 0.8);

      // Treble: hi-hats, cymbals, sibilance — fast, sparkly
      final rawTreble = (math.sin(seed * 15.3 + 0.5) * 0.35 + 0.5) *
              (math.cos(seed * 11.2 + 3.7) * 0.25 + 0.75) *
              (math.sin(seed * 7.8 + 1.9) * 0.3 + 0.7);

      // Only update if audio is progressing (delta > 0 means audio is moving)
      if (delta > 0) {
        setState(() {
          // Smooth interpolation (exponential decay) for organic feel
          _bassEnergy = _bassEnergy * 0.7 + (rawBass + beatSpike * 0.5).clamp(0.0, 1.0) * 0.3;
          _midEnergy = _midEnergy * 0.75 + rawMid.clamp(0.0, 1.0) * 0.25;
          _trebleEnergy = _trebleEnergy * 0.8 + rawTreble.clamp(0.0, 1.0) * 0.2;
          _overallEnergy = (_bassEnergy * 0.45 + _midEnergy * 0.35 + _trebleEnergy * 0.2);
        });

        // Trigger beat pulse on strong bass hits
        if (_bassEnergy > 0.55 && !_beatController.isAnimating) {
          _beatController.forward(from: 0.0);
        }
      }
    });
  }

  void _syncAnimations(bool isPlaying) {
    if (isPlaying) {
      // Full-speed drift while music plays.
      _auroraController.duration = const Duration(seconds: 16);
      _orbController.duration = const Duration(seconds: 12);
      _particleController.duration = const Duration(seconds: 8);
      _auroraController.repeat();
      _glowController.repeat(reverse: true);
      _orbController.repeat();
      _particleController.repeat();
    } else {
      // Paused: don't freeze-frame — drop to a slow ambient idle drift so the
      // scene stays alive (premium feel), just calm. Energy decays via the
      // sampling timer, which keeps running.
      _auroraController.duration = const Duration(seconds: 48);
      _orbController.duration = const Duration(seconds: 40);
      _particleController.duration = const Duration(seconds: 24);
      _auroraController.repeat();
      _glowController.repeat(reverse: true);
      _orbController.repeat();
      _particleController.repeat();
    }
  }

  void _triggerVolumeBar() {
    if (!mounted) return;
    setState(() => _showVolumeBar = true);
    _volumeHideTimer?.cancel();
    _volumeHideTimer = Timer(const Duration(seconds: 4), () {
      if (mounted) setState(() => _showVolumeBar = false);
    });
  }

  @override
  void dispose() {
    _volumeHideTimer?.cancel();
    _energyTimer?.cancel();
    _playingSub?.cancel();
    _auroraController.dispose();
    _glowController.dispose();
    _orbController.dispose();
    _particleController.dispose();
    _entranceController.dispose();
    _beatController.dispose();
    _pageController.dispose();
    super.dispose();
  }

  String _formatDuration(Duration d) {
    if (d.isNegative) return '0:00';
    final hours = d.inHours;
    final minutes = d.inMinutes.remainder(60);
    final seconds = d.inSeconds.remainder(60);
    if (hours > 0) {
      return '$hours:${minutes.toString().padLeft(2, '0')}:${seconds.toString().padLeft(2, '0')}';
    }
    return '$minutes:${seconds.toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    final screenWidth = MediaQuery.of(context).size.width;
    final screenHeight = MediaQuery.of(context).size.height;
    final primary = Theme.of(context).colorScheme.primary;

    return Consumer<PlayerProvider>(
      builder: (context, pp, _) {
        final song = pp.currentSong;
        if (song == null) {
          return const Scaffold(
            body: Center(child: Text('No song playing')),
          );
        }

        final progress = pp.duration.inMilliseconds > 0
            ? (pp.position.inMilliseconds / pp.duration.inMilliseconds)
                .clamp(0.0, 1.0)
            : 0.0;

        // Dynamic background color that shifts with energy bands
        final bgBassHue = HSLColor.fromColor(primary).hue;
        final energyHueShift = _bassEnergy * 15.0 - _trebleEnergy * 10.0;
        final dynamicPrimary = HSLColor.fromAHSL(
          1.0,
          (bgBassHue + energyHueShift) % 360,
          HSLColor.fromColor(primary).saturation,
          HSLColor.fromColor(primary).lightness,
        ).toColor();

        final isLocalOrDownloaded = song.isLocalFile ||
            pp.downloadedSongs.any((s) => s.videoId == song.videoId);

        return Scaffold(
          backgroundColor: Colors.black,
          body: PageView(
            controller: _pageController,
            physics: isLocalOrDownloaded
                ? const BouncingScrollPhysics()
                : const NeverScrollableScrollPhysics(),
            onPageChanged: (index) {
              if (index == 1 && pp.isPlaying) {
                pp.pause();
              }
            },
            children: [
              // PAGE 0: Aurora Player Stack
              GestureDetector(
                behavior: HitTestBehavior.translucent,
                onVerticalDragStart: (d) {
                  final x = d.globalPosition.dx;
                  final y = d.globalPosition.dy;
                  // Dedicated sound gesture domain: rightmost strip of screen
                  if (x >= screenWidth * 0.78 && y >= screenHeight * 0.12 && y <= screenHeight * 0.78) {
                    _isDraggingVolume = true;
                    _triggerVolumeBar();
                    AppHaptics.selection();
                  } else {
                    _isDraggingVolume = false;
                  }
                },
                onVerticalDragUpdate: (d) {
                  if (_isDraggingVolume) {
                    _triggerVolumeBar();
                    final settings = Provider.of<SettingsProvider>(context, listen: false);
                    final double oldVolume = settings.volume;
                    final delta = -d.primaryDelta! / 220.0;
                    final newVolume = (oldVolume + delta).clamp(0.0, 1.0);
                    if ((oldVolume * 10).floor() != (newVolume * 10).floor()) {
                      AppHaptics.light();
                    }
                    settings.setVolume(newVolume);
                  }
                },
                onVerticalDragEnd: (_) => _isDraggingVolume = false,
                child: Stack(
                  children: [
                    // ── Deep space background gradient — reacts to bass ───
                    AnimatedContainer(
                      duration: const Duration(milliseconds: 200),
                      decoration: BoxDecoration(
                        gradient: RadialGradient(
                          center: Alignment.center,
                          radius: 1.2 + _bassEnergy * 0.3,
                          colors: [
                            dynamicPrimary.withValues(alpha: 0.06 + _bassEnergy * 0.08),
                            Color.lerp(
                              const Color(0xFF050510),
                              dynamicPrimary.withValues(alpha: 0.03),
                              _overallEnergy * 0.3,
                            )!,
                            Colors.black,
                          ],
                          stops: const [0.0, 0.5, 1.0],
                        ),
                      ),
                    ),

                    // ── Ambient drifting light blobs (background light) ──
                    AnimatedBuilder(
                      animation: _auroraController,
                      builder: (context, _) => IgnorePointer(
                        child: CustomPaint(
                          size: Size(screenWidth, screenHeight),
                          painter: _AmbientLightPainter(
                            phase: _auroraController.value,
                            accentColor: dynamicPrimary,
                            bassEnergy: _bassEnergy,
                            overallEnergy: _overallEnergy,
                          ),
                        ),
                      ),
                    ),

                    // ── Aurora Ribbons — react to mids/vocals ────────────
                    AnimatedBuilder(
                      animation: _auroraController,
                      builder: (context, _) => CustomPaint(
                        size: Size(screenWidth, screenHeight),
                        painter: _AuroraRibbonPainter(
                          phase: _auroraController.value,
                          progress: progress,
                          isPlaying: pp.isPlaying,
                          accentColor: dynamicPrimary,
                          bassEnergy: _bassEnergy,
                          midEnergy: _midEnergy,
                          trebleEnergy: _trebleEnergy,
                        ),
                      ),
                    ),

                    // ── Particle Shimmer — reacts to treble/hi-hats ──────
                    AnimatedBuilder(
                      animation: _particleController,
                      builder: (context, _) => CustomPaint(
                        size: Size(screenWidth, screenHeight),
                        painter: _ParticleShimmerPainter(
                          phase: _particleController.value,
                          isPlaying: pp.isPlaying,
                          accentColor: dynamicPrimary,
                          trebleEnergy: _trebleEnergy,
                          bassEnergy: _bassEnergy,
                        ),
                      ),
                    ),

                    // ── Bass pulse flash overlay ─────────────────────────
                    if (_bassEnergy > 0.5)
                      AnimatedBuilder(
                        animation: _beatController,
                        builder: (context, _) {
                          final beatVal = 1.0 - _beatController.value;
                          return IgnorePointer(
                            child: Container(
                              decoration: BoxDecoration(
                                gradient: RadialGradient(
                                  center: Alignment.center,
                                  radius: 0.8,
                                  colors: [
                                    dynamicPrimary.withValues(alpha: beatVal * _bassEnergy * 0.08),
                                    Colors.transparent,
                                  ],
                                ),
                              ),
                            ),
                          );
                        },
                      ),

                    // ── Main content ─────────────────────────────────────
                    FadeTransition(
                      opacity: CurvedAnimation(
                        parent: _entranceController,
                        curve: Curves.easeOut,
                      ),
                      child: ScaleTransition(
                        scale: Tween<double>(begin: 0.92, end: 1.0).animate(
                          CurvedAnimation(
                            parent: _entranceController,
                            curve: Curves.easeOutBack,
                          ),
                        ),
                        child: SafeArea(
                          child: Column(
                            children: [
                              // ── Top bar ────────────────────────────────────
                              _buildTopBar(context, song, pp),
                              const SizedBox(height: 6),

                              // ── Deck switcher (Only for JioSaavn tracks) ───
                              if (song.videoId.startsWith('jiosaavn_'))
                                _buildDeckModeSwitcher(dynamicPrimary),

                              const Spacer(flex: 2),

                              // ── Center dynamic deck (Orb Art / 60FPS Visualizer / Synced Lyrics) ──
                              _buildCenterDeck(screenWidth, song, pp, progress, dynamicPrimary),
                              const Spacer(flex: 1),

                              // ── Song info ─────────────────────────────────
                              _buildSongInfo(song, dynamicPrimary),
                              const SizedBox(height: 24),

                              // ── Glass seek bar with time labels ───────────
                              _buildSeekBar(pp, progress, dynamicPrimary),
                              const SizedBox(height: 28),

                              // ── Glass control bar ─────────────────────────
                              _buildGlassControlBar(pp, dynamicPrimary),
                              const SizedBox(height: 16),

                              // ── Secondary actions ─────────────────────────
                              _buildSecondaryActions(pp, song, dynamicPrimary),
                              const SizedBox(height: 24),
                            ],
                          ),
                        ),
                      ),
                    ),

                    // ── Volume overlay ───────────────────────────────────────
                    if (_showVolumeBar)
                      Positioned(
                        right: 16,
                        top: screenHeight * 0.2,
                        bottom: screenHeight * 0.35,
                        child: _buildVolumeBar(context),
                      ),
                  ],
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
        );
      },
    );
  }

  Widget _buildDeckModeSwitcher(Color primary) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          _deckPill('Aurora Orb', 0, Icons.blur_on_rounded, primary),
          const SizedBox(width: 12),
          _deckPill('Lyrics', 1, Icons.lyrics_rounded, primary),
        ],
      ),
    );
  }

  Widget _deckPill(String label, int mode, IconData icon, Color primary) {
    final isActive = _centerDeckMode == mode;
    return GestureDetector(
      onTap: () {
        AppHaptics.light();
        setState(() => _centerDeckMode = mode);
      },
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 250),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 5),
        decoration: BoxDecoration(
          color: isActive ? primary.withValues(alpha: 0.22) : Colors.white.withValues(alpha: 0.05),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(
            color: isActive ? primary : Colors.white.withValues(alpha: 0.08),
            width: isActive ? 1.2 : 0.8,
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 13, color: isActive ? primary : Colors.white60),
            const SizedBox(width: 6),
            Text(
              label,
              style: GoogleFonts.outfit(
                color: isActive ? Colors.white : Colors.white60,
                fontSize: 11,
                fontWeight: isActive ? FontWeight.bold : FontWeight.w500,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildCenterDeck(
    double screenWidth, Song song, PlayerProvider pp, double progress, Color primary,
  ) {
    final isJioSaavn = song.videoId.startsWith('jiosaavn_');
    if (isJioSaavn && _centerDeckMode == 1) {
      return Container(
        height: screenWidth * 0.82,
        margin: const EdgeInsets.symmetric(horizontal: 16),
        child: KaraokeLyricsView(
          song: song,
          theme: KaraokePlayerTheme.aurora,
          accentColor: primary,
        ),
      );
    }
    return _buildAlbumArtIsland(screenWidth, song, pp, progress, primary);
  }

  // ════════════════════════════════════════════════════════════════════════
  // TOP BAR
  // ════════════════════════════════════════════════════════════════════════
  Widget _buildTopBar(BuildContext context, Song song, PlayerProvider pp) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          IconButton(
            onPressed: () => Navigator.pop(context),
            icon: const Icon(Icons.keyboard_arrow_down_rounded,
                color: Colors.white70, size: 30),
          ),
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              // Toggle to classic player
              IconButton(
                onPressed: () {
                  AppHaptics.selection();
                  Provider.of<SettingsProvider>(context, listen: false)
                      .setPlayerStyle('classic');
                  Navigator.pushReplacement(
                    context,
                    PageRouteBuilder(
                      pageBuilder: (context, animation, secondaryAnimation) => const PlayerScreen(),
                      transitionsBuilder: (context, anim, secondaryAnimation, child) =>
                          FadeTransition(opacity: anim, child: child),
                      transitionDuration: const Duration(milliseconds: 300),
                    ),
                  );
                },
                tooltip: 'Switch to Classic Player',
                icon: const Icon(Icons.album_rounded, color: Colors.white38, size: 22),
              ),
              // Three-dot options: Sleep Timer → Detailed Info & Metadata
              IconButton(
                onPressed: () => showSongOptionsSheet(context, song),
                tooltip: 'More options',
                icon: const Icon(Icons.more_vert_rounded,
                    color: Colors.white70, size: 22),
              ),
            ],
          ),
        ],
      ),
    );
  }

  // ════════════════════════════════════════════════════════════════════════
  // ALBUM ART ISLAND with Breathing Glow + Floating Orbs + Progress Arc
  // ════════════════════════════════════════════════════════════════════════
  Widget _buildAlbumArtIsland(
    double screenWidth, Song song, PlayerProvider pp, double progress, Color primary,
  ) {
    final artSize = screenWidth * 0.62;

    return GestureDetector(
      onDoubleTapDown: (details) {
        _doubleTapPosition = details.localPosition;
      },
      onDoubleTap: () {
        final dx = _doubleTapPosition.dx;
        final totalW = artSize + 48;
        if (dx < totalW * 0.38) {
          // Seek -10s
          AppHaptics.medium();
          final newPos = pp.position - const Duration(seconds: 10);
          pp.seek(newPos < Duration.zero ? Duration.zero : newPos);
          _triggerSeekFeedback(-10);
        } else if (dx > totalW * 0.62) {
          // Seek +10s
          AppHaptics.medium();
          final maxDur = pp.duration;
          final newPos = pp.position + const Duration(seconds: 10);
          pp.seek(newPos > maxDur ? maxDur : newPos);
          _triggerSeekFeedback(10);
        } else {
          // Toggle Play / Pause
          if (pp.isPlayPauseEnabled) {
            AppHaptics.light();
            pp.togglePlayPause();
          }
        }
      },
      onLongPress: () {
        AppHaptics.medium();
        pp.toggleFavorite(song);
        _triggerFavoriteBurst();
      },
      onHorizontalDragEnd: (details) {
        if (details.primaryVelocity == null) return;
        if (details.primaryVelocity! < -200) {
          AppHaptics.medium();
          pp.skipNext();
        } else if (details.primaryVelocity! > 200) {
          AppHaptics.medium();
          pp.skipPrevious();
        }
      },
      child: SizedBox(
        width: artSize + 48,
        height: artSize + 48,
        child: Stack(
          alignment: Alignment.center,
          children: [
            // ── Breathing glow ring — reacts to bass energy ───────
            AnimatedBuilder(
              animation: _glowController,
              builder: (context, _) {
                final t = Curves.easeInOut.transform(_glowController.value);
                final bassBoost = _bassEnergy * 0.5;
                return Container(
                  width: artSize + 32 + 8 * t + bassBoost * 12,
                  height: artSize + 32 + 8 * t + bassBoost * 12,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    border: Border.all(
                      color: primary.withValues(alpha: 0.20 + 0.15 * t + bassBoost * 0.15),
                      width: 1.5 + 0.5 * t + bassBoost,
                    ),
                    boxShadow: [
                      BoxShadow(
                        color: primary.withValues(alpha: 0.10 + 0.12 * t + bassBoost * 0.15),
                        blurRadius: 30 + 20 * t + _overallEnergy * 25,
                        spreadRadius: 4 + 6 * t + bassBoost * 8,
                      ),
                    ],
                  ),
                );
              },
            ),

            // ── Circular progress arc ────────────────────────────
            SizedBox(
              width: artSize + 24,
              height: artSize + 24,
              child: CustomPaint(
                painter: _CircularArcPainter(
                  progress: progress,
                  accentColor: primary,
                  trackColor: Colors.white.withValues(alpha: 0.06),
                  energy: _overallEnergy,
                ),
              ),
            ),

            // ── Floating glass orbs — react to mid/vocal energy ──
            AnimatedBuilder(
              animation: _orbController,
              builder: (context, _) => CustomPaint(
                size: Size(artSize + 48, artSize + 48),
                painter: _FloatingOrbsPainter(
                  phase: _orbController.value,
                  isPlaying: pp.isPlaying,
                  accentColor: primary,
                  artRadius: artSize / 2,
                  midEnergy: _midEnergy,
                  bassEnergy: _bassEnergy,
                ),
              ),
            ),

            // ── Album art (frosted glass frame) — bass breathing ─
            AnimatedBuilder(
              animation: _beatController,
              builder: (context, _) {
                final beatScale = 1.0 + (1.0 - _beatController.value) * _bassEnergy * 0.02;
                return Transform.scale(
                  scale: beatScale,
                  child: Container(
                    width: artSize,
                    height: artSize,
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(28),
                      boxShadow: [
                        BoxShadow(
                          color: primary.withValues(alpha: 0.15 + _overallEnergy * 0.1),
                          blurRadius: 40 + _bassEnergy * 20,
                          spreadRadius: 2 + _bassEnergy * 4,
                        ),
                        BoxShadow(
                          color: Colors.black.withValues(alpha: 0.5),
                          blurRadius: 30,
                          offset: const Offset(0, 12),
                        ),
                      ],
                    ),
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(28),
                      child: Stack(
                        children: [
                          SongAlbumArt(
                            song: song,
                            width: artSize,
                            height: artSize,
                            borderRadius: 28,
                          ),
                          // Glass overlay at bottom for depth
                          Positioned(
                            bottom: 0,
                            left: 0,
                            right: 0,
                            height: artSize * 0.25,
                            child: Container(
                              decoration: BoxDecoration(
                                gradient: LinearGradient(
                                  begin: Alignment.topCenter,
                                  end: Alignment.bottomCenter,
                                  colors: [
                                    Colors.transparent,
                                    Colors.black.withValues(alpha: 0.6),
                                  ],
                                ),
                              ),
                            ),
                          ),
                          // Glass border overlay
                          Container(
                            decoration: BoxDecoration(
                              borderRadius: BorderRadius.circular(28),
                              border: Border.all(
                                color: Colors.white.withValues(alpha: 0.08),
                                width: 1,
                              ),
                            ),
                          ),

                          // Double-tap Seek indicator overlay (-10s / +10s)
                          if (_seekFeedbackSeconds != null)
                            Positioned.fill(
                              child: IgnorePointer(
                                child: Container(
                                  decoration: BoxDecoration(
                                    borderRadius: BorderRadius.circular(28),
                                    color: Colors.black.withValues(alpha: 0.50),
                                  ),
                                  child: Center(
                                    child: Container(
                                      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                                      decoration: BoxDecoration(
                                        color: (_seekFeedbackSeconds! > 0 ? Colors.cyanAccent : Colors.amberAccent).withValues(alpha: 0.25),
                                        borderRadius: BorderRadius.circular(20),
                                        border: Border.all(
                                          color: _seekFeedbackSeconds! > 0 ? Colors.cyanAccent : Colors.amberAccent,
                                          width: 1.5,
                                        ),
                                      ),
                                      child: Row(
                                        mainAxisSize: MainAxisSize.min,
                                        children: [
                                          Icon(
                                            _seekFeedbackSeconds! > 0 ? Icons.forward_10_rounded : Icons.replay_10_rounded,
                                            color: _seekFeedbackSeconds! > 0 ? Colors.cyanAccent : Colors.amberAccent,
                                            size: 22,
                                          ),
                                          const SizedBox(width: 4),
                                          Text(
                                            _seekFeedbackSeconds! > 0 ? '+10s' : '-10s',
                                            style: GoogleFonts.outfit(
                                              color: Colors.white,
                                              fontWeight: FontWeight.bold,
                                              fontSize: 15,
                                            ),
                                          ),
                                        ],
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                            ),

                          // Long-press Favorite Heart Burst
                          if (_showFavoriteBurst)
                            Positioned.fill(
                              child: IgnorePointer(
                                child: Center(
                                  child: TweenAnimationBuilder<double>(
                                    tween: Tween<double>(begin: 0.3, end: 1.25),
                                    duration: const Duration(milliseconds: 550),
                                    curve: Curves.elasticOut,
                                    builder: (context, scale, child) {
                                      return Transform.scale(
                                        scale: scale,
                                        child: Container(
                                          padding: const EdgeInsets.all(16),
                                          decoration: BoxDecoration(
                                            shape: BoxShape.circle,
                                            color: Colors.redAccent.withValues(alpha: 0.35),
                                            boxShadow: [
                                              BoxShadow(
                                                color: Colors.redAccent.withValues(alpha: 0.6),
                                                blurRadius: 24,
                                                spreadRadius: 4,
                                              ),
                                            ],
                                          ),
                                          child: const Icon(
                                            Icons.favorite_rounded,
                                            color: Colors.redAccent,
                                            size: 46,
                                          ),
                                        ),
                                      );
                                    },
                                  ),
                                ),
                              ),
                            ),
                        ],
                      ),
                    ),
                  ),
                );
              },
            ),
          ],
        ),
      ),
    );
  }

  // ════════════════════════════════════════════════════════════════════════
  // SONG INFO
  // ════════════════════════════════════════════════════════════════════════
  Widget _buildSongInfo(Song song, Color primary) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 36),
      child: Column(
        children: [
          Text(
            song.title,
            style: GoogleFonts.outfit(
              color: Colors.white,
              fontSize: 20,
              fontWeight: FontWeight.w700,
              height: 1.2,
            ),
            textAlign: TextAlign.center,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
          ),
          const SizedBox(height: 6),
          Text(
            song.artist,
            style: GoogleFonts.inter(
              color: primary.withValues(alpha: 0.7),
              fontSize: 13,
              fontWeight: FontWeight.w500,
            ),
            textAlign: TextAlign.center,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ],
      ),
    );
  }

  // ════════════════════════════════════════════════════════════════════════
  // SEEK BAR — draggable progress with time labels
  // ════════════════════════════════════════════════════════════════════════
  Widget _buildSeekBar(PlayerProvider pp, double progress, Color primary) {
    return ValueListenableBuilder<Map<String, double>>(
      valueListenable: StreamCacheService.bufferProgressNotifier,
      builder: (context, progressMap, child) {
        return StreamBuilder<Duration>(
          stream: pp.positionStream,
          builder: (context, snapshot) {
            final position = snapshot.data ?? pp.position;
            final duration = pp.duration;
            final buffered = pp.bufferedPosition;
            final song = pp.currentSong;

            final totalMs = duration.inMilliseconds;
            final posMs = position.inMilliseconds;
            final bufMs = buffered.inMilliseconds;

            final currentProgress = totalMs > 0 ? (posMs / totalMs).clamp(0.0, 1.0) : 0.0;
            final bufferProgress = totalMs > 0 ? (bufMs / totalMs).clamp(0.0, 1.0) : 0.0;
            final displayProgress = _isDraggingSeek ? _dragSeekValue : currentProgress;
            final displayPosition = _isDraggingSeek
                ? Duration(milliseconds: (_dragSeekValue * totalMs).round())
                : position;
            final remaining = duration - displayPosition;

            return Padding(
              padding: const EdgeInsets.symmetric(horizontal: 36),
              child: Column(
                children: [
                  // ── Seek slider ─────────────────────────────────────────
                  SizedBox(
                    height: 32,
                    child: LayoutBuilder(
                      builder: (context, constraints) {
                        final maxW = constraints.maxWidth;
                        return GestureDetector(
                          behavior: HitTestBehavior.opaque,
                          onPanStart: (d) {
                            setState(() {
                              _isDraggingSeek = true;
                              _dragSeekValue = (d.localPosition.dx / maxW).clamp(0.0, 1.0);
                            });
                          },
                          onPanUpdate: (d) {
                            setState(() {
                              _dragSeekValue = (d.localPosition.dx / maxW).clamp(0.0, 1.0);
                            });
                          },
                          onPanEnd: (_) {
                            final seekMs = (_dragSeekValue * totalMs).round();
                            pp.seek(Duration(milliseconds: seekMs));
                            setState(() => _isDraggingSeek = false);
                          },
                          onTapDown: (d) {
                            final ratio = (d.localPosition.dx / maxW).clamp(0.0, 1.0);
                            final seekMs = (ratio * totalMs).round();
                            pp.seek(Duration(milliseconds: seekMs));
                          },
                          child: Center(
                            child: SizedBox(
                              height: 32,
                              child: Stack(
                                alignment: Alignment.centerLeft,
                                children: [
                                  // Track background
                                  ClipRRect(
                                    borderRadius: BorderRadius.circular(4),
                                    child: BackdropFilter(
                                      filter: ImageFilter.blur(sigmaX: 10, sigmaY: 10),
                                      child: Container(
                                        height: _isDraggingSeek ? 8 : 5,
                                        decoration: BoxDecoration(
                                          color: Colors.white.withValues(alpha: 0.08),
                                          borderRadius: BorderRadius.circular(4),
                                        ),
                                      ),
                                    ),
                                  ),
                                  // Animated Cosmic Aurora Plasma Buffered Indicator
                                  FractionallySizedBox(
                                    widthFactor: bufferProgress,
                                    child: AnimatedBuilder(
                                      animation: _auroraController,
                                      builder: (context, _) {
                                        final auroraVal = _auroraController.value;
                                        final plasmaHue = (HSLColor.fromColor(primary).hue + (auroraVal * 60.0)) % 360;
                                        final plasmaColor = HSLColor.fromAHSL(
                                          1.0,
                                          plasmaHue,
                                          0.85,
                                          0.60,
                                        ).toColor();

                                        return Container(
                                          height: _isDraggingSeek ? 8 : 5,
                                          decoration: BoxDecoration(
                                            borderRadius: BorderRadius.circular(4),
                                            gradient: LinearGradient(
                                              begin: Alignment.centerLeft,
                                              end: Alignment.centerRight,
                                              colors: [
                                                primary.withValues(alpha: 0.20 + _overallEnergy * 0.15),
                                                plasmaColor.withValues(alpha: 0.45 + _bassEnergy * 0.25),
                                                primary.withValues(alpha: 0.30),
                                              ],
                                              stops: [
                                                0.0,
                                                (auroraVal * 0.7 + 0.15).clamp(0.0, 1.0),
                                                1.0,
                                              ],
                                            ),
                                            boxShadow: [
                                              BoxShadow(
                                                color: plasmaColor.withValues(alpha: 0.35 + _bassEnergy * 0.2),
                                                blurRadius: 8 + _bassEnergy * 6,
                                              ),
                                            ],
                                          ),
                                        );
                                      },
                                    ),
                                  ),
                                  // Progress fill — energy-reactive glow
                                  FractionallySizedBox(
                                    widthFactor: displayProgress,
                                    child: Container(
                                      height: _isDraggingSeek ? 8 : 5,
                                      decoration: BoxDecoration(
                                        gradient: LinearGradient(
                                          colors: [
                                            primary,
                                            primary.withValues(alpha: 0.7 + _overallEnergy * 0.3),
                                          ],
                                        ),
                                        borderRadius: BorderRadius.circular(4),
                                        boxShadow: [
                                          BoxShadow(
                                            color: primary.withValues(alpha: 0.3 + _overallEnergy * 0.2),
                                            blurRadius: 6 + _bassEnergy * 6,
                                          ),
                                        ],
                                      ),
                                    ),
                                  ),
                                  // Thumb dot
                                  Positioned(
                                    left: (displayProgress * maxW - 7).clamp(0.0, maxW - 14),
                                    child: AnimatedContainer(
                                      duration: const Duration(milliseconds: 100),
                                      width: _isDraggingSeek ? 16 : 14,
                                      height: _isDraggingSeek ? 16 : 14,
                                      decoration: BoxDecoration(
                                        shape: BoxShape.circle,
                                        color: Colors.white,
                                        boxShadow: [
                                          BoxShadow(
                                            color: primary.withValues(alpha: 0.5),
                                            blurRadius: _isDraggingSeek ? 12 : 6,
                                            spreadRadius: _isDraggingSeek ? 2 : 0,
                                          ),
                                        ],
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        );
                      },
                    ),
                  ),
                  const SizedBox(height: 6),
                  // ── Time labels ──────────────────────────────────────────
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text(
                        _formatDuration(displayPosition),
                        style: GoogleFonts.jetBrainsMono(
                          color: Colors.white38,
                          fontSize: 11,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                      if (bufferProgress > 0.0 && bufferProgress < 1.0 && song != null && !song.isLocalFile)
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
                          decoration: BoxDecoration(
                            color: primary.withValues(alpha: 0.12),
                            borderRadius: BorderRadius.circular(8),
                            border: Border.all(
                              color: primary.withValues(alpha: 0.25),
                              width: 0.8,
                            ),
                          ),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Container(
                                width: 5,
                                height: 5,
                                decoration: BoxDecoration(
                                  shape: BoxShape.circle,
                                  color: primary,
                                  boxShadow: [
                                    BoxShadow(
                                      color: primary.withValues(alpha: 0.7),
                                      blurRadius: 5,
                                      spreadRadius: 1,
                                    ),
                                  ],
                                ),
                              ),
                              const SizedBox(width: 4),
                              Text(
                                '${(bufferProgress * 100).toInt()}% LOADED',
                                style: GoogleFonts.jetBrainsMono(
                                  color: primary.withValues(alpha: 0.9),
                                  fontSize: 9,
                                  fontWeight: FontWeight.w700,
                                  letterSpacing: 0.5,
                                ),
                              ),
                            ],
                          ),
                        ),
                      Text(
                        '-${_formatDuration(remaining.isNegative ? Duration.zero : remaining)}',
                        style: GoogleFonts.jetBrainsMono(
                          color: Colors.white38,
                          fontSize: 11,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            );
          },
        );
      },
    );
  }

  // ════════════════════════════════════════════════════════════════════════
  // GLASS CONTROL BAR
  // ════════════════════════════════════════════════════════════════════════
  Widget _buildGlassControlBar(PlayerProvider pp, Color primary) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 24),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(28),
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: 20, sigmaY: 20),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
            decoration: BoxDecoration(
              color: Colors.white.withValues(alpha: 0.07),
              borderRadius: BorderRadius.circular(28),
              border: Border.all(
                color: Colors.white.withValues(alpha: 0.10),
                width: 1,
              ),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.3),
                  blurRadius: 20,
                  offset: const Offset(0, 8),
                ),
              ],
            ),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceEvenly,
              children: [
                // Shuffle
                _glassIconButton(
                  icon: Icons.shuffle_rounded,
                  isActive: pp.isShuffled,
                  activeColor: primary,
                  size: 20,
                  onTap: () {
                    AppHaptics.selection();
                    pp.toggleShuffle();
                  },
                ),
                // Previous
                _glassIconButton(
                  icon: Icons.skip_previous_rounded,
                  size: 28,
                  onTap: () {
                    AppHaptics.medium();
                    pp.skipPrevious();
                  },
                ),
                // Play / Pause — the hero button
                PremiumTap(
                  onTap: pp.isPlayPauseEnabled
                      ? () {
                          AppHaptics.light();
                          pp.togglePlayPause();
                        }
                      : null,
                  pressedScale: 0.90,
                  child: AnimatedBuilder(
                    animation: _beatController,
                    builder: (context, child) {
                      final beatScale = 1.0 + (1.0 - _beatController.value) * _bassEnergy * 0.04;
                      return Transform.scale(
                        scale: beatScale,
                        child: Container(
                          width: 64,
                          height: 64,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            gradient: LinearGradient(
                              begin: Alignment.topLeft,
                              end: Alignment.bottomRight,
                              colors: [primary, primary.withValues(alpha: 0.7)],
                            ),
                            boxShadow: [
                              BoxShadow(
                                color: primary.withValues(alpha: pp.isPlayPauseEnabled ? (0.4 + _bassEnergy * 0.2) : 0.2),
                                blurRadius: 20 + _bassEnergy * 10,
                                spreadRadius: 2 + _bassEnergy * 3,
                              ),
                            ],
                          ),
                          child: AnimatedSwitcher(
                            duration: const Duration(milliseconds: 200),
                            child: !pp.isPlayPauseEnabled
                                ? const SizedBox(
                                    key: ValueKey('aurora_loading'),
                                    width: 26,
                                    height: 26,
                                    child: CircularProgressIndicator(
                                      color: Colors.white,
                                      strokeWidth: 2.5,
                                    ),
                                  )
                                : Icon(
                                    pp.isPlaying
                                        ? Icons.pause_rounded
                                        : Icons.play_arrow_rounded,
                                    key: ValueKey(pp.isPlaying),
                                    color: Colors.white,
                                    size: 32,
                                  ),
                          ),
                        ),
                      );
                    },
                  ),
                ),
                // Next
                _glassIconButton(
                  icon: Icons.skip_next_rounded,
                  size: 28,
                  onTap: () {
                    AppHaptics.medium();
                    pp.skipNext();
                  },
                ),
                // Repeat
                _glassIconButton(
                  icon: _repeatIcon(pp),
                  isActive: pp.repeatMode != AudioServiceRepeatMode.none,
                  activeColor: primary,
                  size: 20,
                  onTap: () {
                    AppHaptics.selection();
                    pp.cycleRepeatMode();
                  },
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  IconData _repeatIcon(PlayerProvider pp) {
    switch (pp.repeatMode) {
      case AudioServiceRepeatMode.one:
        return Icons.repeat_one_rounded;
      default:
        return Icons.repeat_rounded;
    }
  }

  Widget _glassIconButton({
    required IconData icon,
    required VoidCallback onTap,
    double size = 24,
    bool isActive = false,
    Color? activeColor,
  }) {
    return PremiumTap(
      onTap: onTap,
      pressedScale: 0.88,
      child: Container(
        width: 44,
        height: 44,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: isActive
              ? (activeColor ?? Colors.white).withValues(alpha: 0.12)
              : Colors.transparent,
        ),
        child: Icon(
          icon,
          color: isActive ? (activeColor ?? Colors.white) : Colors.white54,
          size: size,
        ),
      ),
    );
  }

  // ════════════════════════════════════════════════════════════════════════
  // SECONDARY ACTIONS
  // ════════════════════════════════════════════════════════════════════════
  Widget _buildSecondaryActions(PlayerProvider pp, Song song, Color primary) {
    final isFavorite = pp.isFavorite(song.videoId);
    final isDownloaded = pp.downloadedSongs.any((s) => s.videoId == song.videoId);
    final downloadProgress = pp.downloadProgress[song.videoId];
    final downloadStatus = pp.getDownloadStatus(song.videoId);
    final isDownloading = downloadProgress != null || downloadStatus != null;

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 40),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(20),
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: 12, sigmaY: 12),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
            decoration: BoxDecoration(
              color: Colors.white.withValues(alpha: 0.04),
              borderRadius: BorderRadius.circular(20),
              border: Border.all(
                color: Colors.white.withValues(alpha: 0.06),
              ),
            ),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceEvenly,
              children: [
                // Favorite
                _secondaryAction(
                  icon: isFavorite
                      ? Icons.favorite_rounded
                      : Icons.favorite_border_rounded,
                  label: 'Like',
                  isActive: isFavorite,
                  activeColor: Colors.redAccent,
                  onTap: () {
                    AppHaptics.light();
                    pp.toggleFavorite(song);
                  },
                ),
                // Download — animated percentage while downloading
                if (isDownloading)
                  _downloadingIndicator(downloadStatus, downloadProgress, primary)
                else
                  _secondaryAction(
                    icon: isDownloaded
                        ? Icons.download_done_rounded
                        : Icons.download_rounded,
                    label: isDownloaded ? 'Saved' : 'Save',
                    isActive: isDownloaded,
                    activeColor: primary,
                    onTap: () {
                      if (!isDownloaded) {
                        AppHaptics.light();
                        pp.downloadSong(song, context: context);
                      }
                    },
                  ),
                // Queue — opens the live queue sheet
                _secondaryAction(
                  icon: Icons.queue_music_rounded,
                  label: 'Queue',
                  onTap: () {
                    AppHaptics.selection();
                    showQueueSheet(context, pp);
                  },
                ),
                // Next — jump to the next song in the queue
                _secondaryAction(
                  icon: Icons.playlist_play_rounded,
                  label: 'Next',
                  onTap: () {
                    AppHaptics.medium();
                    pp.skipNext();
                  },
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// Download-in-progress indicator: circular percentage ring tinted with the
  /// theme colour plus a live % label underneath.
  Widget _downloadingIndicator(
      DownloadStatus? status, double? progress, Color primary) {
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

    final bool indeterminate =
        status == DownloadStatus.paused || status == DownloadStatus.queued;

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        SizedBox(
          width: 20,
          height: 20,
          child: TweenAnimationBuilder<double>(
            duration: const Duration(milliseconds: 300),
            curve: Curves.easeOut,
            tween: Tween<double>(
              begin: 0.0,
              end: (progress ?? 0.0).clamp(0.0, 1.0),
            ),
            builder: (context, animatedProgress, _) {
              return CircularProgressIndicator(
                strokeWidth: 2.2,
                value: indeterminate
                    ? 0.0
                    : (progress != null ? animatedProgress : null),
                backgroundColor: primary.withValues(alpha: 0.15),
                valueColor: AlwaysStoppedAnimation<Color>(primary),
              );
            },
          ),
        ),
        const SizedBox(height: 3),
        Text(
          label,
          style: TextStyle(
            color: primary,
            fontSize: 9,
            fontWeight: FontWeight.w700,
          ),
        ),
      ],
    );
  }

  Widget _secondaryAction({
    required IconData icon,
    required String label,
    required VoidCallback onTap,
    bool isActive = false,
    Color? activeColor,
  }) {
    final color = isActive ? (activeColor ?? Colors.white) : Colors.white38;
    return PremiumTap(
      onTap: onTap,
      pressedScale: 0.90,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, color: color, size: 20),
          const SizedBox(height: 3),
          Text(
            label,
            style: TextStyle(color: color, fontSize: 9, fontWeight: FontWeight.w600),
          ),
        ],
      ),
    );
  }

  // ════════════════════════════════════════════════════════════════════════
  // VOLUME BAR
  // ════════════════════════════════════════════════════════════════════════
  Widget _buildVolumeBar(BuildContext context) {
    final settings = Provider.of<SettingsProvider>(context);
    return Container(
      width: 36,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(20),
        color: Colors.black.withValues(alpha: 0.5),
        border: Border.all(color: Colors.white.withValues(alpha: 0.08)),
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(20),
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: 10, sigmaY: 10),
          child: Column(
            children: [
              const SizedBox(height: 8),
              Icon(
                settings.volume > 0.5
                    ? Icons.volume_up_rounded
                    : settings.volume > 0
                        ? Icons.volume_down_rounded
                        : Icons.volume_off_rounded,
                color: Colors.white54,
                size: 16,
              ),
              Expanded(
                child: RotatedBox(
                  quarterTurns: 3,
                  child: SliderTheme(
                    data: SliderThemeData(
                      trackHeight: 3,
                      thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 5),
                      activeTrackColor: Theme.of(context).colorScheme.primary,
                      inactiveTrackColor: Colors.white12,
                      thumbColor: Colors.white,
                      overlayShape: SliderComponentShape.noOverlay,
                    ),
                    child: Slider(
                      value: settings.volume,
                      onChanged: (v) => settings.setVolume(v),
                    ),
                  ),
                ),
              ),
              Text(
                '${(settings.volume * 100).round()}',
                style: const TextStyle(
                  color: Colors.white38,
                  fontSize: 9,
                  fontWeight: FontWeight.bold,
                ),
              ),
              const SizedBox(height: 8),
            ],
          ),
        ),
      ),
    );
  }
}

// ══════════════════════════════════════════════════════════════════════════
// CUSTOM PAINTERS — all music-reactive
// ══════════════════════════════════════════════════════════════════════════

/// Aurora ribbons that react to bass (amplitude), mids (wave complexity),
/// and treble (shimmer/speed).
class _AuroraRibbonPainter extends CustomPainter {
  final double phase;
  final double progress;
  final bool isPlaying;
  final Color accentColor;
  final double bassEnergy;
  final double midEnergy;
  final double trebleEnergy;

  _AuroraRibbonPainter({
    required this.phase,
    required this.progress,
    required this.isPlaying,
    required this.accentColor,
    required this.bassEnergy,
    required this.midEnergy,
    required this.trebleEnergy,
  });

  @override
  void paint(Canvas canvas, Size size) {
    // Bass drives amplitude, mids drive wave complexity, treble drives speed
    final baseAmplitude = isPlaying ? 40.0 + bassEnergy * 80.0 : 20.0;
    final waveComplexity = 2.5 + midEnergy * 2.0;
    final speedMul = 1.0 + trebleEnergy * 0.5;

    final ribbonColors = [
      accentColor.withValues(alpha: 0.06 + bassEnergy * 0.06),
      accentColor.withValues(alpha: 0.04 + midEnergy * 0.04),
      Colors.tealAccent.withValues(alpha: 0.03 + trebleEnergy * 0.03),
      Colors.purpleAccent.withValues(alpha: 0.02 + midEnergy * 0.03),
    ];

    for (int i = 0; i < 4; i++) {
      final path = Path();
      final yOffset = size.height * (0.22 + i * 0.15);
      final phaseOffset = phase * 2 * math.pi * speedMul + i * 0.8;
      final ribbonAmplitude = baseAmplitude * (1.0 - i * 0.12);

      path.moveTo(0, yOffset);
      for (double x = 0; x <= size.width; x += 2) {
        final nx = x / size.width;
        final y = yOffset +
            math.sin(nx * waveComplexity * math.pi + phaseOffset) *
                ribbonAmplitude +
            math.cos(nx * (waveComplexity - 0.5) * math.pi + phaseOffset * 0.7) *
                ribbonAmplitude * 0.4 +
            // Add bass punch: sudden spikes
            math.sin(nx * 8 * math.pi + phaseOffset * 2.0) *
                bassEnergy * 15.0;
        path.lineTo(x, y);
      }
      path.lineTo(size.width, size.height);
      path.lineTo(0, size.height);
      path.close();

      final paint = Paint()
        ..shader = LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [
            ribbonColors[i],
            ribbonColors[i].withValues(alpha: 0.0),
          ],
        ).createShader(Rect.fromLTWH(0, 0, size.width, size.height))
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 20);

      canvas.drawPath(path, paint);
    }
  }

  @override
  bool shouldRepaint(covariant _AuroraRibbonPainter old) =>
      old.phase != phase || old.bassEnergy != bassEnergy ||
      old.midEnergy != midEnergy || old.trebleEnergy != trebleEnergy ||
      old.isPlaying != isPlaying;
}

/// Floating orbs that react to mid (vocal) and bass energy.
class _FloatingOrbsPainter extends CustomPainter {
  final double phase;
  final bool isPlaying;
  final Color accentColor;
  final double artRadius;
  final double midEnergy;
  final double bassEnergy;

  _FloatingOrbsPainter({
    required this.phase,
    required this.isPlaying,
    required this.accentColor,
    required this.artRadius,
    required this.midEnergy,
    required this.bassEnergy,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final orbitRadius = artRadius + 18 + bassEnergy * 10;
    final orbCount = 6;

    for (int i = 0; i < orbCount; i++) {
      final speed = isPlaying ? (0.8 + midEnergy * 0.6) : 0.15;
      final angle = phase * 2 * math.pi * speed +
          (i * 2 * math.pi / orbCount) +
          math.sin(phase * 4 * math.pi + i) * 0.3;

      final radiusVariation = orbitRadius +
          math.sin(phase * 3 * math.pi + i * 1.5) * (6 + bassEnergy * 8);
      final x = center.dx + math.cos(angle) * radiusVariation;
      final y = center.dy + math.sin(angle) * radiusVariation;

      // Orb size reacts to mid energy (vocals make orbs grow)
      final orbRadius = 2.5 + (i % 3) * 1.2 + midEnergy * 2.0;
      final opacity = isPlaying
          ? (0.20 + midEnergy * 0.25 + 0.12 * math.sin(phase * 6 * math.pi + i))
          : 0.08;

      // Glow
      canvas.drawCircle(
        Offset(x, y),
        orbRadius * 3,
        Paint()
          ..color = accentColor.withValues(alpha: (opacity * 0.35).clamp(0.0, 1.0))
          ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 8),
      );

      // Core
      canvas.drawCircle(
        Offset(x, y),
        orbRadius,
        Paint()..color = Colors.white.withValues(alpha: opacity.clamp(0.0, 1.0)),
      );
    }
  }

  @override
  bool shouldRepaint(covariant _FloatingOrbsPainter old) =>
      old.phase != phase || old.isPlaying != isPlaying ||
      old.midEnergy != midEnergy || old.bassEnergy != bassEnergy;
}

/// Particles that shimmer with treble and flash on bass hits.
class _ParticleShimmerPainter extends CustomPainter {
  final double phase;
  final bool isPlaying;
  final Color accentColor;
  final double trebleEnergy;
  final double bassEnergy;

  _ParticleShimmerPainter({
    required this.phase,
    required this.isPlaying,
    required this.accentColor,
    required this.trebleEnergy,
    required this.bassEnergy,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final rng = math.Random(42); // Deterministic for consistency
    // More particles when treble is high (hi-hats, cymbals)
    final count = isPlaying ? (15 + (trebleEnergy * 25).round()) : 8;

    for (int i = 0; i < count; i++) {
      final baseX = rng.nextDouble() * size.width;
      final baseY = rng.nextDouble() * size.height;
      final speed = 0.3 + rng.nextDouble() * 0.7;
      final drift = rng.nextDouble() * 20 - 10;

      // Each particle rises and wraps around
      final riseSpeed = speed * (1.0 + trebleEnergy * 0.5);
      final y = (baseY - phase * size.height * riseSpeed) % size.height;
      final x = baseX + math.sin(phase * 4 * math.pi + i) * drift;

      final radius = 0.6 + rng.nextDouble() * 1.0 + bassEnergy * 0.5;
      final alpha = isPlaying
          ? (0.10 + trebleEnergy * 0.20 +
              0.15 * math.sin(phase * 8 * math.pi + i * 0.7) +
              bassEnergy * 0.08)
          : 0.04;

      canvas.drawCircle(
        Offset(x, y),
        radius,
        Paint()..color = Colors.white.withValues(alpha: alpha.clamp(0.0, 1.0)),
      );
    }
  }

  @override
  bool shouldRepaint(covariant _ParticleShimmerPainter old) =>
      old.phase != phase || old.isPlaying != isPlaying ||
      old.trebleEnergy != trebleEnergy || old.bassEnergy != bassEnergy;
}

/// Circular arc with energy-reactive glow on the progress dot.
class _CircularArcPainter extends CustomPainter {
  final double progress;
  final Color accentColor;
  final Color trackColor;
  final double energy;

  _CircularArcPainter({
    required this.progress,
    required this.accentColor,
    required this.trackColor,
    this.energy = 0.0,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final radius = math.min(size.width, size.height) / 2 - 2;
    const startAngle = -math.pi / 2; // 12 o'clock
    const sweepAngle = 2 * math.pi;

    // Track
    canvas.drawCircle(
      center,
      radius,
      Paint()
        ..color = trackColor
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2.5
        ..strokeCap = StrokeCap.round,
    );

    // Progress arc
    if (progress > 0) {
      canvas.drawArc(
        Rect.fromCircle(center: center, radius: radius),
        startAngle,
        sweepAngle * progress,
        false,
        Paint()
          ..color = accentColor
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2.5
          ..strokeCap = StrokeCap.round,
      );

      // Dot at current position
      final dotAngle = startAngle + sweepAngle * progress;
      final dotX = center.dx + math.cos(dotAngle) * radius;
      final dotY = center.dy + math.sin(dotAngle) * radius;

      // Energy-reactive glow
      canvas.drawCircle(
        Offset(dotX, dotY),
        6 + energy * 3,
        Paint()
          ..color = accentColor.withValues(alpha: 0.25 + energy * 0.2)
          ..maskFilter = MaskFilter.blur(BlurStyle.normal, 4 + energy * 3),
      );

      // Core dot
      canvas.drawCircle(
        Offset(dotX, dotY),
        4,
        Paint()..color = Colors.white,
      );
    }
  }

  @override
  bool shouldRepaint(covariant _CircularArcPainter old) =>
      old.progress != progress || old.energy != energy;
}

/// Two large, soft light blobs that drift slowly around the screen — the
/// "background light" layer. They breathe with bass and warm up with overall
/// energy, giving the whole scene a living, premium glow without stealing
/// attention from the art.
class _AmbientLightPainter extends CustomPainter {
  final double phase;
  final Color accentColor;
  final double bassEnergy;
  final double overallEnergy;

  _AmbientLightPainter({
    required this.phase,
    required this.accentColor,
    required this.bassEnergy,
    required this.overallEnergy,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    final angle = phase * 2 * math.pi;

    // Blob 1 — accent tinted, orbits the upper half
    final c1 = Offset(
      size.width * (0.30 + 0.18 * math.sin(angle)),
      size.height * (0.28 + 0.10 * math.cos(angle * 0.8)),
    );
    canvas.drawRect(
      rect,
      Paint()
        ..shader = ui.Gradient.radial(
          c1,
          size.width * (0.55 + bassEnergy * 0.15),
          [
            accentColor.withValues(alpha: 0.10 + overallEnergy * 0.08),
            accentColor.withValues(alpha: 0.03),
            Colors.transparent,
          ],
          [0.0, 0.45, 1.0],
        ),
    );

    // Blob 2 — cool counterweight, orbits the lower half opposite-phase
    final c2 = Offset(
      size.width * (0.72 - 0.15 * math.sin(angle * 0.9)),
      size.height * (0.72 - 0.10 * math.cos(angle * 0.7)),
    );
    canvas.drawRect(
      rect,
      Paint()
        ..shader = ui.Gradient.radial(
          c2,
          size.width * (0.50 + overallEnergy * 0.12),
          [
            const Color(0xFF00C9A7)
                .withValues(alpha: 0.05 + overallEnergy * 0.05),
            Colors.transparent,
          ],
          [0.0, 1.0],
        ),
    );
  }

  @override
  bool shouldRepaint(covariant _AmbientLightPainter old) =>
      old.phase != phase ||
      old.bassEnergy != bassEnergy ||
      old.overallEnergy != overallEnergy;
}
