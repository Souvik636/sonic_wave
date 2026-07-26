import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// Centralized, subtle haptic vocabulary for the app so every interaction
/// speaks the same tactile language. Kept intentionally light — premium apps
/// favour restraint over buzz.
class AppHaptics {
  const AppHaptics._();

  /// A crisp tick for selecting things (tabs, chips, list items, toggles).
  static void selection() => HapticFeedback.selectionClick();

  /// A soft tap for primary actions (play/pause, favourite).
  static void light() => HapticFeedback.lightImpact();

  /// A firmer tap for committal actions (skip track, confirm, delete).
  static void medium() => HapticFeedback.mediumImpact();
}

/// A press-to-scale wrapper that gives any tappable surface a premium,
/// spring-loaded response plus an optional haptic. Drop-in replacement for a
/// bare [GestureDetector] where you want tactile feedback without a Material
/// ripple.
class PremiumTap extends StatefulWidget {
  final Widget child;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;

  /// Scale the child shrinks to while pressed. Lower = more pronounced.
  final double pressedScale;

  /// Haptic fired on a completed tap. Set to null to disable.
  final HapticStyle? haptic;

  final Duration duration;
  final Curve curve;

  /// When false the child is rendered but not interactive (no scale/haptic).
  final bool enabled;

  final HitTestBehavior behavior;

  const PremiumTap({
    super.key,
    required this.child,
    this.onTap,
    this.onLongPress,
    this.pressedScale = 0.96,
    this.haptic = HapticStyle.selection,
    this.duration = const Duration(milliseconds: 120),
    this.curve = Curves.easeOut,
    this.enabled = true,
    this.behavior = HitTestBehavior.opaque,
  });

  @override
  State<PremiumTap> createState() => _PremiumTapState();
}

enum HapticStyle { selection, light, medium }

void _fireHaptic(HapticStyle? style) {
  switch (style) {
    case HapticStyle.selection:
      AppHaptics.selection();
      break;
    case HapticStyle.light:
      AppHaptics.light();
      break;
    case HapticStyle.medium:
      AppHaptics.medium();
      break;
    case null:
      break;
  }
}

/// A refined page transition: the incoming page fades and gently scales into
/// place (and fades/scales back on pop), giving navigations a calm, premium
/// feel versus the default platform slide. Drop-in replacement for
/// `MaterialPageRoute` — `PremiumPageRoute(page: const SomeScreen())`.
class PremiumPageRoute<T> extends PageRouteBuilder<T> {
  final Widget page;

  PremiumPageRoute({required this.page, super.settings})
      : super(
          transitionDuration: const Duration(milliseconds: 360),
          reverseTransitionDuration: const Duration(milliseconds: 280),
          pageBuilder: (context, animation, secondaryAnimation) => page,
          transitionsBuilder: (context, animation, secondaryAnimation, child) {
            // Use `drive(CurveTween(...))` (an Animatable view) rather than
            // constructing a CurvedAnimation here: transitionsBuilder runs every
            // frame, and a CurvedAnimation with a reverseCurve attaches a status
            // listener that is only freed on dispose() — which never happens for
            // per-frame instances, leaking listeners. drive() adds none.
            const curve = Curves.easeOutCubic;
            final fade = animation.drive(CurveTween(curve: curve));
            final scale = animation.drive(
              Tween<double>(begin: 0.97, end: 1.0).chain(CurveTween(curve: curve)),
            );
            return FadeTransition(
              opacity: fade,
              child: ScaleTransition(scale: scale, child: child),
            );
          },
        );
}

/// A one-shot entrance that fades + rises its child, staggered by list [index]
/// so rows cascade in rather than appearing all at once. Safe to use inside a
/// `ListView.builder`: the animation plays once when the row is first built and
/// never blocks scrolling.
class StaggeredReveal extends StatefulWidget {
  final int index;
  final Widget child;

  /// Per-item delay; total stagger is capped so long lists don't feel slow.
  final Duration step;
  final Duration maxDelay;
  final Duration duration;

  /// Vertical distance (px) the child rises from.
  final double offset;

  const StaggeredReveal({
    super.key,
    required this.index,
    required this.child,
    this.step = const Duration(milliseconds: 45),
    this.maxDelay = const Duration(milliseconds: 350),
    this.duration = const Duration(milliseconds: 420),
    this.offset = 24,
  });

  @override
  State<StaggeredReveal> createState() => _StaggeredRevealState();
}

class _StaggeredRevealState extends State<StaggeredReveal>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: widget.duration,
  );
  late final Animation<double> _curved =
      CurvedAnimation(parent: _controller, curve: Curves.easeOutCubic);

  @override
  void initState() {
    super.initState();
    final delayMs =
        (widget.index * widget.step.inMilliseconds).clamp(0, widget.maxDelay.inMilliseconds);
    Future.delayed(Duration(milliseconds: delayMs), () {
      if (mounted) _controller.forward();
    });
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _curved,
      builder: (context, child) {
        return Opacity(
          opacity: _curved.value,
          child: Transform.translate(
            offset: Offset(0, widget.offset * (1 - _curved.value)),
            child: child,
          ),
        );
      },
      child: widget.child,
    );
  }
}

class _PremiumTapState extends State<PremiumTap> {
  bool _pressed = false;

  void _setPressed(bool value) {
    if (_pressed == value) return;
    setState(() => _pressed = value);
  }

  @override
  Widget build(BuildContext context) {
    if (!widget.enabled) return widget.child;

    return GestureDetector(
      behavior: widget.behavior,
      onTapDown: (_) => _setPressed(true),
      onTapUp: (_) => _setPressed(false),
      onTapCancel: () => _setPressed(false),
      onTap: widget.onTap == null
          ? null
          : () {
              _fireHaptic(widget.haptic);
              widget.onTap!();
            },
      onLongPress: widget.onLongPress == null
          ? null
          : () {
              _fireHaptic(HapticStyle.medium);
              widget.onLongPress!();
            },
      child: AnimatedScale(
        scale: _pressed ? widget.pressedScale : 1.0,
        duration: widget.duration,
        curve: widget.curve,
        child: widget.child,
      ),
    );
  }
}

/// A screen headline with a subtle white→accent gradient sweep, matching the
/// Smart Organizer sheet's title treatment so every tab shares the same
/// premium typography language. The accent end follows the current theme.
class GradientHeadline extends StatelessWidget {
  final String text;
  final double fontSize;

  const GradientHeadline(this.text, {super.key, this.fontSize = 24});

  @override
  Widget build(BuildContext context) {
    final accent = Theme.of(context).colorScheme.primary;
    return ShaderMask(
      shaderCallback: (r) => LinearGradient(
        colors: [Colors.white, Color.lerp(Colors.white, accent, 0.75)!],
        begin: Alignment.centerLeft,
        end: Alignment.centerRight,
      ).createShader(r),
      child: Text(
        text,
        style: Theme.of(context).textTheme.headlineLarge?.copyWith(
              fontSize: fontSize,
              fontWeight: FontWeight.w800,
              color: Colors.white,
            ),
      ),
    );
  }
}

/// Accent-glowing empty/info state: a soft breathing halo behind an icon with
/// title + subtitle below, themed to the selected accent. Drop-in for the
/// plain grey icon+text placeholders.
class GlowEmptyState extends StatelessWidget {
  final IconData icon;
  final String title;
  final String? subtitle;
  final Widget? action;

  const GlowEmptyState({
    super.key,
    required this.icon,
    required this.title,
    this.subtitle,
    this.action,
  });

  @override
  Widget build(BuildContext context) {
    final accent = Theme.of(context).colorScheme.primary;
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Container(
            width: 84,
            height: 84,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: accent.withValues(alpha: 0.08),
              border: Border.all(color: accent.withValues(alpha: 0.25)),
              boxShadow: [
                BoxShadow(
                  color: accent.withValues(alpha: 0.12),
                  blurRadius: 24,
                  spreadRadius: 4,
                ),
              ],
            ),
            child: Icon(icon, size: 38, color: accent.withValues(alpha: 0.8)),
          ),
          const SizedBox(height: 18),
          Text(
            title,
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.w600,
                ),
          ),
          if (subtitle != null) ...[
            const SizedBox(height: 6),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 40),
              child: Text(
                subtitle!,
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ),
          ],
          if (action != null) ...[
            const SizedBox(height: 18),
            action!,
          ],
        ],
      ),
    );
  }
}

/// A modern accent-themed loading spinner: a rotating sweep-gradient arc with
/// a soft glow and a bright leading dot. Reads as "resolving / working" far
/// better than the stock [CircularProgressIndicator], and matches the app's
/// premium visual language. Purely decorative — pair it with a semantic label
/// where accessibility matters.
class PremiumLoader extends StatefulWidget {
  final double size;
  final double strokeWidth;
  final Color? color;

  const PremiumLoader({
    super.key,
    this.size = 36,
    this.strokeWidth = 3,
    this.color,
  });

  @override
  State<PremiumLoader> createState() => _PremiumLoaderState();
}

class _PremiumLoaderState extends State<PremiumLoader>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1100),
    )..repeat();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final color = widget.color ?? Theme.of(context).colorScheme.primary;
    return SizedBox(
      width: widget.size,
      height: widget.size,
      child: AnimatedBuilder(
        animation: _controller,
        builder: (context, _) => CustomPaint(
          painter: _PremiumLoaderPainter(
            progress: _controller.value,
            color: color,
            strokeWidth: widget.strokeWidth,
          ),
        ),
      ),
    );
  }
}

class _PremiumLoaderPainter extends CustomPainter {
  final double progress;
  final Color color;
  final double strokeWidth;

  _PremiumLoaderPainter({
    required this.progress,
    required this.color,
    required this.strokeWidth,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final center = size.center(Offset.zero);
    final radius = (size.shortestSide - strokeWidth) / 2;
    final rect = Rect.fromCircle(center: center, radius: radius);
    final rotation = progress * 2 * math.pi;

    // Faint full track so the arc reads as part of a ring.
    canvas.drawCircle(
      center,
      radius,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = strokeWidth
        ..color = color.withValues(alpha: 0.15),
    );

    // Rotating arc that fades in along its length (transparent tail →
    // full-strength head), with a soft glow underneath.
    const sweep = math.pi * 1.35;
    final gradient = SweepGradient(
      startAngle: 0,
      endAngle: sweep,
      colors: [color.withValues(alpha: 0), color],
      transform: GradientRotation(rotation),
    );
    canvas.drawArc(
      rect,
      rotation,
      sweep,
      false,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = strokeWidth + 1.5
        ..strokeCap = StrokeCap.round
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 3)
        ..color = color.withValues(alpha: 0.35),
    );
    canvas.drawArc(
      rect,
      rotation,
      sweep,
      false,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = strokeWidth
        ..strokeCap = StrokeCap.round
        ..shader = gradient.createShader(rect),
    );

    // Bright leading dot at the arc head.
    final headAngle = rotation + sweep;
    final head = Offset(
      center.dx + radius * math.cos(headAngle),
      center.dy + radius * math.sin(headAngle),
    );
    canvas.drawCircle(
      head,
      strokeWidth * 0.9,
      Paint()
        ..color = Colors.white
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 1.5),
    );
  }

  @override
  bool shouldRepaint(_PremiumLoaderPainter old) =>
      old.progress != progress ||
      old.color != color ||
      old.strokeWidth != strokeWidth;
}
