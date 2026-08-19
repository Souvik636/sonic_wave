import 'dart:convert';
import 'dart:typed_data';

/// Pure Dart implementation of DES-ECB decryption for JioSaavn encrypted media URLs.
/// JioSaavn uses standard 64-bit DES in Electronic Codebook (ECB) mode with PKCS5/PKCS7 unpadding.
/// Secret key used by JioSaavn: "38346591"
class DesCipher {
  static const List<int> _ip = [
    58, 50, 42, 34, 26, 18, 10, 2,
    60, 52, 44, 36, 28, 20, 12, 4,
    62, 54, 46, 38, 30, 22, 14, 6,
    64, 56, 48, 40, 32, 24, 16, 8,
    57, 49, 41, 33, 25, 17, 9, 1,
    59, 51, 43, 35, 27, 19, 11, 3,
    61, 53, 45, 37, 29, 21, 13, 5,
    63, 55, 47, 39, 31, 23, 15, 7,
  ];

  static const List<int> _fp = [
    40, 8, 48, 16, 56, 24, 64, 32,
    39, 7, 47, 15, 55, 23, 63, 31,
    38, 6, 46, 14, 54, 22, 62, 30,
    37, 5, 45, 13, 53, 21, 61, 29,
    36, 4, 44, 12, 52, 20, 60, 28,
    35, 3, 43, 11, 51, 19, 59, 27,
    34, 2, 42, 10, 50, 18, 58, 26,
    33, 1, 41, 9, 49, 17, 57, 25,
  ];

  static const List<int> _pc1 = [
    57, 49, 41, 33, 25, 17, 9,
    1, 58, 50, 42, 34, 26, 18,
    10, 2, 59, 51, 43, 35, 27,
    19, 11, 3, 60, 52, 44, 36,
    63, 55, 47, 39, 31, 23, 15,
    7, 62, 54, 46, 38, 30, 22,
    14, 6, 61, 53, 45, 37, 29,
    21, 13, 5, 28, 20, 12, 4,
  ];

  static const List<int> _pc2 = [
    14, 17, 11, 24, 1, 5,
    3, 28, 15, 6, 21, 10,
    23, 19, 12, 4, 26, 8,
    16, 7, 27, 20, 13, 2,
    41, 52, 31, 37, 47, 55,
    30, 40, 51, 45, 33, 48,
    44, 49, 39, 56, 34, 53,
    46, 42, 50, 36, 29, 32,
  ];

  static const List<int> _shifts = [1, 1, 2, 2, 2, 2, 2, 2, 1, 2, 2, 2, 2, 2, 2, 1];

  static const List<int> _e = [
    32, 1, 2, 3, 4, 5,
    4, 5, 6, 7, 8, 9,
    8, 9, 10, 11, 12, 13,
    12, 13, 14, 15, 16, 17,
    16, 17, 18, 19, 20, 21,
    20, 21, 22, 23, 24, 25,
    24, 25, 26, 27, 28, 29,
    28, 29, 30, 31, 32, 1,
  ];

  static const List<int> _p = [
    16, 7, 20, 21,
    29, 12, 28, 17,
    1, 15, 23, 26,
    5, 18, 31, 10,
    2, 8, 24, 14,
    32, 27, 3, 9,
    19, 13, 30, 6,
    22, 11, 4, 25,
  ];

  static const List<List<List<int>>> _sBoxes = [
    // S1
    [
      [14, 4, 13, 1, 2, 15, 11, 8, 3, 10, 6, 12, 5, 9, 0, 7],
      [0, 15, 7, 4, 14, 2, 13, 1, 10, 6, 12, 11, 9, 5, 3, 8],
      [4, 1, 14, 8, 13, 6, 2, 11, 15, 12, 9, 7, 3, 10, 5, 0],
      [15, 12, 8, 2, 4, 9, 1, 7, 5, 11, 3, 14, 10, 0, 6, 13],
    ],
    // S2
    [
      [15, 1, 8, 14, 6, 11, 3, 4, 9, 7, 2, 13, 12, 0, 5, 10],
      [3, 13, 4, 7, 15, 2, 8, 14, 12, 0, 1, 10, 6, 9, 11, 5],
      [0, 14, 7, 11, 10, 4, 13, 1, 5, 8, 12, 6, 9, 3, 2, 15],
      [13, 8, 10, 1, 3, 15, 4, 2, 11, 6, 7, 12, 0, 5, 14, 9],
    ],
    // S3
    [
      [10, 0, 9, 14, 6, 3, 15, 5, 1, 13, 12, 7, 11, 4, 2, 8],
      [13, 7, 0, 9, 3, 4, 6, 10, 2, 8, 5, 14, 12, 11, 15, 1],
      [13, 6, 4, 9, 8, 15, 3, 0, 11, 1, 2, 12, 5, 10, 14, 7],
      [1, 10, 13, 0, 6, 9, 8, 7, 4, 15, 14, 3, 11, 5, 2, 12],
    ],
    // S4
    [
      [7, 13, 14, 3, 0, 6, 9, 10, 1, 2, 8, 5, 11, 12, 4, 15],
      [13, 8, 11, 5, 6, 15, 0, 3, 4, 7, 2, 12, 1, 10, 14, 9],
      [10, 6, 9, 0, 12, 11, 7, 13, 15, 1, 3, 14, 5, 2, 8, 4],
      [3, 15, 0, 6, 10, 1, 13, 8, 9, 4, 5, 11, 12, 7, 2, 14],
    ],
    // S5
    [
      [2, 12, 4, 1, 7, 10, 11, 6, 8, 5, 3, 15, 13, 0, 14, 9],
      [14, 11, 2, 12, 4, 7, 13, 1, 5, 0, 15, 10, 3, 9, 8, 6],
      [4, 2, 1, 11, 10, 13, 7, 8, 15, 9, 12, 5, 6, 3, 0, 14],
      [11, 8, 12, 7, 1, 14, 2, 13, 6, 15, 0, 9, 10, 4, 5, 3],
    ],
    // S6
    [
      [12, 1, 10, 15, 9, 2, 6, 8, 0, 13, 3, 4, 14, 7, 5, 11],
      [10, 15, 4, 2, 7, 12, 9, 5, 6, 1, 13, 14, 0, 11, 3, 8],
      [9, 14, 15, 5, 2, 8, 12, 3, 7, 0, 4, 10, 1, 13, 11, 6],
      [4, 3, 2, 12, 9, 5, 15, 10, 11, 14, 1, 7, 6, 0, 8, 13],
    ],
    // S7
    [
      [4, 11, 2, 14, 15, 0, 8, 13, 3, 12, 9, 7, 5, 10, 6, 1],
      [13, 0, 11, 7, 4, 9, 1, 10, 14, 3, 5, 12, 2, 15, 8, 6],
      [1, 4, 11, 13, 12, 3, 7, 14, 10, 15, 6, 8, 0, 5, 9, 2],
      [6, 11, 13, 8, 1, 4, 10, 7, 9, 5, 0, 15, 14, 2, 3, 12],
    ],
    // S8
    [
      [13, 2, 8, 4, 6, 15, 11, 1, 10, 9, 3, 14, 5, 0, 12, 7],
      [1, 15, 13, 8, 10, 3, 7, 4, 12, 5, 6, 11, 0, 14, 9, 2],
      [7, 11, 4, 1, 9, 12, 14, 2, 0, 6, 10, 13, 15, 3, 5, 8],
      [2, 1, 14, 7, 4, 10, 8, 13, 15, 12, 9, 0, 3, 5, 6, 11],
    ],
  ];

  static List<List<int>> _generateSubkeys(List<int> keyBytes) {
    final keyBits = _bytesToBits(keyBytes);
    final pc1Bits = List<int>.generate(56, (i) => keyBits[_pc1[i] - 1]);
    var c = pc1Bits.sublist(0, 28);
    var d = pc1Bits.sublist(28, 56);

    final subkeys = <List<int>>[];
    for (int round = 0; round < 16; round++) {
      final shift = _shifts[round];
      c = [...c.sublist(shift), ...c.sublist(0, shift)];
      d = [...d.sublist(shift), ...d.sublist(0, shift)];
      final cd = [...c, ...d];
      final subkey = List<int>.generate(48, (i) => cd[_pc2[i] - 1]);
      subkeys.add(subkey);
    }
    return subkeys;
  }

  static List<int> _bytesToBits(List<int> bytes) {
    final bits = List<int>.filled(bytes.length * 8, 0);
    for (int i = 0; i < bytes.length; i++) {
      final b = bytes[i];
      for (int j = 0; j < 8; j++) {
        bits[i * 8 + j] = (b >> (7 - j)) & 1;
      }
    }
    return bits;
  }

  static Uint8List _bitsToBytes(List<int> bits) {
    final bytes = Uint8List(bits.length ~/ 8);
    for (int i = 0; i < bytes.length; i++) {
      int b = 0;
      for (int j = 0; j < 8; j++) {
        b = (b << 1) | bits[i * 8 + j];
      }
      bytes[i] = b;
    }
    return bytes;
  }

  static List<int> _feistel(List<int> r, List<int> subkey) {
    // Expansion
    final expanded = List<int>.generate(48, (i) => r[_e[i] - 1]);
    // XOR with subkey
    final xored = List<int>.generate(48, (i) => expanded[i] ^ subkey[i]);

    // S-Boxes substitution
    final sboxOut = <int>[];
    for (int i = 0; i < 8; i++) {
      final chunk = xored.sublist(i * 6, (i + 1) * 6);
      final row = (chunk[0] << 1) | chunk[5];
      final col = (chunk[1] << 3) | (chunk[2] << 2) | (chunk[3] << 1) | chunk[4];
      final val = _sBoxes[i][row][col];
      for (int j = 3; j >= 0; j--) {
        sboxOut.add((val >> j) & 1);
      }
    }

    // Permutation
    return List<int>.generate(32, (i) => sboxOut[_p[i] - 1]);
  }

  static List<int> _decryptBlock(List<int> blockBits, List<List<int>> subkeys) {
    final ipBits = List<int>.generate(64, (i) => blockBits[_ip[i] - 1]);
    var l = ipBits.sublist(0, 32);
    var r = ipBits.sublist(32, 64);

    // Decryption uses subkeys in reverse order (15 down to 0)
    for (int round = 15; round >= 0; round--) {
      final f = _feistel(r, subkeys[round]);
      final nextL = r;
      final nextR = List<int>.generate(32, (i) => l[i] ^ f[i]);
      l = nextL;
      r = nextR;
    }

    final preOutput = [...r, ...l];
    return List<int>.generate(64, (i) => preOutput[_fp[i] - 1]);
  }

  /// Decrypt Base64 encoded ciphertext using DES-ECB with secret key (default JioSaavn key: "38346591").
  static String? decryptJioSaavnMediaUrl(String base64Ciphertext, {String key = '38346591'}) {
    try {
      final ciphertextBytes = base64Decode(base64Ciphertext.trim());
      if (ciphertextBytes.isEmpty || ciphertextBytes.length % 8 != 0) return null;

      final keyBytes = utf8.encode(key);
      final subkeys = _generateSubkeys(keyBytes);

      final decryptedBytes = <int>[];
      for (int offset = 0; offset < ciphertextBytes.length; offset += 8) {
        final block = ciphertextBytes.sublist(offset, offset + 8);
        final blockBits = _bytesToBits(block);
        final decryptedBits = _decryptBlock(blockBits, subkeys);
        decryptedBytes.addAll(_bitsToBytes(decryptedBits));
      }

      // Remove PKCS5/PKCS7 padding
      if (decryptedBytes.isEmpty) return null;
      final padLen = decryptedBytes.last;
      if (padLen > 0 && padLen <= 8 && decryptedBytes.length >= padLen) {
        bool validPad = true;
        for (int i = decryptedBytes.length - padLen; i < decryptedBytes.length; i++) {
          if (decryptedBytes[i] != padLen) {
            validPad = false;
            break;
          }
        }
        if (validPad) {
          decryptedBytes.removeRange(decryptedBytes.length - padLen, decryptedBytes.length);
        }
      }

      final url = utf8.decode(decryptedBytes).trim();
      if (url.startsWith('http')) {
        // Upgrade quality to 320kbps if formatted as standard Saavn CDN link
        return url
            .replaceFirst('_96.mp4', '_320.mp4')
            .replaceFirst('_160.mp4', '_320.mp4')
            .replaceFirst('_96.mp3', '_320.mp3')
            .replaceFirst('_160.mp3', '_320.mp3');
      }
      return null;
    } catch (_) {
      return null;
    }
  }
}
