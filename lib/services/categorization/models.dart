
// ══════════════════════════════════════════════════════════════
// ENUMS
// ══════════════════════════════════════════════════════════════

/// Strategies the user can reorder to control classification priority.
enum GroupingStrategy {
  existingAlbumsFirst, // match Custom + Default albums
  byRealAlbum,         // MusicBrainz release clustering
  byFolder,            // local files: folder = album
  byArtist,            // canonical artist grouping
  byGenre,             // MusicBrainz tags → keyword fallback
  byMood,              // keyword themes
  byUserCategories,    // Gemini classification against the user's own labels
  bySimilarity,        // REMOVED (was HF embedding clustering) — no longer run
  smartAuto,           // expands to a sensible default order
}

enum ProposalAction { addToExisting, createNew }

enum ProposalSource {
  existingMatch,
  musicbrainz,
  folder,
  artist,
  genre,
  mood,
  userCategory,
  similarity,
  fallback,
}

enum MergeMode { discard, mergeIntoMix, keepAnyway }

// ══════════════════════════════════════════════════════════════
// REQUEST
// ══════════════════════════════════════════════════════════════

/// Configuration for a categorization run.
class CategorizationRequest {
  /// Strategies executed in THIS order (user-controlled priority).
  final List<GroupingStrategy> strategies;

  /// Whether to match songs against default (non-custom) albums too.
  final bool includeDefaultAlbums;

  /// Minimum songs per group to accept a proposal (default 3).
  final int minGroupSize;

  /// Whether network-dependent strategies are allowed.
  final bool allowNetwork;

  /// Whether folder strategy should create new albums for unmatched folders.
  final bool createMissingAlbums;

  /// How to handle groups smaller than [minGroupSize].
  final MergeMode smallGroupMode;

  /// Max MusicBrainz network lookups per run (default 30).
  final int maxMetadataLookups;

  /// User-typed category labels for Gemini classification.
  final List<String> userCategories;

  /// Minimum confidence for a Gemini category to claim a song (default 0.55).
  final double zeroShotThreshold;

  const CategorizationRequest({
    this.strategies = const [GroupingStrategy.smartAuto],
    this.includeDefaultAlbums = false,
    this.minGroupSize = 3,
    this.allowNetwork = true,
    this.createMissingAlbums = true,
    this.smallGroupMode = MergeMode.mergeIntoMix,
    this.maxMetadataLookups = 30,
    this.userCategories = const [],
    this.zeroShotThreshold = 0.55,
  });

  /// Expand [smartAuto] into concrete ordered strategies.
  List<GroupingStrategy> get expandedStrategies {
    final List<GroupingStrategy> result = [];
    for (final s in strategies) {
      if (s == GroupingStrategy.smartAuto) {
        result.addAll([
          GroupingStrategy.existingAlbumsFirst,
          GroupingStrategy.byRealAlbum,
          if (userCategories.isNotEmpty) GroupingStrategy.byUserCategories,
          GroupingStrategy.byFolder,
          GroupingStrategy.byArtist,
          GroupingStrategy.byMood,
        ]);
      } else {
        result.add(s);
      }
    }
    return result;
  }
}

// ══════════════════════════════════════════════════════════════
// PROPOSAL
// ══════════════════════════════════════════════════════════════

/// A single proposed album grouping returned by the pipeline.
class AiProposedAlbum {
  /// Stable UUID for review-screen state management.
  final String id;

  /// Display name for the proposed album.
  final String name;

  /// Human-readable explanation of how this group was formed.
  final String description;

  /// Song IDs belonging to this group (unmodifiable).
  final List<String> songIds;

  /// Non-null when action == addToExisting.
  final String? existingAlbumId;

  /// Whether to add to an existing album or create a new one.
  final ProposalAction action;

  /// Which strategy produced this proposal (drives UI badge).
  final ProposalSource source;

  /// Confidence score 0.0–1.0 (drives sort + badge tier).
  final double confidence;

  const AiProposedAlbum({
    required this.id,
    required this.name,
    required this.description,
    required this.songIds,
    this.existingAlbumId,
    required this.action,
    required this.source,
    this.confidence = 0.7,
  });

  AiProposedAlbum copyWith({
    String? id,
    String? name,
    String? description,
    List<String>? songIds,
    String? existingAlbumId,
    ProposalAction? action,
    ProposalSource? source,
    double? confidence,
  }) {
    return AiProposedAlbum(
      id: id ?? this.id,
      name: name ?? this.name,
      description: description ?? this.description,
      songIds: songIds ?? this.songIds,
      existingAlbumId: existingAlbumId ?? this.existingAlbumId,
      action: action ?? this.action,
      source: source ?? this.source,
      confidence: confidence ?? this.confidence,
    );
  }

  /// Confidence tier for UI badge rendering.
  String get confidenceTier {
    if (confidence >= 0.85) return 'High';
    if (confidence >= 0.65) return 'Medium';
    return 'Low';
  }
}

// ══════════════════════════════════════════════════════════════
// RESULT
// ══════════════════════════════════════════════════════════════

/// Final output of a categorization pipeline run.
class CategorizationResult {
  final List<AiProposedAlbum> proposals;

  /// Songs that no strategy claimed — shown as "Needs your decision" in review UI.
  final List<String> unassignedSongIds;

  final CategorizationStats stats;

  const CategorizationResult({
    required this.proposals,
    required this.unassignedSongIds,
    required this.stats,
  });
}

/// Run statistics for diagnostics and UI feedback.
class CategorizationStats {
  final int totalSongs;
  final int classifiedCount;
  final int unassignedCount;
  final int mbLookups;
  final int mbCacheHits;
  final bool mbAborted;
  final bool cancelled;
  final Duration elapsed;
  final Map<ProposalSource, int> perSourceCounts;
  final String? infoMessage;

  const CategorizationStats({
    this.totalSongs = 0,
    this.classifiedCount = 0,
    this.unassignedCount = 0,
    this.mbLookups = 0,
    this.mbCacheHits = 0,
    this.mbAborted = false,
    this.cancelled = false,
    this.elapsed = Duration.zero,
    this.perSourceCounts = const {},
    this.infoMessage,
  });
}

// ══════════════════════════════════════════════════════════════
// PROGRESS & CANCELLATION
// ══════════════════════════════════════════════════════════════

/// Emitted by strategies to update the progress UI.
class StageProgress {
  final String label;
  final int done;
  final int total;

  const StageProgress({
    required this.label,
    this.done = 0,
    this.total = 0,
  });
}

/// Cooperative cancellation token — checked by strategies inside I/O loops.
class CancellationToken {
  bool _cancelled = false;

  bool get isCancelled => _cancelled;

  void cancel() => _cancelled = true;
}
