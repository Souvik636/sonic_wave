import '../../../models/song.dart';
import '../../../models/album.dart';
import '../models.dart';
import '../musicbrainz_client.dart';
import '../gemini_client.dart';

/// Context passed to every strategy — contains all shared state.
class StrategyContext {
  /// All songs being categorized.
  final List<Song> songs;

  /// All existing user albums (custom + default based on request).
  final List<UserAlbum> albums;

  /// The categorization request configuration.
  final CategorizationRequest request;

  /// Persisted set of "songId|albumId" pairs the user has rejected.
  /// Strategies must skip these pairings.
  final Set<String> rejectedAssignments;

  /// Reused MusicBrainz client.
  final MusicBrainzClient? mbClient;

  /// Reused Gemini API client.
  final GeminiClient? geminiClient;

  const StrategyContext({
    required this.songs,
    required this.albums,
    required this.request,
    this.rejectedAssignments = const {},
    this.mbClient,
    this.geminiClient,
  });
}

/// Abstract base class for all categorization strategies.
///
/// Contract:
/// - MUST only consider songs whose id is NOT in [classifiedIds].
/// - MUST NOT mutate [classifiedIds]; return candidates — the pipeline claims.
/// - MUST check [token.isCancelled] inside any loop doing I/O.
abstract class CategorizationStrategy {
  /// Which strategy this implements.
  GroupingStrategy get type;

  /// Whether this strategy requires network access.
  bool get needsNetwork;

  /// Execute this strategy and return proposed album groupings.
  ///
  /// [ctx]            — shared context (songs, albums, config)
  /// [classifiedIds]  — song IDs already claimed by earlier strategies (READ ONLY)
  /// [token]          — cooperative cancellation
  /// [onProgress]     — callback to update UI progress
  Future<List<AiProposedAlbum>> run(
    StrategyContext ctx,
    Set<String> classifiedIds,
    CancellationToken token,
    void Function(StageProgress) onProgress,
  );

  /// Helper: filter songs down to only unclaimed ones.
  List<Song> unclaimed(StrategyContext ctx, Set<String> classifiedIds) {
    return ctx.songs.where((s) => !classifiedIds.contains(s.videoId)).toList();
  }
}
