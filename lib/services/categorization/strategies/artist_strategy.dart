import 'package:uuid/uuid.dart';
import '../../../models/song.dart';
import '../models.dart';
import '../title_cleaner.dart';
import 'strategy.dart';

/// Groups unclaimed songs by their artist name.
///
/// Uses cleaned canonical artist names to avoid duplicates
/// (e.g., "Arijit Singh VEVO" → "Arijit Singh").
class ArtistStrategy extends CategorizationStrategy {
  static const _uuid = Uuid();

  /// Artist names that are too generic to form meaningful groups.
  static const Set<String> _skipArtists = {
    'local audio', 'unknown', 'various artists', 'various',
    'unknown artist', 'music', 'audio', '',
  };

  @override
  GroupingStrategy get type => GroupingStrategy.byArtist;

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
    if (songs.isEmpty) return [];

    onProgress(StageProgress(
      label: 'Grouping by artist',
      done: 0,
      total: songs.length,
    ));

    // Group by cleaned artist name (with smart fallback parsing)
    final Map<String, List<Song>> artistGroups = {};
    for (final song in songs) {
      if (token.isCancelled) break;

      final parsed = TitleCleaner.parseArtistAndTitle(song.title, song.artist);
      final cleanedArtist = parsed['artist'] ?? song.artist;
      final artistLower = cleanedArtist.toLowerCase().trim();

      if (_skipArtists.contains(artistLower)) continue;

      // Normalize to title case for consistent keys
      final artistKey = cleanedArtist
          .split(' ')
          .map((w) {
            if (w.isEmpty) return w;
            return w[0].toUpperCase() + w.substring(1);
          })
          .join(' ')
          .trim();

      if (artistKey.isNotEmpty) {
        artistGroups.putIfAbsent(artistKey, () => []).add(song);
      }
    }

    // Build proposals
    final proposals = <AiProposedAlbum>[];
    for (final entry in artistGroups.entries) {
      if (token.isCancelled) break;

      proposals.add(AiProposedAlbum(
        id: _uuid.v4(),
        name: '${entry.key} Essentials',
        description: 'Curated collection of ${entry.value.length} tracks by ${entry.key}.',
        songIds: List.unmodifiable(entry.value.map((s) => s.videoId)),
        action: ProposalAction.createNew,
        source: ProposalSource.artist,
        confidence: 0.75,
      ));
    }

    onProgress(StageProgress(
      label: 'Grouping by artist',
      done: songs.length,
      total: songs.length,
    ));

    return proposals;
  }
}
