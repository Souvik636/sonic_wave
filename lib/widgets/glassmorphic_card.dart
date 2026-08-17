import 'dart:ui';
import 'package:flutter/material.dart';
import '../theme/app_colors.dart';
import 'premium_interaction.dart';

class GlassmorphicCard extends StatelessWidget {
  final Widget child;
  final double borderRadius;
  final double blur;
  final double opacity;
  final EdgeInsetsGeometry? padding;
  final EdgeInsetsGeometry? margin;
  final double? width;
  final double? height;
  final VoidCallback? onTap;
  final Color? borderColor;
  final Color? fillColor;

  const GlassmorphicCard({
    super.key,
    required this.child,
    this.borderRadius = 20,
    this.blur = 15,
    this.opacity = 0.1,
    this.padding,
    this.margin,
    this.width,
    this.height,
    this.onTap,
    this.borderColor,
    this.fillColor,
  });

  @override
  Widget build(BuildContext context) {
    final card = Container(
      margin: margin,
      width: width,
      height: height,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(borderRadius),
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: blur, sigmaY: blur),
          child: Container(
            padding: padding ?? const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: fillColor ?? Colors.white.withValues(alpha: opacity),
              borderRadius: BorderRadius.circular(borderRadius),
              border: Border.all(
                color: borderColor ?? AppColors.glassBorder,
                width: 1,
              ),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.1),
                  blurRadius: 20,
                  offset: const Offset(0, 8),
                ),
              ],
            ),
            child: child,
          ),
        ),
      ),
    );

    if (onTap == null) return card;

    // Tappable glass cards get a premium spring-press + haptic instead of a
    // dead GestureDetector.
    return PremiumTap(onTap: onTap, child: card);
  }
}
