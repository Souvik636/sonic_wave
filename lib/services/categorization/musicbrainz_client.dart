import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'metadata_cache.dart';

class MetadataResult {
  final bool found;
  final String? genre;
  final String? albumTitle;
  final String? canonicalArtist;
  final int score;

  const MetadataResult({
    required this.found,
    this.genre,
    this.albumTitle,
    this.canonicalArtist,
    this.score = 0,
  });
}

/// MusicBrainz API client with rate limiting, retries, and circuit breaker.
class MusicBrainzClient {
  static const String _userAgent = 'SonicWave/1.0 (sonicwave-music-app)';

  final HttpClient _client = HttpClient()
    ..connectionTimeout = const Duration(seconds: 8);

  final MetadataCache _cache = MetadataCache();

  int _consecutiveFailures = 0;
  bool _aborted = false;
  int _lookupsCount = 0;
  int _cacheHitsCount = 0;
  bool _budgetExhaustedLogged = false;

  bool get isAborted => _aborted;
  int get lookupsCount => _lookupsCount;
  int get cacheHitsCount => _cacheHitsCount;

  /// Clean special Lucene syntax characters.
  String _lucene(String s) {
    return s.replaceAllMapped(
        RegExp(r'[+\-&|!(){}\[\]^"~*?:\\/]'), (m) => '\\${m[0]}');
  }

  /// Close the HTTP client.
  void dispose() {
    _client.close(force: true);
  }

  /// Lookup song metadata on MusicBrainz, prioritizing cache.
  Future<MetadataResult> lookup(
    String songId,
    String title,
    String artist, {
    int maxLookups = 30,
  }) async {
    await _cache.load();

    // 1. Check cache first
    final cached = _cache.get(songId);
    if (cached != null) {
      _cacheHitsCount++;
      return MetadataResult(
        found: cached.genre != null || cached.albumTitle != null || cached.artistName != null,
        genre: cached.genre,
        albumTitle: cached.albumTitle,
        canonicalArtist: cached.artistName,
        score: 100, // Cache hits are treated as high confidence matches
      );
    }

    // 2. Budget / Circuit Breaker check
    if (_aborted) {
      return const MetadataResult(found: false);
    }

    if (_lookupsCount >= maxLookups) {
      if (!_budgetExhaustedLogged) {
        debugPrint('[MusicBrainz] Lookup budget ($maxLookups) exhausted. Skipping remaining network lookups.');
        _budgetExhaustedLogged = true;
      }
      return const MetadataResult(found: false);
    }

    _lookupsCount++;

    // MusicBrainz rate limit: 1 req/sec. Wait 1100ms before execution.
    await Future.delayed(const Duration(milliseconds: 1100));

    try {
      final result = await _fetchFromNetwork(title, artist);
      _consecutiveFailures = 0; // Reset failure counter on success

      // Cache result
      _cache.put(
        songId,
        genre: result.genre,
        albumTitle: result.albumTitle,
        artistName: result.canonicalArtist,
      );

      return result;
    } catch (e) {
      _consecutiveFailures++;
      debugPrint('[MusicBrainz] Network failure #$_consecutiveFailures: $e');

      if (_consecutiveFailures >= 3) {
        _aborted = true;
        debugPrint('[MusicBrainz] Circuit breaker tripped. Network lookups disabled.');
      }

      // Cache negative lookup to avoid retrying immediately
      _cache.put(songId);

      return const MetadataResult(found: false);
    }
  }

  Future<MetadataResult> _fetchFromNetwork(String title, String artist, {bool isRetry = false}) async {
    final queryArtist = artist.toLowerCase() == 'local audio' || artist.toLowerCase() == 'unknown'
        ? ''
        : artist;

    final uri = Uri(
      scheme: 'https',
      host: 'musicbrainz.org',
      path: '/ws/2/recording',
      queryParameters: {
        'query': queryArtist.isEmpty
            ? 'recording:"${_lucene(title)}"'
            : 'recording:"${_lucene(title)}" AND artist:"${_lucene(queryArtist)}"',
        'fmt': 'json',
        'limit': '5',
        'inc': 'releases+release-groups+tags',
      },
    );

    final request = await _client.getUrl(uri);
    request.headers.set('User-Agent', _userAgent);
    request.headers.set('Accept', 'application/json');

    final response = await request.close().timeout(const Duration(seconds: 8));

    if (response.statusCode == 503 && !isRetry) {
      // 503 Service Unavailable (rate limit). Retry once with 2s backoff.
      await response.drain();
      debugPrint('[MusicBrainz] HTTP 503 received. Retrying with 2s backoff...');
      await Future.delayed(const Duration(seconds: 2));
      return _fetchFromNetwork(title, artist, isRetry: true);
    }

    if (response.statusCode != 200) {
      await response.drain();
      throw HttpException('HTTP error ${response.statusCode}');
    }

    final body = await response.transform(utf8.decoder).join();
    final Map<String, dynamic> data = json.decode(body);

    final recordings = data['recordings'] as List<dynamic>?;
    if (recordings == null || recordings.isEmpty) {
      return const MetadataResult(found: false);
    }

    // Sort by Lucene score to get best match
    recordings.sort((a, b) => ((b['score'] as int?) ?? 0).compareTo((a['score'] as int?) ?? 0));
    final rec = recordings.first as Map<String, dynamic>;
    final score = rec['score'] as int? ?? 0;

    if (score < 75) {
      return const MetadataResult(found: false);
    }

    // Extract tags/genre
    String? genre;
    final tags = rec['tags'] as List<dynamic>?;
    if (tags != null && tags.isNotEmpty) {
      // Sort tags by count to get the most common genre
      tags.sort((a, b) => ((b['count'] as int?) ?? 0).compareTo((a['count'] as int?) ?? 0));
      genre = tags.first['name'] as String?;
    }

    // Extract album name, prioritizing primary-type == Album and excluding compilations
    String? albumTitle;
    final releases = rec['releases'] as List<dynamic>?;
    if (releases != null && releases.isNotEmpty) {
      final List<Map<String, dynamic>> candidates = [];
      for (final r in releases) {
        if (r is Map<String, dynamic>) {
          final group = r['release-group'] as Map<String, dynamic>?;
          if (group != null) {
            final primaryType = group['primary-type'] as String?;
            final secondaryTypes = group['secondary-types'] as List<dynamic>?;
            final isCompilation = secondaryTypes?.contains('Compilation') ?? false;

            if (primaryType == 'Album' && !isCompilation) {
              candidates.add(r);
            }
          }
        }
      }

      if (candidates.isNotEmpty) {
        albumTitle = candidates.first['title'] as String?;
      } else {
        albumTitle = releases.first['title'] as String?;
      }
    }

    // Extract canonical artist
    String? artistName;
    final credits = rec['artist-credit'] as List<dynamic>?;
    if (credits != null && credits.isNotEmpty) {
      final art = credits.first['artist'] as Map<String, dynamic>?;
      artistName = art?['name'] as String?;
    }

    return MetadataResult(
      found: true,
      genre: genre,
      albumTitle: albumTitle,
      canonicalArtist: artistName,
      score: score,
    );
  }
}
