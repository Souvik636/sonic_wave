import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:provider/provider.dart';
import '../providers/player_provider.dart';
import '../providers/settings_provider.dart';
import '../theme/app_colors.dart';
import '../widgets/app_toast.dart';

/// Ultra-Premium Sound Studio Pro Screen
/// Interactive 5-Band Equalizer, Preset Selector, Speed & Pitch Shifter,
/// Karaoke Mode Attenuator, and Animated Frequency Visualizer Meter.
class SoundStudioScreen extends StatefulWidget {
  const SoundStudioScreen({super.key});

  @override
  State<SoundStudioScreen> createState() => _SoundStudioScreenState();
}

class _SoundStudioScreenState extends State<SoundStudioScreen> {
  final List<String> _eqLabels = ['60Hz', '230Hz', '910Hz', '3.6kHz', '14kHz'];
  final List<String> _eqSubLabels = ['Sub Bass', 'Bass', 'Midrange', 'Upper Mid', 'Treble'];

  @override
  Widget build(BuildContext context) {
    final settings = Provider.of<SettingsProvider>(context);
    final playerProvider = Provider.of<PlayerProvider>(context);
    final primary = Theme.of(context).colorScheme.primary;

    final gains = settings.useCustomEqualizer
        ? settings.customEqualizerGains
        : _getPresetGains(settings.soundEnhancer);

    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back_ios_new_rounded, color: Colors.white, size: 20),
          onPressed: () => Navigator.pop(context),
        ),
        title: Column(
          children: [
            Text(
              'SOUND ENHANCER',
              style: GoogleFonts.outfit(
                color: primary,
                fontSize: 11,
                fontWeight: FontWeight.w900,
                letterSpacing: 1.5,
              ),
            ),
            const SizedBox(height: 2),
            Text(
              'Equalizer & Audio FX',
              style: GoogleFonts.outfit(
                color: Colors.white,
                fontSize: 16,
                fontWeight: FontWeight.bold,
              ),
            ),
          ],
        ),
        centerTitle: true,
        actions: [
          IconButton(
            icon: const Icon(Icons.restart_alt_rounded, color: AppColors.textSecondary),
            tooltip: 'Reset EQ',
            onPressed: () {
              settings.setUseCustomEqualizer(false);
              settings.setSoundEnhancer(SoundEnhancer.none);
              playerProvider.setPlaybackSpeed(1.0);
              AppToast.show(context, 'Reset all Sound Studio effects', type: ToastType.info);
            },
          ),
        ],
      ),
      body: SafeArea(
        child: SingleChildScrollView(
          physics: const BouncingScrollPhysics(),
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Master Custom EQ Toggle Banner
              _buildMasterToggleCard(context, settings, primary),

              const SizedBox(height: 20),

              // Animated Frequency Meter & Equalizer Header
              _buildFrequencyMeter(context, gains, primary),

              const SizedBox(height: 20),

              // Interactive 5-Band Sliders
              _buildEqualizerSliders(context, settings, playerProvider, gains, primary),

              const SizedBox(height: 24),

              // Preset Selector Section
              Text(
                'STUDIO PRESETS',
                style: GoogleFonts.outfit(
                  color: AppColors.textTertiary,
                  fontSize: 12,
                  fontWeight: FontWeight.w800,
                  letterSpacing: 1.2,
                ),
              ),
              const SizedBox(height: 10),
              _buildPresetChips(context, settings, playerProvider, primary),

              const SizedBox(height: 24),

              // Playback Speed & Key Pitch Shifter
              Text(
                'PITCH & SPEED CONTROLS',
                style: GoogleFonts.outfit(
                  color: AppColors.textTertiary,
                  fontSize: 12,
                  fontWeight: FontWeight.w800,
                  letterSpacing: 1.2,
                ),
              ),
              const SizedBox(height: 10),
              _buildSpeedAndPitchCard(context, settings, playerProvider, primary),

              const SizedBox(height: 24),

              // Karaoke & Audio FX
              Text(
                'AUDIO FX & KARAOKE',
                style: GoogleFonts.outfit(
                  color: AppColors.textTertiary,
                  fontSize: 12,
                  fontWeight: FontWeight.w800,
                  letterSpacing: 1.2,
                ),
              ),
              const SizedBox(height: 10),
              _buildAudioFxCard(context, settings, playerProvider, primary),

              const SizedBox(height: 40),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildMasterToggleCard(BuildContext context, SettingsProvider settings, Color primary) {
    final isCustom = settings.useCustomEqualizer;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 14),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: [
            isCustom ? primary.withValues(alpha: 0.25) : AppColors.surfaceVariant.withValues(alpha: 0.4),
            AppColors.surfaceVariant.withValues(alpha: 0.6),
          ],
        ),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(
          color: isCustom ? primary.withValues(alpha: 0.5) : AppColors.glassBorder,
          width: 1.2,
        ),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Expanded(
            child: Row(
              children: [
                Container(
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: isCustom ? primary.withValues(alpha: 0.2) : Colors.white.withValues(alpha: 0.05),
                  ),
                  child: Icon(
                    Icons.equalizer_rounded,
                    color: isCustom ? primary : AppColors.textTertiary,
                    size: 22,
                  ),
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        isCustom ? 'Custom 5-Band EQ Active' : 'Preset Mode Active',
                        style: GoogleFonts.outfit(color: Colors.white, fontSize: 15, fontWeight: FontWeight.bold),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        isCustom ? 'Manual frequency band sliders enabled' : 'Using selected studio preset profile',
                        style: GoogleFonts.inter(color: AppColors.textSecondary, fontSize: 11.5),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),

          Switch(
            value: isCustom,
            activeThumbColor: primary,
            onChanged: (val) {
              settings.setUseCustomEqualizer(val);
              AppToast.show(
                context,
                val ? 'Custom Equalizer Enabled' : 'Preset Equalizer Mode Enabled',
                type: ToastType.info,
                icon: Icons.tune_rounded,
              );
            },
          ),
        ],
      ),
    );
  }

  Widget _buildFrequencyMeter(BuildContext context, List<double> gains, Color primary) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppColors.surfaceVariant.withValues(alpha: 0.4),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: AppColors.glassBorder, width: 1),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                'LIVE FREQUENCY SPECTRUM',
                style: GoogleFonts.outfit(color: AppColors.textTertiary, fontSize: 10.5, fontWeight: FontWeight.bold, letterSpacing: 1),
              ),
              Icon(Icons.graphic_eq_rounded, color: primary, size: 18),
            ],
          ),
          const SizedBox(height: 14),
          SizedBox(
            height: 50,
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceEvenly,
              crossAxisAlignment: CrossAxisAlignment.end,
              children: List.generate(gains.length, (idx) {
                final gain = gains[idx].clamp(-12.0, 12.0);
                final normalized = ((gain + 12.0) / 24.0).clamp(0.08, 1.0);

                return AnimatedContainer(
                  duration: const Duration(milliseconds: 300),
                  curve: Curves.easeOutCubic,
                  width: 38,
                  height: 50 * normalized,
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      colors: [
                        primary.withValues(alpha: 0.4),
                        primary,
                      ],
                      begin: Alignment.bottomCenter,
                      end: Alignment.topCenter,
                    ),
                    borderRadius: BorderRadius.circular(8),
                    boxShadow: [
                      BoxShadow(color: primary.withValues(alpha: 0.3), blurRadius: 6),
                    ],
                  ),
                );
              }),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildEqualizerSliders(
    BuildContext context,
    SettingsProvider settings,
    PlayerProvider playerProvider,
    List<double> gains,
    Color primary,
  ) {
    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: AppColors.surfaceVariant.withValues(alpha: 0.5),
        borderRadius: BorderRadius.circular(24),
        border: Border.all(color: AppColors.glassBorder, width: 1),
      ),
      child: Column(
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                '5-BAND GAIN SLIDERS (-12dB to +12dB)',
                style: GoogleFonts.outfit(color: Colors.white, fontSize: 12, fontWeight: FontWeight.bold),
              ),
              GestureDetector(
                onTap: () {
                  final zeroGains = [0.0, 0.0, 0.0, 0.0, 0.0];
                  settings.setCustomEqualizerGains(zeroGains);
                  settings.setUseCustomEqualizer(true);
                },
                child: Text(
                  'Reset Bands',
                  style: GoogleFonts.inter(color: primary, fontSize: 12, fontWeight: FontWeight.bold),
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          SizedBox(
            height: 190,
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceEvenly,
              children: List.generate(5, (index) {
                final gainVal = gains[index].clamp(-12.0, 12.0);

                return Column(
                  children: [
                    // Value readout
                    Text(
                      '${gainVal > 0 ? "+" : ""}${gainVal.toStringAsFixed(1)}dB',
                      style: GoogleFonts.inter(
                        color: gainVal != 0 ? primary : AppColors.textTertiary,
                        fontSize: 10,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    const SizedBox(height: 6),
                    // Vertical Slider
                    Expanded(
                      child: RotatedBox(
                        quarterTurns: 3,
                        child: SliderTheme(
                          data: SliderThemeData(
                            trackHeight: 6,
                            activeTrackColor: primary,
                            inactiveTrackColor: Colors.white.withValues(alpha: 0.1),
                            thumbColor: Colors.white,
                            overlayColor: primary.withValues(alpha: 0.2),
                            thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 8),
                          ),
                          child: Slider(
                            value: gainVal,
                            min: -12.0,
                            max: 12.0,
                            onChanged: (val) {
                              final newGains = List<double>.from(gains);
                              newGains[index] = double.parse(val.toStringAsFixed(1));
                              settings.setCustomEqualizerGains(newGains);
                              settings.setUseCustomEqualizer(true);
                            },
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      _eqLabels[index],
                      style: GoogleFonts.outfit(color: Colors.white, fontSize: 12, fontWeight: FontWeight.bold),
                    ),
                    Text(
                      _eqSubLabels[index],
                      style: GoogleFonts.inter(color: AppColors.textTertiary, fontSize: 9.5),
                    ),
                  ],
                );
              }),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildPresetChips(
    BuildContext context,
    SettingsProvider settings,
    PlayerProvider playerProvider,
    Color primary,
  ) {
    final presets = [
      {'name': 'Flat', 'mode': SoundEnhancer.none, 'icon': Icons.equalizer_rounded},
      {'name': 'Bass Boost', 'mode': SoundEnhancer.bassBoost, 'icon': Icons.speaker_group_rounded},
      {'name': 'Treble Boost', 'mode': SoundEnhancer.trebleBoost, 'icon': Icons.graphic_eq_rounded},
      {'name': 'Vocal Clarity', 'mode': SoundEnhancer.vocal, 'icon': Icons.mic_rounded},
      {'name': '3D Spatial', 'mode': SoundEnhancer.ambient3d, 'icon': Icons.surround_sound_rounded},
    ];

    return SizedBox(
      height: 44,
      child: ListView.builder(
        scrollDirection: Axis.horizontal,
        physics: const BouncingScrollPhysics(),
        itemCount: presets.length,
        itemBuilder: (context, idx) {
          final p = presets[idx];
          final mode = p['mode'] as SoundEnhancer;
          final isSelected = !settings.useCustomEqualizer && settings.soundEnhancer == mode;

          return GestureDetector(
            onTap: () {
              settings.setUseCustomEqualizer(false);
              settings.setSoundEnhancer(mode);
              AppToast.show(context, 'Applied ${p['name']} Preset', type: ToastType.info, icon: p['icon'] as IconData);
            },
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 200),
              margin: const EdgeInsets.only(right: 10),
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
              decoration: BoxDecoration(
                color: isSelected ? primary : AppColors.surfaceVariant.withValues(alpha: 0.5),
                borderRadius: BorderRadius.circular(20),
                border: Border.all(color: isSelected ? primary : AppColors.glassBorder, width: 1),
                boxShadow: isSelected ? [BoxShadow(color: primary.withValues(alpha: 0.3), blurRadius: 8)] : [],
              ),
              child: Row(
                children: [
                  Icon(p['icon'] as IconData, color: isSelected ? Colors.white : AppColors.textSecondary, size: 16),
                  const SizedBox(width: 8),
                  Text(
                    p['name'] as String,
                    style: GoogleFonts.inter(
                      color: isSelected ? Colors.white : AppColors.textSecondary,
                      fontSize: 12.5,
                      fontWeight: isSelected ? FontWeight.bold : FontWeight.w500,
                    ),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  Widget _buildSpeedAndPitchCard(
    BuildContext context,
    SettingsProvider settings,
    PlayerProvider playerProvider,
    Color primary,
  ) {
    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: AppColors.surfaceVariant.withValues(alpha: 0.5),
        borderRadius: BorderRadius.circular(24),
        border: Border.all(color: AppColors.glassBorder, width: 1),
      ),
      child: Column(
        children: [
          // Speed Control
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Row(
                children: [
                  Icon(Icons.speed_rounded, color: primary, size: 18),
                  const SizedBox(width: 8),
                  Text('Playback Speed', style: GoogleFonts.outfit(color: Colors.white, fontSize: 14, fontWeight: FontWeight.bold)),
                ],
              ),
              Text(
                '${playerProvider.playbackSpeed.toStringAsFixed(2)}x',
                style: GoogleFonts.inter(color: primary, fontSize: 13, fontWeight: FontWeight.bold),
              ),
            ],
          ),
          SliderTheme(
            data: SliderThemeData(
              activeTrackColor: primary,
              inactiveTrackColor: Colors.white.withValues(alpha: 0.1),
              thumbColor: Colors.white,
            ),
            child: Slider(
              value: playerProvider.playbackSpeed,
              min: 0.5,
              max: 2.0,
              divisions: 15,
              onChanged: (val) {
                playerProvider.setPlaybackSpeed(val);
              },
            ),
          ),

          const SizedBox(height: 12),
          const Divider(color: AppColors.divider, height: 1),
          const SizedBox(height: 12),

          // Karaoke Toggle
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Expanded(
                child: Row(
                  children: [
                    Icon(Icons.mic_external_on_rounded, color: playerProvider.isKaraokeMode ? Colors.pinkAccent : AppColors.textTertiary, size: 18),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text('Karaoke Vocal Attenuator', style: GoogleFonts.outfit(color: Colors.white, fontSize: 14, fontWeight: FontWeight.bold)),
                          Text('Reduces center vocal frequencies for sing-along', style: GoogleFonts.inter(color: AppColors.textTertiary, fontSize: 11)),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
              Switch(
                value: playerProvider.isKaraokeMode,
                activeThumbColor: Colors.pinkAccent,
                onChanged: (val) {
                  playerProvider.toggleKaraokeMode();
                  AppToast.show(
                    context,
                    val ? 'Karaoke Mode Enabled' : 'Karaoke Mode Disabled',
                    type: ToastType.favorite,
                    icon: Icons.mic_rounded,
                  );
                },
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildAudioFxCard(
    BuildContext context,
    SettingsProvider settings,
    PlayerProvider playerProvider,
    Color primary,
  ) {
    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: AppColors.surfaceVariant.withValues(alpha: 0.5),
        borderRadius: BorderRadius.circular(24),
        border: Border.all(color: AppColors.glassBorder, width: 1),
      ),
      child: Column(
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Row(
                children: [
                  Icon(Icons.alt_route_rounded, color: primary, size: 18),
                  const SizedBox(width: 8),
                  Text('Crossfade Between Tracks', style: GoogleFonts.outfit(color: Colors.white, fontSize: 14, fontWeight: FontWeight.bold)),
                ],
              ),
              Text(
                settings.crossfadeSeconds == 0 ? 'Off' : '${settings.crossfadeSeconds}s',
                style: GoogleFonts.inter(color: primary, fontSize: 13, fontWeight: FontWeight.bold),
              ),
            ],
          ),
          SliderTheme(
            data: SliderThemeData(
              activeTrackColor: primary,
              inactiveTrackColor: Colors.white.withValues(alpha: 0.1),
              thumbColor: Colors.white,
            ),
            child: Slider(
              value: settings.crossfadeSeconds.toDouble(),
              min: 0,
              max: 10,
              divisions: 10,
              onChanged: (val) {
                settings.setCrossfadeSeconds(val.toInt());
              },
            ),
          ),
        ],
      ),
    );
  }

  List<double> _getPresetGains(SoundEnhancer enhancer) {
    switch (enhancer) {
      case SoundEnhancer.none:
        return [0.0, 0.0, 0.0, 0.0, 0.0];
      case SoundEnhancer.bassBoost:
        return [9.0, 5.0, -1.5, 0.0, 1.0];
      case SoundEnhancer.trebleBoost:
        return [-2.0, -1.0, 1.0, 6.0, 10.0];
      case SoundEnhancer.vocal:
        return [-4.0, 2.0, 7.0, 5.0, 2.0];
      case SoundEnhancer.ambient3d:
        return [7.0, 3.0, -5.0, 3.0, 8.0];
    }
  }
}
