import 'dart:io';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:sonic_wave/services/download_service.dart';
import 'package:sonic_wave/services/id3_tag_writer.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory tempDir;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('sonic_wave_container_test_');
  });

  tearDown(() async {
    try {
      if (await tempDir.exists()) {
        await tempDir.delete(recursive: true);
      }
    } catch (_) {}
  });

  test('ID3TagWriter skips prepending ID3 tags to M4A files', () async {
    final m4aFile = File('${tempDir.path}/test_m4a.m4a');
    // Write fake M4A header: 4 bytes len + 'ftyp'
    final m4aBytes = Uint8List.fromList([0, 0, 0, 32, 0x66, 0x74, 0x79, 0x70, 0x4D, 0x34, 0x41, 0x20]);
    await m4aFile.writeAsBytes(m4aBytes);

    final result = await ID3TagWriter.embedCoverArt(
      audioFile: m4aFile,
      imageBytes: Uint8List.fromList([1, 2, 3, 4]),
    );

    expect(result, isFalse);
    final currentBytes = await m4aFile.readAsBytes();
    // Magic bytes at offset 4 must remain 'ftyp'
    expect(currentBytes[4], equals(0x66));
    expect(currentBytes[5], equals(0x74));
  });

  test('DownloadService detectAndFixAudioContainer repairs prepended ID3 header on M4A', () async {
    final corruptedFile = File('${tempDir.path}/corrupted_track.mp3');
    // Build corrupted file: ID3 tag + M4A header
    final builder = BytesBuilder();
    builder.add(Uint8List.fromList([0x49, 0x44, 0x33, 0x03, 0x00, 0x00, 0x00, 0x00, 0x00, 0x0A, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10])); // ID3 tag (10 bytes header + 10 bytes payload)
    builder.add(Uint8List.fromList([0, 0, 0, 32, 0x66, 0x74, 0x79, 0x70, 0x4D, 0x34, 0x41, 0x20])); // Real M4A
    await corruptedFile.writeAsBytes(builder.takeBytes());

    final fixedPath = await DownloadService.detectAndFixAudioContainer(corruptedFile);

    expect(fixedPath.endsWith('.m4a'), isTrue);
    final fixedFile = File(fixedPath);
    expect(await fixedFile.exists(), isTrue);

    final repairedBytes = await fixedFile.readAsBytes();
    // Prepending ID3 should be stripped; file must start with M4A header
    expect(repairedBytes[4], equals(0x66));
    expect(repairedBytes[5], equals(0x74));
  });
}
