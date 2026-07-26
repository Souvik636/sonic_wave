import 'package:uuid/uuid.dart';
import '../../../models/song.dart';
import '../models.dart';
import 'strategy.dart';

/// Groups unclaimed songs by keyword-based mood/theme matching.
///
/// Fixes from v1:
/// - Word-boundary regexes instead of raw substring (kills "Rich**hard**" → Hard Rock)
/// - ALL themes scored per song; best theme wins
/// - Ties broken by specificity (fewer total keywords = more specific)
class MoodStrategy extends CategorizationStrategy {
  static const _uuid = Uuid();

  @override
  GroupingStrategy get type => GroupingStrategy.byMood;

  @override
  bool get needsNetwork => false;

  /// Theme definitions with keyword lists and descriptions.
  static const Map<String, _ThemeConfig> _themes = {
    'Lofi & Chill': _ThemeConfig(
      keywords: ['lofi', 'chill', 'relax', 'sleep', 'ambient', 'calm', 'dreamy', 'soothing'],
      description: 'Relaxing beats and ambient lofi vibes for studying or winding down.',
    ),
    'Acoustic & Mellow': _ThemeConfig(
      keywords: ['acoustic', 'unplugged', 'piano', 'guitar', 'mellow', 'ballad', 'soft'],
      description: 'Mellow acoustic performances, keyboard, and unplugged melodies.',
    ),
    'Rock & Energetic': _ThemeConfig(
      keywords: ['rock', 'metal', 'punk', 'grunge', 'electric', 'riff'],
      description: 'High energy tracks, live concerts, and guitar-driven rhythms.',
    ),
    'Electronic & Dance': _ThemeConfig(
      keywords: ['remix', 'dance', 'edm', 'club', 'house', 'techno', 'trance', 'bass', 'drop'],
      description: 'Upbeat dance mixes, electronic synths, and club remixes.',
    ),
    'Hip-Hop & Rap': _ThemeConfig(
      keywords: ['rap', 'hiphop', 'trap', 'freestyle', 'flow', 'bars', 'cypher'],
      description: 'Hip-hop beats, rap flows, and urban rhythms.',
    ),
    'Classical & Instrumental': _ThemeConfig(
      keywords: ['classical', 'instrumental', 'orchestra', 'symphony', 'sonata', 'concerto', 'opus'],
      description: 'Classical compositions, orchestral works, and instrumental performances.',
    ),
    'Focus & Study': _ThemeConfig(
      keywords: ['focus', 'study', 'concentration', 'meditation', 'zen', 'mindful'],
      description: 'Focus music and study aids for productivity and concentration.',
    ),
    'Bollywood & Indian': _ThemeConfig(
      keywords: ['bollywood', 'hindi', 'punjabi', 'bhojpuri', 'tamil', 'telugu', 'desi', 'sufi'],
      description: 'Indian music spanning Bollywood, regional, and Sufi traditions.',
    ),
  };

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
      label: 'Analyzing song moods',
      done: 0,
      total: songs.length,
    ));

    // Pre-compile word-boundary regexes for each theme
    final compiledThemes = <String, List<RegExp>>{};
    for (final entry in _themes.entries) {
      compiledThemes[entry.key] = entry.value.keywords.map((kw) {
        // Word-boundary regex: matches whole words only
        return RegExp(r'(^|\W)' + RegExp.escape(kw) + r'(\W|$)', caseSensitive: false);
      }).toList();
    }

    // Score each song against ALL themes, pick the best one
    final Map<String, List<Song>> themeGroups = {};
    for (final theme in _themes.keys) {
      themeGroups[theme] = [];
    }

    for (int i = 0; i < songs.length; i++) {
      if (token.isCancelled) break;

      final song = songs[i];
      final combined = '${song.title} ${song.artist}'.toLowerCase();

      String? bestTheme;
      int bestScore = 0;
      int bestSpecificity = 999; // Lower = more specific

      for (final entry in compiledThemes.entries) {
        int matchCount = 0;
        for (final regex in entry.value) {
          if (regex.hasMatch(combined)) {
            matchCount++;
          }
        }

        if (matchCount > 0) {
          final specificity = _themes[entry.key]!.keywords.length;

          // Pick theme with most matches; break ties by specificity
          if (matchCount > bestScore ||
              (matchCount == bestScore && specificity < bestSpecificity)) {
            bestTheme = entry.key;
            bestScore = matchCount;
            bestSpecificity = specificity;
          }
        }
      }

      if (bestTheme != null) {
        themeGroups[bestTheme]!.add(song);
      }

      if (i % 10 == 0) {
        onProgress(StageProgress(
          label: 'Analyzing song moods',
          done: i + 1,
          total: songs.length,
        ));
      }
    }

    // Build proposals
    final proposals = <AiProposedAlbum>[];
    for (final entry in themeGroups.entries) {
      if (entry.value.isEmpty) continue;

      proposals.add(AiProposedAlbum(
        id: _uuid.v4(),
        name: entry.key,
        description: _themes[entry.key]!.description,
        songIds: List.unmodifiable(entry.value.map((s) => s.videoId)),
        action: ProposalAction.createNew,
        source: ProposalSource.mood,
        confidence: 0.65,
      ));
    }

    onProgress(StageProgress(
      label: 'Analyzing song moods',
      done: songs.length,
      total: songs.length,
    ));

    return proposals;
  }
}

class _ThemeConfig {
  final List<String> keywords;
  final String description;

  const _ThemeConfig({required this.keywords, required this.description});
}
