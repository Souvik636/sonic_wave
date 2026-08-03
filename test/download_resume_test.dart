import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:sonic_wave/models/song.dart';
import 'package:sonic_wave/services/download_service.dart';

/// Covers [DownloadTask]'s resume path against a real HTTP server.
///
/// This is the piece of the download pipeline most worth pinning down: it is
/// the only code that decides whether bytes already on disk get appended to,
/// and getting that wrong does not fail loudly — it produces a file that is the
/// right size and plays as noise. Each test drives a real socket rather than a
/// mock so the `Range` / `Content-Range` / 206 / 416 handling is exercised as
/// the server will actually deliver it.
void main() {
  late Directory tempDir;
  late HttpServer server;

  /// Body the server serves, and the knobs each test uses to misbehave.
  late Uint8List body;
  late bool honourRange;
  late int? truncateAfter;
  late List<String> receivedRanges;

  Uri url() =>
      Uri.parse('http://${server.address.host}:${server.port}/a.m4a');

  /// URL carrying an `itag`, which is what [DownloadTask.formatKeyOf] keys on
  /// for YouTube.
  Uri urlWithItag(String itag) => Uri.parse(
      'http://${server.address.host}:${server.port}/a.m4a?itag=$itag');

  Song songFor(String id) => Song(
        id: id,
        videoId: id,
        title: 'Test Song',
        artist: 'Test Artist',
        thumbnailUrl: '',
        highResThumbnailUrl: '',
        duration: const Duration(minutes: 3),
      );

  DownloadTask taskFor(String id) => DownloadTask(
        song: songFor(id),
        audioFile: File('${tempDir.path}${Platform.pathSeparator}$id.m4a'),
        thumbFile: File('${tempDir.path}${Platform.pathSeparator}$id.jpg'),
      );

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('sonic_wave_resume_test');
    // Deterministic, non-repeating content so a wrongly-spliced file is
    // detectable by comparing bytes rather than just length.
    body = Uint8List.fromList(List.generate(4096, (i) => (i * 7) % 251));
    honourRange = true;
    truncateAfter = null;
    receivedRanges = [];

    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((request) async {
      final rangeHeader = request.headers.value(HttpHeaders.rangeHeader);
      if (rangeHeader != null) receivedRanges.add(rangeHeader);

      int start = 0;
      var status = HttpStatus.ok;
      String? contentRange;

      if (rangeHeader != null && honourRange) {
        final match = RegExp(r'bytes=(\d+)-').firstMatch(rangeHeader);
        start = match != null ? int.parse(match.group(1)!) : 0;
        if (start >= body.length) {
          request.response.statusCode =
              HttpStatus.requestedRangeNotSatisfiable;
          await request.response.close();
          return;
        }
        status = HttpStatus.partialContent;
        contentRange = 'bytes $start-${body.length - 1}/${body.length}';
      }

      final slice = body.sublist(start);

      if (truncateAfter == null) {
        request.response.statusCode = status;
        if (contentRange != null) {
          request.response.headers
              .set(HttpHeaders.contentRangeHeader, contentRange);
        }
        request.response.contentLength = slice.length;
        request.response.add(slice);
        await request.response.close();
        return;
      }

      // Simulating a dropped connection: declare the full length, deliver less,
      // then hang up. HttpResponse refuses to close under those terms and would
      // discard the bytes, so the socket is taken over before any headers are
      // written and the response is composed by hand.
      final socket = await request.response.detachSocket(writeHeaders: false);
      final reason =
          status == HttpStatus.partialContent ? 'Partial Content' : 'OK';
      socket.write('HTTP/1.1 $status $reason\r\n');
      socket.write('Content-Length: ${slice.length}\r\n');
      socket.write('Accept-Ranges: bytes\r\n');
      if (contentRange != null) socket.write('Content-Range: $contentRange\r\n');
      socket.write('\r\n');
      socket.add(slice.sublist(0, truncateAfter!));
      await socket.flush();
      await socket.close();
    });
  });

  tearDown(() async {
    await server.close(force: true);
    try {
      await tempDir.delete(recursive: true);
    } catch (_) {}
  });

  group('formatKeyOf', () {
    test('keys on itag when present, because the signature is not stable', () {
      // The same audio resolves to a different signed URL every time, so only
      // the format identifier can decide whether a partial matches.
      final a = Uri.parse('https://r1.googlevideo.com/vp?itag=140&sig=AAA');
      final b = Uri.parse('https://r5.googlevideo.com/vp?itag=140&sig=ZZZ');
      final c = Uri.parse('https://r1.googlevideo.com/vp?itag=251&sig=AAA');

      expect(DownloadTask.formatKeyOf(a), DownloadTask.formatKeyOf(b));
      expect(DownloadTask.formatKeyOf(a), isNot(DownloadTask.formatKeyOf(c)));
    });

    test('falls back to host and path for non-YouTube sources', () {
      final a = Uri.parse('https://cdn.example.com/track.mp3?token=1');
      final b = Uri.parse('https://cdn.example.com/track.mp3?token=2');
      final c = Uri.parse('https://cdn.example.com/other.mp3?token=1');

      expect(DownloadTask.formatKeyOf(a), DownloadTask.formatKeyOf(b));
      expect(DownloadTask.formatKeyOf(a), isNot(DownloadTask.formatKeyOf(c)));
    });
  });

  group('DownloadTask transfer', () {
    test('a clean download writes the full body and leaves no .part', () async {
      final task = taskFor('clean');
      await task.start(url(), 0);

      expect(await task.audioFile.readAsBytes(), body);
      expect(await task.partFile.exists(), isFalse,
          reason: 'the staging file must be promoted, not left behind');
      expect(task.status, DownloadStatus.completed);
    });

    test('bytes land in .part until the transfer completes', () async {
      final task = taskFor('staging');
      // Nothing may appear under the final name mid-flight — that is what
      // makes an unfinished download invisible to other music apps.
      truncateAfter = 1024;
      await expectLater(task.start(url(), 0), throwsA(anything));

      expect(await task.audioFile.exists(), isFalse);
      expect(await task.partFile.exists(), isTrue);
      expect(await task.partFile.length(), 1024);
    });

    test('a truncated body fails instead of promoting a short file', () async {
      // The server closes cleanly after a partial body. Before, that reached
      // onDone and was saved as a finished song that cut off mid-track.
      final task = taskFor('truncated');
      truncateAfter = 2048;

      await expectLater(task.start(url(), 0), throwsA(anything));
      expect(task.status, DownloadStatus.failed);
      expect(await task.audioFile.exists(), isFalse);
    });

    test('resume continues from the partial and reassembles exactly', () async {
      final first = taskFor('resume');
      truncateAfter = 1500;
      await expectLater(first.start(url(), 0), throwsA(anything));
      expect(await first.partFile.length(), 1500);

      // Second attempt against the same rendition, with resume permitted.
      truncateAfter = null;
      receivedRanges.clear();
      final second = taskFor('resume');
      await second.start(url(), body.length, allowResume: true);

      expect(receivedRanges, ['bytes=1500-']);
      expect(await second.audioFile.readAsBytes(), body,
          reason: 'a resumed file must be byte-identical to a fresh download');
      expect(await second.partFile.exists(), isFalse);
    });

    test('without allowResume the partial is discarded, not appended',
        () async {
      final first = taskFor('noresume');
      truncateAfter = 1500;
      await expectLater(first.start(url(), 0), throwsA(anything));

      truncateAfter = null;
      receivedRanges.clear();
      final second = taskFor('noresume');
      await second.start(url(), 0);

      expect(receivedRanges, isEmpty, reason: 'no Range request should be sent');
      expect(await second.audioFile.readAsBytes(), body);
    });

    test('a size mismatch restarts rather than splicing two renditions',
        () async {
      final first = taskFor('mismatch');
      truncateAfter = 1500;
      await expectLater(first.start(url(), 0), throwsA(anything));

      // Caller believes the partial belongs to a 9999-byte rendition, but the
      // server reports 4096. Appending would produce a file that is neither.
      truncateAfter = null;
      final second = taskFor('mismatch');
      await second.start(url(), 9999, allowResume: true);

      expect(await second.audioFile.readAsBytes(), body,
          reason: 'must re-fetch from byte 0, not append onto the partial');
    });

    test('a server that ignores Range still produces a correct file', () async {
      final first = taskFor('ignored');
      truncateAfter = 1500;
      await expectLater(first.start(url(), 0), throwsA(anything));

      // Responds 200 with the whole body despite the Range header — some
      // proxies and Invidious mirrors do exactly this.
      truncateAfter = null;
      honourRange = false;
      final second = taskFor('ignored');
      await second.start(url(), body.length, allowResume: true);

      expect(await second.audioFile.readAsBytes(), body);
    });

    test('a complete .part is promoted when the server answers 416', () async {
      final task = taskFor('complete');
      // Everything is already on disk: the server has nothing left to send.
      await task.partFile.writeAsBytes(body);

      await task.start(url(), body.length, allowResume: true);

      expect(task.status, DownloadStatus.completed);
      expect(await task.audioFile.readAsBytes(), body);
      expect(await task.partFile.exists(), isFalse);
    });

    test('cancel removes the partial so nothing can resume it', () async {
      final task = taskFor('cancelled');
      await task.partFile.writeAsBytes(body.sublist(0, 800));

      await task.cancel();

      expect(await task.partFile.exists(), isFalse);
      expect(task.status, DownloadStatus.cancelled);
    });

    test('an itag change is a different rendition', () async {
      // The guard callers rely on: same video, different format, so the
      // partial must not be offered for resume.
      expect(DownloadTask.formatKeyOf(urlWithItag('140')),
          isNot(DownloadTask.formatKeyOf(urlWithItag('251'))));
    });
  });
}
