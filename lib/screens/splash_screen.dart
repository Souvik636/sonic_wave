import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:provider/provider.dart';
import '../providers/settings_provider.dart';
import '../theme/app_colors.dart';
import 'home_screen.dart';

class SplashScreen extends StatefulWidget {
  const SplashScreen({super.key});

  @override
  State<SplashScreen> createState() => _SplashScreenState();
}

class _SplashScreenState extends State<SplashScreen>
    with TickerProviderStateMixin {
  late AnimationController _logoController;
  late AnimationController _auroraController;
  late AnimationController _exitController;
  late AnimationController _textController;

  late Animation<double> _logoScale;
  late Animation<double> _logoOpacity;
  late Animation<double> _exitScale;
  late Animation<double> _exitOpacity;
  late Animation<Offset> _exitSlide;
  late Animation<double> _logoGlowPulse;

  String _subtitleText = '';
  final String _fullSubtitle = 'Feel the music';
  String _createdByText = '';
  final String _fullCreatedBy = 'Created by Souvik';
  Timer? _typingTimer;

  @override
  void initState() {
    super.initState();

    // 1. Aurora Background Flow Controller (slow looping)
    _auroraController = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 12),
    )..repeat(reverse: true);

    // 2. Logo entrance animations (elastic spring ease-out)
    _logoController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1100),
    );
    _logoScale = Tween<double>(begin: 0.2, end: 1.0).animate(
      CurvedAnimation(
        parent: _logoController,
        curve: const Interval(0.0, 0.85, curve: Curves.easeOutBack),
      ),
    );
    _logoOpacity = Tween<double>(begin: 0.0, end: 1.0).animate(
      CurvedAnimation(
        parent: _logoController,
        curve: const Interval(0.0, 0.4, curve: Curves.easeIn),
      ),
    );
    _logoGlowPulse = Tween<double>(begin: 1.0, end: 1.12).animate(
      CurvedAnimation(
        parent: _logoController,
        curve: const Interval(0.6, 1.0, curve: Curves.elasticOut),
      ),
    );

    // 3. Text & Subtitle fade controllers
    _textController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 700),
    );

    // 4. Exit screen transition controllers
    _exitController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 650),
    );
    _exitScale = Tween<double>(begin: 1.0, end: 0.45).animate(
      CurvedAnimation(parent: _exitController, curve: Curves.easeInBack),
    );
    _exitOpacity = Tween<double>(begin: 1.0, end: 0.0).animate(
      CurvedAnimation(parent: _exitController, curve: const Interval(0.0, 0.7, curve: Curves.easeOut)),
    );
    _exitSlide = Tween<Offset>(
      begin: Offset.zero,
      end: const Offset(0.0, -0.2),
    ).animate(
      CurvedAnimation(parent: _exitController, curve: Curves.easeInOutCubic),
    );

    // Trigger animations sequentially (Motion Choreography)
    _logoController.forward().then((_) {
      _textController.forward();
      _startTypingSubtitle();
    });

    // Exit to Home Screen
    Future.delayed(const Duration(milliseconds: 3900), () {
      if (mounted) {
        _exitController.forward().then((_) {
          if (!mounted) return;
          Navigator.of(context).pushReplacement(
            PageRouteBuilder(
              pageBuilder: (context, animation, secondaryAnimation) =>
                  const HomeScreen(),
              transitionsBuilder: (context, animation, secondaryAnimation, child) {
                final curve = CurvedAnimation(
                  parent: animation,
                  curve: Curves.easeInOutQuart,
                );
                
                final scale = Tween<double>(begin: 0.90, end: 1.0).animate(curve);
                final slide = Tween<Offset>(
                  begin: const Offset(0.0, 0.06),
                  end: Offset.zero,
                ).animate(curve);

                return SlideTransition(
                  position: slide,
                  child: ScaleTransition(
                    scale: scale,
                    child: FadeTransition(
                      opacity: animation,
                      child: child,
                    ),
                  ),
                );
              },
              transitionDuration: const Duration(milliseconds: 900),
            ),
          );
        });
      }
    });
  }

  void _startTypingSubtitle() {
    int index = 0;
    _typingTimer = Timer.periodic(const Duration(milliseconds: 55), (timer) {
      if (index < _fullSubtitle.length) {
        if (mounted) {
          setState(() {
            _subtitleText = _fullSubtitle.substring(0, index + 1);
            index++;
          });
        }
      } else {
        timer.cancel();
        _startTypingCreatedBy();
      }
    });
  }

  void _startTypingCreatedBy() {
    int index = 0;
    _typingTimer = Timer.periodic(const Duration(milliseconds: 65), (timer) {
      if (index < _fullCreatedBy.length) {
        if (mounted) {
          setState(() {
            _createdByText = _fullCreatedBy.substring(0, index + 1);
            index++;
          });
        }
      } else {
        timer.cancel();
      }
    });
  }

  @override
  void dispose() {
    _logoController.dispose();
    _auroraController.dispose();
    _textController.dispose();
    _exitController.dispose();
    _typingTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF04040A),
      body: Stack(
        children: [
          // 1. Premium Aurora flowing neon background lights
          AnimatedBuilder(
            animation: _auroraController,
            builder: (context, child) {
              return Positioned.fill(
                child: CustomPaint(
                  painter: _AuroraBackgroundPainter(
                    progress: _auroraController.value,
                    accent: Provider.of<SettingsProvider>(context).accentColor,
                    accentDark:
                        Provider.of<SettingsProvider>(context).accentColorDark,
                  ),
                ),
              );
            },
          ),

          // 2. Overlay Vignette for deep contrast edges
          Positioned.fill(
            child: Container(
              decoration: BoxDecoration(
                gradient: RadialGradient(
                  colors: [
                    Colors.transparent,
                    const Color(0xFF04040A).withValues(alpha: 0.45),
                    const Color(0xFF04040A).withValues(alpha: 0.95),
                  ],
                  center: Alignment.center,
                  radius: 1.25,
                ),
              ),
            ),
          ),

          // 3. Central Glassmorphic Card containing Logo + App Name
          Center(
            child: AnimatedBuilder(
              animation: Listenable.merge([_logoController, _exitController, _textController]),
              builder: (context, child) {
                return Transform.scale(
                  scale: _exitScale.value,
                  child: SlideTransition(
                    position: _exitSlide,
                    child: Opacity(
                      opacity: _exitOpacity.value,
                      child: child,
                    ),
                  ),
                );
              },
              child: Column(
                mainAxisSize: MainAxisSize.min,
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  // Glassmorphic Glowing Logo Base
                  AnimatedBuilder(
                    animation: _logoController,
                    builder: (context, child) {
                      return Opacity(
                        opacity: _logoOpacity.value,
                        child: Transform.scale(
                          scale: _logoScale.value * _logoGlowPulse.value,
                          child: Container(
                            width: 110,
                            height: 110,
                            decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              gradient: Provider.of<SettingsProvider>(context)
                                  .accentGradient,
                              boxShadow: [
                                BoxShadow(
                                  color: Provider.of<SettingsProvider>(context)
                                      .accentColor
                                      .withValues(alpha: 0.45),
                                  blurRadius: 40,
                                  spreadRadius: 8,
                                ),
                                BoxShadow(
                                  color: Provider.of<SettingsProvider>(context)
                                      .accentColorDark
                                      .withValues(alpha: 0.35),
                                  blurRadius: 25,
                                  spreadRadius: 2,
                                  offset: const Offset(4, 4),
                                ),
                              ],
                            ),
                            child: Stack(
                              alignment: Alignment.center,
                              children: [
                                // Concentric audio circles
                                Container(
                                  width: 90,
                                  height: 90,
                                  decoration: BoxDecoration(
                                    shape: BoxShape.circle,
                                    color: Colors.black.withValues(alpha: 0.15),
                                    border: Border.all(
                                      color: Colors.white.withValues(alpha: 0.25),
                                      width: 1,
                                    ),
                                  ),
                                ),
                                // Inner Glass shine
                                Container(
                                  width: 76,
                                  height: 76,
                                  decoration: BoxDecoration(
                                    shape: BoxShape.circle,
                                    gradient: LinearGradient(
                                      colors: [
                                        Colors.white.withValues(alpha: 0.20),
                                        Colors.white.withValues(alpha: 0.02),
                                      ],
                                      begin: Alignment.topLeft,
                                      end: Alignment.bottomRight,
                                    ),
                                  ),
                                ),
                                const Icon(
                                  Icons.waves_rounded,
                                  color: Colors.white,
                                  size: 54,
                                ),
                              ],
                            ),
                          ),
                        ),
                      );
                    },
                  ),
                  const SizedBox(height: 36),

                  // Brand name with custom Outfit/Inter font pairing
                  AnimatedBuilder(
                    animation: _textController,
                    builder: (context, child) {
                      return Opacity(
                        opacity: _textController.value,
                        child: Transform.translate(
                          offset: Offset(0, 20 * (1.0 - _textController.value)),
                          child: child,
                        ),
                      );
                    },
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          'SonicWave',
                          style: GoogleFonts.outfit(
                            fontSize: 40,
                            fontWeight: FontWeight.w900,
                            color: Colors.white,
                            letterSpacing: -0.7,
                            shadows: [
                              Shadow(
                                color: Provider.of<SettingsProvider>(context).accentColor.withValues(alpha: 0.6),
                                blurRadius: 15,
                                offset: const Offset(0, 4),
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(height: 12),
                        SizedBox(
                          height: 20,
                          child: Text(
                            _subtitleText,
                            style: GoogleFonts.inter(
                              fontSize: 13,
                              fontWeight: FontWeight.w500,
                              color: AppColors.textSecondary,
                              letterSpacing: 4.5,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),

          // 4. "Create By Souvik" animated, glowing 3D-depth footer
          Positioned(
            bottom: 40 + MediaQuery.of(context).padding.bottom,
            left: 0,
            right: 0,
            child: Center(
              child: AnimatedBuilder(
                animation: Listenable.merge([_textController, _auroraController, _exitController]),
                builder: (context, child) {
                  return Opacity(
                    opacity: _textController.value * _exitOpacity.value,
                    child: Transform.scale(
                      scale: _exitScale.value,
                      child: Transform.translate(
                        offset: Offset(
                          0,
                          (20 * (1.0 - _textController.value)) + 
                          (4 * math.sin(_auroraController.value * 2 * math.pi)),
                        ),
                        child: child,
                      ),
                    ),
                  );
                },
                child: Text(
                  _createdByText,
                  style: GoogleFonts.outfit(
                    fontSize: 12,
                    fontWeight: FontWeight.bold,
                    color: Colors.white.withValues(alpha: 0.85),
                    letterSpacing: 2.0,
                    shadows: [
                      // 3D Shadow Layers
                      const Shadow(
                        offset: Offset(1, 1),
                        color: Color(0xFF04040A),
                        blurRadius: 1,
                      ),
                      const Shadow(
                        offset: Offset(2, 2),
                        color: Color(0xAA000000),
                        blurRadius: 1,
                      ),
                      // Neon Glow Layers
                      Shadow(
                        color: Provider.of<SettingsProvider>(context).accentColor.withValues(alpha: 0.6),
                        blurRadius: 8,
                      ),
                      Shadow(
                        color: const Color(0xFF00C9A7).withValues(alpha: 0.4),
                        blurRadius: 15,
                      ),
                    ],
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

/// Shifting neon light leak background painter (Aurora Background concept)
class _AuroraBackgroundPainter extends CustomPainter {
  final double progress;
  final Color accent;
  final Color accentDark;

  const _AuroraBackgroundPainter({
    required this.progress,
    required this.accent,
    required this.accentDark,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;

    // Deep base violet-indigo background
    canvas.drawRect(
      rect,
      Paint()..color = const Color(0xFF04040A),
    );

    // Glowing Neon Blob 1 (Indigo shifting position)
    final paint1 = Paint()
      ..shader = ui.Gradient.radial(
        Offset(
          size.width * (0.3 + 0.15 * math.sin(progress * 2 * math.pi)),
          size.height * (0.4 + 0.12 * math.cos(progress * 2 * math.pi)),
        ),
        size.width * 0.75,
        [
          accentDark.withValues(alpha: 0.18),
          accent.withValues(alpha: 0.08),
          Colors.transparent,
        ],
        [0.0, 0.45, 1.0],
      );
    canvas.drawRect(rect, paint1);

    // Glowing Neon Blob 2 (Orchid shifting position)
    final paint2 = Paint()
      ..shader = ui.Gradient.radial(
        Offset(
          size.width * (0.7 + 0.12 * math.cos(progress * 2 * math.pi)),
          size.height * (0.65 + 0.15 * math.sin(progress * 2 * math.pi)),
        ),
        size.width * 0.70,
        [
          accent.withValues(alpha: 0.15),
          const Color(0xFFFF6584).withValues(alpha: 0.05),
          Colors.transparent,
        ],
        [0.0, 0.5, 1.0],
      );
    canvas.drawRect(rect, paint2);

    // Glowing Neon Blob 3 (Teal highlighting top right corner)
    final paint3 = Paint()
      ..shader = ui.Gradient.radial(
        Offset(
          size.width * 0.9,
          size.height * 0.1,
        ),
        size.width * 0.6,
        [
          const Color(0xFF00C9A7).withValues(alpha: 0.12),
          const Color(0x0000C9A7),
        ],
        [0.0, 1.0],
      );
    canvas.drawRect(rect, paint3);
  }

  @override
  bool shouldRepaint(covariant _AuroraBackgroundPainter oldDelegate) =>
      oldDelegate.progress != progress || oldDelegate.accent != accent;
}
