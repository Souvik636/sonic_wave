import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:sonic_wave/services/audio_format_sniffer.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('AudioFormatSniffer Tests', () {
    final sniffer = AudioFormatSniffer();

    test('Sniffs clean MP3 ID3v2 header at offset 0', () {
      final bytes = Uint8List.fromList([
        0x49, 0x44, 0x33, 0x03, 0x00, 0x00, 0x00, 0x00, 0x00, 0x20,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00
      ]);
      final sniffed = sniffer.sniffBytes(bytes);
      expect(sniffed.format, equals('mp3'));
      expect(sniffed.offset, equals(0));
      expect(sniffed.isObfuscated, isFalse);
    });

    test('Sniffs clean FLAC header at offset 0', () {
      final bytes = Uint8List.fromList([
        0x66, 0x4C, 0x61, 0x43, 0x00, 0x00, 0x00, 0x22,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00
      ]);
      final sniffed = sniffer.sniffBytes(bytes);
      expect(sniffed.format, equals('flac'));
      expect(sniffed.offset, equals(0));
      expect(sniffed.isObfuscated, isFalse);
    });

    test('Sniffs offset-wrapped / encrypted audio file with prepended header bytes', () {
      // 32 dummy container bytes prepended to an ID3 header
      final dummyHeader = List<int>.filled(32, 0x7F);
      final id3Bytes = [
        0x49, 0x44, 0x33, 0x03, 0x00, 0x00, 0x00, 0x00, 0x00, 0x20,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00
      ];
      final fullBytes = Uint8List.fromList([...dummyHeader, ...id3Bytes]);

      final sniffed = sniffer.sniffBytes(fullBytes);
      expect(sniffed.format, equals('mp3'));
      expect(sniffed.offset, equals(32));
      expect(sniffed.isObfuscated, isTrue);
      expect(sniffed.needsUnwrapping, isTrue);
    });

    test('Sniffs XOR-obfuscated audio stream mask', () {
      const xorKey = 0x55;
      final rawFlac = [
        0x66, 0x4C, 0x61, 0x43, 0x00, 0x00, 0x00, 0x22,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00
      ];
      final masked = Uint8List.fromList(rawFlac.map((b) => b ^ xorKey).toList());

      final sniffed = sniffer.sniffBytes(masked);
      expect(sniffed.format, equals('flac'));
      expect(sniffed.xorKey, equals(0x55));
      expect(sniffed.isObfuscated, isTrue);
      expect(sniffed.needsUnwrapping, isTrue);
    });
  });
}
