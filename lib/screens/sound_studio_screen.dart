import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:provider/provider.dart';
import '../providers/player_provider.dart';
import '../providers/settings_provider.dart';
import '../theme/app_colors.dart';
import '../widgets/app_toast.dart';

/// Ultra-Premium Sound Studio Pro Screen
/// Interactive 5-Band Equalizer, 12-Genre Preset Library, Bezier EQ Curve
/// Visualizer, A/B Bypass, Custom Preset Save, Speed & Pitch Shifter,
/// Karaoke Mode Attenuator, and Crossfade controls.
class SoundStudioScreen extends StatefulWidget {
  const SoundStudioScreen({super.key});

  @override
  State<SoundStudioScreen> createState() => _SoundStudioScreenState();
}

class _SoundStudioScreenState extends State<SoundStudioScreen>
    with SingleTickerProviderStateMixin {
  final List<String> _eqLabels    = ['60Hz', '230Hz', '910Hz', '3.6kHz', '14kHz'];
  final List<String> _eqSubLabels = ['Sub Bass', 'Bass', 'Midrange', 'Upper Mid', 'Treble'];

  // Tracks the previous-preset gains for A/B bypass restore
  List<double> _bypassRestoreGains = [0.0, 0.0, 0.0, 0.0, 0.0];
  bool _bypassActive = false;

  // Haptic boundary tracking per slider to fire only once per crossing
  final List<double?> _lastHapticValue = [null, null, null, null, null];

  // Text controller for save-preset dialog
  final TextEditingController _presetNameCtrl = TextEditingController();

  @override
  void dispose() {
    _presetNameCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final settings      = Provider.of<SettingsProvider>(context);
    final playerProvider = Provider.of<PlayerProvider>(context);
    final primary       = Theme.of(context).colorScheme.primary;

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
              'SOUND STUDIO PRO',
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
          // A/B Bypass button
          Tooltip(
            message: _bypassActive ? 'Restore EQ' : 'A/B Bypass',
            child: IconButton(
              icon: Icon(
                _bypassActive ? Icons.compare_arrows_rounded : Icons.swap_horiz_rounded,
                color: _bypassActive ? Colors.orangeAccent : AppColors.textSecondary,
              ),
              onPressed: () => _toggleBypass(settings, gains),
            ),
          ),
          // Reset all button
          IconButton(
            icon: const Icon(Icons.restart_alt_rounded, color: AppColors.textSecondary),
            tooltip: 'Reset EQ',
            onPressed: () {
              _bypassActive = false;
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

              // Bezier EQ Curve Visualizer
              _buildBezierEqCurve(context, gains, primary),

              const SizedBox(height: 20),

              // Interactive 5-Band Sliders
              _buildEqualizerSliders(context, settings, playerProvider, gains, primary),

              const SizedBox(height: 24),

              // Preset Selector Section
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(
                    'STUDIO PRESETS',
                    style: GoogleFonts.outfit(
                      color: AppColors.textTertiary,
                      fontSize: 12,
                      fontWeight: FontWeight.w800,
                      letterSpacing: 1.2,
                    ),
                  ),
                  if (settings.useCustomEqualizer)
                    GestureDetector(
                      onTap: () => _showSavePresetDialog(context, settings, gains),
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                        decoration: BoxDecoration(
                          color: primary.withValues(alpha: 0.15),
                          borderRadius: BorderRadius.circular(12),
                          border: Border.all(color: primary.withValues(alpha: 0.4)),
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(Icons.save_rounded, color: primary, size: 14),
                            const SizedBox(width: 5),
                            Text(
                              'Save Preset',
                              style: GoogleFonts.inter(color: primary, fontSize: 11.5, fontWeight: FontWeight.bold),
                            ),
                          ],
                        ),
                      ),
                    ),
                ],
              ),
              const SizedBox(height: 10),
              _buildPresetChips(context, settings, playerProvider, primary),

              // User custom presets row (shown only if any saved)
              if (settings.customPresets.isNotEmpty) ...[
                const SizedBox(height: 12),
                Text(
                  'MY PRESETS',
                  style: GoogleFonts.outfit(
                    color: AppColors.textTertiary,
                    fontSize: 10.5,
                    fontWeight: FontWeight.w800,
                    letterSpacing: 1.0,
                  ),
                ),
                const SizedBox(height: 8),
                _buildUserPresetChips(context, settings, primary),
              ],

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

  // ─────────────────────────────────────────────────────────
  // A/B bypass
  // ─────────────────────────────────────────────────────────
  void _toggleBypass(SettingsProvider settings, List<double> currentGains) {
    HapticFeedback.lightImpact();
    if (!_bypassActive) {
      // Store current gains so we can restore them
      _bypassRestoreGains = List.from(currentGains);
      _bypassActive = true;
      // Apply flat instantly without persisting
      settings.setCustomEqualizerGains([0.0, 0.0, 0.0, 0.0, 0.0]);
      settings.setUseCustomEqualizer(true);
    } else {
      _bypassActive = false;
      settings.setCustomEqualizerGains(_bypassRestoreGains);
      settings.setUseCustomEqualizer(true);
    }
    setState(() {});
  }

  // ─────────────────────────────────────────────────────────
  // Save preset dialog
  // ─────────────────────────────────────────────────────────
  void _showSavePresetDialog(BuildContext ctx, SettingsProvider settings, List<double> gains) {
    _presetNameCtrl.clear();
    final primary = Theme.of(ctx).colorScheme.primary;
    showDialog<void>(
      context: ctx,
      builder: (dialogCtx) => AlertDialog(
        backgroundColor: AppColors.surface,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: Text('Save Preset', style: GoogleFonts.outfit(color: Colors.white, fontWeight: FontWeight.bold)),
        content: TextField(
          controller: _presetNameCtrl,
          autofocus: true,
          style: GoogleFonts.inter(color: Colors.white),
          decoration: InputDecoration(
            hintText: 'e.g. My Night Mix',
            hintStyle: GoogleFonts.inter(color: AppColors.textTertiary),
            filled: true,
            fillColor: AppColors.surfaceVariant.withValues(alpha: 0.6),
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(12),
              borderSide: BorderSide(color: primary.withValues(alpha: 0.4)),
            ),
            focusedBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(12),
              borderSide: BorderSide(color: primary, width: 1.5),
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogCtx),
            child: Text('Cancel', style: GoogleFonts.inter(color: AppColors.textSecondary)),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
              backgroundColor: primary,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
            ),
            onPressed: () {
              final name = _presetNameCtrl.text.trim();
              if (name.isNotEmpty) {
                settings.saveCustomPreset(name, gains);
                Navigator.pop(dialogCtx);
                AppToast.show(ctx, '"$name" preset saved!', type: ToastType.info, icon: Icons.save_rounded);
              }
            },
            child: Text('Save', style: GoogleFonts.inter(color: Colors.white, fontWeight: FontWeight.bold)),
          ),
        ],
      ),
    );
  }

  // ─────────────────────────────────────────────────────────
  // Master toggle card
  // ─────────────────────────────────────────────────────────
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

  // ─────────────────────────────────────────────────────────
  // Bezier EQ Curve Visualizer (replaces static bars)
  // ─────────────────────────────────────────────────────────
  Widget _buildBezierEqCurve(BuildContext context, List<double> gains, Color primary) {
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 10),
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
                'EQ RESPONSE CURVE',
                style: GoogleFonts.outfit(
                  color: AppColors.textTertiary,
                  fontSize: 10.5,
                  fontWeight: FontWeight.bold,
                  letterSpacing: 1,
                ),
              ),
              Row(
                children: [
                  if (_bypassActive)
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
                      decoration: BoxDecoration(
                        color: Colors.orangeAccent.withValues(alpha: 0.2),
                        borderRadius: BorderRadius.circular(6),
                      ),
                      child: Text('BYPASS', style: GoogleFonts.outfit(color: Colors.orangeAccent, fontSize: 9, fontWeight: FontWeight.bold, letterSpacing: 1)),
                    ),
                  const SizedBox(width: 6),
                  Icon(Icons.show_chart_rounded, color: primary, size: 18),
                ],
              ),
            ],
          ),
          const SizedBox(height: 12),
          SizedBox(
            height: 72,
            child: CustomPaint(
              painter: _EqCurvePainter(gains: gains, color: primary),
              size: Size.infinite,
            ),
          ),
          const SizedBox(height: 8),
          // Frequency labels
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: _eqLabels.map((l) => Text(l,
              style: GoogleFonts.inter(color: AppColors.textTertiary, fontSize: 9),
            )).toList(),
          ),
        ],
      ),
    );
  }

  // ─────────────────────────────────────────────────────────
  // 5-Band Sliders with haptic ticks
  // ─────────────────────────────────────────────────────────
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
                  _lastHapticValue.fillRange(0, 5, null);
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
                              // Haptic tick at 0dB crossing and at ±12dB walls
                              final prev = _lastHapticValue[index];
                              if (prev != null) {
                                final crossedZero  = (prev < 0 && val >= 0) || (prev > 0 && val <= 0);
                                final hitPosWall   = val >= 11.9 && (prev < 11.9);
                                final hitNegWall   = val <= -11.9 && (prev > -11.9);
                                if (crossedZero || hitPosWall || hitNegWall) {
                                  HapticFeedback.selectionClick();
                                }
                              }
                              _lastHapticValue[index] = val;

                              final newGains = List<double>.from(gains);
                              newGains[index] = double.parse(val.toStringAsFixed(1));
                              settings.setCustomEqualizerGains(newGains);
                              settings.setUseCustomEqualizer(true);
                              _bypassActive = false;
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

  // ─────────────────────────────────────────────────────────
  // Genre Preset Chips (12 presets)
  // ─────────────────────────────────────────────────────────
  static const List<Map<String, dynamic>> _allPresets = [
    {'name': 'Flat',        'mode': SoundEnhancer.none,        'icon': Icons.equalizer_rounded,          'color': Color(0xFF9E9E9E)},
    {'name': 'Bass Boost',  'mode': SoundEnhancer.bassBoost,   'icon': Icons.speaker_group_rounded,      'color': Color(0xFF1565C0)},
    {'name': 'Treble',      'mode': SoundEnhancer.trebleBoost, 'icon': Icons.graphic_eq_rounded,         'color': Color(0xFF00ACC1)},
    {'name': 'Vocal',       'mode': SoundEnhancer.vocal,       'icon': Icons.mic_rounded,                'color': Color(0xFFAD1457)},
    {'name': '3D Spatial',  'mode': SoundEnhancer.ambient3d,   'icon': Icons.surround_sound_rounded,     'color': Color(0xFF6A1B9A)},
    {'name': 'Electronic',  'mode': SoundEnhancer.electronic,  'icon': Icons.bolt_rounded,               'color': Color(0xFF0097A7)},
    {'name': 'Rock / Metal','mode': SoundEnhancer.rockMetal,   'icon': Icons.music_note_rounded,         'color': Color(0xFFBF360C)},
    {'name': 'Hip-Hop',     'mode': SoundEnhancer.hipHop,      'icon': Icons.radio_rounded,              'color': Color(0xFFF57F17)},
    {'name': 'Pop',         'mode': SoundEnhancer.pop,         'icon': Icons.star_rounded,               'color': Color(0xFF880E4F)},
    {'name': 'Acoustic',    'mode': SoundEnhancer.acoustic,    'icon': Icons.piano_rounded,              'color': Color(0xFF33691E)},
    {'name': 'Jazz / Blues','mode': SoundEnhancer.jazzBlues,   'icon': Icons.queue_music_rounded,        'color': Color(0xFF4E342E)},
    {'name': 'Night Mode',  'mode': SoundEnhancer.nightMode,   'icon': Icons.nightlight_round,           'color': Color(0xFF37474F)},
  ];

  Widget _buildPresetChips(
    BuildContext context,
    SettingsProvider settings,
    PlayerProvider playerProvider,
    Color primary,
  ) {
    return SizedBox(
      height: 44,
      child: ListView.builder(
        scrollDirection: Axis.horizontal,
        physics: const BouncingScrollPhysics(),
        itemCount: _allPresets.length,
        itemBuilder: (context, idx) {
          final p    = _allPresets[idx];
          final mode = p['mode'] as SoundEnhancer;
          final tint = p['color'] as Color;
          final isSelected = !settings.useCustomEqualizer && settings.soundEnhancer == mode;

          return GestureDetector(
            onTap: () {
              HapticFeedback.selectionClick();
              settings.setUseCustomEqualizer(false);
              settings.setSoundEnhancer(mode);
              _bypassActive = false;
              AppToast.show(context, 'Applied ${p['name']} Preset', type: ToastType.info, icon: p['icon'] as IconData);
            },
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 200),
              margin: const EdgeInsets.only(right: 10),
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
              decoration: BoxDecoration(
                color: isSelected ? tint : AppColors.surfaceVariant.withValues(alpha: 0.5),
                borderRadius: BorderRadius.circular(20),
                border: Border.all(color: isSelected ? tint : AppColors.glassBorder, width: 1),
                boxShadow: isSelected ? [BoxShadow(color: tint.withValues(alpha: 0.4), blurRadius: 10, spreadRadius: 0)] : [],
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

  // ─────────────────────────────────────────────────────────
  // User Saved Preset Chips
  // ─────────────────────────────────────────────────────────
  Widget _buildUserPresetChips(BuildContext context, SettingsProvider settings, Color primary) {
    final entries = settings.customPresets.entries.toList();
    return SizedBox(
      height: 44,
      child: ListView.builder(
        scrollDirection: Axis.horizontal,
        physics: const BouncingScrollPhysics(),
        itemCount: entries.length,
        itemBuilder: (context, idx) {
          final entry = entries[idx];
          return GestureDetector(
            onTap: () {
              HapticFeedback.selectionClick();
              settings.setCustomEqualizerGains(entry.value);
              settings.setUseCustomEqualizer(true);
              _bypassActive = false;
              AppToast.show(context, 'Applied "${entry.key}"', type: ToastType.info, icon: Icons.tune_rounded);
            },
            onLongPress: () {
              HapticFeedback.mediumImpact();
              _showDeletePresetDialog(context, settings, entry.key);
            },
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 200),
              margin: const EdgeInsets.only(right: 10),
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  colors: [primary.withValues(alpha: 0.3), primary.withValues(alpha: 0.1)],
                ),
                borderRadius: BorderRadius.circular(20),
                border: Border.all(color: primary.withValues(alpha: 0.5), width: 1),
              ),
              child: Row(
                children: [
                  Icon(Icons.tune_rounded, color: primary, size: 15),
                  const SizedBox(width: 7),
                  Text(
                    entry.key,
                    style: GoogleFonts.inter(color: Colors.white, fontSize: 12, fontWeight: FontWeight.w600),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  void _showDeletePresetDialog(BuildContext ctx, SettingsProvider settings, String name) {
    showDialog<void>(
      context: ctx,
      builder: (dialogCtx) => AlertDialog(
        backgroundColor: AppColors.surface,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: Text('Delete Preset', style: GoogleFonts.outfit(color: Colors.white, fontWeight: FontWeight.bold)),
        content: Text('Delete "$name"?', style: GoogleFonts.inter(color: AppColors.textSecondary)),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogCtx),
            child: Text('Cancel', style: GoogleFonts.inter(color: AppColors.textSecondary)),
          ),
          TextButton(
            onPressed: () {
              settings.deleteCustomPreset(name);
              Navigator.pop(dialogCtx);
            },
            child: Text('Delete', style: GoogleFonts.inter(color: Colors.redAccent, fontWeight: FontWeight.bold)),
          ),
        ],
      ),
    );
  }

  // ─────────────────────────────────────────────────────────
  // Speed + Pitch + Karaoke card
  // ─────────────────────────────────────────────────────────
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

  // ─────────────────────────────────────────────────────────
  // Audio FX — Crossfade
  // ─────────────────────────────────────────────────────────
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

  // ─────────────────────────────────────────────────────────
  // Preset → gains lookup (mirrors audio_handler preset map)
  // ─────────────────────────────────────────────────────────
  List<double> _getPresetGains(SoundEnhancer enhancer) {
    switch (enhancer) {
      case SoundEnhancer.none:        return [ 0.0,  0.0,  0.0,  0.0,  0.0];
      case SoundEnhancer.bassBoost:   return [ 9.0,  5.0, -1.5,  0.0,  1.0];
      case SoundEnhancer.trebleBoost: return [-2.0, -1.0,  1.0,  6.0, 10.0];
      case SoundEnhancer.vocal:       return [-4.0,  2.0,  7.0,  5.0,  2.0];
      case SoundEnhancer.ambient3d:   return [ 7.0,  3.0, -5.0,  3.0,  8.0];
      case SoundEnhancer.electronic:  return [ 5.0, -2.0, -3.0,  4.0,  6.0];
      case SoundEnhancer.rockMetal:   return [ 4.0,  3.0,  4.0,  3.0, -1.0];
      case SoundEnhancer.hipHop:      return [ 8.0,  6.0, -2.0, -1.0,  2.0];
      case SoundEnhancer.pop:         return [-1.0,  2.0,  1.0,  4.0,  5.0];
      case SoundEnhancer.acoustic:    return [ 0.0,  3.0,  2.0,  3.0,  1.0];
      case SoundEnhancer.jazzBlues:   return [ 3.0,  4.0,  0.0,  2.0,  3.0];
      case SoundEnhancer.nightMode:   return [-3.0,  1.0,  3.0,  1.0, -4.0];
    }
  }
}

// ─────────────────────────────────────────────────────────────
// Bezier EQ Curve Painter
// ─────────────────────────────────────────────────────────────

/// Draws a smooth Catmull-Rom spline through the 5 EQ band gain points
/// plus phantom edge anchors so the curve always returns to 0dB at the edges.
class _EqCurvePainter extends CustomPainter {
  final List<double> gains;
  final Color color;

  const _EqCurvePainter({required this.gains, required this.color});

  @override
  void paint(Canvas canvas, Size size) {
    if (gains.length < 5) return;

    const double maxDb = 12.0;
    final double midY  = size.height / 2;

    // Map gain → Y: +12dB = top, -12dB = bottom, 0 = center
    double gainToY(double gain) => midY - (gain / maxDb) * midY * 0.9;

    // Build control points: phantom anchors at x=-size.width*0.1 and x=size.width*1.1
    final List<Offset> pts = [
      Offset(-size.width * 0.1, midY), // left phantom at 0dB
      ...List.generate(5, (i) {
        final x = size.width * (i / 4.0);
        return Offset(x, gainToY(gains[i]));
      }),
      Offset(size.width * 1.1, midY),  // right phantom at 0dB
    ];

    // Build Catmull-Rom path between real points (index 1-5 in pts)
    final path = Path();
    path.moveTo(pts[1].dx, pts[1].dy);

    for (int i = 1; i < pts.length - 2; i++) {
      final p0 = pts[i - 1];
      final p1 = pts[i];
      final p2 = pts[i + 1];
      final p3 = pts[math.min(i + 2, pts.length - 1)];

      // Catmull-Rom → cubic Bezier conversion (alpha = 0.5 for centripetal)
      final cp1x = p1.dx + (p2.dx - p0.dx) / 6.0;
      final cp1y = p1.dy + (p2.dy - p0.dy) / 6.0;
      final cp2x = p2.dx - (p3.dx - p1.dx) / 6.0;
      final cp2y = p2.dy - (p3.dy - p1.dy) / 6.0;
      path.cubicTo(cp1x, cp1y, cp2x, cp2y, p2.dx, p2.dy);
    }

    // Stroke the curve
    final strokePaint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.5
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;

    // Filled gradient area under the curve
    final fillPath = Path.from(path)
      ..lineTo(size.width, size.height)
      ..lineTo(0, size.height)
      ..close();

    final fillPaint = Paint()
      ..shader = LinearGradient(
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
        colors: [color.withValues(alpha: 0.25), color.withValues(alpha: 0.0)],
      ).createShader(Rect.fromLTWH(0, 0, size.width, size.height));

    // Draw 0dB reference line first (behind curve)
    final refPaint = Paint()
      ..color = Colors.white.withValues(alpha: 0.12)
      ..strokeWidth = 1;
    canvas.drawLine(Offset(0, midY), Offset(size.width, midY), refPaint);

    canvas.drawPath(fillPath, fillPaint);
    canvas.drawPath(path, strokePaint);

    // Draw dots on each band point
    final dotPaint = Paint()
      ..color = color
      ..style = PaintingStyle.fill;
    final dotBorderPaint = Paint()
      ..color = Colors.white
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.5;

    for (int i = 1; i <= 5; i++) {
      canvas.drawCircle(pts[i], 4.5, dotPaint);
      canvas.drawCircle(pts[i], 4.5, dotBorderPaint);
    }
  }

  @override
  bool shouldRepaint(covariant _EqCurvePainter old) =>
      old.gains != gains || old.color != color;
}
