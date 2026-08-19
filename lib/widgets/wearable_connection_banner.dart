import 'dart:async';
import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:provider/provider.dart';
import '../providers/player_provider.dart';
import '../screens/sound_studio_screen.dart';
import '../services/wearable_service.dart';
import '../theme/app_colors.dart';
import '../widgets/premium_interaction.dart';

/// Ultra-Premium Glassmorphic Wearable & Audio Accessory Connection HUD Banner.
///
/// Displays a smooth animated floating overlay whenever a Smartwatch, Wearable,
/// or Wireless Headset is paired or connected. Built with responsive layout wrapping
/// to prevent UI overflow or component occlusion.
class WearableConnectionBanner extends StatefulWidget {
  const WearableConnectionBanner({super.key});

  @override
  State<WearableConnectionBanner> createState() => _WearableConnectionBannerState();
}

class _WearableConnectionBannerState extends State<WearableConnectionBanner>
    with TickerProviderStateMixin {
  late AnimationController _animController;
  late Animation<double> _slideAnimation;
  late Animation<double> _fadeAnimation;
  late AnimationController _pulseController;
  late Animation<double> _pulseAnimation;
  Timer? _autoDismissTimer;
  WearableEvent? _currentEvent;
  double _dragOffsetY = 0.0;

  @override
  void initState() {
    super.initState();
    _animController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 480),
    );
    _slideAnimation = CurvedAnimation(
      parent: _animController,
      curve: Curves.easeOutBack,
      reverseCurve: Curves.easeInCubic,
    );
    _fadeAnimation = CurvedAnimation(
      parent: _animController,
      curve: Curves.easeOut,
    );

    _pulseController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1800),
    )..repeat(reverse: true);
    _pulseAnimation = Tween<double>(begin: 0.85, end: 1.15).animate(
      CurvedAnimation(parent: _pulseController, curve: Curves.easeInOut),
    );

    WearableService().activeEventNotifier.addListener(_onEventChanged);
  }

  void _onEventChanged() {
    final event = WearableService().activeEventNotifier.value;
    if (event != null) {
      setState(() {
        _currentEvent = event;
        _dragOffsetY = 0.0;
      });
      _animController.forward(from: 0.0);
      _autoDismissTimer?.cancel();
      _autoDismissTimer = Timer(const Duration(seconds: 6), _dismiss);
    } else {
      _dismiss();
    }
  }

  void _dismiss() {
    _autoDismissTimer?.cancel();
    if (mounted && _animController.status != AnimationStatus.dismissed) {
      _animController.reverse().then((_) {
        if (mounted) {
          setState(() {
            _currentEvent = null;
            _dragOffsetY = 0.0;
          });
          WearableService().dismissActiveEvent();
        }
      });
    }
  }

  @override
  void dispose() {
    WearableService().activeEventNotifier.removeListener(_onEventChanged);
    _autoDismissTimer?.cancel();
    _animController.dispose();
    _pulseController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_currentEvent == null) return const SizedBox.shrink();

    final event = _currentEvent!;
    final primary = Theme.of(context).colorScheme.primary;
    final isConnected = event.isConnected;
    final accentColor = isConnected
        ? (event.type == WearableDeviceType.watch ? const Color(0xFF00E5FF) : const Color(0xFF00E676))
        : Colors.orangeAccent;

    final topInset = MediaQuery.of(context).padding.top;

    return Positioned(
      top: topInset + 6,
      left: 12,
      right: 12,
      child: SlideTransition(
        position: Tween<Offset>(
          begin: const Offset(0, -0.6),
          end: Offset.zero,
        ).animate(_slideAnimation),
        child: FadeTransition(
          opacity: _fadeAnimation,
          child: Transform.translate(
            offset: Offset(0, _dragOffsetY),
            child: GestureDetector(
              onVerticalDragUpdate: (details) {
                if (details.primaryDelta != null) {
                  setState(() {
                    _dragOffsetY = (_dragOffsetY + details.primaryDelta!).clamp(-60.0, 10.0);
                  });
                }
              },
              onVerticalDragEnd: (details) {
                if (_dragOffsetY < -20 || (details.primaryVelocity ?? 0) < -150) {
                  _dismiss();
                } else {
                  setState(() {
                    _dragOffsetY = 0.0;
                  });
                }
              },
              child: AnimatedBuilder(
                animation: _pulseAnimation,
                builder: (context, child) {
                  return ClipRRect(
                    borderRadius: BorderRadius.circular(20),
                    child: BackdropFilter(
                      filter: ImageFilter.blur(sigmaX: 25, sigmaY: 25),
                      child: Container(
                        padding: const EdgeInsets.fromLTRB(14, 8, 14, 12),
                        decoration: BoxDecoration(
                          color: const Color(0xFF101020).withValues(alpha: 0.88),
                          borderRadius: BorderRadius.circular(20),
                          border: Border.all(
                            color: accentColor.withValues(alpha: 0.35 + (_pulseAnimation.value - 0.85) * 0.4),
                            width: 1.2,
                          ),
                          boxShadow: [
                            BoxShadow(
                              color: accentColor.withValues(alpha: 0.15 * _pulseAnimation.value),
                              blurRadius: 20 * _pulseAnimation.value,
                              spreadRadius: 1,
                              offset: const Offset(0, 4),
                            ),
                            BoxShadow(
                              color: Colors.black.withValues(alpha: 0.65),
                              blurRadius: 20,
                              offset: const Offset(0, 8),
                            ),
                          ],
                        ),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          crossAxisAlignment: CrossAxisAlignment.center,
                          children: [
                            // Subtle Drag Handle Pill
                            Container(
                              width: 32,
                              height: 3.5,
                              margin: const EdgeInsets.only(bottom: 8),
                              decoration: BoxDecoration(
                                color: Colors.white.withValues(alpha: 0.22),
                                borderRadius: BorderRadius.circular(2),
                              ),
                            ),

                            // Main Header Row
                            Row(
                              children: [
                                // Glowing Aura Icon Badge
                                Container(
                                  width: 40,
                                  height: 40,
                                  decoration: BoxDecoration(
                                    shape: BoxShape.circle,
                                    gradient: RadialGradient(
                                      colors: [
                                        accentColor.withValues(alpha: 0.35),
                                        accentColor.withValues(alpha: 0.08),
                                      ],
                                    ),
                                    border: Border.all(
                                      color: accentColor.withValues(alpha: 0.7),
                                      width: 1.4,
                                    ),
                                  ),
                                  child: Center(
                                    child: Text(
                                      event.iconLabel,
                                      style: const TextStyle(fontSize: 19),
                                    ),
                                  ),
                                ),
                                const SizedBox(width: 10),

                                // Device Info & Status
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment: CrossAxisAlignment.start,
                                    children: [
                                      Row(
                                        children: [
                                          Expanded(
                                            child: Text(
                                              event.name,
                                              style: GoogleFonts.outfit(
                                                color: Colors.white,
                                                fontSize: 13.5,
                                                fontWeight: FontWeight.bold,
                                              ),
                                              maxLines: 1,
                                              overflow: TextOverflow.ellipsis,
                                            ),
                                          ),
                                          const SizedBox(width: 6),
                                          Container(
                                            padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1.5),
                                            decoration: BoxDecoration(
                                              color: accentColor.withValues(alpha: 0.18),
                                              borderRadius: BorderRadius.circular(6),
                                              border: Border.all(
                                                color: accentColor.withValues(alpha: 0.5),
                                                width: 0.8,
                                              ),
                                            ),
                                            child: Text(
                                              isConnected ? 'LINKED' : 'UNLINKED',
                                              style: GoogleFonts.inter(
                                                color: accentColor,
                                                fontSize: 8,
                                                fontWeight: FontWeight.w900,
                                                letterSpacing: 0.5,
                                              ),
                                            ),
                                          ),
                                        ],
                                      ),
                                      const SizedBox(height: 2),
                                      Text(
                                        isConnected
                                            ? (event.type == WearableDeviceType.watch
                                                ? '⌚ Watch Remote Active • 24-bit Lossless'
                                                : '🎧 Hi-Fi Audio Active • Low Latency')
                                            : 'Audio output restored to phone speaker',
                                        style: GoogleFonts.inter(
                                          color: AppColors.textTertiary,
                                          fontSize: 10,
                                        ),
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                      ),
                                    ],
                                  ),
                                ),
                                const SizedBox(width: 6),

                                // Dismiss Close Pill
                                GestureDetector(
                                  onTap: () {
                                    AppHaptics.light();
                                    _dismiss();
                                  },
                                  child: Container(
                                    padding: const EdgeInsets.all(5),
                                    decoration: BoxDecoration(
                                      color: Colors.white.withValues(alpha: 0.08),
                                      shape: BoxShape.circle,
                                    ),
                                    child: const Icon(
                                      Icons.close_rounded,
                                      color: Colors.white60,
                                      size: 15,
                                    ),
                                  ),
                                ),
                              ],
                            ),

                            // Responsive Action Pills (Wrapping cleanly without overflow)
                            if (isConnected) ...[
                              const SizedBox(height: 8),
                              const Divider(height: 1, color: Colors.white10),
                              const SizedBox(height: 8),
                              Wrap(
                                alignment: WrapAlignment.end,
                                crossAxisAlignment: WrapCrossAlignment.center,
                                spacing: 6,
                                runSpacing: 6,
                                children: [
                                  // Codec Badge Pill
                                  Container(
                                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3.5),
                                    decoration: BoxDecoration(
                                      color: Colors.white.withValues(alpha: 0.06),
                                      borderRadius: BorderRadius.circular(8),
                                      border: Border.all(color: Colors.white12, width: 0.8),
                                    ),
                                    child: Row(
                                      mainAxisSize: MainAxisSize.min,
                                      children: [
                                        Icon(Icons.graphic_eq_rounded, size: 11, color: accentColor),
                                        const SizedBox(width: 4),
                                        Text(
                                          'Hi-Res Audio',
                                          style: TextStyle(
                                            color: Colors.white.withValues(alpha: 0.85),
                                            fontSize: 9.5,
                                            fontWeight: FontWeight.w600,
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),

                                  // Studio FX Action Pill
                                  TextButton.icon(
                                    style: TextButton.styleFrom(
                                      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 3.5),
                                      minimumSize: Size.zero,
                                      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                                      backgroundColor: Colors.white.withValues(alpha: 0.08),
                                      shape: RoundedRectangleBorder(
                                        borderRadius: BorderRadius.circular(8),
                                        side: const BorderSide(color: Colors.white12, width: 0.8),
                                      ),
                                    ),
                                    onPressed: () {
                                      AppHaptics.selection();
                                      _dismiss();
                                      Navigator.push(
                                        context,
                                        MaterialPageRoute(builder: (_) => const SoundStudioScreen()),
                                      );
                                    },
                                    icon: const Icon(Icons.tune_rounded, size: 12, color: Colors.white70),
                                    label: const Text(
                                      'Studio FX',
                                      style: TextStyle(color: Colors.white70, fontSize: 10, fontWeight: FontWeight.w600),
                                    ),
                                  ),

                                  // Resume / Play Action Pill
                                  Consumer<PlayerProvider>(
                                    builder: (context, pp, _) {
                                      final isPlaying = pp.isPlaying;
                                      return TextButton.icon(
                                        style: TextButton.styleFrom(
                                          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 3.5),
                                          minimumSize: Size.zero,
                                          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                                          backgroundColor: primary.withValues(alpha: 0.18),
                                          shape: RoundedRectangleBorder(
                                            borderRadius: BorderRadius.circular(8),
                                            side: BorderSide(color: primary.withValues(alpha: 0.5), width: 0.8),
                                          ),
                                        ),
                                        onPressed: () {
                                          AppHaptics.medium();
                                          if (!isPlaying && pp.hasCurrentSong) {
                                            pp.togglePlayPause();
                                          } else if (!isPlaying && pp.playlist.isNotEmpty) {
                                            pp.playQueueItem(0);
                                          } else if (isPlaying) {
                                            pp.togglePlayPause();
                                          }
                                          _dismiss();
                                        },
                                        icon: Icon(
                                          isPlaying ? Icons.pause_rounded : Icons.play_arrow_rounded,
                                          size: 13,
                                          color: primary,
                                        ),
                                        label: Text(
                                          isPlaying ? 'Pause' : 'Resume',
                                          style: TextStyle(color: primary, fontSize: 10.5, fontWeight: FontWeight.bold),
                                        ),
                                      );
                                    },
                                  ),
                                ],
                              ),
                            ],
                          ],
                        ),
                      ),
                    ),
                  );
                },
              ),
            ),
          ),
        ),
      ),
    );
  }
}
