import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sonic_wave/providers/settings_provider.dart';
import 'package:sonic_wave/services/local_metadata_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('Theme Accents & Auto-Rotation Tests', () {
    test('SettingsProvider contains 12 manual accents + system', () {
      expect(ThemeAccent.values.length, equals(13));
      expect(ThemeAccent.values.contains(ThemeAccent.arctic), isTrue);
      expect(ThemeAccent.values.contains(ThemeAccent.crimson), isTrue);
      expect(ThemeAccent.values.contains(ThemeAccent.amethyst), isTrue);
    });

    test('Arctic, Ruby (Crimson), and Amethyst have vibrant canonical colors', () {
      expect(SettingsProvider.accentColorOf(ThemeAccent.arctic), equals(const Color(0xFF00F2FE)));
      expect(SettingsProvider.accentColorOf(ThemeAccent.crimson), equals(const Color(0xFFFF1358)));
      expect(SettingsProvider.accentColorOf(ThemeAccent.amethyst), equals(const Color(0xFF9933FF)));
    });
  });

  group('Encoded Audio Title & Artist Cleaning Tests', () {
    test('Cleans percent-encoded filenames', () {
      expect(
        LocalMetadataService.cleanTitleFromFilename('Hotel%20California.mp3'),
        equals('Hotel California'),
      );
      expect(
        LocalMetadataService.cleanTitleFromFilename('01%20-%20Bohemian%20Rhapsody.flac'),
        equals('Bohemian Rhapsody'),
      );
    });

    test('Cleans track numbers, underscores, and video/quality tags', () {
      expect(
        LocalMetadataService.cleanTitleFromFilename('02_Queen_-_Don_t_Stop_Me_Now_[Official_Video].m4a'),
        equals('Don t Stop Me Now'),
      );
      expect(
        LocalMetadataService.cleanTitleFromFilename('04. Alan Walker - Faded (Lyrics) (320kbps).mp3'),
        equals('Faded'),
      );
    });

    test('Extracts artist from "Artist - Title" formatted filenames', () {
      expect(
        LocalMetadataService.cleanArtistFromFilename('Linkin Park - Numb.mp3'),
        equals('Linkin Park'),
      );
      expect(
        LocalMetadataService.cleanArtistFromFilename('Coldplay%20-%20Yellow.flac'),
        equals('Coldplay'),
      );
    });
  });
}
