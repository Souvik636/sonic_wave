import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:provider/provider.dart';
import '../models/song.dart';
import '../providers/player_provider.dart';
import '../services/lyrics_service.dart';
import '../theme/app_colors.dart';
import 'app_toast.dart';
import 'premium_interaction.dart';

/// Ultra-Luxury Apple Music Sing-Style Synchronized Karaoke Lyrics View
class KaraokeLyricsView extends StatefulWidget {
  final Song song;
  final bool isFullScreen;
  final VoidCallback? onClose;

  const KaraokeLyricsView({
    super.key,
    required this.song,
    this.isFullScreen = false,
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
      'Timing Offset: ${newOffset >= 0 ? '+' : ''}$newOffset ms',
      type: ToastType.info,
      icon: Icons.tune_rounded,
    );
  }

  void _scrollToActive(int index) {
    if (_userScrolled) {
      if (DateTime.now().difference(_lastUserScrollTime).inSeconds > 4) {
        _userScrolled = false;
      } else {
        return;
      }
    }
    if (_scrollController.hasClients && _lyrics.isNotEmpty && index >= 0) {
      const itemHeight = 64.0;
      final target = (index * itemHeight) - (MediaQuery.of(context).size.height * 0.28);
      _scrollController.animateTo(
        target.clamp(0.0, _scrollController.position.maxScrollExtent),
        duration: const Duration(milliseconds: 400),
        curve: Curves.easeOutCubic,
      );
    }
  }

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final player = context.watch<PlayerProvider>();
    final positionMs = player.position.inMilliseconds + _syncOffsetMs;

    // Find active lyric line
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

    return Container(
      decoration: BoxDecoration(
        color: widget.isFullScreen ? Colors.black : Colors.transparent,
      ),
      child: Stack(
        children: [
          // Background subtle ambient glow
          Positioned.fill(
            child: BackdropFilter(
              filter: ImageFilter.blur(sigmaX: 25, sigmaY: 25),
              child: Container(
                color: Colors.black.withValues(alpha: widget.isFullScreen ? 0.85 : 0.60),
              ),
            ),
          ),

          SafeArea(
            child: Column(
              children: [
                // Header & Calibration Bar
                _buildHeader(context),

                // Lyrics Content
                Expanded(
                  child: _isLoading
                      ? const Center(
                          child: CircularProgressIndicator(
                            color: AppColors.primary,
                            strokeWidth: 2,
                          ),
                        )
                      : (_lyrics.isEmpty
                          ? _buildEmptyState()
                          : _buildLyricsList(player)),
                ),

                // Bottom sync offset calibration bar
                _buildOffsetControls(),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildHeader(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Row(
            children: [
              Container(
                padding: const EdgeInsets.all(6),
                decoration: BoxDecoration(
                  color: AppColors.primary.withValues(alpha: 0.15),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: const Icon(Icons.lyrics_rounded, color: AppColors.primary, size: 18),
              ),
              const SizedBox(width: 10),
              Text(
                'Karaoke Lyrics',
                style: GoogleFonts.outfit(
                  color: Colors.white,
                  fontSize: 16,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ],
          ),
          Row(
            children: [
              IconButton(
                icon: const Icon(Icons.share_rounded, color: Colors.white70, size: 20),
                tooltip: 'Share Lyric Card',
                onPressed: () => _shareCurrentLyricCard(),
              ),
              if (widget.onClose != null)
                IconButton(
                  icon: const Icon(Icons.keyboard_arrow_down_rounded, color: Colors.white, size: 28),
                  onPressed: widget.onClose,
                ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildEmptyState() {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(Icons.mic_off_rounded, size: 48, color: Colors.white.withValues(alpha: 0.3)),
          const SizedBox(height: 16),
          Text(
            'Lyrics unavailable for this track',
            style: GoogleFonts.outfit(
              color: Colors.white70,
              fontSize: 16,
              fontWeight: FontWeight.w500,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            'We continuously fetch from open databases',
            style: GoogleFonts.outfit(
              color: Colors.white38,
              fontSize: 12,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildLyricsList(PlayerProvider player) {
    return NotificationListener<UserScrollNotification>(
      onNotification: (_) {
        _userScrolled = true;
        _lastUserScrollTime = DateTime.now();
        return false;
      },
      child: ListView.builder(
        controller: _scrollController,
        padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 30),
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
              duration: const Duration(milliseconds: 300),
              curve: Curves.easeOutCubic,
              margin: const EdgeInsets.symmetric(vertical: 10),
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
              decoration: BoxDecoration(
                color: isActive
                    ? AppColors.primary.withValues(alpha: 0.12)
                    : Colors.transparent,
                borderRadius: BorderRadius.circular(16),
                border: isActive
                    ? Border.all(color: AppColors.primary.withValues(alpha: 0.3), width: 1)
                    : null,
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    entry.text,
                    style: GoogleFonts.outfit(
                      color: isActive ? Colors.white : Colors.white.withValues(alpha: 0.32),
                      fontSize: isActive ? 22 : 16,
                      fontWeight: isActive ? FontWeight.w800 : FontWeight.w500,
                      height: 1.35,
                      shadows: isActive
                          ? [
                              Shadow(
                                color: AppColors.primary.withValues(alpha: 0.6),
                                blurRadius: 18,
                              ),
                            ]
                          : null,
                    ),
                  ),
                  if (entry.translation != null && entry.translation!.isNotEmpty) ...[
                    const SizedBox(height: 4),
                    Text(
                      entry.translation!,
                      style: GoogleFonts.outfit(
                        color: isActive
                            ? AppColors.primaryLight.withValues(alpha: 0.85)
                            : Colors.white24,
                        fontSize: isActive ? 14 : 12,
                        fontStyle: FontStyle.italic,
                      ),
                    ),
                  ],
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  Widget _buildOffsetControls() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
      margin: const EdgeInsets.fromLTRB(16, 0, 16, 12),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.05),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: Colors.white.withValues(alpha: 0.08)),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(
            'Sync Calibration',
            style: GoogleFonts.spaceMono(color: Colors.white60, fontSize: 11),
          ),
          Row(
            children: [
              _offsetButton('-0.5s', () => _adjustOffset(-500)),
              const SizedBox(width: 8),
              Text(
                '${_syncOffsetMs >= 0 ? '+' : ''}${_syncOffsetMs}ms',
                style: GoogleFonts.spaceMono(
                  color: AppColors.primaryLight,
                  fontSize: 11,
                  fontWeight: FontWeight.bold,
                ),
              ),
              const SizedBox(width: 8),
              _offsetButton('+0.5s', () => _adjustOffset(500)),
            ],
          ),
        ],
      ),
    );
  }

  Widget _offsetButton(String label, VoidCallback onTap) {
    return Material(
      color: Colors.white.withValues(alpha: 0.08),
      borderRadius: BorderRadius.circular(10),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(10),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          child: Text(
            label,
            style: GoogleFonts.spaceMono(color: Colors.white, fontSize: 10, fontWeight: FontWeight.bold),
          ),
        ),
      ),
    );
  }

  void _shareCurrentLyricCard() {
    if (_lyrics.isEmpty) return;
    final currentText = _lyrics[_currentIndex].text;
    Clipboard.setData(ClipboardData(text: '"$currentText"\n— ${widget.song.title} by ${widget.song.artist}'));
    AppHaptics.medium();
    AppToast.show(
      context,
      'Lyric quote copied to clipboard!',
      type: ToastType.success,
      icon: Icons.check_circle_rounded,
    );
  }
}
