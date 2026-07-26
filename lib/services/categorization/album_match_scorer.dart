import '../../models/album.dart';
import 'title_cleaner.dart';

/// Shared Jaccard-based scoring engine for matching candidate text against albums.
///
/// Used by: existing-album strategy, folder strategy, zero-shot label→album mapping.
class AlbumMatchScorer {
  AlbumMatchScorer._();

  /// Score a candidate text against an album name.
  ///
  /// Returns 0.0–1.0:
  ///  - 1.0: exact substring containment
  ///  - 0.7: Jaccard overlap ≥ 0.5
  ///  - 0.0–0.6: scaled Jaccard
  static double score(String candidateText, String albumName) {
    final cand = TitleCleaner.cleanTitle(candidateText).toLowerCase().trim();
    final alb = albumName.toLowerCase().trim();

    if (cand.isEmpty || alb.isEmpty) return 0.0;

    // Exact substring containment → perfect match
    if (cand.contains(alb) || alb.contains(cand)) return 1.0;

    // Token similarity & concept coverage
    final candTokens = TitleCleaner.tokenize(cand);
    final albTokens = TitleCleaner.tokenize(alb);

    if (candTokens.isEmpty || albTokens.isEmpty) return 0.0;

    final intersection = candTokens.intersection(albTokens);
    final union = candTokens.union(albTokens);
    if (intersection.isEmpty) return 0.0;

    final jaccard = intersection.length / union.length;
    final coverage = intersection.length / albTokens.length;

    if (coverage >= 0.6 || jaccard >= 0.5) {
      return 0.75 + (0.25 * coverage);
    }
    return (jaccard * 0.4) + (coverage * 0.3);
  }

  /// Auto-propose threshold — matches with score ≥ this are accepted.
  static const double threshold = 0.7;

  /// Find the best matching album for a candidate text.
  /// Returns null if no album scores above [threshold].
  static AlbumMatch? bestMatch(
    String candidateText,
    List<UserAlbum> albums, {
    Set<String>? rejectedPairings,
    String? songId,
  }) {
    AlbumMatch? best;

    for (final album in albums) {
      // Skip rejected pairings
      if (rejectedPairings != null &&
          songId != null &&
          rejectedPairings.contains('$songId|${album.id}')) {
        continue;
      }

      final s = score(candidateText, album.name);
      if (s >= threshold && (best == null || s > best.score)) {
        best = AlbumMatch(album: album, score: s);
      }
    }

    return best;
  }
}

/// Result of matching a candidate against an album.
class AlbumMatch {
  final UserAlbum album;
  final double score;

  const AlbumMatch({required this.album, required this.score});
}
