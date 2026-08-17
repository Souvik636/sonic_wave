import 'package:flutter/material.dart';

/// Derived shades of the DYNAMIC theme accent. `colorScheme.primary` already
/// follows the accent selected in Settings (via AppTheme.darkTheme), so these
/// give every accent a light/dark variant without static purple constants.
/// Usage: `Theme.of(context).colorScheme.primaryLight`.
extension AccentShades on ColorScheme {
  Color get primaryLight => Color.lerp(primary, Colors.white, 0.35)!;
  Color get primaryDark => Color.lerp(primary, Colors.black, 0.30)!;
}

class AppColors {
  // NOTE: The theme ACCENT is dynamic (SettingsProvider.accentColor feeds
  // colorScheme.primary). Do NOT use the static primary*/gradient constants
  // below in new code — use Theme.of(context).colorScheme.primary /
  // primaryLight / primaryDark or the SettingsProvider getters
  // (accentGradient, glowGradient, playerGradient, tintedBackgroundGradient,
  // downloadGradient). The constants are kept only as legacy fallbacks and
  // are currently unreferenced.

  // Primary palette (LEGACY — see note above)
  static const Color primary = Color(0xFF6C63FF);
  static const Color primaryLight = Color(0xFF9B94FF);
  static const Color primaryDark = Color(0xFF4A42D4);

  // Secondary / Accent
  static const Color secondary = Color(0xFF00C9A7);
  static const Color secondaryLight = Color(0xFF33D4B9);
  static const Color accent = Color(0xFFFF6584);
  static const Color accentLight = Color(0xFFFF8FA3);

  // Background & Surface
  static const Color background = Color(0xFF060612);
  static const Color surface = Color(0xFF0D0D1A);
  static const Color surfaceLight = Color(0xFF161630);
  static const Color surfaceVariant = Color(0xFF1E1E3F);
  static const Color card = Color(0xFF12122A);

  // Text
  static const Color textPrimary = Color(0xFFF0F0FF);
  static const Color textSecondary = Color(0xFFB0B0CC);
  static const Color textTertiary = Color(0xFF6B6B8D);

  // Glass
  static const Color glassFill = Color(0x1AFFFFFF);
  static const Color glassBorder = Color(0x33FFFFFF);
  static const Color glassHighlight = Color(0x0DFFFFFF);

  // Gradients
  static const LinearGradient primaryGradient = LinearGradient(
    colors: [primary, Color(0xFF845EC2)],
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
  );

  static const LinearGradient accentGradient = LinearGradient(
    colors: [accent, Color(0xFFFF9A5C)],
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
  );

  static const LinearGradient backgroundGradient = LinearGradient(
    colors: [background, Color(0xFF0A0A20), surface],
    begin: Alignment.topCenter,
    end: Alignment.bottomCenter,
  );

  static const LinearGradient playerGradient = LinearGradient(
    colors: [Color(0xFF1A0A3E), Color(0xFF0D0D1A)],
    begin: Alignment.topCenter,
    end: Alignment.bottomCenter,
  );

  static const RadialGradient glowGradient = RadialGradient(
    colors: [Color(0x336C63FF), Color(0x116C63FF), Color(0x00060612)],
    radius: 0.8,
  );

  // Download states
  static const Color downloadActive = Color(0xFF6C63FF);
  static const Color downloadPaused = Color(0xFFFFB74D);
  static const Color downloadQueued = Color(0xFF78909C);
  static const Color downloadFailed = Color(0xFFFF5252);
  static const Color downloadRetrying = Color(0xFFFF9800);
  static const Color downloadSuccess = Color(0xFF00E676);

  static const LinearGradient downloadGradient = LinearGradient(
    colors: [Color(0xFF6C63FF), Color(0xFF00C9A7)],
    begin: Alignment.centerLeft,
    end: Alignment.centerRight,
  );

  static const LinearGradient downloadPausedGradient = LinearGradient(
    colors: [Color(0xFFFFB74D), Color(0xFFFFA726)],
    begin: Alignment.centerLeft,
    end: Alignment.centerRight,
  );

  // Misc
  static const Color shimmerBase = Color(0xFF1A1A35);
  static const Color shimmerHighlight = Color(0xFF2A2A4A);
  static const Color divider = Color(0xFF1E1E3F);
  static const Color error = Color(0xFFFF4D6A);
  static const Color success = Color(0xFF00E676);
}
