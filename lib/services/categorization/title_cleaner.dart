/// Shared title and artist cleaning utilities used across all strategies.
class TitleCleaner {
  TitleCleaner._();

  /// Stop words removed from tokenization to prevent false matches.
  static const Set<String> stopWords = {
    'official', 'video', 'audio', 'lyrics', 'lyric', 'hd', 'full',
    'song', 'music', 'mv', '4k', '1080p', '720p', 'feat', 'ft',
    'the', 'a', 'an', 'and', 'or', 'of', 'in', 'on', 'at', 'to',
    'for', 'is', 'it', 'by', 'with', 'from', 'this', 'that',
    'version', 'remix', 'remastered', 'live', 'cover', 'karaoke',
  };

  /// Remove parenthesized/bracketed suffixes, noise words, and normalize.
  static String cleanTitle(String raw) {
    String s = raw
        .replaceAll(RegExp(r'\([^)]*\)'), '')    // (Official Video)
        .replaceAll(RegExp(r'\[[^\]]*\]'), '')    // [Lyrics]
        .replaceAll(RegExp(r'[|].*$'), '')         // Split at pipe
        .replaceAll(RegExp(r'[^\w\s]'), ' ')       // Non-word → space
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
    return s.isNotEmpty ? s : raw.trim();
  }

  /// Clean artist name: remove Vevo/Official suffixes, normalize whitespace.
  static String cleanArtist(String raw) {
    String s = raw
        .replaceAll(RegExp(r'\([^)]*\)'), '')
        .replaceAll(RegExp(r'vevo', caseSensitive: false), '')
        .replaceAll(RegExp(r'official', caseSensitive: false), '')
        .replaceAll(RegExp(r'[^\w\s]'), ' ')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
    return s.isNotEmpty ? s : raw.trim();
  }

  /// Tokenize into meaningful words (lowercased, stop-words removed, length > 2).
  static Set<String> tokenize(String text) {
    return text
        .toLowerCase()
        .replaceAll(RegExp(r'[^a-z0-9 ]'), ' ')
        .split(RegExp(r'\s+'))
        .where((w) => w.length > 2 && !stopWords.contains(w))
        .toSet();
  }

  /// Parse title and artist from raw title if artist is missing or generic.
  /// Handles patterns like "Artist - Title" or "Artist - Title (Official Video)".
  static Map<String, String> parseArtistAndTitle(String rawTitle, String rawArtist) {
    String cleanA = cleanArtist(rawArtist);
    String cleanT = cleanTitle(rawTitle);

    final genericArtists = {
      'unknown', 'local audio', 'various artists', 'various',
      'unknown artist', 'music', 'audio', '', 'sonicwave',
    };

    if (genericArtists.contains(cleanA.toLowerCase().trim()) && rawTitle.contains(' - ')) {
      final parts = rawTitle.split(' - ');
      if (parts.length >= 2) {
        final possibleArtist = cleanArtist(parts[0]);
        final possibleTitle = cleanTitle(parts.sublist(1).join(' - '));
        if (possibleArtist.isNotEmpty && possibleTitle.isNotEmpty) {
          return {'artist': possibleArtist, 'title': possibleTitle};
        }
      }
    }

    return {'artist': cleanA, 'title': cleanT};
  }

  /// Humanize a folder/directory name: underscores → spaces, title-case.
  static String humanizeFolderName(String dirName) {
    final clean = dirName
        .replaceAll(RegExp(r'[_\-.]'), ' ')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
    if (clean.isEmpty) return dirName;
    return clean.split(' ').map((w) {
      if (w.isEmpty) return w;
      return w[0].toUpperCase() + w.substring(1).toLowerCase();
    }).join(' ');
  }
}
