import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:provider/provider.dart';
import '../providers/settings_provider.dart';
import '../providers/player_provider.dart';
import '../theme/app_colors.dart';
import '../widgets/glassmorphic_card.dart';
import '../widgets/premium_interaction.dart';
import '../services/storage_location_service.dart';
import '../services/updater/github_release_client.dart';
import '../widgets/updater/update_dialog.dart';
import '../widgets/app_toast.dart';
import '../widgets/storage_management_card.dart';
import '../constants/app_version.dart';
import 'sound_studio_screen.dart';

/// Premium settings screen: staggered card entrances, accent-tinted background,
/// a rich theme-accent gallery, player-style picker and a merged visualizer
/// card. Only options that are actually wired to functionality are shown.
class SettingsScreen extends StatelessWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final settings = context.watch<SettingsProvider>();
    return Scaffold(
      extendBodyBehindAppBar: true,
      appBar: AppBar(
        title: Text(
          'Settings',
          style: GoogleFonts.outfit(fontWeight: FontWeight.w700),
        ),
        leading: IconButton(
          icon: const Icon(Icons.arrow_back_ios_new_rounded, size: 20),
          onPressed: () => Navigator.pop(context),
        ),
      ),
      body: Stack(
        children: [
          // Accent-tinted background that shifts with the chosen theme
          AnimatedContainer(
            duration: const Duration(milliseconds: 600),
            curve: Curves.easeOut,
            decoration: BoxDecoration(
              gradient: settings.tintedBackgroundGradient,
            ),
          ),
          // Soft accent glow behind the top of the list
          Positioned(
            top: -120,
            right: -80,
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 600),
              width: 300,
              height: 300,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                gradient: RadialGradient(
                  colors: [
                    settings.accentColor.withValues(alpha: 0.16),
                    Colors.transparent,
                  ],
                ),
              ),
            ),
          ),

          SafeArea(
            child: ListView(
              physics: const BouncingScrollPhysics(),
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
              children: [
                const SizedBox(height: 10),

                // ── Appearance ────────────────────────────────────────
                _reveal(0, _sectionHeader(context, Icons.auto_awesome_rounded, 'Appearance')),
                const SizedBox(height: 12),
                _reveal(1, _buildMaterialYouCard(context)),
                const SizedBox(height: 12),
                _reveal(2, _buildThemeSelector(context)),
                const SizedBox(height: 12),
                _reveal(3, _buildPlayerStyleCard(context)),
                const SizedBox(height: 12),
                _reveal(4, _buildAmbientModeCard(context)),

                const SizedBox(height: 24),

                // ── Music Visualizer ──────────────────────────────────
                _reveal(5, _sectionHeader(context, Icons.graphic_eq_rounded, 'Music Visualizer')),
                const SizedBox(height: 12),
                _reveal(6, _buildVisualizerCard(context)),

                const SizedBox(height: 24),

                // ── Audio ─────────────────────────────────────────────
                _reveal(7, _sectionHeader(context, Icons.tune_rounded, 'Audio')),
                const SizedBox(height: 12),
                _reveal(8, _buildVolumeCard(context)),
                const SizedBox(height: 12),
                _reveal(9, _buildCrossfadeCard(context)),
                const SizedBox(height: 12),
                _reveal(10, _buildSoundEnhancerCard(context)),
                const SizedBox(height: 12),
                _reveal(11, _buildAudioQualityCard(context)),
                const SizedBox(height: 12),
                _reveal(12, _buildCustomEqualizerCard(context)),
                const SizedBox(height: 12),
                _reveal(13, _buildOfflineModeCard(context)),

                const SizedBox(height: 24),

                // ── Storage & Maintenance ─────────────────────────────
                _reveal(14, _sectionHeader(context, Icons.storage_rounded, 'Storage & Maintenance')),
                const SizedBox(height: 12),
                _reveal(15, _buildStorageLocationCard(context)),
                const SizedBox(height: 12),
                _reveal(16, _buildStorageCard(context)),

                const SizedBox(height: 24),

                // ── Application Updates ───────────────────────────────
                _reveal(17, _sectionHeader(context, Icons.system_update_rounded, 'Application Updates')),
                const SizedBox(height: 12),
                _reveal(18, _buildAndroidAutoUpdaterCard(context)),

                const SizedBox(height: 40),
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// Cascading entrance for each settings row.
  Widget _reveal(int index, Widget child) =>
      StaggeredReveal(index: index, child: child);

  Widget _sectionHeader(BuildContext context, IconData icon, String title) {
    final primary = Theme.of(context).colorScheme.primary;
    return Padding(
      padding: const EdgeInsets.only(left: 4),
      child: Row(
        children: [
          Container(
            width: 30,
            height: 30,
            decoration: BoxDecoration(
              gradient: LinearGradient(
                colors: [
                  primary.withValues(alpha: 0.30),
                  primary.withValues(alpha: 0.10),
                ],
              ),
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: primary.withValues(alpha: 0.35)),
            ),
            child: Icon(icon, color: primary, size: 16),
          ),
          const SizedBox(width: 10),
          Text(
            title.toUpperCase(),
            style: GoogleFonts.outfit(
              fontSize: 13,
              fontWeight: FontWeight.w800,
              letterSpacing: 1.6,
              color: Colors.white.withValues(alpha: 0.9),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Container(
              height: 1,
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  colors: [
                    primary.withValues(alpha: 0.35),
                    Colors.transparent,
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  // ══════════════════════════════════════════════════════════════════════
  // APPEARANCE
  // ══════════════════════════════════════════════════════════════════════

  Widget _buildMaterialYouCard(BuildContext context) {
    return Consumer<SettingsProvider>(
      builder: (context, settings, _) {
        return GlassmorphicCard(
          padding: const EdgeInsets.all(20),
          child: Row(
            children: [
              Container(
                width: 44,
                height: 44,
                decoration: BoxDecoration(
                  gradient: const LinearGradient(
                    colors: [Color(0xFF6C63FF), Color(0xFF00C9A7), Color(0xFFFF6584)],
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                  ),
                  borderRadius: BorderRadius.circular(14),
                  boxShadow: [
                    BoxShadow(
                      color: const Color(0xFF6C63FF).withValues(alpha: 0.35),
                      blurRadius: 12,
                    ),
                  ],
                ),
                child: const Icon(Icons.palette_rounded, color: Colors.white, size: 22),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Material You',
                      style: Theme.of(context).textTheme.titleLarge?.copyWith(fontSize: 15),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      'Match colors to your wallpaper (Android 12+)',
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ],
                ),
              ),
              Switch(
                value: settings.useMaterialYou,
                activeThumbColor: Theme.of(context).colorScheme.primary,
                onChanged: (val) {
                  AppHaptics.selection();
                  settings.setUseMaterialYou(val);
                },
              ),
            ],
          ),
        );
      },
    );
  }

  /// Accent palette: name + gradient pair for each swatch orb.
  static const List<({ThemeAccent accent, String name, Color a, Color b})> _accents = [
    (accent: ThemeAccent.purple, name: 'Nebula', a: Color(0xFF7C5CFF), b: Color(0xFFB388FF)),
    (accent: ThemeAccent.cyan, name: 'Aurora', a: Color(0xFF00E5C3), b: Color(0xFF00B0FF)),
    (accent: ThemeAccent.pink, name: 'Blush', a: Color(0xFFFF5C8A), b: Color(0xFFFF9E80)),
    (accent: ThemeAccent.orange, name: 'Sunset', a: Color(0xFFFF8A50), b: Color(0xFFFFC400)),
    (accent: ThemeAccent.emerald, name: 'Emerald', a: Color(0xFF00E676), b: Color(0xFF69F0AE)),
    (accent: ThemeAccent.amber, name: 'Gold', a: Color(0xFFFFC400), b: Color(0xFFFF8A50)),
    (accent: ThemeAccent.sapphire, name: 'Ocean', a: Color(0xFF448AFF), b: Color(0xFF18FFFF)),
    (accent: ThemeAccent.sakura, name: 'Sakura', a: Color(0xFFFF80AB), b: Color(0xFFEA80FC)),
    (accent: ThemeAccent.lava, name: 'Inferno', a: Color(0xFFFF4B2B), b: Color(0xFFFFAB40)),
  ];

  Widget _buildThemeSelector(BuildContext context) {
    return Consumer<SettingsProvider>(
      builder: (context, settings, _) {
        return GlassmorphicCard(
          padding: const EdgeInsets.all(20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Theme Accent',
                          style: Theme.of(context).textTheme.titleLarge?.copyWith(fontSize: 15),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          settings.useMaterialYou
                              ? 'Disabled while Material You is on'
                              : 'The whole app — player, glow, gradients — follows this color',
                          style: Theme.of(context).textTheme.bodySmall,
                        ),
                      ],
                    ),
                  ),
                  // Live accent preview dot
                  AnimatedContainer(
                    duration: const Duration(milliseconds: 400),
                    width: 20,
                    height: 20,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      gradient: settings.accentGradient,
                      boxShadow: [
                        BoxShadow(
                          color: settings.accentColor.withValues(alpha: 0.6),
                          blurRadius: 12,
                          spreadRadius: 1,
                        ),
                      ],
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 18),
              AnimatedOpacity(
                duration: const Duration(milliseconds: 250),
                opacity: settings.useMaterialYou ? 0.35 : 1.0,
                child: IgnorePointer(
                  ignoring: settings.useMaterialYou,
                  child: Wrap(
                    spacing: 12,
                    runSpacing: 14,
                    alignment: WrapAlignment.start,
                    children: _accents.map((entry) {
                      final isSelected = settings.themeAccent == entry.accent;
                      return PremiumTap(
                        onTap: () {
                          AppHaptics.light();
                          settings.setThemeAccent(entry.accent);
                        },
                        pressedScale: 0.85,
                        child: SizedBox(
                          width: 62,
                          child: Column(
                            children: [
                              AnimatedScale(
                                duration: const Duration(milliseconds: 300),
                                curve: Curves.easeOutBack,
                                scale: isSelected ? 1.12 : 1.0,
                                child: AnimatedContainer(
                                  duration: const Duration(milliseconds: 300),
                                  width: 46,
                                  height: 46,
                                  decoration: BoxDecoration(
                                    shape: BoxShape.circle,
                                    gradient: LinearGradient(
                                      colors: [entry.a, entry.b],
                                      begin: Alignment.topLeft,
                                      end: Alignment.bottomRight,
                                    ),
                                    border: Border.all(
                                      color: isSelected
                                          ? Colors.white
                                          : Colors.white.withValues(alpha: 0.12),
                                      width: isSelected ? 2.5 : 1,
                                    ),
                                    boxShadow: [
                                      BoxShadow(
                                        color: entry.a.withValues(
                                            alpha: isSelected ? 0.65 : 0.18),
                                        blurRadius: isSelected ? 18 : 8,
                                        spreadRadius: isSelected ? 2 : 0,
                                      ),
                                    ],
                                  ),
                                  child: AnimatedSwitcher(
                                    duration: const Duration(milliseconds: 200),
                                    child: isSelected
                                        ? const Icon(Icons.check_rounded,
                                            key: ValueKey('check'),
                                            color: Colors.white, size: 22)
                                        : const SizedBox.shrink(
                                            key: ValueKey('empty')),
                                  ),
                                ),
                              ),
                              const SizedBox(height: 7),
                              AnimatedDefaultTextStyle(
                                duration: const Duration(milliseconds: 250),
                                style: GoogleFonts.inter(
                                  fontSize: 10,
                                  fontWeight: isSelected
                                      ? FontWeight.w700
                                      : FontWeight.w400,
                                  color: isSelected
                                      ? Colors.white
                                      : AppColors.textTertiary,
                                ),
                                child: Text(
                                  entry.name,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                            ],
                          ),
                        ),
                      );
                    }).toList(),
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _buildPlayerStyleCard(BuildContext context) {
    return Consumer<SettingsProvider>(
      builder: (context, settings, _) {
        final primary = Theme.of(context).colorScheme.primary;
        return GlassmorphicCard(
          padding: const EdgeInsets.all(20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Player Screen Style',
                style: Theme.of(context).textTheme.titleLarge?.copyWith(fontSize: 15),
              ),
              const SizedBox(height: 4),
              Text(
                'Which full-screen player opens from the mini player',
                style: Theme.of(context).textTheme.bodySmall,
              ),
              const SizedBox(height: 16),
              Row(
                children: [
                  Expanded(
                    child: _playerStyleOption(
                      context: context,
                      title: 'Classic',
                      subtitle: 'Vinyl disc & tonearm',
                      icon: Icons.album_rounded,
                      gradient: LinearGradient(
                        colors: [
                          const Color(0xFF1A1A2E),
                          primary.withValues(alpha: 0.35),
                        ],
                        begin: Alignment.topLeft,
                        end: Alignment.bottomRight,
                      ),
                      isSelected: settings.playerStyle == 'classic',
                      onTap: () {
                        AppHaptics.selection();
                        settings.setPlayerStyle('classic');
                      },
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: _playerStyleOption(
                      context: context,
                      title: 'Aurora',
                      subtitle: 'Glassmorphic & reactive',
                      icon: Icons.flare_rounded,
                      gradient: LinearGradient(
                        colors: [
                          const Color(0xFF050510),
                          primary.withValues(alpha: 0.5),
                          const Color(0xFF00C9A7).withValues(alpha: 0.3),
                        ],
                        begin: Alignment.bottomLeft,
                        end: Alignment.topRight,
                      ),
                      isSelected: settings.playerStyle == 'aurora',
                      onTap: () {
                        AppHaptics.selection();
                        settings.setPlayerStyle('aurora');
                      },
                    ),
                  ),
                ],
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _playerStyleOption({
    required BuildContext context,
    required String title,
    required String subtitle,
    required IconData icon,
    required Gradient gradient,
    required bool isSelected,
    required VoidCallback onTap,
  }) {
    final primary = Theme.of(context).colorScheme.primary;
    return PremiumTap(
      onTap: onTap,
      pressedScale: 0.94,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 300),
        curve: Curves.easeOut,
        height: 108,
        decoration: BoxDecoration(
          gradient: gradient,
          borderRadius: BorderRadius.circular(18),
          border: Border.all(
            color: isSelected ? primary : Colors.white.withValues(alpha: 0.08),
            width: isSelected ? 2 : 1,
          ),
          boxShadow: isSelected
              ? [
                  BoxShadow(
                    color: primary.withValues(alpha: 0.35),
                    blurRadius: 16,
                    spreadRadius: 1,
                  ),
                ]
              : null,
        ),
        child: Stack(
          children: [
            if (isSelected)
              Positioned(
                top: 8,
                right: 8,
                child: Container(
                  padding: const EdgeInsets.all(3),
                  decoration: BoxDecoration(
                    color: primary,
                    shape: BoxShape.circle,
                  ),
                  child: const Icon(Icons.check_rounded,
                      color: Colors.white, size: 12),
                ),
              ),
            Padding(
              padding: const EdgeInsets.all(14),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  Icon(icon,
                      color: isSelected ? Colors.white : Colors.white60,
                      size: 26),
                  const SizedBox(height: 8),
                  Text(
                    title,
                    style: GoogleFonts.outfit(
                      color: Colors.white,
                      fontSize: 14,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  Text(
                    subtitle,
                    style: GoogleFonts.inter(
                      color: Colors.white.withValues(alpha: 0.55),
                      fontSize: 10,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildAmbientModeCard(BuildContext context) {
    return Consumer<SettingsProvider>(
      builder: (context, settings, _) {
        return GlassmorphicCard(
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Immersive Ambient Mode',
                      style: Theme.of(context).textTheme.titleLarge?.copyWith(fontSize: 15),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      'Slowly pulsating, animated glow matching the artwork',
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ],
                ),
              ),
              Switch(
                value: settings.enableAmbientMode,
                activeTrackColor: Theme.of(context).colorScheme.primary,
                onChanged: (v) {
                  AppHaptics.selection();
                  settings.setAmbientMode(v);
                },
              ),
            ],
          ),
        );
      },
    );
  }

  // ══════════════════════════════════════════════════════════════════════
  // MUSIC VISUALIZER — toggle + style + speed in one card
  // ══════════════════════════════════════════════════════════════════════

  Widget _buildVisualizerCard(BuildContext context) {
    return Consumer<SettingsProvider>(
      builder: (context, settings, _) {
        final primary = Theme.of(context).colorScheme.primary;
        return GlassmorphicCard(
          padding: const EdgeInsets.all(20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Music Visualizer',
                          style: Theme.of(context).textTheme.titleLarge?.copyWith(fontSize: 15),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          'Audio-reactive animations in the classic player',
                          style: Theme.of(context).textTheme.bodySmall,
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 8),
                  Switch(
                    value: settings.showVisualizer,
                    onChanged: (v) {
                      AppHaptics.selection();
                      settings.setShowVisualizer(v);
                    },
                    activeThumbColor: primary,
                  ),
                ],
              ),
              // Animated expand/collapse of the style + speed controls
              AnimatedSize(
                duration: const Duration(milliseconds: 350),
                curve: Curves.easeOutCubic,
                alignment: Alignment.topCenter,
                child: !settings.showVisualizer
                    ? const SizedBox(width: double.infinity)
                    : Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Divider(height: 24, color: AppColors.divider),
                          Row(
                            children: [
                              Expanded(
                                child: _visualizerStyleOption(
                                  context, 'Classic Bars', Icons.bar_chart_rounded,
                                  'bars', settings,
                                ),
                              ),
                              const SizedBox(width: 8),
                              Expanded(
                                child: _visualizerStyleOption(
                                  context, 'Circular Wave', Icons.donut_large_rounded,
                                  'circle', settings,
                                ),
                              ),
                              const SizedBox(width: 8),
                              Expanded(
                                child: _visualizerStyleOption(
                                  context, 'Fluid Wave', Icons.waves_rounded,
                                  'waveform', settings,
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 16),
                          Row(
                            mainAxisAlignment: MainAxisAlignment.spaceBetween,
                            children: [
                              Text(
                                'Animation speed',
                                style: Theme.of(context).textTheme.bodySmall,
                              ),
                              Text(
                                '${(settings.visualizerSpeed * 100).toInt()}%',
                                style: TextStyle(
                                  color: primary,
                                  fontWeight: FontWeight.bold,
                                  fontSize: 12,
                                ),
                              ),
                            ],
                          ),
                          Slider(
                            value: settings.visualizerSpeed,
                            min: 0.5,
                            max: 2.0,
                            divisions: 6,
                            onChanged: settings.setVisualizerSpeed,
                          ),
                        ],
                      ),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _visualizerStyleOption(
    BuildContext context,
    String title,
    IconData icon,
    String value,
    SettingsProvider settings,
  ) {
    final isSelected = settings.visualizerTheme == value;
    final primary = Theme.of(context).colorScheme.primary;
    return PremiumTap(
      onTap: () {
        AppHaptics.selection();
        settings.setVisualizerTheme(value);
      },
      pressedScale: 0.93,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 250),
        padding: const EdgeInsets.symmetric(vertical: 12),
        decoration: BoxDecoration(
          color: isSelected
              ? primary.withValues(alpha: 0.15)
              : AppColors.surfaceVariant.withValues(alpha: 0.5),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: isSelected ? primary : Colors.transparent,
            width: 1.2,
          ),
          boxShadow: isSelected
              ? [BoxShadow(color: primary.withValues(alpha: 0.25), blurRadius: 10)]
              : null,
        ),
        child: Column(
          children: [
            Icon(icon,
                size: 18, color: isSelected ? primary : AppColors.textTertiary),
            const SizedBox(height: 6),
            Text(
              title,
              textAlign: TextAlign.center,
              style: TextStyle(
                color: isSelected ? Colors.white : AppColors.textSecondary,
                fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
                fontSize: 10,
              ),
            ),
          ],
        ),
      ),
    );
  }

  // ══════════════════════════════════════════════════════════════════════
  // AUDIO
  // ══════════════════════════════════════════════════════════════════════

  Widget _buildVolumeCard(BuildContext context) {
    return Consumer<SettingsProvider>(
      builder: (context, settings, _) {
        return GlassmorphicCard(
          padding: const EdgeInsets.all(20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(
                    'App Playback Volume',
                    style: Theme.of(context).textTheme.titleLarge?.copyWith(fontSize: 15),
                  ),
                  Text(
                    '${(settings.volume * 100).toInt()}%',
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.primary,
                      fontWeight: FontWeight.bold,
                      fontSize: 14,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  const Icon(Icons.volume_down_rounded, color: AppColors.textTertiary, size: 20),
                  Expanded(
                    child: Slider(
                      value: settings.volume,
                      min: 0.0,
                      max: 1.0,
                      divisions: 20,
                      onChanged: settings.setVolume,
                    ),
                  ),
                  const Icon(Icons.volume_up_rounded, color: AppColors.textTertiary, size: 20),
                ],
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _buildCrossfadeCard(BuildContext context) {
    return Consumer<SettingsProvider>(
      builder: (context, settings, _) {
        final primary = Theme.of(context).colorScheme.primary;
        final seconds = settings.crossfadeSeconds;
        return GlassmorphicCard(
          padding: const EdgeInsets.all(20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Crossfade',
                          style: Theme.of(context).textTheme.titleLarge?.copyWith(fontSize: 15),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          'Smooth fade between tracks on automatic transitions',
                          style: Theme.of(context).textTheme.bodySmall,
                        ),
                      ],
                    ),
                  ),
                  AnimatedSwitcher(
                    duration: const Duration(milliseconds: 250),
                    child: Text(
                      seconds == 0 ? 'Off' : '${seconds}s',
                      key: ValueKey(seconds),
                      style: TextStyle(
                        color: seconds == 0 ? AppColors.textTertiary : primary,
                        fontWeight: FontWeight.bold,
                        fontSize: 14,
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Slider(
                value: seconds.toDouble(),
                min: 0,
                max: 12,
                divisions: 12,
                label: seconds == 0 ? 'Off' : '${seconds}s',
                onChanged: (v) => settings.setCrossfadeSeconds(v.round()),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _buildSoundEnhancerCard(BuildContext context) {
    return Consumer<SettingsProvider>(
      builder: (context, settings, _) {
        return GlassmorphicCard(
          padding: const EdgeInsets.all(20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Acoustic Sound Enhancer',
                style: Theme.of(context).textTheme.titleLarge?.copyWith(fontSize: 15),
              ),
              const SizedBox(height: 4),
              Text(
                'Select presets to enhance sound frequencies dynamically',
                style: Theme.of(context).textTheme.bodySmall,
              ),
              const SizedBox(height: 16),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: SoundEnhancer.values.map((enhancer) {
                  final isSelected = settings.soundEnhancer == enhancer;
                  String label;
                  switch (enhancer) {
                    case SoundEnhancer.none:
                      label = 'Off';
                      break;
                    case SoundEnhancer.bassBoost:
                      label = 'Bass Boost';
                      break;
                    case SoundEnhancer.trebleBoost:
                      label = 'Treble Boost';
                      break;
                    case SoundEnhancer.vocal:
                      label = 'Vocal';
                      break;
                    case SoundEnhancer.ambient3d:
                      label = '3D Surround';
                      break;
                  }

                  return ChoiceChip(
                    label: Text(label),
                    selected: isSelected,
                    onSelected: (selected) {
                      if (selected) {
                        AppHaptics.selection();
                        settings.setSoundEnhancer(enhancer);
                      }
                    },
                    selectedColor: Theme.of(context).colorScheme.primary.withValues(alpha: 0.2),
                    backgroundColor: AppColors.surfaceVariant.withValues(alpha: 0.5),
                    labelStyle: TextStyle(
                      color: isSelected ? Colors.white : AppColors.textSecondary,
                      fontWeight: isSelected ? FontWeight.w600 : FontWeight.w400,
                      fontSize: 12,
                    ),
                    side: BorderSide(
                      color: isSelected ? Theme.of(context).colorScheme.primary : Colors.transparent,
                      width: 1,
                    ),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(16),
                    ),
                  );
                }).toList(),
              ),
              const SizedBox(height: 16),
              SizedBox(
                width: double.infinity,
                child: ElevatedButton.icon(
                  onPressed: () {
                    Navigator.push(
                      context,
                      MaterialPageRoute(builder: (_) => const SoundStudioScreen()),
                    );
                  },
                  icon: const Icon(Icons.tune_rounded, size: 18),
                  label: const Text('Open Sound Enhancer', style: TextStyle(fontWeight: FontWeight.bold)),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Theme.of(context).colorScheme.primary,
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(vertical: 12),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _buildAudioQualityCard(BuildContext context) {
    return Consumer<SettingsProvider>(
      builder: (context, settings, _) {
        return GlassmorphicCard(
          padding: const EdgeInsets.all(20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Streaming Audio Quality',
                style: Theme.of(context).textTheme.titleLarge?.copyWith(fontSize: 15),
              ),
              const SizedBox(height: 4),
              Text(
                'Higher bitrates use more data but provide clearer sound',
                style: Theme.of(context).textTheme.bodySmall,
              ),
              const SizedBox(height: 16),
              Row(
                children: AudioQuality.values.map((quality) {
                  final isSelected = settings.audioQuality == quality;
                  String label;
                  String details;
                  switch (quality) {
                    case AudioQuality.high:
                      label = 'High';
                      details = 'Best Quality';
                      break;
                    case AudioQuality.medium:
                      label = 'Medium';
                      details = 'Balanced';
                      break;
                    case AudioQuality.low:
                      label = 'Low';
                      details = 'Data Saver';
                      break;
                  }

                  return Expanded(
                    child: PremiumTap(
                      onTap: () {
                        AppHaptics.selection();
                        settings.setAudioQuality(quality);
                      },
                      pressedScale: 0.94,
                      child: AnimatedContainer(
                        duration: const Duration(milliseconds: 250),
                        margin: const EdgeInsets.symmetric(horizontal: 4),
                        padding: const EdgeInsets.symmetric(vertical: 12),
                        decoration: BoxDecoration(
                          color: isSelected
                              ? Theme.of(context).colorScheme.primary.withValues(alpha: 0.15)
                              : AppColors.surfaceVariant.withValues(alpha: 0.5),
                          borderRadius: BorderRadius.circular(12),
                          border: Border.all(
                            color: isSelected
                                ? Theme.of(context).colorScheme.primary
                                : Colors.transparent,
                            width: 1.5,
                          ),
                        ),
                        child: Column(
                          children: [
                            Text(
                              label,
                              style: TextStyle(
                                fontSize: 13,
                                fontWeight: FontWeight.w700,
                                color: isSelected ? Colors.white : AppColors.textSecondary,
                              ),
                            ),
                            const SizedBox(height: 4),
                            Text(
                              details,
                              style: TextStyle(
                                fontSize: 10,
                                color: isSelected
                                    ? Theme.of(context).colorScheme.primary
                                    : AppColors.textTertiary,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  );
                }).toList(),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _buildCustomEqualizerCard(BuildContext context) {
    return Consumer<SettingsProvider>(
      builder: (context, settings, _) {
        return GlassmorphicCard(
          padding: const EdgeInsets.all(20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Manual Custom Equalizer',
                        style: Theme.of(context).textTheme.titleLarge?.copyWith(fontSize: 15),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        'Manually adjust acoustic frequency bands',
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    ],
                  ),
                  Switch(
                    value: settings.useCustomEqualizer,
                    onChanged: (v) {
                      AppHaptics.selection();
                      settings.setUseCustomEqualizer(v);
                    },
                    activeThumbColor: Theme.of(context).colorScheme.primary,
                  ),
                ],
              ),
              AnimatedSize(
                duration: const Duration(milliseconds: 350),
                curve: Curves.easeOutCubic,
                alignment: Alignment.topCenter,
                child: !settings.useCustomEqualizer
                    ? const SizedBox(width: double.infinity)
                    : Column(
                        children: [
                          const Divider(height: 24, color: AppColors.divider),
                          const SizedBox(height: 8),
                          Row(
                            mainAxisAlignment: MainAxisAlignment.spaceBetween,
                            children: List.generate(5, (index) {
                              final bandLabels = ['60Hz', '230Hz', '910Hz', '4kHz', '14kHz'];
                              final gain = settings.customEqualizerGains[index];
                              return Expanded(
                                child: Column(
                                  children: [
                                    Text(
                                      '${gain > 0 ? '+' : ''}${gain.toStringAsFixed(0)}dB',
                                      style: TextStyle(
                                        color: Theme.of(context).colorScheme.primary,
                                        fontSize: 10,
                                        fontWeight: FontWeight.bold,
                                      ),
                                    ),
                                    SizedBox(
                                      height: 120,
                                      child: RotatedBox(
                                        quarterTurns: 3,
                                        child: SliderTheme(
                                          data: SliderTheme.of(context).copyWith(
                                            trackHeight: 2,
                                            thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 6),
                                            overlayShape: const RoundSliderOverlayShape(overlayRadius: 12),
                                          ),
                                          child: Slider(
                                            value: gain,
                                            min: -12.0,
                                            max: 12.0,
                                            onChanged: (newVal) {
                                              final newGains = List<double>.from(settings.customEqualizerGains);
                                              newGains[index] = newVal;
                                              settings.setCustomEqualizerGains(newGains);
                                            },
                                          ),
                                        ),
                                      ),
                                    ),
                                    const SizedBox(height: 4),
                                    Text(
                                      bandLabels[index],
                                      style: const TextStyle(color: AppColors.textTertiary, fontSize: 8),
                                    ),
                                  ],
                                ),
                              );
                            }),
                          ),
                        ],
                      ),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _buildOfflineModeCard(BuildContext context) {
    return Consumer<SettingsProvider>(
      builder: (context, settings, _) {
        return GlassmorphicCard(
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Offline Mode Only',
                    style: Theme.of(context).textTheme.titleLarge?.copyWith(fontSize: 15),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    'Only display and search downloaded tracks',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ],
              ),
              Switch(
                value: settings.offlineModeOnly,
                onChanged: (v) {
                  AppHaptics.selection();
                  settings.setOfflineModeOnly(v);
                },
                activeThumbColor: Theme.of(context).colorScheme.primary,
              ),
            ],
          ),
        );
      },
    );
  }

  // ══════════════════════════════════════════════════════════════════════
  // STORAGE & MAINTENANCE
  // ══════════════════════════════════════════════════════════════════════

  Widget _buildStorageCard(BuildContext context) {
    return const StorageManagementCard();
  }

  Widget _buildStorageLocationCard(BuildContext context) {
    return const _StorageLocationCard();
  }


  Widget _buildAndroidAutoUpdaterCard(BuildContext context) {
    final primary = Theme.of(context).colorScheme.primary;
    final appVersion = AppVersion.current;

    return GlassmorphicCard(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    color: primary.withValues(alpha: 0.15),
                    shape: BoxShape.circle,
                  ),
                  child: Icon(Icons.android_rounded, color: primary, size: 22),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Android 64-Bit System Updates',
                        style: Theme.of(context).textTheme.titleMedium?.copyWith(
                              color: Colors.white,
                              fontWeight: FontWeight.bold,
                            ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        'SonicWave v$appVersion (Android arm64-v8a Release)',
                        style: const TextStyle(color: AppColors.textTertiary, fontSize: 11),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 14),
            SizedBox(
              width: double.infinity,
              child: ElevatedButton.icon(
                onPressed: () async {
                  AppToast.show(context, 'Checking GitHub for latest 64-bit APK release...', type: ToastType.info);
                  final client = GitHubReleaseClient(currentVersion: appVersion);
                  try {
                    final release = await client.checkForUpdate();
                    if (!context.mounted) return;

                    if (release != null && release.targetAsset != null) {
                      await UpdateDialog.show(
                        context,
                        updateClient: client,
                        release: release,
                      );
                    } else {
                      AppToast.show(context, 'You are running the latest 64-bit Android release!', type: ToastType.success);
                    }
                  } on GitHubRateLimitException {
                    if (!context.mounted) return;
                    AppToast.show(context, 'GitHub rate limit hit. Try again in a minute.', type: ToastType.warning);
                  } catch (e) {
                    if (!context.mounted) return;
                    final msg = e.toString().contains('SocketException')
                        ? 'No internet connection. Please check your network.'
                        : 'Could not check for updates. Please try again later.';
                    AppToast.show(context, msg, type: ToastType.warning);
                  }
                },
                style: ElevatedButton.styleFrom(
                  backgroundColor: primary.withValues(alpha: 0.20),
                  foregroundColor: Colors.white,
                  side: BorderSide(color: primary.withValues(alpha: 0.4)),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                  padding: const EdgeInsets.symmetric(vertical: 12),
                  elevation: 0,
                ),
                icon: const Icon(Icons.cloud_download_rounded, size: 18),
                label: const Text(
                  'Check for Updates',
                  style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ─── Storage Location Card ───────────────────────────────────────────────────

/// Stateful so it can hold a migration lock (H-2) and cache the path Future
/// per storage type (M-2 — prevents "Loading…" flicker on every unrelated
/// SettingsProvider.notifyListeners() call such as a volume-slider move).
class _StorageLocationCard extends StatefulWidget {
  const _StorageLocationCard();
  @override
  State<_StorageLocationCard> createState() => _StorageLocationCardState();
}

class _StorageLocationCardState extends State<_StorageLocationCard> {
  bool _isMigrating = false;
  StorageType? _cachedType;
  Future<String>? _pathFuture;

  /// Returns the cached path future, refreshing only when the type changed.
  Future<String> _pathFor(SettingsProvider settings) {
    if (_cachedType != settings.storageType) {
      _cachedType = settings.storageType;
      _pathFuture = settings.getStoragePathDisplay();
    }
    return _pathFuture!;
  }

  static const _labels = {
    StorageType.appInternal: 'App Internal',
    StorageType.deviceInternal: 'Device Storage',
    StorageType.sdCard: 'SD Card',
  };
  static const _icons = {
    StorageType.appInternal: Icons.phone_android_rounded,
    StorageType.deviceInternal: Icons.folder_rounded,
    StorageType.sdCard: Icons.sd_card_rounded,
  };
  static const _descriptions = {
    StorageType.appInternal: 'Files hidden in app data (default)',
    StorageType.deviceInternal: 'Visible in /sonicWave/ folder',
    StorageType.sdCard: 'Save to external SD card',
  };

  @override
  Widget build(BuildContext context) {
    return Consumer<SettingsProvider>(
      builder: (context, settings, _) {
        final currentType = settings.storageType;
        return GlassmorphicCard(
          padding: const EdgeInsets.all(20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(Icons.storage_rounded,
                      color: Theme.of(context).colorScheme.primary, size: 22),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('Storage Location',
                            style: Theme.of(context)
                                .textTheme
                                .titleLarge
                                ?.copyWith(fontSize: 15)),
                        const SizedBox(height: 2),
                        Text('Where downloaded files are saved',
                            style: Theme.of(context).textTheme.bodySmall),
                      ],
                    ),
                  ),
                  // H-2: spinner visible while migrating
                  if (_isMigrating)
                    const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                ],
              ),
              const SizedBox(height: 16),
              // M-2: future is cached — no flicker on unrelated rebuilds
              FutureBuilder<String>(
                future: _pathFor(settings),
                builder: (context, snapshot) {
                  final path = snapshot.data ?? 'Loading...';
                  return Container(
                    width: double.infinity,
                    padding: const EdgeInsets.symmetric(
                        horizontal: 12, vertical: 8),
                    decoration: BoxDecoration(
                      color: AppColors.surfaceVariant.withValues(alpha: 0.4),
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(
                          color:
                              AppColors.glassBorder.withValues(alpha: 0.15)),
                    ),
                    child: Row(
                      children: [
                        Icon(Icons.folder_open_rounded,
                            size: 14, color: AppColors.textTertiary),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(path,
                              style: const TextStyle(
                                color: AppColors.textTertiary,
                                fontSize: 11,
                                fontFamily: 'monospace',
                              ),
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis),
                        ),
                      ],
                    ),
                  );
                },
              ),
              const SizedBox(height: 14),
              ...StorageType.values.map((type) {
                final isSelected = currentType == type;
                return Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: InkWell(
                    borderRadius: BorderRadius.circular(12),
                    // H-2: tiles non-interactive during migration
                    onTap: _isMigrating
                        ? null
                        : () => _onTypeSelected(context, settings, type),
                    child: AnimatedContainer(
                      duration: const Duration(milliseconds: 250),
                      padding: const EdgeInsets.symmetric(
                          horizontal: 14, vertical: 12),
                      decoration: BoxDecoration(
                        color: isSelected
                            ? Theme.of(context)
                                .colorScheme
                                .primary
                                .withValues(alpha: 0.1)
                            : AppColors.surfaceVariant.withValues(alpha: 0.2),
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(
                          color: isSelected
                              ? Theme.of(context)
                                  .colorScheme
                                  .primary
                                  .withValues(alpha: 0.4)
                              : AppColors.glassBorder.withValues(alpha: 0.1),
                          width: isSelected ? 1.5 : 0.5,
                        ),
                      ),
                      child: Row(
                        children: [
                          Icon(_icons[type] ?? Icons.storage_rounded,
                              size: 20,
                              color: isSelected
                                  ? Theme.of(context).colorScheme.primary
                                  : AppColors.textSecondary),
                          const SizedBox(width: 14),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(_labels[type] ?? '',
                                    style: TextStyle(
                                      color: isSelected
                                          ? Colors.white
                                          : AppColors.textPrimary,
                                      fontSize: 13,
                                      fontWeight: isSelected
                                          ? FontWeight.bold
                                          : FontWeight.w500,
                                    )),
                                const SizedBox(height: 2),
                                Text(_descriptions[type] ?? '',
                                    style: const TextStyle(
                                        color: AppColors.textTertiary,
                                        fontSize: 10)),
                              ],
                            ),
                          ),
                          if (isSelected)
                            Icon(Icons.check_circle_rounded,
                                color:
                                    Theme.of(context).colorScheme.primary,
                                size: 20),
                        ],
                      ),
                    ),
                  ),
                );
              }),
            ],
          ),
        );
      },
    );
  }

  Future<void> _onTypeSelected(
      BuildContext context, SettingsProvider settings, StorageType type) async {
    if (type == settings.storageType || _isMigrating) return;

    final oldType = settings.storageType;
    final player = context.read<PlayerProvider>();

    // C-1: request permission BEFORE touching any files — a denied dialog
    // after the copy+delete had already run left the library inaccessible.
    if (type != StorageType.appInternal) {
      final granted =
          await settings.storageService.requestStoragePermission();
      if (!granted) {
        if (context.mounted) {
          AppToast.show(
              context,
              'Storage permission required. Please grant in app settings.',
              type: ToastType.warning);
        }
        return;
      }
    }

    // H-1: safe sdPath strip — replaceAll was fragile on volume paths that
    // contained the app folder name more than once.
    String? sdPath;
    if (type == StorageType.sdCard) {
      final volumes = await settings.getAvailableStorageVolumes();
      final sdVolumes =
          volumes.where((v) => v.type == StorageType.sdCard).toList();
      if (sdVolumes.isEmpty) {
        if (context.mounted) {
          AppToast.show(context, 'No SD card detected on this device',
              type: ToastType.warning);
        }
        return;
      }
      final raw = sdVolumes.first.path;
      const suffix = '/${StorageLocationService.appFolderName}';
      sdPath = raw.endsWith(suffix)
          ? raw.substring(0, raw.length - suffix.length)
          : raw;
    }

    setState(() => _isMigrating = true);
    if (context.mounted) {
      AppToast.show(context,
          'Migrating files to ${_labels[type]}…', type: ToastType.info);
    }

    try {
      final success = await player.migrateDownloadedFiles(
        oldType, type,
        sdCardPath: sdPath,
      );
      await settings.setStorageType(type, sdCardPath: sdPath);
      // Invalidate the cached path so the FutureBuilder refreshes.
      if (mounted) setState(() => _cachedType = null);

      if (context.mounted) {
        AppToast.show(
          context,
          success
              ? 'All files moved to ${_labels[type]}!'
              : 'Storage location changed to ${_labels[type]}',
          type: success ? ToastType.success : ToastType.info,
        );
      }
    } catch (e) {
      // C-2: roll back to oldType, not always appInternal — if the user was on
      // deviceInternal and the sdCard migration failed, dropping to appInternal
      // meant their library silently moved to a third location they didn't pick.
      debugPrint('[StorageCard] migration failed: $e');
      await settings.setStorageType(oldType);
      if (context.mounted) {
        AppToast.show(context, 'Migration failed — location not changed.',
            type: ToastType.warning);
      }
    } finally {
      if (mounted) setState(() => _isMigrating = false);
    }
  }
}
