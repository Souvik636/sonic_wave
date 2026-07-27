import 'dart:math' as math;
import 'package:flutter/foundation.dart';
import '../models/song.dart';

/// Lightweight, local context-aware recommendation engine.
///
/// Analyzes user's current track context (genre, artist, mood), recently played
/// tracks, and favorite songs to score and recommend matching tracks from the
/// available library or catalog for dynamic queue auto-injection.
class RecommendationEngine {
  static final RecommendationEngine _instance = RecommendationEngine._internal();
  factory RecommendationEngine() => _instance;
  RecommendationEngine._internal();

  /// Suggest matching tracks to append to the active queue when approaching the end of queue.
  List<Song> generateRecommendations({
    required Song currentSong,
    required List<Song> activeQueue,
    required List<Song> librarySongs,
    required List<Song> favoriteSongs,
    required List<Song> recentlyPlayed,
    int count = 4,
  }) {
    if (librarySongs.isEmpty && favoriteSongs.isEmpty && recentlyPlayed.isEmpty) {
      return [];
    }

    final activeIds = activeQueue.map((s) => s.videoId).toSet();
    activeIds.add(currentSong.videoId);

    // Pool candidate songs not already in active queue
    final candidatePool = <String, Song>{};
    for (final s in librarySongs) {
      if (!activeIds.contains(s.videoId)) {
        candidatePool[s.videoId] = s;
      }
    }
    for (final s in favoriteSongs) {
      if (!activeIds.contains(s.videoId)) {
        candidatePool[s.videoId] = s;
      }
    }
    for (final s in recentlyPlayed) {
      if (!activeIds.contains(s.videoId)) {
        candidatePool[s.videoId] = s;
      }
    }

    if (candidatePool.isEmpty) return [];

    final favIds = favoriteSongs.map((s) => s.videoId).toSet();
    final currentArtistLower = currentSong.artist.trim().toLowerCase();
    final currentTitleLower = currentSong.title.trim().toLowerCase();
    final rng = math.Random();

    // Score candidates based on metadata vector similarity
    final scoredCandidates = <_ScoredSong>[];

    for (final song in candidatePool.values) {
      double score = 0.0;
      final songArtistLower = song.artist.trim().toLowerCase();
      final songTitleLower = song.title.trim().toLowerCase();

      // 1. Same Artist Boost (+40 pts)
      if (songArtistLower == currentArtistLower && songArtistLower.isNotEmpty && songArtistLower != 'unknown artist' && songArtistLower != 'local audio') {
        score += 40.0;
      }

      // 2. Favorite Boost (+25 pts)
      if (favIds.contains(song.videoId)) {
        score += 25.0;
      }

      // 3. Title / Keyword similarity (+15 pts)
      final currentTokens = currentTitleLower.split(RegExp(r'\s+')).where((t) => t.length > 3).toSet();
      final songTokens = songTitleLower.split(RegExp(r'\s+')).where((t) => t.length > 3).toSet();
      final commonTokens = currentTokens.intersection(songTokens);
      if (commonTokens.isNotEmpty) {
        score += commonTokens.length * 15.0;
      }

      // 4. Source & Album matching (+10 pts)
      if (song.albumFolderName != null && song.albumFolderName == currentSong.albumFolderName) {
        score += 15.0;
      }
      if (song.source == currentSong.source) {
        score += 5.0;
      }

      // 5. Add subtle random noise to keep suggestions fresh across sessions
      score += rng.nextDouble() * 10.0;

      scoredCandidates.add(_ScoredSong(song: song, score: score));
    }

    // Sort descending by score
    scoredCandidates.sort((a, b) => b.score.compareTo(a.score));

    final recommendations = scoredCandidates.take(count).map((item) => item.song).toList();
    debugPrint('[RecommendationEngine] Recommended ${recommendations.length} tracks for current song "${currentSong.title}"');
    return recommendations;
  }
}

class _ScoredSong {
  final Song song;
  final double score;
  const _ScoredSong({required this.song, required this.score});
}
