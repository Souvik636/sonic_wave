import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/foundation.dart';

/// Utility to write ID3v2.3 metadata and embedded APIC cover art frames
/// directly into MP3 audio files.
class ID3TagWriter {
  ID3TagWriter._();

  /// Embed cover artwork (and optional title/artist metadata) into an MP3 file.
  ///
  /// Returns `true` if tags were successfully written or attached.
  static Future<bool> embedCoverArt({
    required File audioFile,
    required Uint8List imageBytes,
    String mimeType = 'image/jpeg',
    String? title,
    String? artist,
  }) async {
    if (!await audioFile.exists() || imageBytes.isEmpty) return false;

    try {
      final originalBytes = await audioFile.readAsBytes();
      if (originalBytes.length < 10) return false;

      // Container Safety Check: Do NOT prepend ID3 tags to non-MP3 files (M4A, WebM, OGG, FLAC)
      // MP4/M4A starts with 'ftyp' at offset 4 (0x66 0x74 0x79 0x70)
      // WebM starts with 0x1A 0x45 0xDF 0xA3 (EBML)
      // OGG starts with 'OggS' (0x4F 0x67 0x67 0x53)
      // FLAC starts with 'fLaC' (0x66 0x4C 0x61 0x43)
      if (originalBytes.length >= 8) {
        final isM4a = originalBytes[4] == 0x66 && originalBytes[5] == 0x74 && originalBytes[6] == 0x79 && originalBytes[7] == 0x70;
        final isWebm = originalBytes[0] == 0x1A && originalBytes[1] == 0x45 && originalBytes[2] == 0xDF && originalBytes[3] == 0xA3;
        final isOgg = originalBytes[0] == 0x4F && originalBytes[1] == 0x67 && originalBytes[2] == 0x67 && originalBytes[3] == 0x53;
        final isFlac = originalBytes[0] == 0x66 && originalBytes[1] == 0x4C && originalBytes[2] == 0x61 && originalBytes[3] == 0x43;
        if (isM4a || isWebm || isOgg || isFlac) {
          debugPrint('[ID3TagWriter] Skipping ID3 injection for non-MP3 container format (M4A/WebM/OGG/FLAC).');
          return false;
        }
      }

      final id3v2Header = _buildID3v2Tag(
        imageBytes: imageBytes,
        mimeType: mimeType,
        title: title,
        artist: artist,
      );

      // Check if original file already has an ID3v2 tag at the start
      int audioDataOffset = 0;
      if (originalBytes[0] == 0x49 && // 'I'
          originalBytes[1] == 0x44 && // 'D'
          originalBytes[2] == 0x33) { // '3'
        // Existing ID3v2 tag size calculation (synchsafe int)
        final existingTagSize = (originalBytes[6] & 0x7F) << 21 |
            (originalBytes[7] & 0x7F) << 14 |
            (originalBytes[8] & 0x7F) << 7 |
            (originalBytes[9] & 0x7F);
        audioDataOffset = 10 + existingTagSize;
      }

      final builder = BytesBuilder(copy: false);
      builder.add(id3v2Header);

      if (audioDataOffset < originalBytes.length) {
        builder.add(Uint8List.sublistView(originalBytes, audioDataOffset));
      } else {
        builder.add(originalBytes);
      }

      await audioFile.writeAsBytes(builder.takeBytes(), flush: true);
      return true;
    } catch (e) {
      debugPrint('[ID3TagWriter] Error embedding cover art: $e');
      return false;
    }
  }

  /// Construct an ID3v2.3 tag header and frame payloads.
  static Uint8List _buildID3v2Tag({
    required Uint8List imageBytes,
    required String mimeType,
    String? title,
    String? artist,
  }) {
    final frames = BytesBuilder(copy: false);

    // 1. APIC Frame (Attached Picture)
    final apicPayload = BytesBuilder(copy: false);
    apicPayload.addByte(0x00); // ISO-8859-1 encoding
    apicPayload.add(latin1.encode(mimeType));
    apicPayload.addByte(0x00); // MIME null terminator
    apicPayload.addByte(0x03); // Picture type: 3 = Cover Front
    apicPayload.addByte(0x00); // Description null terminator
    apicPayload.add(imageBytes);

    _addFrame(frames, 'APIC', apicPayload.takeBytes());

    // 2. TIT2 Frame (Title)
    if (title != null && title.isNotEmpty) {
      final titlePayload = BytesBuilder(copy: false);
      titlePayload.addByte(0x00); // ISO-8859-1
      titlePayload.add(latin1.encode(title));
      _addFrame(frames, 'TIT2', titlePayload.takeBytes());
    }

    // 3. TPE1 Frame (Artist)
    if (artist != null && artist.isNotEmpty) {
      final artistPayload = BytesBuilder(copy: false);
      artistPayload.addByte(0x00); // ISO-8859-1
      artistPayload.add(latin1.encode(artist));
      _addFrame(frames, 'TPE1', artistPayload.takeBytes());
    }

    final frameBytes = frames.takeBytes();
    final tagSize = frameBytes.length;

    // ID3v2.3 Header (10 bytes)
    final header = Uint8List(10);
    header[0] = 0x49; // 'I'
    header[1] = 0x44; // 'D'
    header[2] = 0x33; // '3'
    header[3] = 0x03; // Version 2.3.0
    header[4] = 0x00; // Revision
    header[5] = 0x00; // Flags

    // Encoded synchsafe integer size (4 bytes)
    header[6] = (tagSize >> 21) & 0x7F;
    header[7] = (tagSize >> 14) & 0x7F;
    header[8] = (tagSize >> 7) & 0x7F;
    header[9] = tagSize & 0x7F;

    final result = BytesBuilder(copy: false);
    result.add(header);
    result.add(frameBytes);
    return result.takeBytes();
  }

  static void _addFrame(BytesBuilder builder, String frameId, Uint8List payload) {
    builder.add(ascii.encode(frameId));

    // Frame size (4 bytes - big endian uint32 for ID3v2.3)
    final len = payload.length;
    builder.addByte((len >> 24) & 0xFF);
    builder.addByte((len >> 16) & 0xFF);
    builder.addByte((len >> 8) & 0xFF);
    builder.addByte(len & 0xFF);

    // Flags (2 bytes)
    builder.addByte(0x00);
    builder.addByte(0x00);

    // Payload
    builder.add(payload);
  }
}
