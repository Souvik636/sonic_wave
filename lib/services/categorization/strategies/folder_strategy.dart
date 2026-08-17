import 'package:uuid/uuid.dart';
import '../../../models/song.dart';
import '../models.dart';
import '../title_cleaner.dart';
import '../album_match_scorer.dart';
import 'strategy.dart';

/// Groups local songs by their parent directory path.
///
/// Fixes from v1:
/// - Humanizes folder names (underscores → spaces, title-case)
/// - Skips generic container folders (Music, Downloads, etc.)
/// - Optionally creates new albums for unmatched folders
/// - Scores folder names against existing albums to avoid duplicates
class FolderStrategy extends CategorizationStrategy {
  static const _uuid = Uuid();

  /// Folders that are generic containers and should not be used as album names.
  static const Set<String> _genericFolders = {
    '0',
    'music',
    'download',
    'downloads',
    'audio',
    'storage',
    'emulated',
    'documents',
    'raw',
    'cache',
    'temp',
    'media',
    'sdcard',
    'internal',
    'external',
    'files',
    'data',
  };

  @override
  GroupingStrategy get type => GroupingStrategy.byFolder;

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

    onProgress(
      StageProgress(label: 'Grouping by folder', done: 0, total: songs.length),
    );

    // Group songs by parent directory
    final Map<String, List<Song>> folderGroups = {};
    for (final song in songs) {
      if (token.isCancelled) break;

      final path = song.filePath ?? song.videoId;
      final parts = path.split(RegExp(r'[/\\]'));
      if (parts.length <= 1) continue;

      final folderName = parts[parts.length - 2].trim();
      final folderLower = folderName.toLowerCase();

      // Skip generic container folders and very short names
      if (folderName.length <= 2 || _genericFolders.contains(folderLower)) {
        continue;
      }

      folderGroups.putIfAbsent(folderName, () => []).add(song);
    }

    // Build proposals
    final proposals = <AiProposedAlbum>[];
    for (final entry in folderGroups.entries) {
      if (token.isCancelled) break;

      final folderName = entry.key;
      final folderSongs = entry.value;

      final humanName = TitleCleaner.humanizeFolderName(folderName);

      // Check if this folder maps to an existing album
      final match = AlbumMatchScorer.bestMatch(humanName, ctx.albums);

      if (match != null) {
        proposals.add(
          AiProposedAlbum(
            id: _uuid.v4(),
            name: match.album.name,
            description:
                'Songs from your "$folderName" folder matched to this album.',
            songIds: List.unmodifiable(folderSongs.map((s) => s.videoId)),
            existingAlbumId: match.album.id,
            action: ProposalAction.addToExisting,
            source: ProposalSource.folder,
            confidence: match.score,
          ),
        );
      } else if (ctx.request.createMissingAlbums) {
        proposals.add(
          AiProposedAlbum(
            id: _uuid.v4(),
            name: humanName,
            description: 'Songs found in your "$folderName" folder.',
            songIds: List.unmodifiable(folderSongs.map((s) => s.videoId)),
            action: ProposalAction.createNew,
            source: ProposalSource.folder,
            confidence: 0.8,
          ),
        );
      }
    }

    onProgress(
      StageProgress(
        label: 'Grouping by folder',
        done: songs.length,
        total: songs.length,
      ),
    );

    return proposals;
  }
}
