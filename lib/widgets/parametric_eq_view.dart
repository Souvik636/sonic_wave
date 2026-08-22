import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:provider/provider.dart';
import '../providers/settings_provider.dart';
import '../theme/app_colors.dart';
import 'app_toast.dart';
import 'premium_interaction.dart';

/// Draggable 5-Band Parametric Equalizer with Bézier Frequency Response Spline
class ParametricEqView extends StatefulWidget {
  const ParametricEqView({super.key});

  static void show(BuildContext context) {
    AppHaptics.medium();
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (_) => const ParametricEqView(),
    );
  }

  @override
  State<ParametricEqView> createState() => _ParametricEqViewState();
}

class _ParametricEqViewState extends State<ParametricEqView> {
  // 5 band center frequencies and default labels
  final List<String> _bandLabels = ['60Hz', '230Hz', '910Hz', '4kHz', '14kHz'];
  List<double> _gains = [0.0, 0.0, 0.0, 0.0, 0.0];
  int? _activeDragIndex;

  @override
  void initState() {
    super.initState();
    final settings = context.read<SettingsProvider>();
    if (settings.customEqualizerGains.length == 5) {
      _gains = List.from(settings.customEqualizerGains);
    }
  }

  void _updateGain(int index, double newGain) {
    final clamped = newGain.clamp(-12.0, 12.0);
    setState(() {
      _gains[index] = clamped;
    });
    final settings = context.read<SettingsProvider>();
    settings.setCustomEqualizerGains(_gains);
  }

  void _applyPreset(String name, List<double> gains) {
    AppHaptics.medium();
    setState(() {
      _gains = List.from(gains);
    });
    final settings = context.read<SettingsProvider>();
    settings.setCustomEqualizerGains(_gains);
    AppToast.show(
      context,
      'Applied "$name" Equalizer Profile',
      type: ToastType.success,
      icon: Icons.graphic_eq_rounded,
    );
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 32),
      decoration: BoxDecoration(
        color: const Color(0xFF0D1017),
        borderRadius: const BorderRadius.vertical(top: Radius.circular(28)),
        border: Border.all(color: Colors.white.withValues(alpha: 0.1)),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.9),
            blurRadius: 30,
            offset: const Offset(0, -6),
          ),
        ],
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Drag handle
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

          // Header
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Row(
                children: [
                  Container(
                    padding: const EdgeInsets.all(8),
                    decoration: BoxDecoration(
                      color: AppColors.primary.withValues(alpha: 0.15),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: const Icon(Icons.tune_rounded, color: AppColors.primary, size: 20),
                  ),
                  const SizedBox(width: 12),
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Parametric Equalizer (PEQ)',
                        style: GoogleFonts.outfit(
                          color: Colors.white,
                          fontSize: 18,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      Text(
                        'Draggable 5-Band Studio Spline',
                        style: GoogleFonts.outfit(
                          color: AppColors.primaryLight,
                          fontSize: 12,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    ],
                  ),
                ],
              ),
              TextButton(
                onPressed: () => _applyPreset('Flat', [0, 0, 0, 0, 0]),
                child: Text(
                  'Reset',
                  style: GoogleFonts.outfit(color: Colors.white60, fontSize: 13),
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),

          // Interactive Frequency Response Spline Canvas
          Container(
            height: 180,
            width: double.infinity,
            decoration: BoxDecoration(
              color: Colors.black.withValues(alpha: 0.5),
              borderRadius: BorderRadius.circular(20),
              border: Border.all(color: Colors.white.withValues(alpha: 0.08)),
            ),
            child: LayoutBuilder(
              builder: (context, constraints) {
                return GestureDetector(
                  onPanDown: (details) {
                    final localX = details.localPosition.dx;
                    final w = constraints.maxWidth;
                    // Find closest node
                    int closest = 0;
                    double minDist = double.infinity;
                    for (int i = 0; i < 5; i++) {
                      final nodeX = (w / 6) * (i + 1);
                      final dist = (localX - nodeX).abs();
                      if (dist < minDist) {
                        minDist = dist;
                        closest = i;
                      }
                    }
                    _activeDragIndex = closest;
                    final localY = details.localPosition.dy;
                    final normalizedY = (1.0 - (localY / constraints.maxHeight)).clamp(0.0, 1.0);
                    final gain = (normalizedY * 24.0) - 12.0;
                    _updateGain(closest, gain);
                  },
                  onPanUpdate: (details) {
                    if (_activeDragIndex != null) {
                      final localY = details.localPosition.dy;
                      final normalizedY = (1.0 - (localY / constraints.maxHeight)).clamp(0.0, 1.0);
                      final gain = (normalizedY * 24.0) - 12.0;
                      _updateGain(_activeDragIndex!, gain);
                    }
                  },
                  onPanEnd: (_) => _activeDragIndex = null,
                  child: CustomPaint(
                    size: Size(constraints.maxWidth, constraints.maxHeight),
                    painter: _ParametricSplinePainter(
                      gains: _gains,
                      bandLabels: _bandLabels,
                      activeIndex: _activeDragIndex,
                    ),
                  ),
                );
              },
            ),
          ),
          const SizedBox(height: 18),

          // Presets Row
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              children: [
                _buildPresetPill('Bass Punch', [7.0, 4.0, -1.0, 0.0, 2.0]),
                _buildPresetPill('Harman Target', [5.5, 3.0, 1.0, 4.5, 6.0]),
                _buildPresetPill('Vocal Boost', [-3.0, 2.0, 6.5, 4.0, 1.5]),
                _buildPresetPill('Electronic', [6.0, -2.0, -3.0, 4.0, 7.0]),
                _buildPresetPill('Rock & Metal', [4.0, 3.0, 4.0, 3.0, -1.0]),
                _buildPresetPill('Acoustic Clarity', [0.0, 3.0, 2.0, 4.0, 2.0]),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildPresetPill(String name, List<double> gains) {
    return Padding(
      padding: const EdgeInsets.only(right: 8),
      child: Material(
        color: Colors.white.withValues(alpha: 0.06),
        borderRadius: BorderRadius.circular(12),
        child: InkWell(
          onTap: () => _applyPreset(name, gains),
          borderRadius: BorderRadius.circular(12),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: Colors.white.withValues(alpha: 0.08)),
            ),
            child: Text(
              name,
              style: GoogleFonts.outfit(
                color: Colors.white,
                fontSize: 12,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _ParametricSplinePainter extends CustomPainter {
  final List<double> gains;
  final List<String> bandLabels;
  final int? activeIndex;

  _ParametricSplinePainter({
    required this.gains,
    required this.bandLabels,
    this.activeIndex,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width;
    final h = size.height;

    // Draw Grid Lines (0 dB Center line, +6dB, -6dB)
    final gridPaint = Paint()
      ..color = Colors.white.withValues(alpha: 0.07)
      ..strokeWidth = 1.0;

    final centerLinePaint = Paint()
      ..color = Colors.white.withValues(alpha: 0.20)
      ..strokeWidth = 1.2
      ..style = PaintingStyle.stroke;

    canvas.drawLine(Offset(0, h * 0.25), Offset(w, h * 0.25), gridPaint); // +6dB
    canvas.drawLine(Offset(0, h * 0.50), Offset(w, h * 0.50), centerLinePaint); // 0dB
    canvas.drawLine(Offset(0, h * 0.75), Offset(w, h * 0.75), gridPaint); // -6dB

    // Node Positions
    final List<Offset> points = [];
    points.add(Offset(0, h * 0.50 - (gains[0] / 24.0 * h))); // Edge start anchor

    for (int i = 0; i < 5; i++) {
      final x = (w / 6) * (i + 1);
      final normalizedGain = gains[i] / 24.0; // [-0.5, 0.5]
      final y = (h * 0.50) - (normalizedGain * h);
      points.add(Offset(x, y));
    }
    points.add(Offset(w, h * 0.50 - (gains[4] / 24.0 * h))); // Edge end anchor

    // Construct Smooth Bézier Spline
    final path = Path();
    path.moveTo(points[0].dx, points[0].dy);

    for (int i = 0; i < points.length - 1; i++) {
      final p0 = points[i];
      final p1 = points[i + 1];
      final midX = (p0.dx + p1.dx) / 2;
      path.cubicTo(midX, p0.dy, midX, p1.dy, p1.dx, p1.dy);
    }

    // Gradient Fill Under Curve
    final fillPath = Path.from(path)
      ..lineTo(w, h)
      ..lineTo(0, h)
      ..close();

    final fillGradient = ui.Gradient.linear(
      Offset(0, 0),
      Offset(0, h),
      [
        const Color(0xFF00FFC2).withValues(alpha: 0.35),
        const Color(0xFF00E5FF).withValues(alpha: 0.05),
        Colors.transparent,
      ],
      [0.0, 0.6, 1.0],
    );

    final fillPaint = Paint()
      ..shader = fillGradient
      ..style = PaintingStyle.fill;

    canvas.drawPath(fillPath, fillPaint);

    // Glowing Neon Spline Stroke
    final splinePaint = Paint()
      ..color = const Color(0xFF00FFC2)
      ..strokeWidth = 2.8
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round;

    final glowPaint = Paint()
      ..color = const Color(0xFF00FFC2).withValues(alpha: 0.4)
      ..strokeWidth = 8.0
      ..style = PaintingStyle.stroke
      ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 6);

    canvas.drawPath(path, glowPaint);
    canvas.drawPath(path, splinePaint);

    // Draw Draggable Control Nodes & Labels
    for (int i = 0; i < 5; i++) {
      final pt = points[i + 1];
      final isActive = i == activeIndex;

      // Outer glow ring
      canvas.drawCircle(
        pt,
        isActive ? 14 : 10,
        Paint()..color = const Color(0xFF00FFC2).withValues(alpha: isActive ? 0.4 : 0.2),
      );

      // Node inner circle
      canvas.drawCircle(
        pt,
        isActive ? 7 : 5,
        Paint()..color = Colors.white,
      );

      // Label below grid
      final textPainter = TextPainter(
        text: TextSpan(
          text: '${bandLabels[i]}\n${gains[i] >= 0 ? '+' : ''}${gains[i].toStringAsFixed(1)}dB',
          style: TextStyle(
            color: isActive ? const Color(0xFF00FFC2) : Colors.white60,
            fontSize: 9,
            fontWeight: FontWeight.bold,
          ),
        ),
        textAlign: TextAlign.center,
        textDirection: TextDirection.ltr,
      )..layout();

      textPainter.paint(
        canvas,
        Offset(pt.dx - textPainter.width / 2, h - 24),
      );
    }
  }

  @override
  bool shouldRepaint(covariant _ParametricSplinePainter oldDelegate) => true;
}
