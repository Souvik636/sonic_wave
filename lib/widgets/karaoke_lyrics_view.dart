import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:provider/provider.dart';
import '../models/song.dart';
import '../providers/player_provider.dart';
import '../services/lyrics_service.dart';
import '../theme/app_colors.dart';
import 'app_toast.dart';
import 'premium_interaction.dart';

/// Style theme for Karaoke Lyrics View
enum KaraokePlayerTheme {
  /// Studio Obsidian & Neon Cyan aesthetic with studio precision
  classic,

  /// Ethereal dynamic color-shifting glow with cosmic atmosphere
  aurora,
}

/// High-Performance, GPU-Optimized Synchronized Karaoke Lyrics View
///
/// Designed with 60FPS fluid auto-scroll, top/bottom alpha gradient fade,
/// low-GPU overhead (zero heavy backdrop filters in embedded mode), and distinct
/// visual styling for Classic and Aurora player architectures.
class KaraokeLyricsView extends StatefulWidget {
  final Song song;
  final KaraokePlayerTheme theme;
  final bool isFullScreen;
  final Color? accentColor;
  final VoidCallback? onClose;

  const KaraokeLyricsView({
    super.key,
    required this.song,
    this.theme = KaraokePlayerTheme.classic,
    this.isFullScreen = false,
    this.accentColor,
    this.onClose,
  });

  @override
  State<KaraokeLyricsView> createState() => _KaraokeLyricsViewState();
}

class _KaraokeLyricsViewState extends State<KaraokeLyricsView> {
  final ScrollController _scrollController = ScrollController();
  final LyricsService _lyricsService = LyricsService();

  List<LyricEntry> _lyrics = [];
  bool _isLoading = true;
  int _currentIndex = 0;
  int _syncOffsetMs = 0;
  bool _userScrolled = false;
  DateTime _lastUserScrollTime = DateTime.now();

  @override
  void initState() {
    super.initState();
    _loadLyrics();
  }

  @override
  void didUpdateWidget(KaraokeLyricsView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.song.videoId != widget.song.videoId) {
      _loadLyrics();
    }
  }

  Future<void> _loadLyrics() async {
    setState(() {
      _isLoading = true;
      _lyrics = [];
      _currentIndex = 0;
    });

    final offset = await _lyricsService.getSyncOffset(widget.song.videoId);
    final entries = await _lyricsService.getLyricsForSong(widget.song);

    if (mounted) {
      setState(() {
        _lyrics = entries;
        _syncOffsetMs = offset;
        _isLoading = false;
      });
    }
  }

  void _adjustOffset(int deltaMs) {
    final newOffset = _syncOffsetMs + deltaMs;
    setState(() {
      _syncOffsetMs = newOffset;
    });
    _lyricsService.setSyncOffset(widget.song.videoId, newOffset);
    AppHaptics.light();
    AppToast.show(
      context,
      'Timing Calibration: ${newOffset >= 0 ? '+' : ''}$newOffset ms',
      type: ToastType.info,
      icon: Icons.tune_rounded,
    );
  }

  void _scrollToActive(int index) {
    if (_userScrolled) {
      if (DateTime.now().difference(_lastUserScrollTime).inMilliseconds > 3500) {
        _userScrolled = false;
      } else {
        return;
      }
    }
    if (_scrollController.hasClients && _lyrics.isNotEmpty && index >= 0) {
      const estimatedItemHeight = 68.0;
      final viewportHeight = _scrollController.position.viewportDimension;
      final target = (index * estimatedItemHeight) - (viewportHeight * 0.35);
      _scrollController.animateTo(
        target.clamp(0.0, _scrollController.position.maxScrollExtent),
        duration: const Duration(milliseconds: 380),
        curve: Curves.easeOutCubic,
      );
    }
  }

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  Color _getPrimaryAccent() {
    if (widget.accentColor != null) return widget.accentColor!;
    return widget.theme == KaraokePlayerTheme.aurora
        ? const Color(0xFF9D6BFF)
        : AppColors.primary;
  }

  @override
  Widget build(BuildContext context) {
    final player = context.watch<PlayerProvider>();
    final positionMs = player.position.inMilliseconds + _syncOffsetMs;
    final accent = _getPrimaryAccent();

    // Determine active lyric index
    int activeIdx = 0;
    if (_lyrics.isNotEmpty) {
      for (int i = _lyrics.length - 1; i >= 0; i--) {
        if (positionMs >= _lyrics[i].time.inMilliseconds) {
          activeIdx = i;
          break;
        }
      }
    }

    if (activeIdx != _currentIndex && !_isLoading) {
      _currentIndex = activeIdx;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _scrollToActive(_currentIndex);
      });
    }

    final isAurora = widget.theme == KaraokePlayerTheme.aurora;

    return Container(
      decoration: BoxDecoration(
        color: widget.isFullScreen
            ? (isAurora ? const Color(0xFF060611) : Colors.black)
            : (isAurora
                ? accent.withValues(alpha: 0.07)
                : const Color(0xFF0C0E17).withValues(alpha: 0.85)),
        borderRadius: widget.isFullScreen ? BorderRadius.zero : BorderRadius.circular(24),
        border: widget.isFullScreen
            ? null
            : Border.all(
                color: isAurora
                    ? accent.withValues(alpha: 0.25)
                    : Colors.white.withValues(alpha: 0.08),
                width: 1.0,
              ),
      ),
      child: ClipRRect(
        borderRadius: widget.isFullScreen ? BorderRadius.zero : BorderRadius.circular(24),
        child: Column(
          children: [
            // Top Mini-Header with Sync Calibration Toggle
            _buildTopActionBar(accent, isAurora),

            // Lyrics Main Viewport with Smooth Gradient Fade Mask
            Expanded(
              child: _isLoading
                  ? Center(
                      child: CircularProgressIndicator(
                        color: accent,
                        strokeWidth: 2.5,
                      ),
                    )
                  : (_lyrics.isEmpty
                      ? _buildEmptyState(accent)
                      : _buildFadingLyricsList(player, accent, isAurora)),
            ),

            // Bottom Quick Offset Pill Bar
            _buildSyncFooter(accent, isAurora),
          ],
        ),
      ),
    );
  }

  Widget _buildTopActionBar(Color accent, bool isAurora) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Row(
            children: [
              Container(
                padding: const EdgeInsets.all(5),
                decoration: BoxDecoration(
                  color: accent.withValues(alpha: 0.18),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Icon(
                  isAurora ? Icons.auto_awesome_rounded : Icons.lyrics_rounded,
                  color: accent,
                  size: 14,
                ),
              ),
              const SizedBox(width: 8),
              Text(
                isAurora ? 'AURORA LYRICS' : 'SYNCED LYRICS',
                style: GoogleFonts.outfit(
                  color: isAurora ? Colors.white : Colors.white70,
                  fontSize: 11,
                  fontWeight: FontWeight.w800,
                  letterSpacing: 1.2,
                ),
              ),
            ],
          ),
          if (_userScrolled)
            GestureDetector(
              onTap: () {
                AppHaptics.light();
                _userScrolled = false;
                _scrollToActive(_currentIndex);
              },
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                decoration: BoxDecoration(
                  color: accent.withValues(alpha: 0.22),
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(color: accent.withValues(alpha: 0.4), width: 0.8),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.center_focus_strong_rounded, size: 11, color: accent),
                    const SizedBox(width: 4),
                    Text(
                      'Sync Line',
                      style: GoogleFonts.outfit(
                        color: Colors.white,
                        fontSize: 10,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildFadingLyricsList(PlayerProvider player, Color accent, bool isAurora) {
    return ShaderMask(
      shaderCallback: (Rect bounds) {
        return const LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [
            Colors.transparent,
            Colors.white,
            Colors.white,
            Colors.transparent,
          ],
          stops: [0.0, 0.10, 0.90, 1.0],
        ).createShader(bounds);
      },
      blendMode: BlendMode.dstIn,
      child: RepaintBoundary(
        child: NotificationListener<UserScrollNotification>(
          onNotification: (_) {
            _userScrolled = true;
            _lastUserScrollTime = DateTime.now();
            return false;
          },
          child: ListView.builder(
            controller: _scrollController,
            physics: const BouncingScrollPhysics(),
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 24),
            itemCount: _lyrics.length,
            itemBuilder: (context, index) {
              final entry = _lyrics[index];
              final isActive = index == _currentIndex;

              return GestureDetector(
                onTap: () {
                  AppHaptics.light();
                  player.seek(entry.time);
                },
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 220),
                  curve: Curves.easeOutCubic,
                  margin: const EdgeInsets.symmetric(vertical: 6),
                  padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                  decoration: BoxDecoration(
                    color: isActive
                        ? (isAurora
                            ? accent.withValues(alpha: 0.18)
                            : accent.withValues(alpha: 0.12))
                        : Colors.transparent,
                    borderRadius: BorderRadius.circular(16),
                    border: isActive
                        ? Border.all(
                            color: isAurora
                                ? accent.withValues(alpha: 0.45)
                                : accent.withValues(alpha: 0.30),
                            width: 1.0,
                          )
                        : null,
                  ),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      // Active glowing bar indicator
                      if (isActive)
                        Container(
                          width: 3.5,
                          height: 22,
                          margin: const EdgeInsets.only(right: 10, top: 4),
                          decoration: BoxDecoration(
                            color: accent,
                            borderRadius: BorderRadius.circular(2),
                            boxShadow: [
                              BoxShadow(
                                color: accent.withValues(alpha: 0.8),
                                blurRadius: 8,
                                spreadRadius: 1,
                              ),
                            ],
                          ),
                        ),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              entry.text,
                              style: GoogleFonts.outfit(
                                color: isActive
                                    ? Colors.white
                                    : Colors.white.withValues(alpha: 0.38),
                                fontSize: isActive ? 21 : 16,
                                fontWeight: isActive ? FontWeight.w800 : FontWeight.w500,
                                height: 1.32,
                                shadows: (isActive && isAurora)
                                    ? [
                                        Shadow(
                                          color: accent.withValues(alpha: 0.7),
                                          blurRadius: 14,
                                        ),
                                      ]
                                    : null,
                              ),
                            ),
                            if (entry.translation != null && entry.translation!.isNotEmpty) ...[
                              const SizedBox(height: 3),
                              Text(
                                entry.translation!,
                                style: GoogleFonts.outfit(
                                  color: isActive
                                      ? (isAurora ? const Color(0xFFCBB2FF) : AppColors.primaryLight)
                                      : Colors.white24,
                                  fontSize: isActive ? 13 : 11,
                                  fontStyle: FontStyle.italic,
                                ),
                              ),
                            ],
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              );
            },
          ),
        ),
      ),
    );
  }

  Widget _buildEmptyState(Color accent) {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(Icons.mic_off_rounded, size: 36, color: Colors.white24),
          const SizedBox(height: 12),
          Text(
            'Lyrics unavailable for this track',
            style: GoogleFonts.outfit(
              color: Colors.white70,
              fontSize: 14,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            'Synced lyrics stream from open databases',
            style: GoogleFonts.outfit(
              color: Colors.white38,
              fontSize: 11,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSyncFooter(Color accent, bool isAurora) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
      margin: const EdgeInsets.fromLTRB(12, 0, 12, 8),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.04),
        borderRadius: BorderRadius.circular(14),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(
            'Sync Calibration',
            style: GoogleFonts.spaceMono(color: Colors.white54, fontSize: 10),
          ),
          Row(
            children: [
              _calibrationButton('-0.5s', () => _adjustOffset(-500), accent),
              const SizedBox(width: 8),
              Text(
                '${_syncOffsetMs >= 0 ? '+' : ''}${_syncOffsetMs}ms',
                style: GoogleFonts.spaceMono(
                  color: isAurora ? const Color(0xFFCBB2FF) : accent,
                  fontSize: 10,
                  fontWeight: FontWeight.bold,
                ),
              ),
              const SizedBox(width: 8),
              _calibrationButton('+0.5s', () => _adjustOffset(500), accent),
            ],
          ),
        ],
      ),
    );
  }

  Widget _calibrationButton(String label, VoidCallback onTap, Color accent) {
    return Material(
      color: Colors.white.withValues(alpha: 0.06),
      borderRadius: BorderRadius.circular(8),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(8),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
          child: Text(
            label,
            style: GoogleFonts.spaceMono(color: Colors.white70, fontSize: 10),
          ),
        ),
      ),
    );
  }
}
