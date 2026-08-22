import 'dart:math' as math;
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:provider/provider.dart';
import '../providers/player_provider.dart';
import '../theme/app_colors.dart';
import 'premium_interaction.dart';

enum VisualizerMode {
  spectrumBars,
  analogVuMeters,
  cosmicGalaxy,
  auroraRibbon,
}

/// Real-Time 60FPS Audio Visualizer Suite with 4 GPU CustomPainter Modes
class AudioVisualizerSuite extends StatefulWidget {
  final VisualizerMode initialMode;
  final double height;
  final bool showModeSelector;

  const AudioVisualizerSuite({
    super.key,
    this.initialMode = VisualizerMode.spectrumBars,
    this.height = 240,
    this.showModeSelector = true,
  });

  @override
  State<AudioVisualizerSuite> createState() => _AudioVisualizerSuiteState();
}

class _AudioVisualizerSuiteState extends State<AudioVisualizerSuite>
    with SingleTickerProviderStateMixin {
  late AnimationController _ticker;
  late VisualizerMode _currentMode;

  @override
  void initState() {
    super.initState();
    _currentMode = widget.initialMode;
    _ticker = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 10),
    )..repeat();
  }

  @override
  void dispose() {
    _ticker.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final player = context.watch<PlayerProvider>();
    final isPlaying = player.isPlaying;

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        // Mode Selector Pills
        if (widget.showModeSelector)
          Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  _modeButton('Bars', VisualizerMode.spectrumBars, Icons.equalizer_rounded),
                  const SizedBox(width: 8),
                  _modeButton('VU Meters', VisualizerMode.analogVuMeters, Icons.speed_rounded),
                  const SizedBox(width: 8),
                  _modeButton('Galaxy', VisualizerMode.cosmicGalaxy, Icons.blur_on_rounded),
                  const SizedBox(width: 8),
                  _modeButton('Aurora', VisualizerMode.auroraRibbon, Icons.waves_rounded),
                ],
              ),
            ),
          ),

        // Visualizer Canvas Container
        Container(
          height: widget.height,
          width: double.infinity,
          decoration: BoxDecoration(
            color: Colors.black.withValues(alpha: 0.6),
            borderRadius: BorderRadius.circular(24),
            border: Border.all(color: Colors.white.withValues(alpha: 0.08)),
          ),
          clipBehavior: Clip.antiAlias,
          child: AnimatedBuilder(
            animation: _ticker,
            builder: (context, _) {
              final time = DateTime.now().millisecondsSinceEpoch / 1000.0;
              final positionMs = player.position.inMilliseconds;

              return CustomPaint(
                painter: _VisualizerPainter(
                  mode: _currentMode,
                  time: time,
                  positionMs: positionMs,
                  isPlaying: isPlaying,
                ),
              );
            },
          ),
        ),
      ],
    );
  }

  Widget _modeButton(String label, VisualizerMode mode, IconData icon) {
    final isActive = _currentMode == mode;
    return Material(
      color: isActive ? AppColors.primary.withValues(alpha: 0.25) : Colors.white.withValues(alpha: 0.06),
      borderRadius: BorderRadius.circular(12),
      child: InkWell(
        onTap: () {
          AppHaptics.light();
          setState(() {
            _currentMode = mode;
          });
        },
        borderRadius: BorderRadius.circular(12),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(12),
            border: Border.all(
              color: isActive ? AppColors.primary : Colors.white.withValues(alpha: 0.06),
              width: isActive ? 1.2 : 0.8,
            ),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, color: isActive ? AppColors.primary : Colors.white60, size: 14),
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
      ),
    );
  }
}

class _VisualizerPainter extends CustomPainter {
  final VisualizerMode mode;
  final double time;
  final int positionMs;
  final bool isPlaying;

  _VisualizerPainter({
    required this.mode,
    required this.time,
    required this.positionMs,
    required this.isPlaying,
  });

  @override
  void paint(Canvas canvas, Size size) {
    switch (mode) {
      case VisualizerMode.spectrumBars:
        _drawSpectrumBars(canvas, size);
        break;
      case VisualizerMode.analogVuMeters:
        _drawAnalogVuMeters(canvas, size);
        break;
      case VisualizerMode.cosmicGalaxy:
        _drawCosmicGalaxy(canvas, size);
        break;
      case VisualizerMode.auroraRibbon:
        _drawAuroraRibbon(canvas, size);
        break;
    }
  }

  // 1. Neon Spectrum Bars
  void _drawSpectrumBars(Canvas canvas, Size size) {
    const int barCount = 32;
    final barWidth = (size.width - ((barCount - 1) * 3)) / barCount;
    final energyBase = isPlaying ? 1.0 : 0.05;

    for (int i = 0; i < barCount; i++) {
      final x = i * (barWidth + 3);
      final phase = (i / barCount) * math.pi * 2;
      final wave1 = math.sin(time * 6.0 + phase);
      final wave2 = math.cos(time * 3.5 - phase * 1.5);
      final rawHeight = (wave1.abs() * 0.6 + wave2.abs() * 0.4) * size.height * 0.85 * energyBase;
      final h = math.max(6.0, rawHeight);

      final rect = Rect.fromLTWH(x, size.height - h - 12, barWidth, h);
      final paint = Paint()
        ..shader = ui.Gradient.linear(
          Offset(x, size.height),
          Offset(x, size.height - h),
          [
            const Color(0xFF00E5FF),
            const Color(0xFF00FFC2),
            const Color(0xFFFF4081),
          ],
          [0.0, 0.65, 1.0],
        )
        ..style = PaintingStyle.fill;

      canvas.drawRRect(
        RRect.fromRectAndRadius(rect, const Radius.circular(4)),
        paint,
      );

      // Peak Cap
      if (isPlaying && h > 15) {
        final capRect = Rect.fromLTWH(x, size.height - h - 18, barWidth, 2.5);
        canvas.drawRRect(
          RRect.fromRectAndRadius(capRect, const Radius.circular(2)),
          Paint()..color = const Color(0xFFFF80AB),
        );
      }
    }
  }

  // 2. Analog Stereo VU Meters
  void _drawAnalogVuMeters(Canvas canvas, Size size) {
    final meterW = (size.width - 24) / 2;
    final meterH = size.height - 24;

    _drawSingleVuMeter(canvas, Rect.fromLTWH(8, 12, meterW, meterH), 'L - CHANNEL', 0.0);
    _drawSingleVuMeter(canvas, Rect.fromLTWH(16 + meterW, 12, meterW, meterH), 'R - CHANNEL', 0.8);
  }

  void _drawSingleVuMeter(Canvas canvas, Rect rect, String label, double phaseOffset) {
    // Dial Background
    final dialPaint = Paint()
      ..color = const Color(0xFF161A22)
      ..style = PaintingStyle.fill;
    canvas.drawRRect(RRect.fromRectAndRadius(rect, const Radius.circular(16)), dialPaint);

    final borderPaint = Paint()
      ..color = Colors.white.withValues(alpha: 0.12)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.2;
    canvas.drawRRect(RRect.fromRectAndRadius(rect, const Radius.circular(16)), borderPaint);

    // Arc Scale
    final center = Offset(rect.center.dx, rect.bottom + 10);
    final radius = rect.height * 0.9;
    final arcRect = Rect.fromCircle(center: center, radius: radius);

    final arcPaint = Paint()
      ..color = const Color(0xFF00FFC2).withValues(alpha: 0.6)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.0;
    canvas.drawArc(arcRect, -math.pi * 0.75, math.pi * 0.5, false, arcPaint);

    // Dynamic Needle Angle
    final energy = isPlaying ? (math.sin(time * 5.0 + phaseOffset).abs() * 0.75 + 0.15) : 0.05;
    final angle = -math.pi * 0.75 + (energy * math.pi * 0.5);

    final needleEnd = Offset(
      center.dx + math.cos(angle) * (radius * 0.85),
      center.dy + math.sin(angle) * (radius * 0.85),
    );

    final needlePaint = Paint()
      ..color = const Color(0xFFFF5252)
      ..strokeWidth = 2.2
      ..strokeCap = StrokeCap.round;

    canvas.drawLine(center, needleEnd, needlePaint);

    // Pivot Circle
    canvas.drawCircle(center, 6, Paint()..color = Colors.white70);

    // Label
    final tp = TextPainter(
      text: TextSpan(
        text: label,
        style: const TextStyle(color: Colors.white54, fontSize: 9, fontWeight: FontWeight.bold),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    tp.paint(canvas, Offset(rect.center.dx - tp.width / 2, rect.top + 10));
  }

  // 3. Cosmic Particle Galaxy
  void _drawCosmicGalaxy(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    const int particleCount = 45;
    final energy = isPlaying ? 1.0 : 0.1;

    for (int i = 0; i < particleCount; i++) {
      final angle = (i / particleCount) * math.pi * 2 + (time * 0.8);
      final distWave = math.sin(time * 3.0 + i) * 20;
      final dist = ((i % 5 + 1) * 18.0 + distWave) * energy;
      final x = center.dx + math.cos(angle) * dist;
      final y = center.dy + math.sin(angle) * dist;

      final pSize = (math.sin(time * 4.0 + i).abs() * 3.5 + 1.5) * energy;
      final color = i % 2 == 0 ? const Color(0xFF00FFC2) : const Color(0xFFE040FB);

      canvas.drawCircle(
        Offset(x, y),
        pSize,
        Paint()
          ..color = color.withValues(alpha: 0.8)
          ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 2),
      );
    }
  }

  // 4. Aurora Liquid Ribbon
  void _drawAuroraRibbon(Canvas canvas, Size size) {
    final path = Path();
    path.moveTo(0, size.height / 2);

    for (double x = 0; x <= size.width; x += 10) {
      final progress = x / size.width;
      final wave1 = math.sin(progress * math.pi * 3 + time * 3.5) * 35;
      final wave2 = math.cos(progress * math.pi * 2 - time * 2.0) * 20;
      final y = (size.height / 2) + ((wave1 + wave2) * (isPlaying ? 1.0 : 0.1));
      path.lineTo(x, y);
    }

    final glowPaint = Paint()
      ..color = const Color(0xFF00FFC2).withValues(alpha: 0.5)
      ..strokeWidth = 6.0
      ..style = PaintingStyle.stroke
      ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 8);

    final strokePaint = Paint()
      ..shader = ui.Gradient.linear(
        Offset(0, 0),
        Offset(size.width, 0),
        [const Color(0xFF00E5FF), const Color(0xFF00FFC2), const Color(0xFFFF4081)],
      )
      ..strokeWidth = 3.0
      ..style = PaintingStyle.stroke;

    canvas.drawPath(path, glowPaint);
    canvas.drawPath(path, strokePaint);
  }

  @override
  bool shouldRepaint(covariant _VisualizerPainter oldDelegate) => true;
}
