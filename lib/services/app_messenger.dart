import 'package:flutter/material.dart';

import '../theme/app_colors.dart';

/// Shows a snackbar from code that has no [BuildContext].
///
/// Needed because a shared YouTube link is handled by PlayerProvider, which is
/// driven by a platform channel rather than by a widget. Without this the user
/// taps "share to SonicWave" and the app looks like it did nothing until the
/// download eventually surfaces in the Downloads list.
class AppMessenger {
  AppMessenger._();

  /// Wired into `MaterialApp.scaffoldMessengerKey` in main.dart.
  static final GlobalKey<ScaffoldMessengerState> key =
      GlobalKey<ScaffoldMessengerState>();

  static void show(
    String message, {
    bool isError = false,
    Duration duration = const Duration(seconds: 3),
  }) {
    final messenger = key.currentState;
    if (messenger == null) {
      // No UI attached yet (very early startup, or a unit test) — the message
      // is informational, so dropping it must never break the caller.
      debugPrint('[AppMessenger] (no UI) $message');
      return;
    }
    messenger.hideCurrentSnackBar();
    messenger.showSnackBar(
      SnackBar(
        content: Text(message),
        duration: duration,
        behavior: SnackBarBehavior.floating,
        backgroundColor: isError
            ? AppColors.error.withValues(alpha: 0.95)
            : AppColors.success.withValues(alpha: 0.95),
      ),
    );
  }
}
