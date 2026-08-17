import 'package:uuid/uuid.dart';
import '../models.dart';
import 'strategy.dart';

/// Groups unclaimed songs by their normalized MusicBrainz genre tags.
class GenreStrategy extends CategorizationStrategy {
  static const _uuid = Uuid();

  @override
  GroupingStrategy get type => GroupingStrategy.byGenre;

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
        label: 'Analyzing genre metadata',
        done: 0,
        total: songs.length,
      ),
    );

    // Groups based on normalized genre: genre -> list of song IDs
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
          result.genre != null &&
          result.genre!.trim().isNotEmpty) {
        final normalized = _normalizeGenre(result.genre!);
        groups.putIfAbsent(normalized, () => []).add(song.videoId);
      }

      onProgress(
        StageProgress(
          label: 'Analyzing genre metadata',
          done: i + 1,
          total: songs.length,
        ),
      );
    }

    final proposals = <AiProposedAlbum>[];
    groups.forEach((genre, songIds) {
      proposals.add(
        AiProposedAlbum(
          id: _uuid.v4(),
          name: '$genre Collection',
          description: 'Songs tagged as "$genre" by the MusicBrainz community.',
          songIds: List.unmodifiable(songIds),
          action: ProposalAction.createNew,
          source: ProposalSource.genre,
          confidence: 0.75,
        ),
      );
    });

    return proposals;
  }

  /// Normalize raw genre tags into structured collections.
  String _normalizeGenre(String raw) {
    final lower = raw.toLowerCase().trim();

    // Common genre mapping table
    const genreMap = {
      'pop': 'Pop',
      'rock': 'Rock',
      'hip hop': 'Hip-Hop',
      'hip-hop': 'Hip-Hop',
      'rap': 'Hip-Hop',
      'electronic': 'Electronic',
      'edm': 'Electronic',
      'techno': 'Electronic',
      'house': 'Electronic',
      'jazz': 'Jazz',
      'classical': 'Classical',
      'r&b': 'R&B',
      'rnb': 'R&B',
      'soul': 'R&B',
      'country': 'Country',
      'metal': 'Metal',
      'folk': 'Folk',
      'blues': 'Blues',
      'reggae': 'Reggae',
      'punk': 'Punk',
      'latin': 'Latin',
      'indie': 'Indie',
      'alternative': 'Alternative',
      'dance': 'Dance',
      'ambient': 'Ambient',
      'soundtrack': 'Soundtrack',
      'bollywood': 'Bollywood',
      'indian': 'Indian',
      'hindi film music': 'Bollywood',
    };

    if (genreMap.containsKey(lower)) {
      return genreMap[lower]!;
    }

    // Title Case default
    return raw
        .split(' ')
        .map((w) {
          if (w.isEmpty) return w;
          return w[0].toUpperCase() + w.substring(1).toLowerCase();
        })
        .join(' ');
  }
}
