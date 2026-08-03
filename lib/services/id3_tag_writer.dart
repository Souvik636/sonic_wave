import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/foundation.dart';

/// Utility to write metadata and embedded cover art frames
/// directly into MP3 (ID3v2.3), M4A (MP4 covr atom), and FLAC (PICTURE block) audio files.
class ID3TagWriter {
  ID3TagWriter._();

  static const List<int> _apicMarker = [0x41, 0x50, 0x49, 0x43]; // 'APIC'
  static const List<int> _covrMarker = [0x63, 0x6F, 0x76, 0x72]; // 'covr'
  static const List<int> _dataMarker = [0x64, 0x61, 0x74, 0x61]; // 'data'

  /// Bytes examined at each end of the file by [hasEmbeddedCover].
  static const int _coverProbeBytes = 512 * 1024;

  /// Whether [audioFile] already carries cover art inside the container.
  ///
  /// This is what decides whether a sidecar image is written at all. Artwork
  /// that lives in the file travels with it into every other player and every
  /// other device, so a second copy on disk is pure clutter — and on shared
  /// storage it is one more picture in the user's Gallery.
  ///
  /// BOTH ends of the file are probed. An MP4 `moov` box (which holds the
  /// `covr` atom) may sit at the front for faststart output or at the very
  /// back for a plain remux; scanning only the head reports "no artwork" for
  /// every non-faststart M4A and provokes a sidecar the file never needed.
  ///
  /// Conservative by construction: a false negative costs one redundant image,
  /// a false positive would lose the artwork entirely.
  static Future<bool> hasEmbeddedCover(File audioFile) async {
    try {
      final len = await audioFile.length();
      if (len < 16) return false;
      final raf = await audioFile.open();
      try {
        final headLen = len < _coverProbeBytes ? len : _coverProbeBytes;
        final head = await raf.read(headLen);
        if (head.length < 4) return false;

        // MP3: an APIC frame only ever lives in the ID3v2 tag at the very
        // start, so there is no point looking anywhere else.
        if (head[0] == 0x49 && head[1] == 0x44 && head[2] == 0x33) {
          return _indexOf(head, _apicMarker) >= 0;
        }

        if (_hasCovrAtom(head)) return true;
        if (len > _coverProbeBytes) {
          await raf.setPosition(len - _coverProbeBytes);
          final tail = await raf.read(_coverProbeBytes);
          if (_hasCovrAtom(tail)) return true;
        }
        return false;
      } finally {
        await raf.close();
      }
    } catch (e) {
      debugPrint('[ID3TagWriter] Cover probe failed for ${audioFile.path}: $e');
      return false;
    }
  }

  /// A genuine `covr` atom is immediately followed by a sized `data` atom:
  /// `[len]['covr'][len]['data']`. Requiring that pairing stops four incidental
  /// bytes of AAC payload from reading as artwork.
  static bool _hasCovrAtom(List<int> bytes) {
    int from = 0;
    while (true) {
      final at = _indexOf(bytes, _covrMarker, from);
      if (at < 0) return false;
      final dataAt = at + 8;
      if (dataAt + 4 <= bytes.length && _matchesAt(bytes, dataAt, _dataMarker)) {
        return true;
      }
      from = at + 1;
    }
  }

  static bool _matchesAt(List<int> haystack, int at, List<int> needle) {
    if (at + needle.length > haystack.length) return false;
    for (int i = 0; i < needle.length; i++) {
      if (haystack[at + i] != needle[i]) return false;
    }
    return true;
  }

  static int _indexOf(List<int> haystack, List<int> needle, [int from = 0]) {
    final limit = haystack.length - needle.length;
    for (int i = from < 0 ? 0 : from; i <= limit; i++) {
      if (_matchesAt(haystack, i, needle)) return i;
    }
    return -1;
  }

  /// Embed cover artwork (and optional title/artist metadata) into an audio file.
  ///
  /// Supports MP3, M4A, and FLAC containers.
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

      // 1. MP4 / M4A container check
      if (originalBytes.length >= 8 &&
          originalBytes[4] == 0x66 && // 'f'
          originalBytes[5] == 0x74 && // 't'
          originalBytes[6] == 0x79 && // 'y'
          originalBytes[7] == 0x70) { // 'p'
        return await _embedM4aCoverArt(audioFile, originalBytes, imageBytes, mimeType);
      }

      // 2. FLAC container check
      if (originalBytes[0] == 0x66 && // 'f'
          originalBytes[1] == 0x4C && // 'L'
          originalBytes[2] == 0x61 && // 'a'
          originalBytes[3] == 0x43) { // 'C'
        return await _embedFlacCoverArt(audioFile, originalBytes, imageBytes, mimeType);
      }

      // 3. Skip WebM / OGG (unsupported for native tag embedding without ffmpeg)
      if (originalBytes.length >= 4) {
        final isWebm = originalBytes[0] == 0x1A && originalBytes[1] == 0x45 && originalBytes[2] == 0xDF && originalBytes[3] == 0xA3;
        final isOgg = originalBytes[0] == 0x4F && originalBytes[1] == 0x67 && originalBytes[2] == 0x67 && originalBytes[3] == 0x53;
        if (isWebm || isOgg) {
          debugPrint('[ID3TagWriter] Skipping ID3 injection for WebM/OGG container.');
          return false;
        }
      }

      // 4. Default: MP3 (ID3v2.3 APIC frame injection)
      return await _embedMp3CoverArt(audioFile, originalBytes, imageBytes, mimeType, title, artist);
    } catch (e) {
      debugPrint('[ID3TagWriter] Error embedding cover art: $e');
      return false;
    }
  }

  // --- MP3 ID3v2.3 Embedding ---
  static Future<bool> _embedMp3CoverArt(
    File audioFile,
    Uint8List originalBytes,
    Uint8List imageBytes,
    String mimeType,
    String? title,
    String? artist,
  ) async {
    final id3v2Header = _buildID3v2Tag(
      imageBytes: imageBytes,
      mimeType: mimeType,
      title: title,
      artist: artist,
    );

    int audioDataOffset = 0;
    if (originalBytes[0] == 0x49 &&
        originalBytes[1] == 0x44 &&
        originalBytes[2] == 0x33) {
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
    debugPrint('[ID3TagWriter] Successfully embedded ID3v2.3 APIC cover art into MP3.');
    return true;
  }

  // --- FLAC Picture Block Embedding ---
  static Future<bool> _embedFlacCoverArt(
    File audioFile,
    Uint8List originalBytes,
    Uint8List imageBytes,
    String mimeType,
  ) async {
    final mimeAscii = ascii.encode(mimeType);
    final picPayload = BytesBuilder(copy: false);

    // 32-bit uint Picture Type (3 = Cover front)
    picPayload.addByte(0x00); picPayload.addByte(0x00); picPayload.addByte(0x00); picPayload.addByte(0x03);
    // 32-bit uint MIME length
    final mimeLen = mimeAscii.length;
    picPayload.addByte((mimeLen >> 24) & 0xFF); picPayload.addByte((mimeLen >> 16) & 0xFF);
    picPayload.addByte((mimeLen >> 8) & 0xFF); picPayload.addByte(mimeLen & 0xFF);
    picPayload.add(mimeAscii);
    // Description length (0)
    picPayload.addByte(0x00); picPayload.addByte(0x00); picPayload.addByte(0x00); picPayload.addByte(0x00);
    // Width, Height, Color Depth, Color Count (all 0)
    for (int i = 0; i < 16; i++) {
      picPayload.addByte(0x00);
    }
    // Image data length
    final imgLen = imageBytes.length;
    picPayload.addByte((imgLen >> 24) & 0xFF); picPayload.addByte((imgLen >> 16) & 0xFF);
    picPayload.addByte((imgLen >> 8) & 0xFF); picPayload.addByte(imgLen & 0xFF);
    picPayload.add(imageBytes);

    final picBytes = picPayload.takeBytes();
    final blockLen = picBytes.length;

    // Metadata block header: 1 byte (type=6 PICTURE) + 3 bytes length
    final blockHeader = Uint8List(4);
    blockHeader[0] = 0x06;
    blockHeader[1] = (blockLen >> 16) & 0xFF;
    blockHeader[2] = (blockLen >> 8) & 0xFF;
    blockHeader[3] = blockLen & 0xFF;

    final builder = BytesBuilder(copy: false);
    builder.add(Uint8List.sublistView(originalBytes, 0, 4));
    builder.add(blockHeader);
    builder.add(picBytes);
    builder.add(Uint8List.sublistView(originalBytes, 4));

    await audioFile.writeAsBytes(builder.takeBytes(), flush: true);
    debugPrint('[ID3TagWriter] Successfully embedded PICTURE metadata block into FLAC.');
    return true;
  }

  // --- M4A Covr Atom Embedding ---
  static Future<bool> _embedM4aCoverArt(
    File audioFile,
    Uint8List originalBytes,
    Uint8List imageBytes,
    String mimeType,
  ) async {
    final isPng = mimeType.toLowerCase().contains('png');
    final dataFlags = isPng ? 0x0E : 0x0D;

    final dataPayload = BytesBuilder(copy: false);
    final dataLen = 16 + imageBytes.length;
    dataPayload.addByte((dataLen >> 24) & 0xFF); dataPayload.addByte((dataLen >> 16) & 0xFF);
    dataPayload.addByte((dataLen >> 8) & 0xFF); dataPayload.addByte(dataLen & 0xFF);
    dataPayload.add(ascii.encode('data'));
    dataPayload.addByte(0x00); dataPayload.addByte(0x00); dataPayload.addByte(0x00); dataPayload.addByte(dataFlags);
    dataPayload.addByte(0x00); dataPayload.addByte(0x00); dataPayload.addByte(0x00); dataPayload.addByte(0x00);
    dataPayload.add(imageBytes);

    final dataAtomBytes = dataPayload.takeBytes();
    final covrLen = 8 + dataAtomBytes.length;
    final covrPayload = BytesBuilder(copy: false);
    covrPayload.addByte((covrLen >> 24) & 0xFF); covrPayload.addByte((covrLen >> 16) & 0xFF);
    covrPayload.addByte((covrLen >> 8) & 0xFF); covrPayload.addByte(covrLen & 0xFF);
    covrPayload.add(ascii.encode('covr'));
    covrPayload.add(dataAtomBytes);
    final covrAtomBytes = covrPayload.takeBytes();

    final moovAtom = _findAtom(originalBytes, 0, originalBytes.length, 'moov');
    if (moovAtom == null) return false;

    final udtaAtom = _findAtom(originalBytes, moovAtom.payloadOffset, moovAtom.offset + moovAtom.length, 'udta');
    final builder = BytesBuilder(copy: false);

    if (udtaAtom != null) {
      final metaAtom = _findAtom(originalBytes, udtaAtom.payloadOffset, udtaAtom.offset + udtaAtom.length, 'meta');
      if (metaAtom != null) {
        final metaStart = metaAtom.payloadOffset + 4;
        final ilstAtom = _findAtom(originalBytes, metaStart, metaAtom.offset + metaAtom.length, 'ilst');
        if (ilstAtom != null) {
          final existingCovr = _findAtom(originalBytes, ilstAtom.payloadOffset, ilstAtom.offset + ilstAtom.length, 'covr');
          int delta = 0;
          if (existingCovr != null) {
            delta = covrAtomBytes.length - existingCovr.length;
            builder.add(Uint8List.sublistView(originalBytes, 0, existingCovr.offset));
            builder.add(covrAtomBytes);
            builder.add(Uint8List.sublistView(originalBytes, existingCovr.offset + existingCovr.length));
          } else {
            delta = covrAtomBytes.length;
            builder.add(Uint8List.sublistView(originalBytes, 0, ilstAtom.payloadOffset + ilstAtom.payloadLength));
            builder.add(covrAtomBytes);
            builder.add(Uint8List.sublistView(originalBytes, ilstAtom.payloadOffset + ilstAtom.payloadLength));
          }
          final newBytes = builder.takeBytes();
          _updateAtomLength(newBytes, ilstAtom.offset, ilstAtom.length + delta);
          _updateAtomLength(newBytes, metaAtom.offset, metaAtom.length + delta);
          _updateAtomLength(newBytes, udtaAtom.offset, udtaAtom.length + delta);
          _updateAtomLength(newBytes, moovAtom.offset, moovAtom.length + delta);

          _adjustChunkOffsets(newBytes, moovAtom.offset, moovAtom.length + delta, delta);
          await audioFile.writeAsBytes(newBytes, flush: true);
          debugPrint('[ID3TagWriter] Successfully embedded covr atom into M4A ilst metadata.');
          return true;
        }
      }
    }

    final ilstPayload = BytesBuilder(copy: false);
    ilstPayload.add(covrAtomBytes);
    final ilstBytes = _createAtom('ilst', ilstPayload.takeBytes());

    final metaPayload = BytesBuilder(copy: false);
    metaPayload.addByte(0x00); metaPayload.addByte(0x00); metaPayload.addByte(0x00); metaPayload.addByte(0x00);
    final hdlrPayload = BytesBuilder(copy: false);
    for (int i = 0; i < 8; i++) {
      hdlrPayload.addByte(0x00);
    }
    hdlrPayload.add(ascii.encode('mdir'));
    hdlrPayload.add(ascii.encode('appl'));
    for (int i = 0; i < 9; i++) {
      hdlrPayload.addByte(0x00);
    }
    metaPayload.add(_createAtom('hdlr', hdlrPayload.takeBytes()));
    metaPayload.add(ilstBytes);
    final metaBytes = _createAtom('meta', metaPayload.takeBytes());

    final udtaBytes = _createAtom('udta', metaBytes);
    final delta = udtaBytes.length;

    builder.add(Uint8List.sublistView(originalBytes, 0, moovAtom.payloadOffset + moovAtom.payloadLength));
    builder.add(udtaBytes);
    builder.add(Uint8List.sublistView(originalBytes, moovAtom.payloadOffset + moovAtom.payloadLength));
    final newBytes = builder.takeBytes();

    _updateAtomLength(newBytes, moovAtom.offset, moovAtom.length + delta);
    _adjustChunkOffsets(newBytes, moovAtom.offset, moovAtom.length + delta, delta);

    await audioFile.writeAsBytes(newBytes, flush: true);
    debugPrint('[ID3TagWriter] Successfully constructed udta/meta/ilst/covr in M4A.');
    return true;
  }

  // --- MP4 Atom Helpers ---
  static _Atom? _findAtom(Uint8List bytes, int start, int end, String targetType) {
    int pos = start;
    while (pos + 8 <= end && pos < bytes.length) {
      int len = (bytes[pos] << 24) | (bytes[pos + 1] << 16) | (bytes[pos + 2] << 8) | bytes[pos + 3];
      if (len < 8 || pos + len > bytes.length) break;
      final type = String.fromCharCodes(Uint8List.sublistView(bytes, pos + 4, pos + 8));
      if (type == targetType) {
        return _Atom(type, pos, len, 8);
      }
      pos += len;
    }
    return null;
  }

  static Uint8List _createAtom(String type, Uint8List payload) {
    final len = 8 + payload.length;
    final b = BytesBuilder(copy: false);
    b.addByte((len >> 24) & 0xFF); b.addByte((len >> 16) & 0xFF);
    b.addByte((len >> 8) & 0xFF); b.addByte(len & 0xFF);
    b.add(ascii.encode(type));
    b.add(payload);
    return b.takeBytes();
  }

  static void _updateAtomLength(Uint8List bytes, int offset, int newLength) {
    if (offset + 4 <= bytes.length) {
      bytes[offset] = (newLength >> 24) & 0xFF;
      bytes[offset + 1] = (newLength >> 16) & 0xFF;
      bytes[offset + 2] = (newLength >> 8) & 0xFF;
      bytes[offset + 3] = newLength & 0xFF;
    }
  }

  static void _adjustChunkOffsets(Uint8List bytes, int moovOffset, int moovLen, int delta) {
    if (delta == 0) return;
    final mdatAtom = _findAtom(bytes, 0, bytes.length, 'mdat');
    if (mdatAtom == null || moovOffset > mdatAtom.offset) return;

    int pos = moovOffset + 8;
    final moovEnd = moovOffset + moovLen;
    while (pos + 16 <= moovEnd && pos + 16 <= bytes.length) {
      if (bytes[pos + 4] == 0x73 && bytes[pos + 5] == 0x74 && bytes[pos + 6] == 0x63 && bytes[pos + 7] == 0x6F) {
        final count = (bytes[pos + 12] << 24) | (bytes[pos + 13] << 16) | (bytes[pos + 14] << 8) | bytes[pos + 15];
        int entryOffset = pos + 16;
        for (int i = 0; i < count; i++) {
          if (entryOffset + 4 > bytes.length) break;
          final current = (bytes[entryOffset] << 24) | (bytes[entryOffset + 1] << 16) | (bytes[entryOffset + 2] << 8) | bytes[entryOffset + 3];
          final updated = current + delta;
          bytes[entryOffset] = (updated >> 24) & 0xFF;
          bytes[entryOffset + 1] = (updated >> 16) & 0xFF;
          bytes[entryOffset + 2] = (updated >> 8) & 0xFF;
          bytes[entryOffset + 3] = updated & 0xFF;
          entryOffset += 4;
        }
      }
      pos++;
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
    apicPayload.addByte(0x00);
    apicPayload.add(latin1.encode(mimeType));
    apicPayload.addByte(0x00);
    apicPayload.addByte(0x03);
    apicPayload.addByte(0x00);
    apicPayload.add(imageBytes);

    _addFrame(frames, 'APIC', apicPayload.takeBytes());

    // 2. TIT2 Frame (Title)
    if (title != null && title.isNotEmpty) {
      final titlePayload = BytesBuilder(copy: false);
      titlePayload.addByte(0x00);
      titlePayload.add(latin1.encode(title));
      _addFrame(frames, 'TIT2', titlePayload.takeBytes());
    }

    // 3. TPE1 Frame (Artist)
    if (artist != null && artist.isNotEmpty) {
      final artistPayload = BytesBuilder(copy: false);
      artistPayload.addByte(0x00);
      artistPayload.add(latin1.encode(artist));
      _addFrame(frames, 'TPE1', artistPayload.takeBytes());
    }

    final frameBytes = frames.takeBytes();
    final tagSize = frameBytes.length;

    final header = Uint8List(10);
    header[0] = 0x49;
    header[1] = 0x44;
    header[2] = 0x33;
    header[3] = 0x03;
    header[4] = 0x00;
    header[5] = 0x00;

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

    final len = payload.length;
    builder.addByte((len >> 24) & 0xFF);
    builder.addByte((len >> 16) & 0xFF);
    builder.addByte((len >> 8) & 0xFF);
    builder.addByte(len & 0xFF);

    builder.addByte(0x00);
    builder.addByte(0x00);

    builder.add(payload);
  }
}

class _Atom {
  final String type;
  final int offset;
  final int length;
  final int headerSize;
  _Atom(this.type, this.offset, this.length, this.headerSize);
  int get payloadOffset => offset + headerSize;
  int get payloadLength => length - headerSize;
}
