import 'dart:async';
import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import '../theme/app_colors.dart';

enum ToastType { success, info, warning, error, favorite, download }

class ToastConfig {
  final Color color;
  final IconData icon;

  const ToastConfig(this.color, this.icon);
}

/// Ultra-Premium Top Toast & In-App Notification System
/// Displays floating glass notifications at the TOP of the screen.
class AppToast {
  static OverlayEntry? _currentOverlay;
  static Timer? _dismissTimer;

  static void show(
    BuildContext context,
    String message, {
    ToastType type = ToastType.info,
    IconData? icon,
    String? actionLabel,
    VoidCallback? onAction,
    Duration? duration,
  }) {
    if (!context.mounted) return;

    // Clear active toast if present
    _currentOverlay?.remove();
    _currentOverlay = null;
    _dismissTimer?.cancel();

    final overlayState = Overlay.maybeOf(context);
    if (overlayState == null) return;

    final autoDuration =
        duration ?? _getSmartDuration(message, type, actionLabel != null);
    final config = _getToastConfig(type, Theme.of(context).colorScheme.primary);

    late OverlayEntry entry;
    entry = OverlayEntry(
      builder: (ctx) {
        final topMargin = MediaQuery.of(ctx).padding.top + 8;
        return Positioned(
          top: topMargin,
          left: 16,
          right: 16,
          child: Material(
            color: Colors.transparent,
            child: _TopToastCard(
              message: message,
              type: type,
              icon: icon ?? config.icon,
              accentColor: config.color,
              actionLabel: actionLabel,
              onAction: onAction,
              onDismiss: () {
                _dismissTimer?.cancel();
                if (_currentOverlay == entry) {
                  entry.remove();
                  _currentOverlay = null;
                }
              },
            ),
          ),
        );
      },
    );

    _currentOverlay = entry;
    overlayState.insert(entry);

    _dismissTimer = Timer(autoDuration, () {
      if (_currentOverlay == entry) {
        entry.remove();
        _currentOverlay = null;
      }
    });
  }

  static ToastConfig _getToastConfig(ToastType type, Color primaryColor) {
    switch (type) {
      case ToastType.success:
        return const ToastConfig(Color(0xFF00E676), Icons.check_circle_rounded);
      case ToastType.favorite:
        return const ToastConfig(Color(0xFFFF2A6D), Icons.favorite_rounded);
      case ToastType.download:
        return const ToastConfig(
          Color(0xFF00E5FF),
          Icons.download_done_rounded,
        );
      case ToastType.warning:
        return const ToastConfig(
          Color(0xFFFF9100),
          Icons.warning_amber_rounded,
        );
      case ToastType.error:
        return const ToastConfig(
          Color(0xFFFF1744),
          Icons.error_outline_rounded,
        );
      case ToastType.info:
        return ToastConfig(primaryColor, Icons.info_rounded);
    }
  }

  static Duration _getSmartDuration(
    String message,
    ToastType type,
    bool hasAction,
  ) {
    if (hasAction) return const Duration(milliseconds: 4500);
    if (type == ToastType.error || type == ToastType.warning) {
      return const Duration(milliseconds: 3800);
    }
    if (message.length > 50) return const Duration(milliseconds: 3200);
    if (type == ToastType.favorite || type == ToastType.success) {
      return const Duration(milliseconds: 2000);
    }
    return const Duration(milliseconds: 2600);
  }
}

class _TopToastCard extends StatefulWidget {
  final String message;
  final ToastType type;
  final IconData icon;
  final Color accentColor;
  final String? actionLabel;
  final VoidCallback? onAction;
  final VoidCallback onDismiss;

  const _TopToastCard({
    required this.message,
    required this.type,
    required this.icon,
    required this.accentColor,
    required this.onDismiss,
    this.actionLabel,
    this.onAction,
  });

  @override
  State<_TopToastCard> createState() => _TopToastCardState();
}

class _TopToastCardState extends State<_TopToastCard>
    with SingleTickerProviderStateMixin {
  late AnimationController _controller;
  late Animation<double> _slideAnimation;
  late Animation<double> _scaleAnimation;
  late Animation<double> _opacityAnimation;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 450),
    );

    _slideAnimation = Tween<double>(
      begin: -60.0,
      end: 0.0,
    ).animate(CurvedAnimation(parent: _controller, curve: Curves.easeOutBack));

    _scaleAnimation = Tween<double>(
      begin: 0.90,
      end: 1.0,
    ).animate(CurvedAnimation(parent: _controller, curve: Curves.easeOutCubic));

    _opacityAnimation = Tween<double>(
      begin: 0.0,
      end: 1.0,
    ).animate(CurvedAnimation(parent: _controller, curve: Curves.easeOut));

    _controller.forward();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _controller,
      builder: (context, child) {
        return Transform.translate(
          offset: Offset(0, _slideAnimation.value),
          child: Transform.scale(
            scale: _scaleAnimation.value,
            child: Opacity(opacity: _opacityAnimation.value, child: child),
          ),
        );
      },
      child: GestureDetector(
        onTap: widget.onDismiss,
        child: ClipRRect(
          borderRadius: BorderRadius.circular(22),
          child: BackdropFilter(
            filter: ImageFilter.blur(sigmaX: 18, sigmaY: 18),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              decoration: BoxDecoration(
                color: AppColors.surface.withValues(alpha: 0.90),
                borderRadius: BorderRadius.circular(22),
                border: Border.all(
                  color: widget.accentColor.withValues(alpha: 0.45),
                  width: 1.2,
                ),
                boxShadow: [
                  BoxShadow(
                    color: widget.accentColor.withValues(alpha: 0.22),
                    blurRadius: 20,
                    spreadRadius: 1,
                    offset: const Offset(0, 4),
                  ),
                  BoxShadow(
                    color: Colors.black.withValues(alpha: 0.5),
                    blurRadius: 14,
                    spreadRadius: -2,
                  ),
                ],
              ),
              child: Row(
                children: [
                  // Glowing Icon Badge
                  Container(
                    padding: const EdgeInsets.all(9),
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: widget.accentColor.withValues(alpha: 0.15),
                      border: Border.all(
                        color: widget.accentColor.withValues(alpha: 0.35),
                        width: 1,
                      ),
                      boxShadow: [
                        BoxShadow(
                          color: widget.accentColor.withValues(alpha: 0.3),
                          blurRadius: 10,
                        ),
                      ],
                    ),
                    child: Icon(
                      widget.icon,
                      color: widget.accentColor,
                      size: 20,
                    ),
                  ),
                  const SizedBox(width: 14),
                  // Message Text
                  Expanded(
                    child: Text(
                      widget.message,
                      style: GoogleFonts.inter(
                        color: Colors.white,
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                        height: 1.3,
                      ),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  // Action Button (if any)
                  if (widget.actionLabel != null &&
                      widget.onAction != null) ...[
                    const SizedBox(width: 10),
                    TextButton(
                      onPressed: () {
                        widget.onDismiss();
                        widget.onAction!();
                      },
                      style: TextButton.styleFrom(
                        foregroundColor: widget.accentColor,
                        padding: const EdgeInsets.symmetric(
                          horizontal: 12,
                          vertical: 6,
                        ),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(10),
                        ),
                        backgroundColor: widget.accentColor.withValues(
                          alpha: 0.15,
                        ),
                      ),
                      child: Text(
                        widget.actionLabel!,
                        style: const TextStyle(
                          fontWeight: FontWeight.bold,
                          fontSize: 12,
                        ),
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
