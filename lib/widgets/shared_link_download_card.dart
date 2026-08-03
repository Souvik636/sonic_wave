import 'dart:async';
import 'dart:math' as math;
import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:shimmer/shimmer.dart';

import '../providers/player_provider.dart';
import '../theme/app_colors.dart';
import 'download_widgets.dart';
import 'premium_interaction.dart';
import 'song_album_art.dart';

/// Floating card that reports what happened to a YouTube link shared into the
/// app.
///
/// A share is the one download with nowhere to render itself: it begins in
/// another app's share sheet, so there is no song tile to grow a progress ring
/// and no screen the user chose to be on. This used to be three snackbars — one
/// on start, silence for the length of the download, one at the end — which left
/// the app looking idle for minutes and gave no way to stop or replay anything.
///
/// Lives in the root overlay rather than a screen's tree so it survives route
/// pushes: the user can open the player or settings while a shared song
/// downloads and still see it land.
class SharedLinkDownloadCard extends StatefulWidget {
  const SharedLinkDownloadCard({super.key});

  /// Height of the mini player that sits directly above the bottom nav.
  static const double _miniPlayerHeight = 84;
  static const double _gap = 12;

  @override
  State<SharedLinkDownloadCard> createState() => _SharedLinkDownloadCardState();
}

class _SharedLinkDownloadCardState extends State<SharedLinkDownloadCard>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  late final Animation<double> _fade;
  late final Animation<Offset> _slide;

  /// The last status we were given, kept alive through the exit animation so the
  /// card does not blank out a frame before it finishes sliding away.
  SharedDownloadStatus? _shown;
  SharedDownloadPhase? _lastPhase;
  Timer? _autoDismiss;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 380),
      reverseDuration: const Duration(milliseconds: 240),
    );
    _fade = CurvedAnimation(parent: _controller, curve: Curves.easeOut);
    _slide = Tween<Offset>(begin: const Offset(0, 0.35), end: Offset.zero)
        .animate(CurvedAnimation(parent: _controller, curve: Curves.easeOutCubic));
  }

  @override
  void dispose() {
    _autoDismiss?.cancel();
    _controller.dispose();
    super.dispose();
  }

  /// Fold a new status into the animation state.
  ///
  /// Called from build (the Consumer is the only source of change), so it must
  /// not call setState — the frame is already being built. Everything it touches
  /// is either an animation controller or state the same build reads afterwards.
  void _sync(SharedDownloadStatus? status) {
    final previousPhase = _lastPhase;

    if (status == null) {
      if (_shown != null && _controller.status != AnimationStatus.dismissed) {
        _autoDismiss?.cancel();
        _controller.reverse().then((_) {
          if (mounted) setState(() => _shown = null);
        });
      }
      _lastPhase = null;
      return;
    }

    _shown = status;
    _lastPhase = status.phase;

    if (_controller.status == AnimationStatus.dismissed ||
        _controller.status == AnimationStatus.reverse) {
      _controller.forward();
      AppHaptics.light();
    }

    if (status.phase != previousPhase) {
      _autoDismiss?.cancel();
      if (status.phase == SharedDownloadPhase.done) {
        AppHaptics.medium();
      } else if (status.phase == SharedDownloadPhase.failed) {
        AppHaptics.medium();
      }
      // Only terminal states time out. A download in progress stays on screen
      // for as long as it takes — it is the only place its progress is shown.
      final linger = switch (status.phase) {
        SharedDownloadPhase.done => const Duration(seconds: 4),
        SharedDownloadPhase.duplicate => const Duration(seconds: 4),
        SharedDownloadPhase.failed => const Duration(seconds: 6),
        _ => null,
      };
      if (linger != null) {
        _autoDismiss = Timer(linger, () {
          if (mounted) context.read<PlayerProvider>().dismissSharedDownload();
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final status = context.select<PlayerProvider, SharedDownloadStatus?>(
      (p) => p.sharedDownload,
    );
    final hasMiniPlayer =
        context.select<PlayerProvider, bool>((p) => p.hasCurrentSong);

    _sync(status);

    final shown = _shown;
    if (shown == null) return const SizedBox.shrink();

    // The card is mounted in MaterialApp.builder, so its Stack spans the WHOLE
    // screen — including the area the Scaffold reserves for the bottom nav and
    // the area the system reserves for the gesture bar. Neither is subtracted
    // for us, so both have to be added here or the card is drawn behind the nav.
    //
    // kBottomNavigationBarHeight (56) + the nav's own top border is what
    // BottomNavigationBar actually occupies; the hardcoded 62 this used to
    // assume was close enough on a 3-button device and visibly wrong on a
    // gesture-nav one, where viewPadding.bottom adds another ~24-48px that was
    // simply ignored.
    final systemInset = MediaQuery.viewPaddingOf(context).bottom;
    final bottom = kBottomNavigationBarHeight +
        systemInset +
        (hasMiniPlayer ? SharedLinkDownloadCard._miniPlayerHeight : 0) +
        SharedLinkDownloadCard._gap;

    return AnimatedPositioned(
      duration: const Duration(milliseconds: 260),
      curve: Curves.easeOutCubic,
      left: 14,
      right: 14,
      bottom: bottom,
      child: SlideTransition(
        position: _slide,
        child: FadeTransition(
          opacity: _fade,
          child: _ShakeOnFailure(
            phase: shown.phase,
            child: Dismissible(
              key: const ValueKey('shared_link_download_card'),
              direction: DismissDirection.down,
              onDismissed: (_) {
                _autoDismiss?.cancel();
                context.read<PlayerProvider>().dismissSharedDownload();
              },
              child: _CardSurface(status: shown),
            ),
          ),
        ),
      ),
    );
  }
}

/// Nudges the card sideways when a download fails.
///
/// A colour change alone is easy to miss on a card the user may not be looking
/// at; the motion is what pulls the eye to it. Three quick oscillations, damped
/// to nothing, so it reads as "that didn't work" rather than as a glitch.
class _ShakeOnFailure extends StatelessWidget {
  final SharedDownloadPhase phase;
  final Widget child;

  const _ShakeOnFailure({required this.phase, required this.child});

  @override
  Widget build(BuildContext context) {
    if (phase != SharedDownloadPhase.failed) return child;
    return TweenAnimationBuilder<double>(
      key: const ValueKey('shake'),
      tween: Tween<double>(begin: 0, end: 1),
      duration: const Duration(milliseconds: 320),
      builder: (context, t, inner) {
        final damping = 1 - t;
        final dx = math.sin(t * 3 * 2 * math.pi) * 8 * damping;
        return Transform.translate(offset: Offset(dx, 0), child: inner);
      },
      child: child,
    );
  }
}

class _CardSurface extends StatelessWidget {
  final SharedDownloadStatus status;

  const _CardSurface({required this.status});

  Color _accentOf(BuildContext context) => switch (status.phase) {
        SharedDownloadPhase.done => AppColors.success,
        SharedDownloadPhase.failed => AppColors.error,
        _ => Theme.of(context).colorScheme.primary,
      };

  @override
  Widget build(BuildContext context) {
    final accent = _accentOf(context);

    return Material(
      color: Colors.transparent,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(20),
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: 18, sigmaY: 18),
          // Border and glow crossfade with the phase, so success and failure
          // register before a single word has been read.
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 400),
            curve: Curves.easeOut,
            padding: const EdgeInsets.fromLTRB(12, 12, 8, 12),
            decoration: BoxDecoration(
              color: const Color(0xFF12122A).withValues(alpha: 0.82),
              borderRadius: BorderRadius.circular(20),
              border: Border.all(color: accent.withValues(alpha: 0.38)),
              boxShadow: [
                BoxShadow(
                  color: accent.withValues(alpha: 0.20),
                  blurRadius: 26,
                  offset: const Offset(0, 10),
                ),
              ],
            ),
            child: AnimatedSize(
              duration: const Duration(milliseconds: 300),
              curve: Curves.easeOutCubic,
              alignment: Alignment.topCenter,
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  _Artwork(status: status, accent: accent),
                  const SizedBox(width: 12),
                  Expanded(child: _Details(status: status, accent: accent)),
                  const SizedBox(width: 4),
                  _Action(status: status, accent: accent),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Artwork slot: a shimmering placeholder until the video's details resolve,
/// then the real cover fading in over it.
class _Artwork extends StatelessWidget {
  final SharedDownloadStatus status;
  final Color accent;

  const _Artwork({required this.status, required this.accent});

  @override
  Widget build(BuildContext context) {
    const size = 52.0;
    final song = status.song;
    final queued = status.phase == SharedDownloadPhase.waitingForNetwork;

    // A queued share is not "still loading" — it is deliberately parked, and a
    // shimmer would read as activity that isn't happening. A static offline
    // glyph says what the state actually is.
    if (queued && song == null) {
      return SizedBox(
        width: size,
        height: size,
        child: Container(
          decoration: BoxDecoration(
            color: Colors.white.withValues(alpha: 0.08),
            borderRadius: BorderRadius.circular(12),
          ),
          child: Icon(
            Icons.cloud_off_rounded,
            size: 22,
            color: Colors.white.withValues(alpha: 0.6),
          ),
        ),
      );
    }

    return SizedBox(
      width: size,
      height: size,
      child: AnimatedSwitcher(
        duration: const Duration(milliseconds: 320),
        switchInCurve: Curves.easeOut,
        child: song != null
            ? SongAlbumArt(
                key: ValueKey('art_${song.videoId}'),
                song: song,
                width: size,
                height: size,
                borderRadius: 12,
              )
            : Shimmer.fromColors(
                key: const ValueKey('art_skeleton'),
                baseColor: AppColors.shimmerBase,
                highlightColor: AppColors.shimmerHighlight,
                child: Container(
                  decoration: BoxDecoration(
                    color: AppColors.shimmerBase,
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Icon(
                    Icons.link_rounded,
                    size: 22,
                    color: Colors.white.withValues(alpha: 0.5),
                  ),
                ),
              ),
      ),
    );
  }
}

class _Details extends StatelessWidget {
  final SharedDownloadStatus status;
  final Color accent;

  const _Details({required this.status, required this.accent});

  String get _title {
    final song = status.song;
    if (song != null && song.title.isNotEmpty) return song.title;
    return switch (status.phase) {
      SharedDownloadPhase.resolving => 'Reading video details…',
      SharedDownloadPhase.failed => 'Couldn\'t save that link',
      SharedDownloadPhase.waitingForNetwork => 'Saved for when you\'re online',
      _ => 'Shared link',
    };
  }

  String? get _subtitle {
    if (status.message != null && status.message!.isNotEmpty) {
      return status.message;
    }
    final artist = status.song?.artist;
    if (artist != null && artist.isNotEmpty) return artist;
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final subtitle = _subtitle;
    final showBar = status.phase == SharedDownloadPhase.downloading;

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          _title,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(
            color: Colors.white,
            fontSize: 13.5,
            fontWeight: FontWeight.w700,
          ),
        ),
        if (subtitle != null) ...[
          const SizedBox(height: 2),
          Text(
            subtitle,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              color: Colors.white.withValues(alpha: 0.68),
              fontSize: 11.5,
              height: 1.2,
            ),
          ),
        ],
        // The bar is inside the AnimatedSize above, so it grows and collapses
        // with the card rather than snapping the layout on completion.
        AnimatedSize(
          duration: const Duration(milliseconds: 300),
          curve: Curves.easeOutCubic,
          alignment: Alignment.topLeft,
          child: showBar
              ? Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Row(
                    children: [
                      Expanded(
                        child: GradientProgressBar(
                          progress: status.progress,
                          isPaused: false,
                        ),
                      ),
                      const SizedBox(width: 8),
                      SizedBox(
                        width: 34,
                        child: Text(
                          '${(status.progress.clamp(0.0, 1.0) * 100).round()}%',
                          textAlign: TextAlign.right,
                          style: TextStyle(
                            color: Colors.white.withValues(alpha: 0.75),
                            fontSize: 11,
                            fontWeight: FontWeight.w600,
                            fontFeatures: const [FontFeature.tabularFigures()],
                          ),
                        ),
                      ),
                    ],
                  ),
                )
              : const SizedBox(width: double.infinity),
        ),
      ],
    );
  }
}

/// Trailing slot: cancel while running, Play when the song is available, Retry
/// when it failed for a reason worth retrying.
class _Action extends StatelessWidget {
  final SharedDownloadStatus status;
  final Color accent;

  const _Action({required this.status, required this.accent});

  @override
  Widget build(BuildContext context) {
    final provider = context.read<PlayerProvider>();

    Widget child;
    switch (status.phase) {
      case SharedDownloadPhase.resolving:
      case SharedDownloadPhase.downloading:
      case SharedDownloadPhase.waitingForNetwork:
        child = _IconAction(
          key: const ValueKey('cancel'),
          icon: Icons.close_rounded,
          tooltip: 'Cancel download',
          color: Colors.white.withValues(alpha: 0.75),
          onTap: () => provider.cancelSharedDownload(),
        );
      case SharedDownloadPhase.done:
        child = Row(
          key: const ValueKey('done'),
          mainAxisSize: MainAxisSize.min,
          children: [
            _Checkmark(color: accent),
            if (status.song != null)
              _TextAction(
                label: 'Play',
                color: accent,
                onTap: () {
                  provider.dismissSharedDownload();
                  provider.playSong(status.song!);
                },
              ),
          ],
        );
      case SharedDownloadPhase.duplicate:
        child = status.song != null
            ? _TextAction(
                key: const ValueKey('duplicate'),
                label: 'Play',
                color: accent,
                onTap: () {
                  provider.dismissSharedDownload();
                  provider.playSong(status.song!);
                },
              )
            : _IconAction(
                key: const ValueKey('duplicate_dismiss'),
                icon: Icons.close_rounded,
                tooltip: 'Dismiss',
                color: Colors.white.withValues(alpha: 0.75),
                onTap: provider.dismissSharedDownload,
              );
      case SharedDownloadPhase.failed:
        child = status.canRetry
            ? _TextAction(
                key: const ValueKey('retry'),
                label: 'Retry',
                color: accent,
                onTap: () => provider.retrySharedDownload(),
              )
            : _IconAction(
                key: const ValueKey('failed_dismiss'),
                icon: Icons.close_rounded,
                tooltip: 'Dismiss',
                color: Colors.white.withValues(alpha: 0.75),
                onTap: provider.dismissSharedDownload,
              );
    }

    return AnimatedSwitcher(
      duration: const Duration(milliseconds: 220),
      switchInCurve: Curves.easeOut,
      transitionBuilder: (widget, animation) => FadeTransition(
        opacity: animation,
        child: ScaleTransition(
          scale: Tween<double>(begin: 0.9, end: 1.0).animate(animation),
          child: widget,
        ),
      ),
      child: child,
    );
  }
}

/// The tick that lands when a shared song is saved. Overshoots slightly on the
/// way in — the one moment in this flow that deserves to feel like a reward.
class _Checkmark extends StatelessWidget {
  final Color color;

  const _Checkmark({required this.color});

  @override
  Widget build(BuildContext context) {
    return TweenAnimationBuilder<double>(
      tween: Tween<double>(begin: 0, end: 1),
      duration: const Duration(milliseconds: 420),
      curve: Curves.easeOutBack,
      builder: (context, t, child) =>
          Transform.scale(scale: t.clamp(0.0, 1.4), child: child),
      child: Container(
        width: 30,
        height: 30,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: color.withValues(alpha: 0.16),
          border: Border.all(color: color.withValues(alpha: 0.45)),
        ),
        child: Icon(Icons.check_rounded, size: 18, color: color),
      ),
    );
  }
}

class _IconAction extends StatelessWidget {
  final IconData icon;
  final String tooltip;
  final Color color;
  final VoidCallback onTap;

  const _IconAction({
    super.key,
    required this.icon,
    required this.tooltip,
    required this.color,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip,
      child: PremiumTap(
        onTap: onTap,
        haptic: HapticStyle.light,
        child: Padding(
          padding: const EdgeInsets.all(8),
          child: Icon(icon, size: 20, color: color),
        ),
      ),
    );
  }
}

class _TextAction extends StatelessWidget {
  final String label;
  final Color color;
  final VoidCallback onTap;

  const _TextAction({
    super.key,
    required this.label,
    required this.color,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return PremiumTap(
      onTap: onTap,
      haptic: HapticStyle.light,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.14),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: color.withValues(alpha: 0.38)),
        ),
        child: Text(
          label,
          style: TextStyle(
            color: color,
            fontSize: 12.5,
            fontWeight: FontWeight.w700,
          ),
        ),
      ),
    );
  }
}
