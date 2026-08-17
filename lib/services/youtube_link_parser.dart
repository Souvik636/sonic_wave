/// Pulls a YouTube video id out of whatever the Android share sheet hands us.
///
/// Sharing from the YouTube app rarely produces a bare URL. It is usually the
/// video title, a newline, the link, and a "via @YouTube" tail — and the link
/// itself carries tracking parameters (`?si=`, `&t=`, `&list=`). Every one of
/// those forms has to reduce to the same 11-character id, because that id is
/// what the yt-dlp download pipeline takes.
class YouTubeLinkParser {
  YouTubeLinkParser._();

  /// A YouTube video id is exactly 11 characters of URL-safe base64.
  static final RegExp _idPattern = RegExp(r'^[A-Za-z0-9_-]{11}$');

  /// Any YouTube-ish URL embedded in free text, with or without a scheme.
  static final RegExp _urlPattern = RegExp(
    r'(?:https?://)?(?:[\w-]+\.)*(?:youtube\.com|youtu\.be|youtube-nocookie\.com)/\S*',
    caseSensitive: false,
  );

  /// Path prefixes that carry the id in the NEXT segment.
  static const Set<String> _idBearingPrefixes = {
    'shorts',
    'embed',
    'live',
    'v',
  };

  /// Trailing characters that come from surrounding prose, not the URL.
  static final RegExp _trailingJunk = RegExp(r'''[.,;:!?)\]}>"'‘’“”]+$''');

  /// The first YouTube video id found in [text], or null if there is none.
  static String? extractVideoId(String? text) {
    if (text == null || text.trim().isEmpty) return null;

    for (final match in _urlPattern.allMatches(text)) {
      final id = _idFromUrl(match.group(0)!);
      if (id != null) return id;
    }
    return null;
  }

  /// True when [text] contains a downloadable YouTube video link.
  static bool hasVideoLink(String? text) => extractVideoId(text) != null;

  static String? _idFromUrl(String raw) {
    var candidate = raw.trim().replaceAll(_trailingJunk, '');
    if (candidate.isEmpty) return null;

    // Uri.parse needs a scheme to populate host/path correctly; shared text
    // sometimes omits it ("youtu.be/dQw4w9WgXcQ").
    if (!candidate.toLowerCase().startsWith('http')) {
      candidate = 'https://$candidate';
    }

    final Uri uri;
    try {
      uri = Uri.parse(candidate);
    } catch (_) {
      return null;
    }

    final host = uri.host.toLowerCase();
    final segments = uri.pathSegments
        .where((s) => s.isNotEmpty)
        .toList(growable: false);

    // Short form: youtu.be/<id>
    if (host == 'youtu.be' || host.endsWith('.youtu.be')) {
      return segments.isEmpty ? null : _validId(segments.first);
    }

    final isYouTube =
        host == 'youtube.com' ||
        host.endsWith('.youtube.com') ||
        host == 'youtube-nocookie.com' ||
        host.endsWith('.youtube-nocookie.com');
    if (!isYouTube) return null;

    // Standard and music watch pages: /watch?v=<id>. Checked before the path
    // forms because a watch URL can also carry &list=, and the video is what
    // the user shared.
    final fromQuery = _validId(uri.queryParameters['v']);
    if (fromQuery != null) return fromQuery;

    // /shorts/<id>, /embed/<id>, /live/<id>, /v/<id>
    if (segments.length >= 2 &&
        _idBearingPrefixes.contains(segments.first.toLowerCase())) {
      return _validId(segments[1]);
    }

    return null;
  }

  static String? _validId(String? id) =>
      (id != null && _idPattern.hasMatch(id)) ? id : null;
}
