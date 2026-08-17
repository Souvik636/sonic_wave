import 'dart:math';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../providers/settings_provider.dart';

/// A small decorative "now playing" equalizer.
///
/// Deterministic by design: every bar's motion is a fixed-phase sine wave off a
/// single continuous controller — no `Random()`, so the animation is smooth and
/// repeatable rather than jittery/random. Bars stay visually distinct via
/// per-index phase + frequency offsets derived from the bar index alone.
class AnimatedEqualizer extends StatefulWidget {
  final bool isPlaying;
  final double height;
  final double barWidth;
  final int barCount;
  final Color? color;

  const AnimatedEqualizer({
    super.key,
    this.isPlaying = true,
    this.height = 20,
    this.barWidth = 3,
    this.barCount = 4,
    this.color,
  });

  @override
  State<AnimatedEqualizer> createState() => _AnimatedEqualizerState();
}

class _AnimatedEqualizerState extends State<AnimatedEqualizer>
    with SingleTickerProviderStateMixin {
  late AnimationController _controller;

  @override
  void initState() {
    super.initState();
    final speed = Provider.of<SettingsProvider>(
      context,
      listen: false,
    ).visualizerSpeed;
    // One continuous driver — its phase is the shared clock for every bar.
    _controller = AnimationController(
      vsync: this,
      duration: Duration(milliseconds: (1400 / speed).round().clamp(200, 6000)),
    );
    if (widget.isPlaying) _controller.repeat();
  }

  @override
  void didUpdateWidget(AnimatedEqualizer oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.isPlaying != oldWidget.isPlaying) {
      if (widget.isPlaying) {
        _controller.repeat();
      } else {
        _controller.stop();
      }
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  /// Deterministic height factor (0.16..1.0) for [index] at controller [t].
  double _factor(int index, double t) {
    if (!widget.isPlaying) return 0.18;
    // Per-bar phase + frequency come from the index only → distinct but stable.
    final double phase = index * 0.9;
    final double freq = 1.0 + (index % 3) * 0.6;
    final double v = 0.5 + 0.5 * sin(t * 2 * pi * freq + phase);
    return 0.2 + 0.8 * v;
  }

  @override
  Widget build(BuildContext context) {
    final color = widget.color ?? Theme.of(context).colorScheme.primary;

    return SizedBox(
      height: widget.height,
      width: (widget.barWidth + 2) * widget.barCount,
      child: AnimatedBuilder(
        animation: _controller,
        builder: (context, _) {
          return Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            crossAxisAlignment: CrossAxisAlignment.end,
            children: List.generate(widget.barCount, (index) {
              final factor = _factor(index, _controller.value);
              return TweenAnimationBuilder<double>(
                // Smooth any change so paused/resumed transitions never snap.
                tween: Tween(begin: factor, end: factor),
                duration: const Duration(milliseconds: 120),
                curve: Curves.easeOut,
                builder: (context, value, child) => Container(
                  width: widget.barWidth,
                  height: widget.height * value,
                  decoration: BoxDecoration(
                    color: color,
                    borderRadius: BorderRadius.circular(widget.barWidth / 2),
                    boxShadow: [
                      BoxShadow(
                        color: color.withValues(alpha: 0.4),
                        blurRadius: 4,
                        offset: const Offset(0, 1),
                      ),
                    ],
                  ),
                ),
              );
            }),
          );
        },
      ),
    );
  }
}
