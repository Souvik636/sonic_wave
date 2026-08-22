import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import '../services/ambient_soundscape_service.dart';
import 'premium_interaction.dart';

/// Ambient Soundscape Layer Selector & Volume Mixer Bottom Sheet
class AmbientSoundscapeSheet extends StatelessWidget {
  const AmbientSoundscapeSheet({super.key});

  static void show(BuildContext context) {
    AppHaptics.medium();
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (_) => const AmbientSoundscapeSheet(),
    );
  }

  @override
  Widget build(BuildContext context) {
    final service = AmbientSoundscapeService();

    return Container(
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 32),
      decoration: BoxDecoration(
        color: const Color(0xFF0F1218),
        borderRadius: const BorderRadius.vertical(top: Radius.circular(28)),
        border: Border.all(color: Colors.white.withValues(alpha: 0.1)),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.9),
            blurRadius: 30,
            offset: const Offset(0, -6),
          ),
        ],
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Drag handle
          Center(
            child: Container(
              width: 40,
              height: 4,
              decoration: BoxDecoration(
                color: Colors.white24,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
          ),
          const SizedBox(height: 16),

          // Header
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Row(
                children: [
                  Container(
                    padding: const EdgeInsets.all(8),
                    decoration: BoxDecoration(
                      color: const Color(0xFF64B5F6).withValues(alpha: 0.15),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: const Icon(Icons.cloud_queue_rounded, color: Color(0xFF64B5F6), size: 20),
                  ),
                  const SizedBox(width: 12),
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Ambient Soundscape Layer',
                        style: GoogleFonts.outfit(
                          color: Colors.white,
                          fontSize: 18,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      Text(
                        'Mix relaxing atmospheres under music',
                        style: GoogleFonts.outfit(
                          color: const Color(0xFF64B5F6),
                          fontSize: 12,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    ],
                  ),
                ],
              ),
              ValueListenableBuilder<AmbientType?>(
                valueListenable: service.activeTypeNotifier,
                builder: (context, activeType, _) {
                  if (activeType == null) return const SizedBox.shrink();
                  return TextButton(
                    onPressed: () {
                      AppHaptics.light();
                      service.stop();
                    },
                    child: Text('Mute All', style: GoogleFonts.outfit(color: Colors.white54, fontSize: 12)),
                  );
                },
              ),
            ],
          ),
          const SizedBox(height: 20),

          // Volume Slider
          ValueListenableBuilder<double>(
            valueListenable: service.volumeNotifier,
            builder: (context, volume, _) {
              return Container(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                decoration: BoxDecoration(
                  color: Colors.white.withValues(alpha: 0.05),
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(color: Colors.white.withValues(alpha: 0.06)),
                ),
                child: Row(
                  children: [
                    const Icon(Icons.volume_down_rounded, color: Colors.white54, size: 20),
                    Expanded(
                      child: Slider(
                        value: volume,
                        activeColor: const Color(0xFF64B5F6),
                        inactiveColor: Colors.white12,
                        onChanged: (val) => service.setVolume(val),
                      ),
                    ),
                    Text(
                      '${(volume * 100).toInt()}%',
                      style: GoogleFonts.spaceMono(
                        color: const Color(0xFF64B5F6),
                        fontSize: 12,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ],
                ),
              );
            },
          ),
          const SizedBox(height: 16),

          // Soundscape Grid
          ValueListenableBuilder<AmbientType?>(
            valueListenable: service.activeTypeNotifier,
            builder: (context, activeType, _) {
              return Column(
                children: service.soundscapes.map((scape) {
                  final isActive = activeType == scape.type;
                  return Container(
                    margin: const EdgeInsets.only(bottom: 8),
                    decoration: BoxDecoration(
                      color: isActive
                          ? const Color(0xFF64B5F6).withValues(alpha: 0.12)
                          : Colors.white.withValues(alpha: 0.04),
                      borderRadius: BorderRadius.circular(16),
                      border: Border.all(
                        color: isActive
                            ? const Color(0xFF64B5F6).withValues(alpha: 0.4)
                            : Colors.white.withValues(alpha: 0.06),
                        width: isActive ? 1.2 : 0.8,
                      ),
                    ),
                    child: Material(
                      color: Colors.transparent,
                      child: InkWell(
                        onTap: () {
                          AppHaptics.medium();
                          service.selectAndPlay(scape.type);
                        },
                        borderRadius: BorderRadius.circular(16),
                        child: Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                          child: Row(
                            children: [
                              Text(scape.icon, style: const TextStyle(fontSize: 22)),
                              const SizedBox(width: 14),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      scape.title,
                                      style: GoogleFonts.outfit(
                                        color: Colors.white,
                                        fontSize: 14,
                                        fontWeight: FontWeight.w600,
                                      ),
                                    ),
                                    Text(
                                      scape.description,
                                      style: GoogleFonts.outfit(
                                        color: Colors.white54,
                                        fontSize: 11,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                              if (isActive)
                                Container(
                                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                                  decoration: BoxDecoration(
                                    color: const Color(0xFF64B5F6).withValues(alpha: 0.2),
                                    borderRadius: BorderRadius.circular(8),
                                  ),
                                  child: Text(
                                    'ACTIVE',
                                    style: GoogleFonts.spaceMono(
                                      color: const Color(0xFF64B5F6),
                                      fontSize: 10,
                                      fontWeight: FontWeight.bold,
                                    ),
                                  ),
                                ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  );
                }).toList(),
              );
            },
          ),
        ],
      ),
    );
  }
}
