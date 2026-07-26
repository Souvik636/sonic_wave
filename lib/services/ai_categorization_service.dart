import 'package:flutter/foundation.dart';
import '../models/song.dart';
import '../models/album.dart';
import 'categorization/models.dart' as cat;
import 'categorization/categorization_pipeline.dart';

/// Mutable proposed album for the review UI (backward-compatible with existing sheet).
class AiProposedAlbum {
  String name;
  String description;
  final List<String> songIds;
  final String? existingAlbumId;
  final String source;       // Badge label: "Existing", "Folder", "Artist", "Mood"
  final double confidence;   // 0.0–1.0

  AiProposedAlbum({
    required this.name,
    required this.description,
    required this.songIds,
    this.existingAlbumId,
    this.source = '',
    this.confidence = 0.7,
  });
}

/// AI Categorization Service — now delegates to the modular pipeline.
///
/// This wrapper maintains backward compatibility with the existing UI while
/// using the new strategy-based pipeline internally.
class AiCategorizationService {
  final CategorizationPipeline _pipeline = CategorizationPipeline();

  /// Categorize songs using the new modular pipeline.
  ///
  /// Returns mutable [AiProposedAlbum] instances for the review UI.
  Future<List<AiProposedAlbum>> categorizeSongs(
    List<Song> songs,
    List<UserAlbum> existingAlbums, {
    void Function(cat.StageProgress)? onProgress,
    cat.CancellationToken? token,
  }) async {
    if (songs.isEmpty) return [];

    final existingNames = existingAlbums.map((a) => a.name).toList();
    final standardSuggestions = [
      'Workout',
      'Chill Vibes',
      'Romantic',
      'Devotional',
      'Party Hits',
      'Sad Melodies',
    ];
    final List<String> categories = [...existingNames];
    for (final sug in standardSuggestions) {
      if (!existingNames.any((name) => name.toLowerCase() == sug.toLowerCase())) {
        categories.add(sug);
      }
    }

    final request = cat.CategorizationRequest(
      strategies: [cat.GroupingStrategy.smartAuto],
      includeDefaultAlbums: false,
      minGroupSize: 3,
      allowNetwork: true, // Enabled for MusicBrainz and Gemini lookups
      createMissingAlbums: true,
      smallGroupMode: cat.MergeMode.mergeIntoMix,
      userCategories: categories,
    );

    final result = await _pipeline.run(
      songs,
      existingAlbums,
      request,
      onProgress: onProgress,
      token: token,
    );

    debugPrint('[AiCategorization] Pipeline completed:');
    debugPrint('  Total: ${result.stats.totalSongs}');
    debugPrint('  Classified: ${result.stats.classifiedCount}');
    debugPrint('  Unassigned: ${result.stats.unassignedCount}');
    debugPrint('  Elapsed: ${result.stats.elapsed.inMilliseconds}ms');

    // Convert pipeline proposals to mutable AiProposedAlbum for the review UI
    final proposals = <AiProposedAlbum>[];
    for (final p in result.proposals) {
      proposals.add(AiProposedAlbum(
        name: p.name,
        description: p.description,
        songIds: List.from(p.songIds), // Mutable copy for review UI
        existingAlbumId: p.existingAlbumId,
        source: _sourceLabel(p.source),
        confidence: p.confidence,
      ));
    }

    // Add unassigned songs as "Needs Your Decision" group
    if (result.unassignedSongIds.isNotEmpty) {
      proposals.add(AiProposedAlbum(
        name: 'Needs Your Decision',
        description: '${result.unassignedSongIds.length} songs couldn\'t be automatically grouped. Assign them manually.',
        songIds: List.from(result.unassignedSongIds),
        source: 'Unassigned',
        confidence: 0.0,
      ));
    }

    return proposals;
  }

  String _sourceLabel(cat.ProposalSource source) {
    switch (source) {
      case cat.ProposalSource.existingMatch: return 'Existing Album';
      case cat.ProposalSource.musicbrainz: return 'MusicBrainz';
      case cat.ProposalSource.folder: return 'Folder';
      case cat.ProposalSource.artist: return 'Artist';
      case cat.ProposalSource.genre: return 'Genre';
      case cat.ProposalSource.mood: return 'Mood';
      case cat.ProposalSource.userCategory: return 'Your Category';
      case cat.ProposalSource.similarity: return 'Similar';
      case cat.ProposalSource.fallback: return 'Discovery';
    }
  }
}
