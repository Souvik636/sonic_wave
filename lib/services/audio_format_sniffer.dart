import 'dart:async';
import 'dart:io';
import 'package:audio_metadata_reader/audio_metadata_reader.dart';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

/// Sniffed audio format and stream offset details.
class SniffedAudio {
  final String format; // 'mp3', 'm4a', 'flac', 'ogg', 'wav', 'aac'
  final int offset;
  final int? xorKey;
  final bool isObfuscated;

  const SniffedAudio({
    required this.format,
    this.offset = 0,
    this.xorKey,
    this.isObfuscated = false,
  });

  bool get needsUnwrapping => offset > 0 || xorKey != null;
}

/// Advanced Binary Sniffer & De-obfuscator for Encrypted/Containerized Local Audio.
class AudioFormatSniffer {
  static final AudioFormatSniffer _instance = AudioFormatSniffer._internal();
  factory AudioFormatSniffer() => _instance;
  AudioFormatSniffer._internal();

  Directory? _unwrappedDir;

  Future<Directory> _getUnwrapDir() async {
    if (_unwrappedDir != null) return _unwrappedDir!;
    final temp = await getTemporaryDirectory();
    final dir = Directory('${temp.path}${Platform.pathSeparator}unwrapped_audio');
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    _unwrappedDir = dir;
    return dir;
  }

  /// Sniff binary headers to detect true audio format, frame offset, and encryption mask.
  SniffedAudio sniffFile(File file) {
    try {
      if (!file.existsSync()) return const SniffedAudio(format: 'mp3');
      final stat = file.statSync();
      if (stat.size < 64) return const SniffedAudio(format: 'mp3');

      final raf = file.openSync(mode: FileMode.read);
      final readLen = stat.size > 65536 ? 65536 : stat.size;
      final bytes = raf.readSync(readLen);
      raf.closeSync();

      return sniffBytes(bytes);
    } catch (_) {
      return const SniffedAudio(format: 'mp3');
    }
  }

  /// Sniff byte buffer to find sync markers and offsets.
  SniffedAudio sniffBytes(Uint8List bytes) {
    if (bytes.length < 16) return const SniffedAudio(format: 'mp3');

    // 1. Direct offset 0 check
    if (bytes[0] == 0x1A && bytes[1] == 0x45 && bytes[2] == 0xDF && bytes[3] == 0xA3) {
      return const SniffedAudio(format: 'webm', offset: 0); // EBML (WebM/Matroska)
    }
    if (bytes[0] == 0x49 && bytes[1] == 0x44 && bytes[2] == 0x33) {
      return const SniffedAudio(format: 'mp3', offset: 0); // ID3v2
    }
    if (bytes[0] == 0x66 && bytes[1] == 0x4C && bytes[2] == 0x61 && bytes[3] == 0x43) {
      return const SniffedAudio(format: 'flac', offset: 0); // fLaC
    }
    if (bytes[0] == 0x4F && bytes[1] == 0x67 && bytes[2] == 0x67 && bytes[3] == 0x53) {
      return const SniffedAudio(format: 'ogg', offset: 0); // OggS
    }
    if (bytes[0] == 0x52 && bytes[1] == 0x49 && bytes[2] == 0x46 && bytes[3] == 0x46) {
      return const SniffedAudio(format: 'wav', offset: 0); // RIFF
    }
    if (bytes.length >= 8 &&
        bytes[4] == 0x66 &&
        bytes[5] == 0x74 &&
        bytes[6] == 0x79 &&
        bytes[7] == 0x70) {
      return const SniffedAudio(format: 'm4a', offset: 0); // ftyp
    }
    if ((bytes[0] == 0xFF && (bytes[1] & 0xFE) == 0xFA) ||
        (bytes[0] == 0xFF && (bytes[1] & 0xFE) == 0xF2)) {
      return const SniffedAudio(format: 'mp3', offset: 0); // Direct MP3 frame
    }
    if (bytes[0] == 0xFF && (bytes[1] & 0xF6) == 0xF0) {
      return const SniffedAudio(format: 'aac', offset: 0); // AAC ADTS
    }

    // 2. Scan for Offset Sync Markers (Header Wrapper / Encryption Offset)
    for (int i = 1; i < bytes.length - 12; i++) {
      // ID3v2 Header
      if (bytes[i] == 0x49 && bytes[i + 1] == 0x44 && bytes[i + 2] == 0x33) {
        return SniffedAudio(format: 'mp3', offset: i, isObfuscated: true);
      }
      // MP4 / M4A Atom
      if (bytes[i] == 0x66 &&
          bytes[i + 1] == 0x74 &&
          bytes[i + 2] == 0x79 &&
          bytes[i + 3] == 0x70 &&
          i >= 4) {
        return SniffedAudio(format: 'm4a', offset: i - 4, isObfuscated: true);
      }
      // FLAC
      if (bytes[i] == 0x66 &&
          bytes[i + 1] == 0x4C &&
          bytes[i + 2] == 0x61 &&
          bytes[i + 3] == 0x43) {
        return SniffedAudio(format: 'flac', offset: i, isObfuscated: true);
      }
      // Ogg Vorbis/Opus
      if (bytes[i] == 0x4F &&
          bytes[i + 1] == 0x67 &&
          bytes[i + 2] == 0x67 &&
          bytes[i + 3] == 0x53) {
        return SniffedAudio(format: 'ogg', offset: i, isObfuscated: true);
      }
      // WAV
      if (bytes[i] == 0x52 &&
          bytes[i + 1] == 0x49 &&
          bytes[i + 2] == 0x46 &&
          bytes[i + 3] == 0x46) {
        return SniffedAudio(format: 'wav', offset: i, isObfuscated: true);
      }
      // MP3 Sync Frame with validation
      if (bytes[i] == 0xFF && (bytes[i + 1] & 0xE0) == 0xE0) {
        final layer = (bytes[i + 1] >> 1) & 0x03;
        final bitrateIdx = (bytes[i + 2] >> 4) & 0x0F;
        if (layer != 0 && bitrateIdx != 0 && bitrateIdx != 15) {
          return SniffedAudio(format: 'mp3', offset: i, isObfuscated: true);
        }
      }
    }

    // 3. Scan for Common Single-Byte XOR Encryption Masks (e.g. offline cached media)
    const commonXorKeys = [0x55, 0xAA, 0x88, 0x5A, 0xA5, 0x66, 0x77, 0xFF, 0x11, 0x22, 0x33, 0x44];
    for (final k in commonXorKeys) {
      if ((bytes[0] ^ k) == 0x49 && (bytes[1] ^ k) == 0x44 && (bytes[2] ^ k) == 0x33) {
        return SniffedAudio(format: 'mp3', offset: 0, xorKey: k, isObfuscated: true);
      }
      if ((bytes[0] ^ k) == 0x66 && (bytes[1] ^ k) == 0x4C && (bytes[2] ^ k) == 0x61 && (bytes[3] ^ k) == 0x43) {
        return SniffedAudio(format: 'flac', offset: 0, xorKey: k, isObfuscated: true);
      }
      if ((bytes[0] ^ k) == 0x4F && (bytes[1] ^ k) == 0x67 && (bytes[2] ^ k) == 0x67 && (bytes[3] ^ k) == 0x53) {
        return SniffedAudio(format: 'ogg', offset: 0, xorKey: k, isObfuscated: true);
      }
      if ((bytes[0] ^ k) == 0x52 && (bytes[1] ^ k) == 0x49 && (bytes[2] ^ k) == 0x46 && (bytes[3] ^ k) == 0x46) {
        return SniffedAudio(format: 'wav', offset: 0, xorKey: k, isObfuscated: true);
      }
      if (bytes.length >= 8 &&
          (bytes[4] ^ k) == 0x66 &&
          (bytes[5] ^ k) == 0x74 &&
          (bytes[6] ^ k) == 0x79 &&
          (bytes[7] ^ k) == 0x70) {
        return SniffedAudio(format: 'm4a', offset: 0, xorKey: k, isObfuscated: true);
      }
    }

    return const SniffedAudio(format: 'mp3', offset: 0);
  }

  /// Transparently returns a playable file for AudioHandler.
  /// If the file is clean, returns [sourceFile] immediately.
  /// If obfuscated/header-wrapped, extracts a clean audio stream into app cache.
  Future<File> getPlayableFile(File sourceFile) async {
    try {
      if (!await sourceFile.exists()) return sourceFile;
      final sniffed = sniffFile(sourceFile);
      if (!sniffed.needsUnwrapping) {
        return sourceFile;
      }

      final stat = await sourceFile.stat();
      final hash = '${sourceFile.path.hashCode.toUnsigned(32).toRadixString(16)}_${stat.size}_${stat.modified.millisecondsSinceEpoch}';
      final unwrapDir = await _getUnwrapDir();
      final targetFile = File('${unwrapDir.path}${Platform.pathSeparator}$hash.${sniffed.format}');

      if (await targetFile.exists() && (await targetFile.length()) > 0) {
        return targetFile;
      }

      // Stream copy / decode from offset
      final reader = await sourceFile.open(mode: FileMode.read);
      final writer = await targetFile.open(mode: FileMode.write);

      if (sniffed.offset > 0) {
        await reader.setPosition(sniffed.offset);
      }

      final buffer = Uint8List(65536);
      int readBytes = 0;
      final k = sniffed.xorKey;

      while ((readBytes = await reader.readInto(buffer)) > 0) {
        if (k != null) {
          for (int i = 0; i < readBytes; i++) {
            buffer[i] ^= k;
          }
        }
        await writer.writeFrom(buffer, 0, readBytes);
      }

      await reader.close();
      await writer.close();

      debugPrint('[AudioSniffer] Unwrapped obfuscated audio (${sniffed.format}, offset: ${sniffed.offset}, xor: ${sniffed.xorKey}): ${sourceFile.path} -> ${targetFile.path}');
      return targetFile;
    } catch (e) {
      debugPrint('[AudioSniffer] Failed to unwrap audio file: $e');
      return sourceFile;
    }
  }

  /// Parse metadata from potentially encrypted/obfuscated audio file.
  Future<AudioMetadata?> readMetadataResilient(File sourceFile) async {
    try {
      // 1. Try direct parser
      return readMetadata(sourceFile, getImage: true);
    } catch (_) {
      // 2. If direct parser throws (unsupported wrapper/encryption), unwrap and parse
      try {
        final cleanFile = await getPlayableFile(sourceFile);
        if (cleanFile.path != sourceFile.path) {
          return readMetadata(cleanFile, getImage: true);
        }
      } catch (_) {}
    }
    return null;
  }
}
