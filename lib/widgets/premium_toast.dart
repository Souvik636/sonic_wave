import 'dart:async';
import 'dart:ui';

import 'package:flutter/material.dart';
import 'premium_interaction.dart';

/// The visual/timing profile of a playback error, derived from its message so
/// the toast can show a matching icon and stay on screen just long enough for
/// its severity ("no internet" earns more reading time than a generic retry).
class PlaybackErrorContext {
  final IconData icon;
  final String title;
  final Duration dismissAfter;
  final bool canRetry;

  const PlaybackErrorContext({
    required this.icon,
    required this.title,
    required this.dismissAfter,
    this.canRetry = true,
  });
}

PlaybackErrorContext classifyPlaybackError(String message) {
  final msg = message.toLowerCase();

  // Timeout first: its message also mentions "connection", so it must win
  // over the broader network branch below.
  if (msg.contains('timed out') || msg.contains('slow')) {
    return const PlaybackErrorContext(
      icon: Icons.hourglass_bottom_rounded,
      title: 'Taking too long',
      dismissAfter: Duration(seconds: 5),
    );
  }
  if (msg.contains('internet') ||
      msg.contains('network') ||
      msg.contains('connection')) {
    return const PlaybackErrorContext(
      icon: Icons.wifi_off_rounded,
      title: 'Connection problem',
      dismissAfter: Duration(seconds: 6),
    );
  }
  if (msg.contains('too many requests') || msg.contains('wait a moment')) {
    return const PlaybackErrorContext(
      icon: Icons.speed_rounded,
      title: 'Slow down a moment',
      dismissAfter: Duration(seconds: 5),
    );
  }
  if (msg.contains('restricted') ||
      msg.contains('no longer available') ||
      msg.contains('different song')) {
    // Retrying the same song won't help — steer to another track instead.
    return const PlaybackErrorContext(
      icon: Icons.music_off_rounded,
      title: 'Song unavailable',
      dismissAfter: Duration(seconds: 4),
      canRetry: false,
    );
  }
  return const PlaybackErrorContext(
    icon: Icons.error_outline_rounded,
    title: 'Playback failed',
    dismissAfter: Duration(seconds: 4),
  );
}

/// Glassmorphic floating toast for playback errors: frosted blur, accent-red
/// tinted border/glow, slide+fade entrance, swipe-up to dismiss, and an
/// auto-dismiss timer chosen by [classifyPlaybackError]. Only one toast is
/// visible at a time — a new error replaces the current one.
class PremiumToast {
  PremiumToast._();

  static OverlayEntry? _entry;

  static void showPlaybackError(
    BuildContext context, {
    required String message,
    VoidCallback? onRetry,
  }) {
    dismiss();
    final errorContext = classifyPlaybackError(message);
    final overlay = Overlay.of(context, rootOverlay: true);
    _entry = OverlayEntry(
      builder: (_) => _ToastCard(
        message: message,
        errorContext: errorContext,
        onRetry: errorContext.canRetry ? onRetry : null,
        onDismissed: dismiss,
      ),
    );
    overlay.insert(_entry!);
  }

  static void dismiss() {
    _entry?.remove();
    _entry = null;
  }
}

class _ToastCard extends StatefulWidget {
  final String message;
  final PlaybackErrorContext errorContext;
  final VoidCallback? onRetry;
  final VoidCallback onDismissed;

  const _ToastCard({
    required this.message,
    required this.errorContext,
    required this.onRetry,
    required this.onDismissed,
  });

  @override
  State<_ToastCard> createState() => _ToastCardState();
}

class _ToastCardState extends State<_ToastCard>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  late final Animation<double> _fade;
  late final Animation<Offset> _slide;
  Timer? _autoDismiss;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 320),
      reverseDuration: const Duration(milliseconds: 220),
    );
    _fade = CurvedAnimation(parent: _controller, curve: Curves.easeOut);
    _slide = Tween<Offset>(
      begin: const Offset(0, -0.4),
      end: Offset.zero,
    ).animate(CurvedAnimation(parent: _controller, curve: Curves.easeOutCubic));
    _controller.forward();
    _autoDismiss = Timer(widget.errorContext.dismissAfter, _close);
  }

  Future<void> _close() async {
    _autoDismiss?.cancel();
    if (mounted) await _controller.reverse();
    widget.onDismissed();
  }

  @override
  void dispose() {
    _autoDismiss?.cancel();
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    const errorColor = Color(0xFFFF5A6E);
    return Positioned(
      top: MediaQuery.of(context).padding.top + 12,
      left: 16,
      right: 16,
      child: SlideTransition(
        position: _slide,
        child: FadeTransition(
          opacity: _fade,
          child: Dismissible(
            key: const ValueKey('premium_error_toast'),
            direction: DismissDirection.up,
            onDismissed: (_) {
              _autoDismiss?.cancel();
              widget.onDismissed();
            },
            child: Material(
              color: Colors.transparent,
              child: ClipRRect(
                borderRadius: BorderRadius.circular(18),
                child: BackdropFilter(
                  filter: ImageFilter.blur(sigmaX: 18, sigmaY: 18),
                  child: Container(
                    padding: const EdgeInsets.fromLTRB(14, 12, 8, 12),
                    decoration: BoxDecoration(
                      color: const Color(0xFF12122A).withValues(alpha: 0.78),
                      borderRadius: BorderRadius.circular(18),
                      border: Border.all(
                        color: errorColor.withValues(alpha: 0.35),
                        width: 1,
                      ),
                      boxShadow: [
                        BoxShadow(
                          color: errorColor.withValues(alpha: 0.18),
                          blurRadius: 24,
                          offset: const Offset(0, 8),
                        ),
                      ],
                    ),
                    child: Row(
                      children: [
                        Container(
                          width: 40,
                          height: 40,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            color: errorColor.withValues(alpha: 0.14),
                            border: Border.all(
                              color: errorColor.withValues(alpha: 0.4),
                            ),
                          ),
                          child: Icon(
                            widget.errorContext.icon,
                            color: errorColor,
                            size: 20,
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                widget.errorContext.title,
                                style: const TextStyle(
                                  color: Colors.white,
                                  fontSize: 13.5,
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                              const SizedBox(height: 2),
                              Text(
                                widget.message,
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  color: Colors.white.withValues(alpha: 0.72),
                                  fontSize: 12,
                                  height: 1.25,
                                ),
                              ),
                            ],
                          ),
                        ),
                        if (widget.onRetry != null) ...[
                          const SizedBox(width: 6),
                          TextButton(
                            onPressed: () {
                              AppHaptics.light();
                              _autoDismiss?.cancel();
                              widget.onDismissed();
                              widget.onRetry!();
                            },
                            style: TextButton.styleFrom(
                              foregroundColor: Theme.of(
                                context,
                              ).colorScheme.primary,
                              padding: const EdgeInsets.symmetric(
                                horizontal: 12,
                                vertical: 8,
                              ),
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(12),
                              ),
                            ),
                            child: const Text(
                              'Retry',
                              style: TextStyle(
                                fontSize: 12.5,
                                fontWeight: FontWeight.w700,
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
          ),
        ),
      ),
    );
  }
}
