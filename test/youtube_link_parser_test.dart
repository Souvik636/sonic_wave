import 'package:flutter_test/flutter_test.dart';
import 'package:sonic_wave/services/youtube_link_parser.dart';

void main() {
  const id = 'dQw4w9WgXcQ';

  group('extracts the video id from every share format', () {
    test('standard watch URL', () {
      expect(
          YouTubeLinkParser.extractVideoId(
              'https://www.youtube.com/watch?v=$id'),
          id);
    });

    test('short youtu.be link with a tracking parameter', () {
      expect(YouTubeLinkParser.extractVideoId('https://youtu.be/$id?si=AbC123'),
          id);
    });

    test('mobile link', () {
      expect(
          YouTubeLinkParser.extractVideoId('https://m.youtube.com/watch?v=$id'),
          id);
    });

    test('YouTube Music link', () {
      expect(
          YouTubeLinkParser.extractVideoId(
              'https://music.youtube.com/watch?v=$id&feature=share'),
          id);
    });

    test('Shorts link', () {
      expect(
          YouTubeLinkParser.extractVideoId('https://youtube.com/shorts/$id?si=x'),
          id);
    });

    test('embed and live links', () {
      expect(YouTubeLinkParser.extractVideoId('https://www.youtube.com/embed/$id'), id);
      expect(YouTubeLinkParser.extractVideoId('https://www.youtube.com/live/$id'), id);
    });

    test('watch URL inside a playlist still yields the video', () {
      expect(
          YouTubeLinkParser.extractVideoId(
              'https://www.youtube.com/watch?v=$id&list=PLabcdefg&index=3'),
          id);
    });

    test('timestamped link', () {
      expect(
          YouTubeLinkParser.extractVideoId('https://youtu.be/$id?t=42'), id);
    });
  });

  group('handles what the share sheet actually sends', () {
    test('title, newline, link and a "via" tail', () {
      const shared = 'Rick Astley - Never Gonna Give You Up (Official Video)\n'
          'https://youtu.be/$id?si=Xy9\n'
          'via @YouTube';
      expect(YouTubeLinkParser.extractVideoId(shared), id);
    });

    test('link wrapped in prose and trailing punctuation', () {
      expect(
          YouTubeLinkParser.extractVideoId(
              'listen to this (https://www.youtube.com/watch?v=$id).'),
          id);
    });

    test('scheme-less link', () {
      expect(YouTubeLinkParser.extractVideoId('youtu.be/$id'), id);
    });

    test('first video wins when several are shared', () {
      expect(
          YouTubeLinkParser.extractVideoId(
              'https://youtu.be/$id and https://youtu.be/abcdefghijk'),
          id);
    });
  });

  group('rejects things that are not a downloadable video', () {
    test('null, empty and whitespace', () {
      expect(YouTubeLinkParser.extractVideoId(null), isNull);
      expect(YouTubeLinkParser.extractVideoId(''), isNull);
      expect(YouTubeLinkParser.extractVideoId('   '), isNull);
    });

    test('plain text with no link', () {
      expect(YouTubeLinkParser.extractVideoId('check out this song'), isNull);
    });

    test('a non-YouTube link', () {
      expect(
          YouTubeLinkParser.extractVideoId('https://open.spotify.com/track/xyz'),
          isNull);
    });

    test('a lookalike host is not YouTube', () {
      expect(
          YouTubeLinkParser.extractVideoId(
              'https://notyoutube.com.evil.test/watch?v=$id'),
          isNull);
    });

    test('a playlist-only or channel link has no single video', () {
      expect(
          YouTubeLinkParser.extractVideoId(
              'https://www.youtube.com/playlist?list=PLabcdefg'),
          isNull);
      expect(
          YouTubeLinkParser.extractVideoId('https://www.youtube.com/@SomeChannel'),
          isNull);
    });

    test('a malformed id of the wrong length', () {
      expect(YouTubeLinkParser.extractVideoId('https://youtu.be/tooshort'),
          isNull);
    });
  });

  test('hasVideoLink mirrors extractVideoId', () {
    expect(YouTubeLinkParser.hasVideoLink('https://youtu.be/$id'), isTrue);
    expect(YouTubeLinkParser.hasVideoLink('nothing here'), isFalse);
  });
}
