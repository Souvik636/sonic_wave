import 'package:uuid/uuid.dart';
import '../../../models/song.dart';
import '../models.dart';
import '../title_cleaner.dart';
import '../album_match_scorer.dart';
import 'strategy.dart';

/// Classifies unclaimed songs into the user's custom category labels using Gemini 3.1 Flash Lite batch classification.
class ZeroShotStrategy extends CategorizationStrategy {
  static const _uuid = Uuid();

  @override
  GroupingStrategy get type => GroupingStrategy.byUserCategories;

  @override
  bool get needsNetwork => true;

  @override
  Future<List<AiProposedAlbum>> run(
    StrategyContext ctx,
    Set<String> classifiedIds,
    CancellationToken token,
    void Function(StageProgress) onProgress,
  ) async {
    final songs = unclaimed(ctx, classifiedIds);
    final labels = ctx.request.userCategories;

    if (songs.isEmpty || labels.isEmpty || ctx.geminiClient == null) {
      return [];
    }

    onProgress(StageProgress(
      label: 'Sorting into your categories',
      done: 0,
      total: songs.length,
    ));

    final List<String> songReps = [];
    final List<Song> chunkSongs = [];
    for (final song in songs) {
      songReps.add('${TitleCleaner.cleanTitle(song.title)} — ${TitleCleaner.cleanArtist(song.artist)}');
      chunkSongs.add(song);
    }

    // label -> list of scored songs
    final Map<String, List<_ScoredSong>> buckets = {};
    const int chunkSize = 50;

    for (int i = 0; i < songReps.length; i += chunkSize) {
      if (token.isCancelled) break;

      final end = (i + chunkSize < songReps.length) ? i + chunkSize : songReps.length;
      final batchReps = songReps.sublist(i, end);
      final batchSongs = chunkSongs.sublist(i, end);

      final results = await ctx.geminiClient!.classifyBatch(batchReps, labels);
      if (results != null) {
        for (final res in results) {
          // res.index is 1-based relative to the batch list
          final listIndex = res.index - 1;
          if (listIndex >= 0 && listIndex < batchSongs.length) {
            final song = batchSongs[listIndex];
            final category = res.category.trim();

            if (category != 'UNASSIGNED' && res.confidence >= ctx.request.zeroShotThreshold) {
              buckets
                  .putIfAbsent(category, () => [])
                  .add(_ScoredSong(song.videoId, res.confidence));
            }
          }
        }
      }

      onProgress(StageProgress(
        label: 'Sorting into your categories',
        done: end,
        total: songs.length,
      ));
    }

    final proposals = <AiProposedAlbum>[];

    for (final entry in buckets.entries) {
      final label = entry.key;
      final scoredSongs = entry.value;

      final avgScore = scoredSongs.map((s) => s.score).reduce((a, b) => a + b) / scoredSongs.length;

      // Map category label to existing user album if similarity >= 0.7
      final match = AlbumMatchScorer.bestMatch(label, ctx.albums);

      if (match != null) {
        proposals.add(AiProposedAlbum(
          id: _uuid.v4(),
          name: match.album.name,
          description: 'Songs classified into your custom category "$label" (merged with existing album).',
          songIds: List.unmodifiable(scoredSongs.map((s) => s.songId)),
          existingAlbumId: match.album.id,
          action: ProposalAction.addToExisting,
          source: ProposalSource.userCategory,
          confidence: avgScore,
        ));
      } else {
        proposals.add(AiProposedAlbum(
          id: _uuid.v4(),
          name: label,
          description: 'Songs classified into your custom category "$label".',
          songIds: List.unmodifiable(scoredSongs.map((s) => s.songId)),
          action: ProposalAction.createNew,
          source: ProposalSource.userCategory,
          confidence: avgScore,
        ));
      }
    }

    return proposals;
  }
}

class _ScoredSong {
  final String songId;
  final double score;
  const _ScoredSong(this.songId, this.score);
}
