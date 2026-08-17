import 'package:flutter/foundation.dart';
import 'package:uuid/uuid.dart';
import '../../models/song.dart';
import '../../models/album.dart';
import 'models.dart';
import 'musicbrainz_client.dart';
import 'gemini_client.dart';
import 'metadata_cache.dart';
import 'strategies/strategy.dart';
import 'strategies/existing_album_strategy.dart';
import 'strategies/folder_strategy.dart';
import 'strategies/artist_strategy.dart';
import 'strategies/mood_strategy.dart';
import 'strategies/real_album_strategy.dart';
import 'strategies/genre_strategy.dart';
import 'strategies/zeroshot_strategy.dart';

/// Orchestrator that executes strategies in user-defined order.
///
/// Single source of truth for claiming song IDs — strategies return
/// candidates, the pipeline claims them after each stage.
class CategorizationPipeline {
  static const _uuid = Uuid();

  /// Run the full categorization pipeline.
  Future<CategorizationResult> run(
    List<Song> songs,
    List<UserAlbum> albums,
    CategorizationRequest request, {
    void Function(StageProgress)? onProgress,
    CancellationToken? token,
    Set<String>? rejectedAssignments,
  }) async {
    final stopwatch = Stopwatch()..start();
    final effectiveToken = token ?? CancellationToken();

    if (songs.isEmpty) {
      return CategorizationResult(
        proposals: [],
        unassignedSongIds: [],
        stats: const CategorizationStats(),
      );
    }

    // Filter albums based on request settings
    final effectiveAlbums = request.includeDefaultAlbums
        ? albums
        : albums.where((a) => a.isCustom).toList();

    // 1. Initialize network clients if enabled (MusicBrainz + Gemini only).
    MusicBrainzClient? mbClient;
    GeminiClient? geminiClient;

    if (request.allowNetwork) {
      mbClient = MusicBrainzClient();
      geminiClient = GeminiClient();
    }

    final ctx = StrategyContext(
      songs: songs,
      albums: effectiveAlbums,
      request: request,
      rejectedAssignments: rejectedAssignments ?? {},
      mbClient: mbClient,
      geminiClient: geminiClient,
    );

    // Expand smartAuto → concrete strategy list
    final strategyOrder = request.expandedStrategies;

    // Build strategy instances
    final strategyMap = _buildStrategies();

    final Set<String> classifiedIds = {};
    final List<AiProposedAlbum> proposals = [];
    final Map<ProposalSource, int> perSourceCounts = {};
    bool wasCancelled = false;

    try {
      for (final strategyType in strategyOrder) {
        if (effectiveToken.isCancelled) {
          wasCancelled = true;
          break;
        }

        final strategy = strategyMap[strategyType];
        if (strategy == null) {
          debugPrint(
            '[Pipeline] No implementation for $strategyType, skipping',
          );
          continue;
        }

        // Skip network strategies when offline, or the Gemini-backed
        // user-category strategy when no Gemini client is available.
        if (strategy.needsNetwork &&
            (!request.allowNetwork ||
                (strategyType == GroupingStrategy.byUserCategories &&
                    geminiClient == null))) {
          debugPrint(
            '[Pipeline] Skipping $strategyType (network/API unavailable)',
          );
          continue;
        }

        try {
          final candidates = await strategy.run(
            ctx,
            classifiedIds,
            effectiveToken,
            onProgress ?? (_) {},
          );

          if (effectiveToken.isCancelled) {
            wasCancelled = true;
            break;
          }

          // Dedupe candidates against existing proposals
          final deduped = _deduplicateCandidates(candidates, proposals);

          // Apply min-group-size filter
          final accepted = <AiProposedAlbum>[];
          final stash = <String>[]; // Songs from too-small groups

          for (final candidate in deduped) {
            // Existing-album proposals bypass min-group-size
            final bypasses = candidate.action == ProposalAction.addToExisting;

            if (bypasses || candidate.songIds.length >= request.minGroupSize) {
              accepted.add(candidate);
            } else {
              // Route by smallGroupMode
              switch (request.smallGroupMode) {
                case MergeMode.discard:
                  // Leave unclaimed → ends up in unassignedSongIds
                  break;
                case MergeMode.mergeIntoMix:
                  stash.addAll(candidate.songIds);
                  break;
                case MergeMode.keepAnyway:
                  accepted.add(
                    candidate.copyWith(confidence: candidate.confidence * 0.6),
                  );
                  break;
              }
            }
          }

          // Claim song IDs for accepted proposals
          for (final proposal in accepted) {
            classifiedIds.addAll(proposal.songIds);
            proposals.add(proposal);

            // Track per-source counts
            perSourceCounts[proposal.source] =
                (perSourceCounts[proposal.source] ?? 0) + 1;
          }

          // Handle merge-into-mix stash
          if (stash.isNotEmpty && stash.length >= request.minGroupSize) {
            final mixProposal = AiProposedAlbum(
              id: _uuid.v4(),
              name: 'Discoveries',
              description: 'Small groups combined into a discovery playlist.',
              songIds: List.unmodifiable(stash),
              action: ProposalAction.createNew,
              source: ProposalSource.fallback,
              confidence: 0.5,
            );
            classifiedIds.addAll(stash);
            proposals.add(mixProposal);
          }
        } catch (e) {
          debugPrint('[Pipeline] Strategy $strategyType failed: $e');
          // Continue with next strategy
        }
      }
    } finally {
      // 2. Cleanup & persist caches
      if (mbClient != null) {
        mbClient.dispose();
        await MetadataCache().flush();
      }
      if (geminiClient != null) {
        geminiClient.dispose();
      }
    }

    // Collect unassigned song IDs
    final unassigned = songs
        .where((s) => !classifiedIds.contains(s.videoId))
        .map((s) => s.videoId)
        .toList();

    stopwatch.stop();

    // Hint the user when their own category labels were the only thing missing
    // (Gemini classifies into them). No HF/embedding involvement anymore.
    final infoMessage = (request.allowNetwork && request.userCategories.isEmpty)
        ? 'Add your own category labels in Settings to let Gemini sort songs into them.'
        : null;

    return CategorizationResult(
      proposals: proposals,
      unassignedSongIds: unassigned,
      stats: CategorizationStats(
        totalSongs: songs.length,
        classifiedCount: classifiedIds.length,
        unassignedCount: unassigned.length,
        mbLookups: mbClient?.lookupsCount ?? 0,
        mbCacheHits: mbClient?.cacheHitsCount ?? 0,
        mbAborted: mbClient?.isAborted ?? false,
        cancelled: wasCancelled,
        elapsed: stopwatch.elapsed,
        perSourceCounts: perSourceCounts,
        infoMessage: infoMessage,
      ),
    );
  }

  /// Build strategy instances for all implemented strategies.
  Map<GroupingStrategy, CategorizationStrategy> _buildStrategies() {
    return {
      GroupingStrategy.existingAlbumsFirst: ExistingAlbumStrategy(),
      GroupingStrategy.byFolder: FolderStrategy(),
      GroupingStrategy.byArtist: ArtistStrategy(),
      GroupingStrategy.byMood: MoodStrategy(),
      GroupingStrategy.byRealAlbum: RealAlbumStrategy(),
      GroupingStrategy.byGenre: GenreStrategy(),
      GroupingStrategy.byUserCategories: ZeroShotStrategy(),
      // bySimilarity intentionally omitted — it required Hugging Face embeddings,
      // which have been removed. It is dropped from the smartAuto expansion too.
    };
  }

  /// Deduplicate candidates against accepted proposals.
  ///
  /// If overlap >= 80%, keep the higher-confidence one.
  List<AiProposedAlbum> _deduplicateCandidates(
    List<AiProposedAlbum> candidates,
    List<AiProposedAlbum> accepted,
  ) {
    final result = <AiProposedAlbum>[];

    for (final candidate in candidates) {
      bool isDuplicate = false;
      final candSet = candidate.songIds.toSet();

      for (int i = 0; i < accepted.length; i++) {
        final existing = accepted[i];
        final existingSet = existing.songIds.toSet();

        final overlapCount = candSet.intersection(existingSet).length;
        final minSize = candSet.length < existingSet.length
            ? candSet.length
            : existingSet.length;

        if (minSize > 0 && overlapCount / minSize >= 0.8) {
          // High overlap — keep higher confidence
          if (candidate.confidence > existing.confidence) {
            // Replace existing with candidate
            accepted[i] = candidate;
          }
          isDuplicate = true;
          break;
        }
      }

      if (!isDuplicate) {
        result.add(candidate);
      }
    }

    return result;
  }
}
