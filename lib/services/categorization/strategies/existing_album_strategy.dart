import 'package:uuid/uuid.dart';
import '../../../models/album.dart';
import '../models.dart';
import '../album_match_scorer.dart';
import '../title_cleaner.dart';
import 'strategy.dart';

/// Matches unclaimed songs against existing user albums using scored Jaccard matching.
///
/// Fixes from v1:
/// - Now optionally includes default (non-custom) albums via `includeDefaultAlbums`
/// - Uses Jaccard scoring instead of loose token matching
/// - Respects `rejectedAssignments` — never re-proposes rejected pairings
/// - Bypasses `minGroupSize` (adding even 1 song to a user's album is valid)
class ExistingAlbumStrategy extends CategorizationStrategy {
  static const _uuid = Uuid();

  @override
  GroupingStrategy get type => GroupingStrategy.existingAlbumsFirst;

  @override
  bool get needsNetwork => false;

  @override
  Future<List<AiProposedAlbum>> run(
    StrategyContext ctx,
    Set<String> classifiedIds,
    CancellationToken token,
    void Function(StageProgress) onProgress,
  ) async {
    final songs = unclaimed(ctx, classifiedIds);
    if (songs.isEmpty || ctx.albums.isEmpty) return [];

    onProgress(
      StageProgress(
        label: 'Matching songs to your albums',
        done: 0,
        total: songs.length,
      ),
    );

    // bucket[albumId] → list of (songId, score)
    final Map<String, List<_ScoredSong>> buckets = {};
    final Map<String, UserAlbum> albumMap = {
      for (final a in ctx.albums) a.id: a,
    };

    for (int i = 0; i < songs.length; i++) {
      if (token.isCancelled) break;

      final song = songs[i];
      final candidateText =
          '${TitleCleaner.cleanTitle(song.title)} ${TitleCleaner.cleanArtist(song.artist)}';

      final match = AlbumMatchScorer.bestMatch(
        candidateText,
        ctx.albums,
        rejectedPairings: ctx.rejectedAssignments,
        songId: song.videoId,
      );

      if (match != null) {
        buckets
            .putIfAbsent(match.album.id, () => [])
            .add(_ScoredSong(song.videoId, match.score));
      }

      if (i % 10 == 0) {
        onProgress(
          StageProgress(
            label: 'Matching songs to your albums',
            done: i + 1,
            total: songs.length,
          ),
        );
      }
    }

    // Build proposals
    final proposals = <AiProposedAlbum>[];
    for (final entry in buckets.entries) {
      final album = albumMap[entry.key];
      if (album == null) continue;

      final avgScore =
          entry.value.map((s) => s.score).reduce((a, b) => a + b) /
          entry.value.length;

      proposals.add(
        AiProposedAlbum(
          id: _uuid.v4(),
          name: album.name,
          description:
              'Matched ${entry.value.length} song${entry.value.length > 1 ? "s" : ""} to your existing album.',
          songIds: List.unmodifiable(entry.value.map((s) => s.songId)),
          existingAlbumId: album.id,
          action: ProposalAction.addToExisting,
          source: ProposalSource.existingMatch,
          confidence: avgScore.clamp(0.0, 1.0),
        ),
      );
    }

    onProgress(
      StageProgress(
        label: 'Matching songs to your albums',
        done: songs.length,
        total: songs.length,
      ),
    );

    return proposals;
  }
}

class _ScoredSong {
  final String songId;
  final double score;
  const _ScoredSong(this.songId, this.score);
}
