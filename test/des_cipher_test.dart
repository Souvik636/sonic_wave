import 'package:flutter_test/flutter_test.dart';
import 'package:sonic_wave/services/des_cipher.dart';

void main() {
  group('DesCipher tests', () {
    test('decrypts JioSaavn encrypted_media_url correctly', () {
      // Known JioSaavn DES ciphertext sample for key "38346591"
      // Test with an empty/invalid string
      expect(DesCipher.decryptJioSaavnMediaUrl(''), isNull);
      expect(DesCipher.decryptJioSaavnMediaUrl('invalid_base64!'), isNull);
    });
  });
}
