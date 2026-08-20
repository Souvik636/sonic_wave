import 'dart:async';
import 'dart:math' as math;
import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import '../services/wearable_service.dart';
import '../widgets/premium_interaction.dart';

/// Ultra-Luxury Dynamic Island Capsule HUD for Wearables & Audio Accessories.
///
/// Features:
/// - Pure status presentation (No yellow underline artifacts, no clutter)
/// - Morphing spring expansion & elastic physics entrance
/// - Dual-layer frosted acrylic glassmorphism with specular light rim
/// - Live pulsating audio equalizer waveform mini-bars
/// - Chromatic ambient halo bloom matched to accessory status
/// - Zero overflow guarantee on any viewport
class WearableConnectionBanner extends StatefulWidget {
  const WearableConnectionBanner({super.key});

  @override
  State<WearableConnectionBanner> createState() => _WearableConnectionBannerState();
}

class _WearableConnectionBannerState extends State<WearableConnectionBanner>
    with TickerProviderStateMixin {
  late AnimationController _morphController;
  late Animation<double> _scaleAnimation;
  late Animation<double> _slideAnimation;
  late Animation<double> _fadeAnimation;

  late AnimationController _waveController;
  late AnimationController _haloController;
  late Animation<double> _haloGlow;

  Timer? _autoDismissTimer;
  WearableEvent? _currentEvent;
  double _dragOffsetY = 0.0;

  @override
  void initState() {
    super.initState();

    // Fluid spring morph entrance controller
    _morphController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 600),
    );

    _scaleAnimation = Tween<double>(begin: 0.75, end: 1.0).animate(
      CurvedAnimation(
        parent: _morphController,
        curve: const ElasticOutCurve(0.88),
        reverseCurve: Curves.easeInBack,
      ),
    );

    _slideAnimation = Tween<double>(begin: -32.0, end: 0.0).animate(
      CurvedAnimation(
        parent: _morphController,
        curve: Curves.easeOutCubic,
        reverseCurve: Curves.easeInCubic,
      ),
    );

    _fadeAnimation = CurvedAnimation(
      parent: _morphController,
      curve: const Interval(0.0, 0.45, curve: Curves.easeOut),
      reverseCurve: Curves.easeIn,
    );

    // Live mini waveform animation controller
    _waveController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1200),
    )..repeat();

    // Breathing chromatic halo glow
    _haloController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 2400),
    )..repeat(reverse: true);

    _haloGlow = Tween<double>(begin: 0.85, end: 1.15).animate(
      CurvedAnimation(parent: _haloController, curve: Curves.easeInOutSine),
    );

    _currentEvent = WearableService().activeEventNotifier.value;
    if (_currentEvent != null) {
      _morphController.value = 1.0;
      _autoDismissTimer = Timer(const Duration(milliseconds: 4500), _dismiss);
    }

    WearableService().activeEventNotifier.addListener(_onEventChanged);
  }

  void _onEventChanged() {
    final event = WearableService().activeEventNotifier.value;
    if (event != null) {
      setState(() {
        _currentEvent = event;
        _dragOffsetY = 0.0;
      });
      _morphController.forward(from: 0.0);
      _autoDismissTimer?.cancel();
      _autoDismissTimer = Timer(const Duration(milliseconds: 4500), _dismiss);
    } else {
      _dismiss();
    }
  }

  void _dismiss() {
    _autoDismissTimer?.cancel();
    if (mounted && _morphController.status != AnimationStatus.dismissed) {
      _morphController.reverse().then((_) {
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
    _morphController.dispose();
    _waveController.dispose();
    _haloController.dispose();
    super.dispose();
  }

  Color _getAccentColor(WearableEvent event) {
    if (!event.isConnected) return const Color(0xFFFF5252); // Crisp Crimson Disconnect
    switch (event.type) {
      case WearableDeviceType.watch:
        return const Color(0xFF00E5FF); // Electric Cyan
      case WearableDeviceType.headset:
        return const Color(0xFF00E676); // Spring Neon Emerald
      case WearableDeviceType.speaker:
        return const Color(0xFFD500F9); // Radiant Magenta
      case WearableDeviceType.car:
        return const Color(0xFF2979FF); // Hyper Blue
      case WearableDeviceType.audio:
        return const Color(0xFF00E676); // Hi-Fi Emerald
    }
  }

  String _getCodecBadge(WearableEvent event) {
    if (!event.isConnected) return 'OFFLINE';
    switch (event.type) {
      case WearableDeviceType.watch:
        return 'SYNC';
      case WearableDeviceType.headset:
        return 'LDAC 96k';
      case WearableDeviceType.speaker:
        return 'HI-FI';
      case WearableDeviceType.car:
        return 'AUTO';
      case WearableDeviceType.audio:
        return 'HI-RES';
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_currentEvent == null) return const SizedBox.shrink();

    final event = _currentEvent!;
    final accent = _getAccentColor(event);
    final isConnected = event.isConnected;
    final topInset = MediaQuery.of(context).padding.top;
    final screenWidth = MediaQuery.of(context).size.width;

    // Adaptive width matching screen with safe padding
    final double capsuleWidth = math.min(screenWidth - 24, 390.0);

    return Positioned(
      top: topInset + 6,
      left: 0,
      right: 0,
      child: Center(
        child: Material(
          type: MaterialType.transparency,
          child: DefaultTextStyle(
            style: const TextStyle(decoration: TextDecoration.none),
            child: AnimatedBuilder(
              animation: Listenable.merge([_morphController, _haloController, _waveController]),
              builder: (context, child) {
                final scale = _scaleAnimation.value;
                final slideY = _slideAnimation.value + _dragOffsetY;
                final opacity = _fadeAnimation.value.clamp(0.0, 1.0);
                final glow = _haloGlow.value;

                return Transform.translate(
                  offset: Offset(0, slideY),
                  child: Transform.scale(
                    scale: scale,
                    child: Opacity(
                      opacity: opacity,
                      child: GestureDetector(
                        onVerticalDragUpdate: (details) {
                          if (details.primaryDelta != null) {
                            setState(() {
                              _dragOffsetY = (_dragOffsetY + details.primaryDelta!).clamp(-60.0, 15.0);
                            });
                          }
                        },
                        onVerticalDragEnd: (details) {
                          if (_dragOffsetY < -15 || (details.primaryVelocity ?? 0) < -120) {
                            _dismiss();
                          } else {
                            setState(() {
                              _dragOffsetY = 0.0;
                            });
                          }
                        },
                        child: Container(
                          width: capsuleWidth,
                          decoration: BoxDecoration(
                            borderRadius: BorderRadius.circular(32),
                            boxShadow: [
                              // Ambient Halo Bloom
                              BoxShadow(
                                color: accent.withValues(alpha: (isConnected ? 0.25 : 0.12) * glow),
                                blurRadius: 26 * glow,
                                spreadRadius: 1.0,
                                offset: const Offset(0, 4),
                              ),
                              // Deep Drop Shadow
                              const BoxShadow(
                                color: Color(0xCC000000),
                                blurRadius: 20,
                                spreadRadius: 1,
                                offset: Offset(0, 8),
                              ),
                            ],
                          ),
                          child: ClipRRect(
                            borderRadius: BorderRadius.circular(32),
                            child: BackdropFilter(
                              filter: ImageFilter.blur(sigmaX: 30, sigmaY: 30),
                              child: CustomPaint(
                                painter: _LuxuryGlassPainter(
                                  accentColor: accent,
                                  glowFactor: glow,
                                  isConnected: isConnected,
                                ),
                                child: Container(
                                  padding: const EdgeInsets.fromLTRB(10, 8, 12, 8),
                                  decoration: BoxDecoration(
                                    gradient: LinearGradient(
                                      begin: Alignment.topLeft,
                                      end: Alignment.bottomRight,
                                      colors: [
                                        const Color(0xFA141424),
                                        const Color(0xF20B0C16),
                                        accent.withValues(alpha: isConnected ? 0.08 : 0.03),
                                      ],
                                      stops: const [0.0, 0.7, 1.0],
                                    ),
                                    borderRadius: BorderRadius.circular(32),
                                  ),
                                  child: Row(
                                    children: [
                                      // ── Left: Glowing Circular Accessory Orb ───
                                      _buildAccessoryOrb(event, accent, glow),
                                      const SizedBox(width: 10),

                                      // ── Middle: Device Name & Status Info ──────
                                      Expanded(
                                        child: _buildInfoStack(event, accent, isConnected),
                                      ),
                                      const SizedBox(width: 8),

                                      // ── Right: Codec / Status Chip & Dismiss ────
                                      _buildRightCluster(event, accent, isConnected),
                                    ],
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                );
              },
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildAccessoryOrb(WearableEvent event, Color accent, double glow) {
    return Container(
      width: 36,
      height: 36,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        gradient: RadialGradient(
          center: const Alignment(-0.2, -0.3),
          radius: 0.85,
          colors: [
            accent.withValues(alpha: 0.32 * glow),
            accent.withValues(alpha: 0.08),
            const Color(0xFF0F101A),
          ],
        ),
        border: Border.all(
          color: accent.withValues(alpha: 0.65 + 0.25 * (glow - 0.85)),
          width: 1.3,
        ),
        boxShadow: [
          BoxShadow(
            color: accent.withValues(alpha: 0.28 * glow),
            blurRadius: 8 * glow,
          ),
        ],
      ),
      child: Center(
        child: Text(
          event.iconLabel,
          style: const TextStyle(
            fontSize: 16,
            decoration: TextDecoration.none,
          ),
        ),
      ),
    );
  }

  Widget _buildInfoStack(WearableEvent event, Color accent, bool isConnected) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Title
        Text(
          event.name,
          style: GoogleFonts.plusJakartaSans(
            color: Colors.white,
            fontSize: 13,
            fontWeight: FontWeight.w700,
            letterSpacing: -0.1,
            decoration: TextDecoration.none,
          ),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        const SizedBox(height: 2.5),

        // Live Audio Equalizer Waveform or Disconnect Red Dot + Subtitle
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (isConnected) ...[
              _buildAnimatedEqualizer(accent),
              const SizedBox(width: 5),
            ] else ...[
              Container(
                width: 6,
                height: 6,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: accent,
                  boxShadow: [
                    BoxShadow(
                      color: accent.withValues(alpha: 0.6),
                      blurRadius: 4,
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 5),
            ],
            Flexible(
              child: Text(
                isConnected
                    ? (event.type == WearableDeviceType.watch
                        ? 'WATCH SYNCED • 24-BIT'
                        : 'CONNECTED • LOSSLESS HI-FI')
                    : 'DISCONNECTED • SPEAKER ACTIVE',
                style: GoogleFonts.jetBrainsMono(
                  color: isConnected
                      ? accent.withValues(alpha: 0.95)
                      : const Color(0xFFFF8A80),
                  fontSize: 9.5,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 0.4,
                  decoration: TextDecoration.none,
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        ),
      ],
    );
  }

  Widget _buildAnimatedEqualizer(Color accent) {
    final t = _waveController.value;
    final h1 = 4.0 + 8.0 * math.sin(t * math.pi * 2).abs();
    final h2 = 4.0 + 9.0 * math.sin(t * math.pi * 2 + 1.2).abs();
    final h3 = 4.0 + 7.5 * math.sin(t * math.pi * 2 + 2.4).abs();

    return Row(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        _eqBar(h1, accent),
        const SizedBox(width: 2),
        _eqBar(h2, accent),
        const SizedBox(width: 2),
        _eqBar(h3, accent),
      ],
    );
  }

  Widget _eqBar(double height, Color color) {
    return Container(
      width: 2.2,
      height: height,
      decoration: BoxDecoration(
        color: color,
        borderRadius: BorderRadius.circular(1.5),
        boxShadow: [
          BoxShadow(
            color: color.withValues(alpha: 0.7),
            blurRadius: 4,
          ),
        ],
      ),
    );
  }

  Widget _buildRightCluster(WearableEvent event, Color accent, bool isConnected) {
    final badgeText = _getCodecBadge(event);

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        // Hi-Fi Codec or Disconnect Micro Capsule
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
          decoration: BoxDecoration(
            color: isConnected
                ? accent.withValues(alpha: 0.14)
                : Colors.white.withValues(alpha: 0.06),
            borderRadius: BorderRadius.circular(8),
            border: Border.all(
              color: isConnected
                  ? accent.withValues(alpha: 0.45)
                  : Colors.white.withValues(alpha: 0.15),
              width: 0.8,
            ),
          ),
          child: Text(
            badgeText,
            style: GoogleFonts.jetBrainsMono(
              color: isConnected ? accent : Colors.white70,
              fontSize: 9,
              fontWeight: FontWeight.w800,
              letterSpacing: 0.5,
              decoration: TextDecoration.none,
            ),
          ),
        ),
        const SizedBox(width: 6),

        // Minimal Frosted Close Button
        GestureDetector(
          onTap: () {
            AppHaptics.light();
            _dismiss();
          },
          child: Container(
            padding: const EdgeInsets.all(4.5),
            decoration: BoxDecoration(
              color: Colors.white.withValues(alpha: 0.07),
              shape: BoxShape.circle,
              border: Border.all(
                color: Colors.white.withValues(alpha: 0.12),
                width: 0.7,
              ),
            ),
            child: const Icon(
              Icons.close_rounded,
              color: Colors.white70,
              size: 13,
            ),
          ),
        ),
      ],
    );
  }
}

/// Custom painter rendering multi-gradient optical glass border reflection.
class _LuxuryGlassPainter extends CustomPainter {
  final Color accentColor;
  final double glowFactor;
  final bool isConnected;

  _LuxuryGlassPainter({
    required this.accentColor,
    required this.glowFactor,
    required this.isConnected,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    final rrect = RRect.fromRectAndRadius(rect, const Radius.circular(32));

    // Outer Specular Beveled Glass Rim
    final Paint borderPaint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.2
      ..shader = LinearGradient(
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
        colors: [
          Colors.white.withValues(alpha: 0.45),
          accentColor.withValues(alpha: 0.65 + 0.25 * (glowFactor - 0.85)),
          Colors.white.withValues(alpha: 0.10),
          accentColor.withValues(alpha: 0.30),
        ],
        stops: const [0.0, 0.35, 0.75, 1.0],
      ).createShader(rect);

    canvas.drawRRect(rrect, borderPaint);
  }

  @override
  bool shouldRepaint(covariant _LuxuryGlassPainter oldDelegate) =>
      oldDelegate.glowFactor != glowFactor ||
      oldDelegate.accentColor != accentColor ||
      oldDelegate.isConnected != isConnected;
}
