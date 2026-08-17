import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:youtube_explode_dart/youtube_explode_dart.dart';
import 'package:flutter/foundation.dart';
import 'package:extractor/extractor.dart';
import '../models/song.dart';
import '../providers/settings_provider.dart' show AudioQuality;
import 'ytdlp_runtime.dart';
import 'diagnostic_log_service.dart';
import 'encoding_sanitizer.dart';

class YouTubeService {
  static YoutubeExplode _yt = YoutubeExplode();

  static void refreshExplodeClient() {
    try {
      debugPrint('[YT] Refreshing YoutubeExplode client socket connection pool');
      _yt.close();
    } catch (_) {}
    _yt = YoutubeExplode();
  }

  /// Streaming quality preference (set from Settings via PlayerProvider).
  /// low ≈ smallest bitrate, medium ≈ ~128kbps balance, high = best bitrate.
  static AudioQuality streamingQuality = AudioQuality.high;

  // Stream URL cache: '<videoId>@<quality>' → (url, timestamp)
  //
  // The key includes the quality because a cached High URL must NOT be served
  // after the user switches to Low. Keying on videoId alone made a quality
  // change appear to do nothing until the 5-minute TTL lapsed.
  //
  // STATIC, because YouTubeService is not a singleton and callers each build
  // their own: the audio handler holds one, StreamResolverService holds a
  // different one, and the providers hold three more. Per-instance this cache
  // silently threw away the app's two prefetch paths — the near-end
  // `prefetchStreamUrl` warmed the handler's map while playback resolved
  // through the resolver's map, so the URL was ALWAYS re-resolved from scratch
  // and every skip paid the full 10-30s yt-dlp extraction it had just paid to
  // avoid. One shared map is what makes prefetching (and replaying a song)
  // actually free. The quality is already in the key, so sharing cannot leak a
  // stale-quality URL across instances.
  static final Map<String, _CachedUrl> _streamCache = {};

  /// How long a resolved URL stays usable.
  ///
  /// This was 5 minutes, which threw away perfectly good URLs: YouTube's signed
  /// stream links are typically valid for hours, so replaying a song from six
  /// minutes ago paid a full re-resolution — the single most expensive thing in
  /// the playback path — for no reason. 90 minutes keeps replays and
  /// back-navigation instant while staying well inside the real expiry, and a
  /// URL that does go stale early is not a failure: the caller falls through to
  /// the existing Explode/Invidious/Piped/yt-dlp ladder, and retries force a
  /// refresh explicitly (see [getAudioStreamUrl]'s `forceRefresh`).
  static const Duration _cacheExpiry = Duration(minutes: 90);

  /// Evict expired entries so the cache doesn't grow unbounded during long
  /// listening sessions. Called on every cache write (cheap: the map is small).
  static void _evictExpiredCache() {
    _streamCache.removeWhere((_, v) => v.isExpired);
  }

  /// Cache key for [videoId] under the quality currently selected in Settings.
  static String _cacheKey(String videoId) =>
      '$videoId@${streamingQuality.name}';

  /// Forget the cached URL for [videoId], across every quality.
  ///
  /// Resolution succeeding and playback succeeding are different things. A URL
  /// can resolve cleanly and still be unplayable: it is IP-bound and the carrier
  /// NAT moved, YouTube 403s it on fetch, or the format is one ExoPlayer refuses.
  /// Nothing in the resolver can see that — only the player finds out.
  ///
  /// Without this the failure is *sticky*. The cache is static and now holds
  /// entries for 90 minutes, so a dead URL was handed back to every retry until
  /// the process itself died — which is exactly why force-closing the app and
  /// reopening it made a "permanently broken" song play again on the first try.
  /// Called whenever a load fails, so the next attempt genuinely re-resolves.
  ///
  /// Every quality variant is dropped, not just the current one: the entry was
  /// keyed by the quality active when it was written, and the user may have
  /// changed it between the failure and the retry.
  static void invalidateStreamUrl(String videoId) {
    final removed = <String>[];
    for (final quality in AudioQuality.values) {
      final key = '$videoId@${quality.name}';
      if (_streamCache.remove(key) != null) removed.add(quality.name);
    }
    if (removed.isNotEmpty) {
      debugPrint('[YT] Dropped cached stream url for $videoId '
          '(${removed.join(", ")}) after a playback failure');
    }
  }

  // Pool of Invidious instances (pruned to verified-working ones)
  static List<String> _invidiousInstances = [
    'invidious.drgns.space',
    'inv.tux.pizza',
    'yewtu.be',
    'invidious.nerdvpn.de',
  ];

  // Pool of Piped API instances (alternative YouTube frontend)
  static List<String> _pipedInstances = [
    'https://api.piped.private.coffee',
  ];

  static bool _instancesLoaded = false;

  /// Instances that just failed, and when.
  ///
  /// These used to be permanent `Set<String>` blacklists for the life of the
  /// process, which is why resolution got progressively worse the longer the app
  /// stayed open: on mobile a timeout means "this cell handed over" far more
  /// often than "this host is dead", and with only a handful of seeded instances
  /// a few transient failures emptied the entire fallback pool. Every later
  /// share then had nothing but Explode and yt-dlp to fall back on, and a bad
  /// minute became a bad session.
  ///
  /// A cooldown keeps the useful half of the behaviour — don't re-dial a host
  /// that just timed out, within one resolution — without the permanence.
  static final Map<String, DateTime> _instanceCooldown = {};
  static final Map<String, DateTime> _pipedCooldown = {};

  /// How long a failed instance is skipped for.
  static const Duration _instanceCooldownPeriod = Duration(minutes: 3);

  /// Most instances one resolution will try before giving up on a mirror pool.
  ///
  /// The pool is walked in order and each attempt costs up to its own timeout,
  /// so an unbounded walk of a stale list can outlive the entire resolution
  /// deadline — and it is racing Explode and yt-dlp, which have very likely
  /// answered already. Three is enough for the pool to be a real fallback
  /// without it becoming the reason a song takes twenty seconds to start.
  static const int _maxInstanceAttempts = 3;

  static bool _isCoolingDown(Map<String, DateTime> book, String key) {
    final failedAt = book[key];
    if (failedAt == null) return false;
    if (DateTime.now().difference(failedAt) >= _instanceCooldownPeriod) {
      book.remove(key);
      return false;
    }
    return true;
  }

  static final List<YoutubeApiClient> _clientPriority = [
    YoutubeApiClient.ios,
    YoutubeApiClient.tv,
    YoutubeApiClient.mweb,
    YoutubeApiClient.androidVr,
  ];

  /// Pre-defined static local song metadata catalog to prevent all startup YouTube/Invidious network/scraping calls
  static final List<Song> _trendingNow = [
    const Song(
      id: 'dMMOBgUTMTo',
      videoId: 'dMMOBgUTMTo',
      title: 'Starboy',
      artist: 'The Weeknd',
      thumbnailUrl: 'https://img.youtube.com/vi/dMMOBgUTMTo/mqdefault.jpg',
      highResThumbnailUrl: 'https://img.youtube.com/vi/dMMOBgUTMTo/hqdefault.jpg',
      duration: Duration(minutes: 3, seconds: 50),
    ),
    const Song(
      id: '2Vv-BfVoq4g',
      videoId: '2Vv-BfVoq4g',
      title: 'Perfect',
      artist: 'Ed Sheeran',
      thumbnailUrl: 'https://img.youtube.com/vi/2Vv-BfVoq4g/mqdefault.jpg',
      highResThumbnailUrl: 'https://img.youtube.com/vi/2Vv-BfVoq4g/hqdefault.jpg',
      duration: Duration(minutes: 4, seconds: 23),
    ),
    const Song(
      id: '4NRXx6U8ABQ',
      videoId: '4NRXx6U8ABQ',
      title: 'Blinding Lights',
      artist: 'The Weeknd',
      thumbnailUrl: 'https://img.youtube.com/vi/4NRXx6U8ABQ/mqdefault.jpg',
      highResThumbnailUrl: 'https://img.youtube.com/vi/4NRXx6U8ABQ/hqdefault.jpg',
      duration: Duration(minutes: 3, seconds: 20),
    ),
    const Song(
      id: 'JGwWNGJdvx8',
      videoId: 'JGwWNGJdvx8',
      title: 'Shape of You',
      artist: 'Ed Sheeran',
      thumbnailUrl: 'https://img.youtube.com/vi/JGwWNGJdvx8/mqdefault.jpg',
      highResThumbnailUrl: 'https://img.youtube.com/vi/JGwWNGJdvx8/hqdefault.jpg',
      duration: Duration(minutes: 3, seconds: 53),
    ),
    const Song(
      id: '60ItHLz5WEA',
      videoId: '60ItHLz5WEA',
      title: 'Faded',
      artist: 'Alan Walker',
      thumbnailUrl: 'https://img.youtube.com/vi/60ItHLz5WEA/mqdefault.jpg',
      highResThumbnailUrl: 'https://img.youtube.com/vi/60ItHLz5WEA/hqdefault.jpg',
      duration: Duration(minutes: 3, seconds: 32),
    ),
  ];

  static final Map<String, List<Song>> _staticCatalog = {
    'Pop Hits': [
      const Song(
        id: 'H5v3kku4y6Q',
        videoId: 'H5v3kku4y6Q',
        title: 'As It Was',
        artist: 'Harry Styles',
        thumbnailUrl: 'https://img.youtube.com/vi/H5v3kku4y6Q/mqdefault.jpg',
        highResThumbnailUrl: 'https://img.youtube.com/vi/H5v3kku4y6Q/hqdefault.jpg',
        duration: Duration(minutes: 2, seconds: 47),
      ),
      const Song(
        id: 'kTJczUoc26U',
        videoId: 'kTJczUoc26U',
        title: 'Stay',
        artist: 'The Kid LAROI & Justin Bieber',
        thumbnailUrl: 'https://img.youtube.com/vi/kTJczUoc26U/mqdefault.jpg',
        highResThumbnailUrl: 'https://img.youtube.com/vi/kTJczUoc26U/hqdefault.jpg',
        duration: Duration(minutes: 2, seconds: 21),
      ),
      const Song(
        id: 'G7KNmW9a75Y',
        videoId: 'G7KNmW9a75Y',
        title: 'Flowers',
        artist: 'Miley Cyrus',
        thumbnailUrl: 'https://img.youtube.com/vi/G7KNmW9a75Y/mqdefault.jpg',
        highResThumbnailUrl: 'https://img.youtube.com/vi/G7KNmW9a75Y/hqdefault.jpg',
        duration: Duration(minutes: 3, seconds: 20),
      ),
    ],
    'Hip Hop': [
      const Song(
        id: 'xpVfcZ0ZcFM',
        videoId: 'xpVfcZ0ZcFM',
        title: "God's Plan",
        artist: 'Drake',
        thumbnailUrl: 'https://img.youtube.com/vi/xpVfcZ0ZcFM/mqdefault.jpg',
        highResThumbnailUrl: 'https://img.youtube.com/vi/xpVfcZ0ZcFM/hqdefault.jpg',
        duration: Duration(minutes: 3, seconds: 18),
      ),
      const Song(
        id: 'tvTRZJ-4EyI',
        videoId: 'tvTRZJ-4EyI',
        title: 'HUMBLE.',
        artist: 'Kendrick Lamar',
        thumbnailUrl: 'https://img.youtube.com/vi/tvTRZJ-4EyI/mqdefault.jpg',
        highResThumbnailUrl: 'https://img.youtube.com/vi/tvTRZJ-4EyI/hqdefault.jpg',
        duration: Duration(minutes: 2, seconds: 57),
      ),
      const Song(
        id: 'd-JBBPbC3yA',
        videoId: 'd-JBBPbC3yA',
        title: 'SICKO MODE',
        artist: 'Travis Scott',
        thumbnailUrl: 'https://img.youtube.com/vi/d-JBBPbC3yA/mqdefault.jpg',
        highResThumbnailUrl: 'https://img.youtube.com/vi/d-JBBPbC3yA/hqdefault.jpg',
        duration: Duration(minutes: 5, seconds: 12),
      ),
    ],
    'Lo-Fi Chill': [
      const Song(
        id: 'jfKfPfyJRdk',
        videoId: 'jfKfPfyJRdk',
        title: 'lofi hip hop radio - beats to relax/study to',
        artist: 'Lofi Girl',
        thumbnailUrl: 'https://img.youtube.com/vi/jfKfPfyJRdk/mqdefault.jpg',
        highResThumbnailUrl: 'https://img.youtube.com/vi/jfKfPfyJRdk/hqdefault.jpg',
        duration: Duration(minutes: 3, seconds: 0),
      ),
      const Song(
        id: '5yx6GY50_7g',
        videoId: '5yx6GY50_7g',
        title: 'Chill Lofi Beats',
        artist: 'Lofi Keepers',
        thumbnailUrl: 'https://img.youtube.com/vi/5yx6GY50_7g/mqdefault.jpg',
        highResThumbnailUrl: 'https://img.youtube.com/vi/5yx6GY50_7g/hqdefault.jpg',
        duration: Duration(minutes: 2, seconds: 45),
      ),
    ],
    'Bollywood': [
      const Song(
        id: 'BddP6PYo2gs',
        videoId: 'BddP6PYo2gs',
        title: 'Kesariya',
        artist: 'Arijit Singh',
        thumbnailUrl: 'https://img.youtube.com/vi/BddP6PYo2gs/mqdefault.jpg',
        highResThumbnailUrl: 'https://img.youtube.com/vi/BddP6PYo2gs/hqdefault.jpg',
        duration: Duration(minutes: 4, seconds: 28),
      ),
      const Song(
        id: 'Umqb9M08yxs',
        videoId: 'Umqb9M08yxs',
        title: 'Tum Hi Ho',
        artist: 'Arijit Singh',
        thumbnailUrl: 'https://img.youtube.com/vi/Umqb9M08yxs/mqdefault.jpg',
        highResThumbnailUrl: 'https://img.youtube.com/vi/Umqb9M08yxs/hqdefault.jpg',
        duration: Duration(minutes: 4, seconds: 22),
      ),
    ],
    'EDM': [
      const Song(
        id: 'IcrbM1l_BoI',
        videoId: 'IcrbM1l_BoI',
        title: 'Wake Me Up',
        artist: 'Avicii',
        thumbnailUrl: 'https://img.youtube.com/vi/IcrbM1l_BoI/mqdefault.jpg',
        highResThumbnailUrl: 'https://img.youtube.com/vi/IcrbM1l_BoI/hqdefault.jpg',
        duration: Duration(minutes: 4, seconds: 7),
      ),
      const Song(
        id: 'IxxstCcJlps',
        videoId: 'IxxstCcJlps',
        title: 'Clarity',
        artist: 'Zedd ft. Foxes',
        thumbnailUrl: 'https://img.youtube.com/vi/IxxstCcJlps/mqdefault.jpg',
        highResThumbnailUrl: 'https://img.youtube.com/vi/IxxstCcJlps/hqdefault.jpg',
        duration: Duration(minutes: 4, seconds: 31),
      ),
    ],
    'Rock': [
      const Song(
        id: '7wtfhZwyrcc',
        videoId: '7wtfhZwyrcc',
        title: 'Believer',
        artist: 'Imagine Dragons',
        thumbnailUrl: 'https://img.youtube.com/vi/7wtfhZwyrcc/mqdefault.jpg',
        highResThumbnailUrl: 'https://img.youtube.com/vi/7wtfhZwyrcc/hqdefault.jpg',
        duration: Duration(minutes: 3, seconds: 24),
      ),
      const Song(
        id: 'fJ9rUzIMcZQ',
        videoId: 'fJ9rUzIMcZQ',
        title: 'Bohemian Rhapsody',
        artist: 'Queen',
        thumbnailUrl: 'https://img.youtube.com/vi/fJ9rUzIMcZQ/mqdefault.jpg',
        highResThumbnailUrl: 'https://img.youtube.com/vi/fJ9rUzIMcZQ/hqdefault.jpg',
        duration: Duration(minutes: 5, seconds: 55),
      ),
    ],
    'R&B Soul': [
      const Song(
        id: 'fHI8X4OXluQ',
        videoId: 'fHI8X4OXluQ',
        title: 'Blinding Lights (R&B Mix)',
        artist: 'The Weeknd',
        thumbnailUrl: 'https://img.youtube.com/vi/fHI8X4OXluQ/mqdefault.jpg',
        highResThumbnailUrl: 'https://img.youtube.com/vi/fHI8X4OXluQ/hqdefault.jpg',
        duration: Duration(minutes: 3, seconds: 21),
      ),
      const Song(
        id: '8dM5QeC0JfA',
        videoId: '8dM5QeC0JfA',
        title: 'Adorn',
        artist: 'Miguel',
        thumbnailUrl: 'https://img.youtube.com/vi/8dM5QeC0JfA/mqdefault.jpg',
        highResThumbnailUrl: 'https://img.youtube.com/vi/8dM5QeC0JfA/hqdefault.jpg',
        duration: Duration(minutes: 3, seconds: 13),
      ),
    ],
    'Jazz': [
      const Song(
        id: 'Y2rDb4Ur2dw',
        videoId: 'Y2rDb4Ur2dw',
        title: 'Fly Me To The Moon',
        artist: 'Frank Sinatra',
        thumbnailUrl: 'https://img.youtube.com/vi/Y2rDb4Ur2dw/mqdefault.jpg',
        highResThumbnailUrl: 'https://img.youtube.com/vi/Y2rDb4Ur2dw/hqdefault.jpg',
        duration: Duration(minutes: 2, seconds: 27),
      ),
      const Song(
        id: 'vmDDOFXSgAs',
        videoId: 'vmDDOFXSgAs',
        title: 'Take Five',
        artist: 'Dave Brubeck',
        thumbnailUrl: 'https://img.youtube.com/vi/vmDDOFXSgAs/mqdefault.jpg',
        highResThumbnailUrl: 'https://img.youtube.com/vi/vmDDOFXSgAs/hqdefault.jpg',
        duration: Duration(minutes: 5, seconds: 24),
      ),
    ],
  };

  Future<void> _loadWorkingInstances() async {
    if (_instancesLoaded) return;
    _instancesLoaded = true; // Mark as true immediately to prevent concurrent calls
    Future.microtask(() async {
      final client = HttpClient()..connectionTimeout = const Duration(seconds: 3);

      // Load Invidious instances
      try {
        final uri = Uri.parse('https://api.invidious.io/instances.json');
        final request = await client.getUrl(uri).timeout(const Duration(seconds: 3));
        final response = await request.close().timeout(const Duration(seconds: 3));
        if (response.statusCode == 200) {
          final body = await response.transform(utf8.decoder).join();
          final List<dynamic> data = json.decode(body);
          final List<String> loaded = [];
          for (final item in data) {
            if (item is List && item.length > 1) {
              final host = item[0] as String;
              final info = item[1] as Map<String, dynamic>;
              final apiEnabled = info['api'] == true;
              final isHttps = info['type'] == 'https';
              if (apiEnabled && isHttps) {
                loaded.add(host);
              }
            }
          }
          if (loaded.isNotEmpty) {
            loaded.shuffle();
            final merged = <String>{...loaded, ..._invidiousInstances}.toList();
            _invidiousInstances = merged;
            debugPrint('[YT] Loaded ${loaded.length} Invidious instances dynamically.');
          }
        }
      } catch (e) {
        debugPrint('[YT] Failed to fetch Invidious instances: $e');
      }

      // Load Piped instances
      try {
        final uri = Uri.parse('https://piped-instances.kavin.rocks/');
        final request = await client.getUrl(uri).timeout(const Duration(seconds: 3));
        final response = await request.close().timeout(const Duration(seconds: 3));
        if (response.statusCode == 200) {
          final body = await response.transform(utf8.decoder).join();
          final List<dynamic> data = json.decode(body);
          final List<String> loaded = [];
          for (final item in data) {
            if (item is Map) {
              final apiUrl = item['api_url'] as String?;
              final uptime = (item['uptime_24h'] as num?) ?? 0;
              if (apiUrl != null && uptime > 85) {
                loaded.add(apiUrl);
              }
            }
          }
          if (loaded.isNotEmpty) {
            loaded.shuffle();
            final merged = <String>{...loaded, ..._pipedInstances}.toList();
            _pipedInstances = merged;
            debugPrint('[YT] Loaded ${loaded.length} Piped instances dynamically.');
          }
        }
      } catch (e) {
        debugPrint('[YT] Failed to fetch Piped instances: $e');
      }

      await testAndSortYoutubeStreaming();
      client.close();
    });
  }

  /// Run latency benchmarks on YouTube clients and backup proxy instances, sorting them.
  Future<void> testAndSortYoutubeStreaming() async {
    final testVideoId = 'dMMOBgUTMTo'; // Starboy (verified video ID)
    debugPrint('[YT Test] Starting YouTube streaming server benchmarking...');
    
    // 1. Test YouTube explode clients
    final scoredClients = <MapEntry<YoutubeApiClient, int>>[];
    for (final client in [
      YoutubeApiClient.androidVr,
      YoutubeApiClient.android,
      YoutubeApiClient.androidSdkless,
    ]) {
      final sw = Stopwatch()..start();
      try {
        final manifest = await _yt.videos.streamsClient
            .getManifest(testVideoId, ytClients: [client])
            .timeout(const Duration(seconds: 3));
        sw.stop();
        if (manifest.audioOnly.isNotEmpty) {
          scoredClients.add(MapEntry(client, sw.elapsedMilliseconds));
        } else {
          scoredClients.add(MapEntry(client, 999999));
        }
      } catch (_) {
        scoredClients.add(MapEntry(client, 999999));
      }
    }
    
    scoredClients.sort((a, b) => a.value.compareTo(b.value));
    _clientPriority.clear();
    for (final entry in scoredClients) {
      if (entry.value < 999999) {
        _clientPriority.add(entry.key);
      }
    }
    if (_clientPriority.isEmpty) {
      _clientPriority.addAll([
        YoutubeApiClient.ios,
        YoutubeApiClient.tv,
        YoutubeApiClient.mweb,
        YoutubeApiClient.androidVr,
      ]);
    }
    
    // 2. Test Invidious instances (limit to a subset to avoid stalling startup)
    final invidiousToTest = _invidiousInstances.take(5).toList();
    final scoredInvidious = <MapEntry<String, int>>[];
    final httpClient = HttpClient()..connectionTimeout = const Duration(seconds: 2);
    
    for (final instance in invidiousToTest) {
      final sw = Stopwatch()..start();
      try {
        final uri = Uri.https(instance, '/api/v1/videos/$testVideoId', {'local': 'true'});
        final request = await httpClient.getUrl(uri).timeout(const Duration(seconds: 2));
        final response = await request.close().timeout(const Duration(seconds: 2));
        sw.stop();
        if (response.statusCode == 200) {
          scoredInvidious.add(MapEntry(instance, sw.elapsedMilliseconds));
        } else {
          await response.drain();
          scoredInvidious.add(MapEntry(instance, 999999));
        }
      } catch (_) {
        scoredInvidious.add(MapEntry(instance, 999999));
      }
    }
    
    scoredInvidious.sort((a, b) => a.value.compareTo(b.value));
    final List<String> workingInvidious = [];
    final List<String> failedInvidious = [];
    for (final entry in scoredInvidious) {
      if (entry.value < 999999) {
        workingInvidious.add(entry.key);
      } else {
        failedInvidious.add(entry.key);
      }
    }
    
    final untestedInvidious = _invidiousInstances
        .where((i) => !invidiousToTest.contains(i))
        .toList();
    _invidiousInstances = [...workingInvidious, ...untestedInvidious, ...failedInvidious];
    // Ordering already demotes these; the cooldown keeps them out of the next
    // few resolutions without exiling them for the life of the process.
    final now = DateTime.now();
    for (final instance in failedInvidious) {
      _instanceCooldown[instance] = now;
    }

    // 3. Test Piped instances
    final scoredPiped = <MapEntry<String, int>>[];
    for (final apiUrl in _pipedInstances.take(3)) {
      final sw = Stopwatch()..start();
      try {
        final uri = Uri.parse('$apiUrl/streams/$testVideoId');
        final request = await httpClient.getUrl(uri).timeout(const Duration(seconds: 2));
        request.headers.set(HttpHeaders.userAgentHeader,
            'Mozilla/5.0 (Linux; Android 10; Mobile) AppleWebKit/537.36');
        final response = await request.close().timeout(const Duration(seconds: 2));
        sw.stop();
        if (response.statusCode == 200) {
          scoredPiped.add(MapEntry(apiUrl, sw.elapsedMilliseconds));
        } else {
          await response.drain();
          scoredPiped.add(MapEntry(apiUrl, 999999));
        }
      } catch (_) {
        scoredPiped.add(MapEntry(apiUrl, 999999));
      }
    }
    
    scoredPiped.sort((a, b) => a.value.compareTo(b.value));
    final List<String> workingPiped = [];
    final List<String> failedPiped = [];
    for (final entry in scoredPiped) {
      if (entry.value < 999999) {
        workingPiped.add(entry.key);
      } else {
        failedPiped.add(entry.key);
      }
    }
    
    final untestedPiped = _pipedInstances
        .where((p) => !_pipedInstances.take(3).contains(p))
        .toList();
    _pipedInstances = [...workingPiped, ...untestedPiped, ...failedPiped];
    final pipedFailedAt = DateTime.now();
    for (final apiUrl in failedPiped) {
      _pipedCooldown[apiUrl] = pipedFailedAt;
    }
    
    httpClient.close();
    
    debugPrint('[YT Test] Benchmarking complete.');
    debugPrint('[YT Test] Client Priority: ${_clientPriority.map((c) => c.toString().split('.').last).join(', ')}');
    if (workingInvidious.isNotEmpty) {
      debugPrint('[YT Test] Top Invidious instance: ${workingInvidious.first}');
    }
    if (workingPiped.isNotEmpty) {
      debugPrint('[YT Test] Top Piped instance: ${workingPiped.first}');
    }
  }

  Future<List<Song>?> _fetchInvidiousSearch(String query) async {
    _loadWorkingInstances();
    final client = HttpClient();
    
    // Scan instances that are not cooling down after a recent failure
    for (final instance in _invidiousInstances) {
      if (_isCoolingDown(_instanceCooldown, instance)) continue;

      try {
        final uri = Uri.https(instance, '/api/v1/search', {
          'q': query,
          'type': 'video',
        });
        final request = await client.getUrl(uri).timeout(const Duration(seconds: 4));
        final response = await request.close().timeout(const Duration(seconds: 4));
        
        if (response.statusCode == 200) {
          final body = await response.transform(utf8.decoder).join();
          final data = json.decode(body);
          if (data is List) {
            final List<Song> songs = [];
            for (final item in data) {
              if (item['type'] == 'video') {
                final videoId = item['videoId'] as String?;
                final title = item['title'] as String? ?? 'Unknown';
                final author = item['author'] as String? ?? 'Unknown';
                final durationSecs = item['lengthSeconds'] as int? ?? 180;
                
                if (videoId != null && videoId.isNotEmpty) {
                  String thumb = item['videoThumbnails']?.first['url'] as String? ?? '';
                  
                  // Normalize thumbnail URL
                  if (thumb.isNotEmpty) {
                    thumb = Uri.decodeFull(thumb);
                    if (thumb.startsWith('//')) {
                      thumb = 'https:$thumb';
                    } else if (thumb.startsWith('/')) {
                      thumb = 'https://$instance$thumb';
                    }
                  } else {
                    thumb = 'https://img.youtube.com/vi/$videoId/mqdefault.jpg';
                  }
                  
                  songs.add(Song(
                    id: videoId,
                    title: title,
                    artist: author,
                    thumbnailUrl: thumb,
                    highResThumbnailUrl: thumb,
                    duration: Duration(seconds: durationSecs),
                    videoId: videoId,
                  ));
                }
              }
            }
            if (songs.isNotEmpty) {
              client.close();
              return songs;
            }
          }
        }
      } catch (e) {
        _instanceCooldown[instance] = DateTime.now();
        debugPrint('Invidious search failed for instance $instance: $e');
      }
    }
    client.close();
    return null;
  }

  /// Resolve a stream URL from the Invidious mirror pool.
  ///
  /// [shouldAbort] is polled between instances so the walk stops the moment the
  /// resolution it belongs to has been won elsewhere — without it, a losing
  /// branch of the race kept dialling mirrors for another dozen seconds after
  /// the user's song had already started playing.
  Future<String?> _fetchInvidiousStreamUrl(String videoId,
      {bool Function()? shouldAbort}) async {
    _loadWorkingInstances();
    final client = HttpClient();
    var attempts = 0;

    for (final instance in _invidiousInstances) {
      if (shouldAbort?.call() ?? false) break;
      if (_isCoolingDown(_instanceCooldown, instance)) continue;
      if (attempts >= _maxInstanceAttempts) break;
      attempts++;

      try {
        final uri = Uri.https(instance, '/api/v1/videos/$videoId', {'local': 'true'});
        final request = await client.getUrl(uri).timeout(const Duration(seconds: 4));
        final response = await request.close().timeout(const Duration(seconds: 4));
        
        if (response.statusCode == 200) {
          final body = await response.transform(utf8.decoder).join();
          final data = json.decode(body);
          final adaptive = data['adaptiveFormats'] as List?;
          if (adaptive != null && adaptive.isNotEmpty) {
            final audioStreams = adaptive.where((item) {
              final type = item['type'] as String? ?? '';
              return type.startsWith('audio/');
            }).toList();
            
            if (audioStreams.isNotEmpty) {
              audioStreams.sort((a, b) {
                final aBit = int.tryParse(a['bitrate']?.toString() ?? '0') ?? 0;
                final bBit = int.tryParse(b['bitrate']?.toString() ?? '0') ?? 0;
                return aBit.compareTo(bBit);
              });
              
              final bestStream = audioStreams.last;
              final streamUrl = bestStream['url'] as String?;
              if (streamUrl != null && streamUrl.isNotEmpty) {
                client.close();
                return streamUrl;
              }
            }
          }
        }
      } catch (e) {
        _instanceCooldown[instance] = DateTime.now();
        debugPrint('Invidious instance $instance failed for $videoId: $e');
      }
    }
    client.close();
    return null;
  }

  /// Fetch stream URL from Piped API instances.
  /// Piped uses a different API format: /streams/{videoId} → audioStreams[].url
  Future<String?> _fetchPipedStreamUrl(String videoId,
      {bool Function()? shouldAbort}) async {
    _loadWorkingInstances();
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 5);
    var attempts = 0;

    for (final apiUrl in _pipedInstances) {
      if (shouldAbort?.call() ?? false) break;
      if (_isCoolingDown(_pipedCooldown, apiUrl)) continue;
      if (attempts >= _maxInstanceAttempts) break;
      attempts++;

      try {
        final uri = Uri.parse('$apiUrl/streams/$videoId');
        final request = await client.getUrl(uri).timeout(const Duration(seconds: 5));
        request.headers.set(HttpHeaders.userAgentHeader,
            'Mozilla/5.0 (Linux; Android 10; Mobile) AppleWebKit/537.36 '
            '(KHTML, like Gecko) Chrome/120.0.0.0 Mobile Safari/537.36');
        final response = await request.close().timeout(const Duration(seconds: 5));

        if (response.statusCode == 200) {
          final body = await response.transform(utf8.decoder).join();
          final data = json.decode(body);

          final audioStreams = data['audioStreams'] as List?;
          if (audioStreams != null && audioStreams.isNotEmpty) {
            // Sort by bitrate and pick the best audio stream
            audioStreams.sort((a, b) =>
                (a['bitrate'] as int? ?? 0).compareTo(b['bitrate'] as int? ?? 0));
            final best = audioStreams.last;
            final streamUrl = best['url'] as String?;
            if (streamUrl != null && streamUrl.isNotEmpty) {
              client.close();
              return streamUrl;
            }
          }
        } else {
          await response.drain();
        }
      } catch (e) {
        _pipedCooldown[apiUrl] = DateTime.now();
        debugPrint('[YT] Piped instance $apiUrl failed for $videoId: $e');
      }
    }
    client.close();
    return null;
  }

  /// Search for songs on YouTube (user initiated search)
  Future<List<Song>> searchSongs(String query, {int maxResults = 20}) async {
    try {
      final searchResults = await _yt.search.search('$query music');
      final songs = <Song>[];

      for (final result in searchResults.take(maxResults)) {
        songs.add(_videoToSong(result));
      }

      return songs;
    } catch (e) {
      debugPrint('Failed to search songs using YouTube Explode: $e');
      final fallbackSongs = await _fetchInvidiousSearch('$query music');
      if (fallbackSongs != null && fallbackSongs.isNotEmpty) {
        return fallbackSongs.take(maxResults).toList();
      }
      throw Exception('Failed to search songs: $e');
    }
  }

  /// Get trending music videos dynamically from YouTube. Falls back to static list.
  Future<List<Song>> getTrendingMusic({bool forceRefresh = false}) async {
    // Trending is fetched live on every call, so [forceRefresh] is accepted for
    // API symmetry with the cached paths but needs no special handling here.
    try {
      final List<Song> trending = [];
      // PL4fGSI1pDJn5kI81J1fYxT5M838p9c58A is YouTube Music's official Trending playlist
      final playlistVideos = _yt.playlists.getVideos('PL4fGSI1pDJn5kI81J1fYxT5M838p9c58A');
      await for (final video in playlistVideos.take(20)) {
        trending.add(_videoToSong(video));
      }
      if (trending.isNotEmpty) return trending;
    } catch (e) {
      debugPrint('Failed to fetch dynamic trending from YouTube: $e');
    }
    // Return predefined trending list directly as fallback
    return List.from(_trendingNow);
  }

  /// Get songs by genre/mood (Static offline-first layout, zero startup server calls)
  Future<List<Song>> getSongsByCategory(String category,
      {bool forceRefresh = false}) async {
    // Category listings come from the static catalog, so [forceRefresh] is a
    // no-op here; it exists for API parity with the live fetch paths.
    if (_staticCatalog.containsKey(category)) {
      return List.from(_staticCatalog[category]!);
    }
    return [];
  }

  /// Get the audio stream URL for a video.
  ///
  /// Strategy: ALL sources race in parallel from the very first moment —
  /// YouTube Explode clients → Invidious → Piped on one track, native yt-dlp
  /// (JunkFood02/Seal) on the other. No artificial delay: the first source to
  /// produce a playable URL wins; the loser is ignored.
  ///
  /// [forceRefresh] bypasses the cache AND drops the entry, which is what a
  /// retry needs: resolved URLs are time-limited and IP-bound, so the most
  /// likely reason a transfer just died is that this exact URL stopped working.
  /// Handing the same one back made every retry fail identically — with the
  /// 90-minute TTL that is a much longer window than the old 5-minute one, so
  /// the bypass is what keeps the longer TTL safe.
  Future<String> getAudioStreamUrl(String videoId,
      {bool forceRefresh = false}) async {
    final cacheKey = _cacheKey(videoId);
    if (forceRefresh) {
      _streamCache.remove(cacheKey);
    } else {
      final cached = _streamCache[cacheKey];
      if (cached != null && !cached.isExpired) {
        return cached.url;
      }
    }

    // Step 1: Native yt-dlp FIRST when ready (JunkFood02/Seal Architecture).
    // yt-dlp correctly decrypts N-sig & handles PO-tokens, matching download speed and reliability.
    if (YtDlpRuntime.isReady) {
      try {
        debugPrint('[YT] Primary resolution via native yt-dlp engine for $videoId');
        final ytdlpUrl = await getYtDlpStreamUrl(videoId)
            .timeout(const Duration(seconds: 15));
        if (ytdlpUrl != null && ytdlpUrl.startsWith('http')) {
          debugPrint('[YT] Native yt-dlp primary resolution succeeded for $videoId');
          _evictExpiredCache();
          _streamCache[cacheKey] = _CachedUrl(ytdlpUrl, DateTime.now());
          return ytdlpUrl;
        }
      } catch (e) {
        debugPrint('[YT] Native yt-dlp primary failed for $videoId: $e — trying fallback sources');
      }
    }

    // Step 2: Fallback to Explode / Invidious / Piped ladder if yt-dlp was cold or failed
    try {
      final fallbackUrl = await _resolveFromAllSources(videoId);
      if (fallbackUrl.startsWith('http')) {
        return fallbackUrl;
      }
    } catch (e) {
      debugPrint('[YT] Fallback sources failed for $videoId: $e');
    }

    // Step 3: Final extended yt-dlp attempt if cold initialization finished in background
    try {
      await YtDlpRuntime.ensureInitialized();
      final ytdlpUrl = await getYtDlpStreamUrl(videoId)
          .timeout(const Duration(seconds: 25));
      if (ytdlpUrl != null && ytdlpUrl.startsWith('http')) {
        debugPrint('[YT] Final yt-dlp retry resolved stream for $videoId');
        _evictExpiredCache();
        _streamCache[cacheKey] = _CachedUrl(ytdlpUrl, DateTime.now());
        return ytdlpUrl;
      }
    } catch (e) {
      debugPrint('[YT] Final yt-dlp retry failed for $videoId: $e');
    }

    YtDlpRuntime.markExtractionFailed();
    throw Exception('Could not find a playable stream for $videoId.');
  }

  /// Internal: race Explode, Invidious, Piped, and yt-dlp in parallel.
  /// Returns the first playable URL or throws/times out.
  Future<String> _resolveFromAllSources(String videoId) async {
    final cacheKey = _cacheKey(videoId);
    final completer = Completer<String>();
    bool fastChainDone = false;
    bool ytDlpStarted = false;
    bool ytDlpDone = false;
    Object? fastError;

    void completeWith(String url) {
      if (!completer.isCompleted) {
        _evictExpiredCache();
        _streamCache[cacheKey] = _CachedUrl(url, DateTime.now());
        completer.complete(url);
      }
    }

    void failIfBothExhausted() {
      if (!completer.isCompleted && fastChainDone && (ytDlpDone || !ytDlpStarted)) {
        completer.completeError(
            fastError ?? Exception('All sources exhausted.'));
      }
    }

    Future<void> runYtDlp() async {
      if (ytDlpStarted || completer.isCompleted) return;
      ytDlpStarted = true;
      try {
        final ytdlpUrl = await getYtDlpStreamUrl(videoId);
        if (ytdlpUrl != null && ytdlpUrl.startsWith('http')) {
          debugPrint('[YT] yt-dlp resolved stream successfully for $videoId');
          completeWith(ytdlpUrl);
          return;
        }
      } catch (e) {
        debugPrint('[YT] yt-dlp stream resolution failed for $videoId: $e');
      } finally {
        ytDlpDone = true;
      }
      failIfBothExhausted();
    }

    Future<void> runFastChain() async {
      try {
        final List<YoutubeApiClient> clients = List.from(_clientPriority);

        Future<void> tryExplode(YoutubeApiClient client) async {
          if (completer.isCompleted) return;
          try {
            final manifest = await _yt.videos.streamsClient
                .getManifest(videoId, ytClients: [client])
                .timeout(const Duration(seconds: 6));
            if (completer.isCompleted) return;
            final url = _pickBestStream(manifest);
            if (url != null) {
              if (completer.isCompleted) return;
              completeWith(url);
              if (_clientPriority.isNotEmpty && _clientPriority.first != client) {
                _clientPriority.remove(client);
                _clientPriority.insert(0, client);
              }
            }
          } catch (e) {
            debugPrint('[YT] Client $client failed for $videoId: $e');
            final err = e.toString().toLowerCase();
            if (err.contains('socket') ||
                err.contains('clientexception') ||
                err.contains('connection reset') ||
                err.contains('broken pipe')) {
              refreshExplodeClient();
            }
          }
        }

        Future<void> tryInvidious() async {
          if (completer.isCompleted) return;
          try {
            final invidiousUrl = await _fetchInvidiousStreamUrl(
              videoId,
              shouldAbort: () => completer.isCompleted,
            );
            if (invidiousUrl != null) completeWith(invidiousUrl);
          } catch (e) {
            debugPrint('[YT] Invidious stream fallback failed for $videoId: $e');
          }
        }

        Future<void> tryPiped() async {
          if (completer.isCompleted) return;
          try {
            final pipedUrl = await _fetchPipedStreamUrl(
              videoId,
              shouldAbort: () => completer.isCompleted,
            );
            if (pipedUrl != null) completeWith(pipedUrl);
          } catch (e) {
            debugPrint('[YT] Piped stream fallback failed for $videoId: $e');
          }
        }

        await Future.wait<void>([
          ...clients.map(tryExplode),
          tryInvidious(),
          tryPiped(),
        ]);
      } catch (e) {
        fastError = e;
      } finally {
        fastChainDone = true;
        if (!completer.isCompleted) {
          failIfBothExhausted();
        }
      }
    }

    runFastChain();
    runYtDlp();

    return completer.future.timeout(
      _resolveDeadline,
      onTimeout: () => throw TimeoutException(
          'Stream resolution timed out after ${_resolveDeadline.inSeconds}s',
          _resolveDeadline),
    );
  }

  /// Ceiling on the first-attempt parallel resolution across every source.
  /// Extended to 30s because yt-dlp needs 8–15s on mobile data and is often
  /// the ONLY working extractor when YouTube enforces PO-tokens on Explode.
  static const Duration _resolveDeadline = Duration(seconds: 30);

  /// Pick a stream honouring the user's streaming-quality setting.
  String? _pickBestStream(StreamManifest manifest) {
    final audioStreams = manifest.audioOnly.toList();
    if (audioStreams.isEmpty) return null;

    // Sort by bitrate ascending
    audioStreams.sort((a, b) => a.bitrate.bitsPerSecond.compareTo(b.bitrate.bitsPerSecond));

    final AudioOnlyStreamInfo picked;
    switch (streamingQuality) {
      case AudioQuality.low:
        // Smallest stream — data saver.
        picked = audioStreams.first;
      case AudioQuality.high:
        // Best available bitrate.
        picked = audioStreams.last;
      case AudioQuality.medium:
        // ~128kbps balance of speed and quality.
        picked = audioStreams.firstWhere(
          (s) =>
              s.bitrate.bitsPerSecond >= 100000 &&
              s.bitrate.bitsPerSecond <= 160000,
          // Fallback: middle bitrate if available, else highest.
          orElse: () => audioStreams.length >= 3
              ? audioStreams[audioStreams.length ~/ 2]
              : audioStreams.last,
        );
    }

    debugPrint('[YT] Explode picked quality=${streamingQuality.name} '
        '${picked.bitrate.bitsPerSecond ~/ 1000}kbps ${picked.container.name}');
    return picked.url.toString();
  }

  /// YouTube player clients to try, in order, via yt-dlp's
  /// `--extractor-args youtube:player_client=...`. YouTube periodically blocks
  /// the default web client (signature / nsig throttling); the mobile/tv
  /// clients often still return unthrottled audio formats. This mirrors how
  /// yt-dlp itself (and JunkFood02/Seal) recover from extraction failures.
  ///
  /// Order matters: android/android_music return their audio-only formats
  /// WITHOUT urls (PO-token gated), leaving only the muxed 360p video
  /// (itag 18) playable — which forces ExoPlayer to spin up a video decoder
  /// for a music stream. android_vr and tv are not PO-token gated and yield
  /// real audio-only urls, so they go first; the android pair is kept last
  /// as a plays-something fallback.
  static final List<String> _ytDlpPlayerClients = [
    'android_vr',
    'tv',
    'ios',
    'mweb',
    'android_music,android',
  ];

  /// Seal-style `-S` audio sorter for the user's streaming-quality setting
  /// (DownloadUtil.toAudioFormatSorter maps HIGH/MEDIUM/LOW to abr~192/128/64).
  static String ytDlpAudioSorter(AudioQuality quality) {
    switch (quality) {
      case AudioQuality.high:
        return 'abr~192';
      case AudioQuality.medium:
        return 'abr~128';
      case AudioQuality.low:
        return 'abr~64';
    }
  }

  /// Format chain (`-f`) matching the `-S` sorter for [quality].
  ///
  /// This is the fix for "the quality setting does nothing": the old value was a
  /// hardcoded `140/251/bestaudio/best`. Because `-f` names itag 140 first and
  /// `-f` wins outright, yt-dlp always returned the same AAC 128k stream and the
  /// `-S abr~` sorter below it was never consulted — High and Medium produced
  /// byte-identical audio and Low was ignored entirely.
  ///
  /// Each chain now uses *filters* rather than fixed itags, so `-S` does the
  /// final ordering within the matched set. Every chain keeps a progressively
  /// looser fallback so a video with an unusual format ladder still resolves.
  static String ytDlpFormatChain(AudioQuality quality) {
    // Prefer M4A/AAC streams (acodec=mp4a) over WebM/Opus so the output is
    // natively M4A without needing FFmpeg remux. Falls back to bestaudio (which
    // may be Opus/WebM) only when no AAC stream is available — yt-dlp's
    // extractAudio + audioFormat='m4a' will remux it via FFmpeg.
    switch (quality) {
      case AudioQuality.high:
        return 'bestaudio[acodec^=mp4a]/bestaudio[abr>=160]/bestaudio/best';
      case AudioQuality.medium:
        return '140/bestaudio[acodec^=mp4a][abr<=140]/bestaudio[abr<=140]/bestaudio/best';
      case AudioQuality.low:
        return 'bestaudio[acodec^=mp4a][abr<=70]/worstaudio[acodec^=mp4a]/worstaudio/bestaudio/best';
    }
  }

  /// Format chain used for STREAMING, as opposed to [ytDlpFormatChain] which
  /// downloads use.
  ///
  /// Same quality-matched head, but every chain ends in an unconstrained
  /// `bestaudio/best` with no codec filter, so whatever format the player client
  /// hands back is accepted on the spot. The download chain's preference for
  /// `mp4a` exists to avoid an FFmpeg remux on the way to a file on disk — for
  /// streaming there is no file and no remux, and ExoPlayer decodes Opus/WebM
  /// just as happily as AAC/M4A. Insisting on a container there only bought
  /// another extraction round-trip on videos whose client returns Opus.
  ///
  /// `-S` (see [ytDlpAudioSorter]) still orders within the matched set, so the
  /// Low/Medium/High setting keeps its effect.
  static String ytDlpStreamFormatChain(AudioQuality quality) {
    switch (quality) {
      case AudioQuality.high:
        return 'bestaudio[abr>=160]/bestaudio/best';
      case AudioQuality.medium:
        return 'bestaudio[abr<=140]/bestaudio/best';
      case AudioQuality.low:
        return 'bestaudio[abr<=70]/worstaudio/bestaudio/best';
    }
  }

  String _ytDlpAudioSorter() => ytDlpAudioSorter(streamingQuality);

  /// Per-player-client extraction timeout in the yt-dlp race.
  /// 20s allows mobile 4G/5G networks (DNS+TLS+extraction) to complete.
  static const Duration _ytDlpClientTimeout = Duration(seconds: 20);

  /// Ceiling on the whole yt-dlp track, however many clients are in flight.
  /// Set to 25s to give the slowest client time to finish while staying
  static const Duration _ytDlpOverallTimeout = Duration(seconds: 25);

  /// Clear stream cache on app resume to prevent 403 Forbidden errors
  /// on URLs resolved before backgrounding/network switch.
  static void clearStreamCacheOnResume() {
    debugPrint('[YT] App resumed — invalidating cached stream URLs & refreshing Explode socket pool');
    _streamCache.clear();
    refreshExplodeClient();
  }

  /// Resolve stream URL specifically using the native yt-dlp binary
  /// (JunkFood02/Seal implementation).
  ///
  /// NOTE: This method does NOT call markExtractionFailed(). Failure reporting
  /// is centralized in [getAudioStreamUrl] so that a single play attempt can
  /// never increment the failure counter more than once.
  Future<String?> getYtDlpStreamUrl(String videoId) async {
    if (!YtDlpRuntime.isReady) {
      debugPrint('[YT] yt-dlp not warm yet — skipping it for $videoId');
      return null;
    }

    final videoUrl = 'https://www.youtube.com/watch?v=$videoId';
    final clients = List<String>.from(_ytDlpPlayerClients);
    final completer = Completer<String?>();
    int pending = clients.length;

    Future<void> attempt(String client) async {
      final attemptSw = Stopwatch()..start();
      try {
        debugPrint('[YT] yt-dlp extract $videoId (player_client=$client)');
        final info = await YoutubeDLFlutter.instance
            .getVideoInfoWithOptions(videoUrl, {
              '--no-update': '',
              '--socket-timeout': '8',
              '-R': '2',
              '--no-playlist': '',
              '--force-ipv4': '',
              '--no-check-certificates': '',
              '-f': ytDlpStreamFormatChain(streamingQuality),
              '-S': _ytDlpAudioSorter(),
              '--extractor-args':
                  'youtube:player_client=$client;skip=hls,dash,translated_subs,webpage',
            })
            .timeout(_ytDlpClientTimeout);

        if (completer.isCompleted) return;

        String? url = info.url;
        if (url == null || !url.startsWith('http')) {
          url = _pickYtDlpAudioUrl(info.formats);
        }
        if (url != null) {
          if (completer.isCompleted) return;
          completer.complete(url);
          attemptSw.stop();
          DiagnosticLogService().log(DiagnosticLogService.ytdlpExtract, {
            'videoId': videoId,
            'client': client,
            'elapsed_ms': attemptSw.elapsedMilliseconds,
            'ok': true,
            'ext': info.ext,
            'acodec': info.acodec,
          });

          if (_ytDlpPlayerClients.contains(client) &&
              _ytDlpPlayerClients.first != client) {
            _ytDlpPlayerClients.remove(client);
            _ytDlpPlayerClients.insert(0, client);
            debugPrint('[YT] Promoted $client to primary yt-dlp player client');
          }

          debugPrint('[YT] yt-dlp resolved via player_client=$client '
              'quality=${streamingQuality.name} '
              'ext=${info.ext ?? "?"} acodec=${info.acodec ?? "?"}');
          YtDlpRuntime.markHealthy();
          _evictExpiredCache();
          _streamCache[_cacheKey(videoId)] = _CachedUrl(url, DateTime.now());
          return;
        }
        debugPrint('[YT] yt-dlp client=$client returned no playable audio');
      } on TimeoutException {
        debugPrint('[YT] yt-dlp client=$client timed out');
      } catch (e) {
        debugPrint('[YT] yt-dlp client=$client failed: $e');
        if (e.toString().toLowerCase().contains('process') ||
            e.toString().toLowerCase().contains('nullpointer') ||
            e.toString().toLowerCase().contains('broken pipe') ||
            e.toString().toLowerCase().contains('uninitialized')) {
          debugPrint('[YT] Native yt-dlp process error detected ($e) — triggering re-initialization');
          YtDlpRuntime.forceReinitialize();
        }
      } finally {
        attemptSw.stop();
        pending--;
        if (pending == 0 && !completer.isCompleted) {
          completer.complete(null);
        }
      }
    }

    for (final client in clients) {
      attempt(client);
    }

    try {
      return await completer.future.timeout(_ytDlpOverallTimeout);
    } on TimeoutException {
      debugPrint('[YT] yt-dlp race exceeded ${_ytDlpOverallTimeout.inSeconds}s '
          'for $videoId');
      return null;
    }
  }

  /// Pick the best audio-only stream URL from a yt-dlp format list, preferring
  /// audio-only tracks by bitrate, then any track carrying an audio codec.
  ///
  /// Deliberately container-agnostic: selection is by the presence of an audio
  /// codec and by bitrate, never by extension. Opus/WebM, AAC/M4A and a muxed
  /// MP4 are all acceptable to stream — ExoPlayer decodes them all, and
  /// rejecting one here would just cost another extraction attempt.
  String? _pickYtDlpAudioUrl(List<VideoFormat?>? formats) {
    if (formats == null || formats.isEmpty) return null;

    final audioOnly = formats.where((f) {
      if (f == null) return false;
      final acodec = f.acodec?.toLowerCase();
      final vcodec = f.vcodec?.toLowerCase();
      return acodec != null &&
          acodec != 'none' &&
          (vcodec == null || vcodec == 'none' || vcodec.isEmpty);
    }).cast<VideoFormat>().toList();

    VideoFormat? selected;
    if (audioOnly.isNotEmpty) {
      final m4aAudio = audioOnly.where((f) {
        final ext = f.ext?.toLowerCase() ?? '';
        final acodec = f.acodec?.toLowerCase() ?? '';
        return ext == 'm4a' || acodec.contains('mp4a') || acodec.contains('aac');
      }).toList();

      final pool = m4aAudio.isNotEmpty ? m4aAudio : audioOnly;
      pool.sort((a, b) => (a.tbr ?? 0).compareTo(b.tbr ?? 0));

      switch (streamingQuality) {
        case AudioQuality.low:
          selected = pool.first; // Data saver (~64kbps)
          break;
        case AudioQuality.high:
          selected = pool.last; // High quality (~160kbps - 256kbps)
          break;
        case AudioQuality.medium:
          for (final f in pool) {
            if ((f.tbr ?? 0) >= 100 && (f.tbr ?? 0) <= 160) {
              selected = f;
              break;
            }
          }
          selected ??= pool[pool.length ~/ 2];
          break;
      }
    } else {
      final anyAudio = formats.where((f) {
        if (f == null) return false;
        final acodec = f.acodec?.toLowerCase();
        return acodec != null && acodec != 'none';
      }).cast<VideoFormat>().toList();
      if (anyAudio.isNotEmpty) {
        anyAudio.sort((a, b) => (a.tbr ?? 0).compareTo(b.tbr ?? 0));
        selected = anyAudio.last;
      }
    }
    selected ??= formats.whereType<VideoFormat>().isNotEmpty
        ? formats.whereType<VideoFormat>().last
        : null;

    final url = selected?.url;
    if (url != null && url.startsWith('http')) return url;
    return null;
  }

  /// Public fallback method to resolve stream URL, trying yt-dlp first then Invidious/Piped proxies.
  /// Used when ExoPlayer fails with signature blocks (HTTP 403).
  Future<String?> getFallbackStreamUrl(String videoId) async {
    // Try yt-dlp stream resolution first
    try {
      final ytdlpUrl = await getYtDlpStreamUrl(videoId);
      if (ytdlpUrl != null) return ytdlpUrl;
    } catch (e) {
      debugPrint('[YT] Fallback yt-dlp failed for $videoId: $e');
    }

    // Try Invidious as secondary
    try {
      final invidiousUrl = await _fetchInvidiousStreamUrl(videoId);
      if (invidiousUrl != null) return invidiousUrl;
    } catch (e) {
      debugPrint('[YT] Fallback Invidious failed for $videoId: $e');
    }

    // Try Piped as tertiary
    try {
      final pipedUrl = await _fetchPipedStreamUrl(videoId);
      if (pipedUrl != null) return pipedUrl;
    } catch (e) {
      debugPrint('[YT] Fallback Piped failed for $videoId: $e');
    }
    return null;
  }

  /// Prefetch stream URL for a song (call ahead of time to warm the cache)
  Future<void> prefetchStreamUrl(String videoId) async {
    final cached = _streamCache[_cacheKey(videoId)];
    if (cached != null && !cached.isExpired) return;

    try {
      await getAudioStreamUrl(videoId);
    } catch (_) {
      // Silently fail
    }
  }

  /// Ceiling on the Explode metadata call.
  ///
  /// `videos.get` has no internal timeout, so on a stalled mobile socket it can
  /// hang for the OS-level TCP timeout — minutes — with the shared-link card
  /// stuck on "Reading video details…" the whole time. Explode is the *fast*
  /// path here; if it has not answered in six seconds it has lost its purpose
  /// and yt-dlp should be given the remaining budget.
  static const Duration _metadataExplodeTimeout = Duration(seconds: 6);

  /// Ceiling on the whole yt-dlp metadata fallback, across every player client.
  static const Duration _metadataYtDlpDeadline = Duration(seconds: 22);

  /// Get video details by ID.
  ///
  /// Explode is tried first (one cheap HTTP call), but it is the same client
  /// stack that already fails outright on device for stream resolution, and a
  /// shared YouTube link has nothing else to fall back on — a metadata failure
  /// there kills a download the yt-dlp pipeline could have completed on its
  /// own. So a failure here drops to yt-dlp, which is the extractor the app
  /// actually trusts.
  ///
  /// Both legs are time-boxed. Unbounded, this was the single worst offender in
  /// the shared-link flow: an untimed Explode call followed by four yt-dlp
  /// clients at 20s each, behind a 25s runtime init, could leave the card
  /// "resolving" for well over a minute before anything was even downloaded.
  Future<Song> getVideoDetails(String videoId) async {
    try {
      final video =
          await _yt.videos.get(videoId).timeout(_metadataExplodeTimeout);
      return Song(
        id: video.id.value,
        title: video.title,
        artist: video.author,
        thumbnailUrl: video.thumbnails.mediumResUrl,
        highResThumbnailUrl: video.thumbnails.standardResUrl.isNotEmpty
            ? video.thumbnails.standardResUrl
            : video.thumbnails.mediumResUrl,
        duration: video.duration ?? Duration.zero,
        videoId: video.id.value,
      );
    } catch (e) {
      debugPrint('[YT] Explode metadata failed for $videoId: $e '
          '— falling back to yt-dlp');
      final viaYtDlp = await getVideoDetailsViaYtDlp(videoId);
      if (viaYtDlp != null) return viaYtDlp;
      throw Exception('Failed to get video details: $e');
    }
  }

  /// Stand-in metadata for a video whose details could not be read.
  ///
  /// Deliberately obvious rather than a guess, and the canonical `i.ytimg.com`
  /// thumbnail always exists for a valid id, so the card still has artwork while
  /// the download runs. yt-dlp overwrites all of this with the real tags when it
  /// writes the file.
  static Song placeholderSong(String videoId) => Song(
        id: videoId,
        videoId: videoId,
        title: 'YouTube video',
        artist: 'Unknown artist',
        thumbnailUrl: 'https://i.ytimg.com/vi/$videoId/mqdefault.jpg',
        highResThumbnailUrl: 'https://i.ytimg.com/vi/$videoId/hqdefault.jpg',
        duration: Duration.zero,
      );

  /// Metadata for [videoId] that ALWAYS returns something usable.
  ///
  /// A shared link is a download request, not a metadata request. The id alone
  /// is enough for yt-dlp to fetch the audio — and yt-dlp writes the real title,
  /// artist and artwork into the file itself — so letting a failed *metadata*
  /// lookup abort the whole share throws away a download that would have
  /// succeeded. That was a large share of the "shared link failed" reports:
  /// the transfer never even started.
  Future<Song> getVideoDetailsResilient(String videoId) async {
    try {
      return await getVideoDetails(videoId);
    } catch (e) {
      debugPrint('[YT] Metadata unavailable for $videoId ($e) — proceeding with '
          'a placeholder so the download can still run');
      return placeholderSong(videoId);
    }
  }

  /// Video metadata straight from the yt-dlp binary, or null if it can't get it.
  ///
  /// Deliberately metadata-only (`--skip-download`, no format selection): the
  /// caller wants a title, artist, cover and duration, and asking yt-dlp to
  /// also resolve stream urls here would cost a PO-token-gated round trip the
  /// download itself is going to redo anyway.
  Future<Song?> getVideoDetailsViaYtDlp(String videoId) async {
    try {
      if (!await YtDlpRuntime.ensureInitialized()) {
        debugPrint('[YT] yt-dlp unavailable for metadata of $videoId');
        return null;
      }
    } catch (e) {
      debugPrint('[YT] yt-dlp init failed while reading metadata: $e');
      return null;
    }

    final videoUrl = 'https://www.youtube.com/watch?v=$videoId';
    // One budget for the whole walk, not per client. Four clients at 20s each
    // was a 80-second worst case for a step the user is watching a spinner for.
    final deadline = DateTime.now().add(_metadataYtDlpDeadline);
    for (final client in _ytDlpPlayerClients) {
      final remaining = deadline.difference(DateTime.now());
      if (remaining <= Duration.zero) {
        debugPrint('[YT] yt-dlp metadata budget exhausted for $videoId');
        break;
      }
      try {
        final info = await YoutubeDLFlutter.instance
            .getVideoInfoWithOptions(videoUrl, {
              '--no-update': '',
              '--no-playlist': '',
              '--force-ipv4': '',
              '--socket-timeout': '6',
              '-R': '1',
              '--skip-download': '',
              '--extractor-args':
                  'youtube:player_client=$client;skip=hls,dash,translated_subs',
            })
            // Whichever is shorter: this client's own slice, or what is left of
            // the overall budget.
            .timeout(remaining < const Duration(seconds: 10)
                ? remaining
                : const Duration(seconds: 10));

        final title = info.title?.trim();
        if (title == null || title.isEmpty) continue;

        // yt-dlp's own thumbnail url beats a guessed one, but i.ytimg.com is a
        // stable last resort — the download path needs SOMETHING to write as
        // the sidecar cover when the file carries no embedded art.
        final thumb = (info.thumbnail != null && info.thumbnail!.isNotEmpty)
            ? info.thumbnail!
            : 'https://i.ytimg.com/vi/$videoId/hqdefault.jpg';

        debugPrint('[YT] yt-dlp metadata for $videoId via player_client=$client');
        return Song(
          id: videoId,
          title: title,
          artist: (info.uploader?.trim().isNotEmpty ?? false)
              ? info.uploader!.trim()
              : 'YouTube',
          thumbnailUrl: thumb,
          highResThumbnailUrl: thumb,
          duration: Duration(seconds: info.duration ?? 0),
          videoId: videoId,
        );
      } on TimeoutException {
        debugPrint('[YT] yt-dlp metadata timed out (player_client=$client)');
      } catch (e) {
        debugPrint('[YT] yt-dlp metadata failed (player_client=$client): $e');
      }
    }
    return null;
  }

  /// Get search suggestions
  Future<List<String>> getSearchSuggestions(String query) async {
    try {
      final suggestions = await _yt.search.getQuerySuggestions(query);
      return suggestions.take(8).toList();
    } catch (e) {
      return [];
    }
  }

  Song _videoToSong(Video video) {
    final cleanTitle = EncodingSanitizer.sanitize(video.title);
    final cleanAuthor = EncodingSanitizer.sanitize(video.author);
    final medThumb = EncodingSanitizer.sanitizeThumbnailUrl(
      video.thumbnails.mediumResUrl,
      videoId: video.id.value,
    );
    final highThumb = EncodingSanitizer.sanitizeThumbnailUrl(
      video.thumbnails.standardResUrl.isNotEmpty
          ? video.thumbnails.standardResUrl
          : (video.thumbnails.maxResUrl.isNotEmpty ? video.thumbnails.maxResUrl : video.thumbnails.mediumResUrl),
      videoId: video.id.value,
    );

    return Song(
      id: video.id.value,
      title: cleanTitle.isNotEmpty ? cleanTitle : 'YouTube Video',
      artist: cleanAuthor.isNotEmpty ? cleanAuthor : 'YouTube',
      thumbnailUrl: medThumb,
      highResThumbnailUrl: highThumb.isNotEmpty ? highThumb : medThumb,
      duration: video.duration ?? Duration.zero,
      videoId: video.id.value,
    );
  }

  void dispose() {
    _yt.close();
  }
}

class _CachedUrl {
  final String url;
  final DateTime cachedAt;

  _CachedUrl(this.url, this.cachedAt);

  bool get isExpired =>
      DateTime.now().difference(cachedAt) > YouTubeService._cacheExpiry;
}
