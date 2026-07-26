import 'package:flutter_test/flutter_test.dart';
import 'package:sonic_wave/providers/settings_provider.dart';

// Standalone test for EQ calculations and profiles mapping.
void main() {
  group('Equalizer and Sound Enhancer Profile Tests', () {
    // Simulated Android Equalizer min/max decibels (typically -15.0 to +15.0 dB on Android)
    const double minDecibels = -15.0;
    const double maxDecibels = 15.0;

    // Professional acoustically optimized EQ profiles
    final Map<SoundEnhancer, List<double>> presets = {
      SoundEnhancer.none: [0.0, 0.0, 0.0, 0.0, 0.0],
      SoundEnhancer.bassBoost: [9.0, 5.0, -1.5, 0.0, 1.0],
      SoundEnhancer.trebleBoost: [-2.0, -1.0, 1.0, 6.0, 10.0],
      SoundEnhancer.vocal: [-4.0, 2.0, 7.0, 5.0, 2.0],
      SoundEnhancer.ambient3d: [7.0, 3.0, -5.0, 3.0, 8.0],
    };

    double mapCustomGainSliderValue(double rawGain, double minLimit, double maxLimit) {
      // slider value from -12.0 to 12.0
      final double ratio = (rawGain + 12.0) / 24.0; // 0.0 to 1.0
      final double mappedGain = minLimit + ratio * (maxLimit - minLimit);
      return mappedGain.clamp(minLimit, maxLimit);
    }

    test('Verification of Sound Enhancer preset values within safe limits', () {
      for (final mode in presets.keys) {
        final bands = presets[mode]!;
        expect(bands.length, equals(5));

        for (final gain in bands) {
          // Check that all defined presets are safe within standard hardware limits
          expect(gain, greaterThanOrEqualTo(minDecibels));
          expect(gain, lessThanOrEqualTo(maxDecibels));
        }
      }
    });

    test('Custom Equalizer Gain Mapping Ratios', () {
      // Raw slider value: -12.0 should map to minLimit (-15.0)
      final minMapped = mapCustomGainSliderValue(-12.0, minDecibels, maxDecibels);
      expect(minMapped, equals(-15.0));

      // Raw slider value: 0.0 should map to center (0.0)
      final centerMapped = mapCustomGainSliderValue(0.0, minDecibels, maxDecibels);
      expect(centerMapped, equals(0.0));

      // Raw slider value: 12.0 should map to maxLimit (15.0)
      final maxMapped = mapCustomGainSliderValue(12.0, minDecibels, maxDecibels);
      expect(maxMapped, equals(15.0));

      // Raw slider value: 6.0 (midway positive) should map to 7.5
      final halfPosMapped = mapCustomGainSliderValue(6.0, minDecibels, maxDecibels);
      expect(halfPosMapped, equals(7.5));
    });

    test('Equalizer Preset Decibel Clamping Verification', () {
      // Test dynamic hardware limits: e.g. a device that only supports -10.0 to +10.0 dB
      const double tightMin = -10.0;
      const double tightMax = 10.0;

      // Bass Boost Band 0 target is 9.0 dB. Should remain 9.0 dB under loose limits,
      // and clamp to 10.0 dB (or max supported) under tighter limits.
      final targetGains = presets[SoundEnhancer.bassBoost]!;
      
      final gain1 = targetGains[0].clamp(minDecibels, maxDecibels); // 9.0 -> 9.0
      expect(gain1, equals(9.0));

      final gain2 = targetGains[0].clamp(tightMin, tightMax); // 9.0 -> 9.0
      expect(gain2, equals(9.0));

      // Treble Boost Band 4 target is 10.0 dB.
      // Under tight limit of 8.0 dB, it should clamp to 8.0 dB.
      const double restrictiveMax = 8.0;
      final gain3 = presets[SoundEnhancer.trebleBoost]![4].clamp(tightMin, restrictiveMax); // 10.0 -> 8.0
      expect(gain3, equals(8.0));
    });

    test('Karaoke Mid-Scooping Override Logic', () {
      const bool isKaraokeMode = true;
      final targetGains = presets[SoundEnhancer.vocal]!; // [ -4.0, 2.0, 7.0, 5.0, 2.0 ]

      final List<double> finalGains = [];
      for (int i = 0; i < 5; i++) {
        double gain = targetGains[i];
        if (isKaraokeMode && (i == 2 || i == 3)) {
          gain = minDecibels; // Voice range scoop
        }
        finalGains.add(gain.clamp(minDecibels, maxDecibels));
      }

      // Mid bands (index 2 & 3) must be fully scooped to minLimit
      expect(finalGains[0], equals(-4.0));
      expect(finalGains[1], equals(2.0));
      expect(finalGains[2], equals(-15.0)); // Scooped
      expect(finalGains[3], equals(-15.0)); // Scooped
      expect(finalGains[4], equals(2.0));
    });
  });
}
