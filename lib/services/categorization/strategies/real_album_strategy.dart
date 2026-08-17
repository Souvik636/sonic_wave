import 'package:uuid/uuid.dart';
import '../models.dart';
import 'strategy.dart';

/// Groups unclaimed songs by their MusicBrainz album title.
class RealAlbumStrategy extends CategorizationStrategy {
  static const _uuid = Uuid();

  @override
  GroupingStrategy get type => GroupingStrategy.byRealAlbum;

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
    if (songs.isEmpty || ctx.mbClient == null) return [];

    onProgress(
      StageProgress(
        label: 'Querying MusicBrainz database',
        done: 0,
        total: songs.length,
      ),
    );

    // Groups based on albumTitle: title -> list of song IDs
    final Map<String, List<String>> groups = {};

    for (int i = 0; i < songs.length; i++) {
      if (token.isCancelled) break;

      final song = songs[i];
      final result = await ctx.mbClient!.lookup(
        song.videoId,
        song.title,
        song.artist,
        maxLookups: ctx.request.maxMetadataLookups,
      );

      if (result.found &&
          result.albumTitle != null &&
          result.albumTitle!.trim().isNotEmpty) {
        groups.putIfAbsent(result.albumTitle!, () => []).add(song.videoId);
      }

      onProgress(
        StageProgress(
          label: 'Querying MusicBrainz database',
          done: i + 1,
          total: songs.length,
        ),
      );
    }

    final proposals = <AiProposedAlbum>[];
    groups.forEach((albumTitle, songIds) {
      proposals.add(
        AiProposedAlbum(
          id: _uuid.v4(),
          name: albumTitle,
          description: 'Album identified via MusicBrainz database matching.',
          songIds: List.unmodifiable(songIds),
          action: ProposalAction.createNew,
          source: ProposalSource.musicbrainz,
          confidence: 0.85,
        ),
      );
    });

    return proposals;
  }
}
