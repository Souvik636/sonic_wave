import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import '../models/song.dart';

/// Live radio stations from the Radio-Browser open API.
///
/// Key reliability rules applied here:
///   - Only HTTPS stations are requested from the API (`is_https=true`)
///     so we NEVER need to rewrite http:// -> https:// (rewriting breaks
///     most streams because their servers don't serve TLS at all).
///   - Broken stations are excluded server-side (`hidebroken=true`).
///   - Station IDs embed the stream URL after the `_url_` marker; ALWAYS
///     extract it with [RadioService.streamUrlFromId], never split('_').
class RadioService {
  static final RadioService _instance = RadioService._internal();
  factory RadioService() => _instance;
  RadioService._internal();

  static const String idPrefix = 'radio_';
  static const String _urlMarker = '_url_';

  final HttpClient _client = HttpClient()
    ..connectionTimeout = const Duration(seconds: 4);

  List<Song>? _cache;
  DateTime? _cacheTime;
  static const Duration _cacheTtl = Duration(minutes: 30);

  // Small per-query cache for global searches (query → results).
  final Map<String, List<Song>> _searchCache = {};

  final List<String> _apiServers = [
    'https://de1.api.radio-browser.info',
    'https://nl1.api.radio-browser.info',
    'https://at1.api.radio-browser.info',
    'https://fr1.api.radio-browser.info',
  ];

  /// True if this Song id belongs to a radio station.
  static bool isRadioId(String id) => id.startsWith(idPrefix);

  /// Extracts the direct stream URL from a radio Song id.
  /// Splits on the FIRST `_url_` marker only — stream URLs themselves
  /// often contain underscores.
  static String? streamUrlFromId(String id) {
    final index = id.indexOf(_urlMarker);
    if (index == -1) return null;
    final url = id.substring(index + _urlMarker.length);
    return url.isEmpty ? null : url;
  }

  /// Parse one Radio-Browser station JSON entry into a Song, applying the
  /// same safety rules everywhere (HTTPS-only, playable container, dedupe).
  Song? _stationFromJson(dynamic item, Set<String> seenUrls,
      {String fallbackGenre = 'RADIO'}) {
    final uuid = item['stationuuid'] as String?;
    final name = (item['name'] as String? ?? '').trim();
    final url =
        (item['url_resolved'] as String? ?? item['url'] as String? ?? '')
            .trim();
    final tags = item['tags'] as String? ?? '';
    final favicon = item['favicon'] as String? ?? '';
    final country = (item['countrycode'] as String? ?? '').trim();

    if (uuid == null || uuid.isEmpty || url.isEmpty || name.isEmpty) {
      return null;
    }
    // Defensive: even with is_https=true, never let cleartext through.
    if (!url.startsWith('https://')) return null;
    // Skip playlists the player can't open directly (.pls/.m3u text
    // playlists — note plain .m3u8 HLS IS playable by just_audio).
    final lower = url.toLowerCase();
    if (lower.endsWith('.pls') ||
        (lower.endsWith('.m3u') && !lower.endsWith('.m3u8'))) {
      return null;
    }
    if (!seenUrls.add(url)) return null;

    final genre = tags.isNotEmpty
        ? tags.split(',')[0].trim().toUpperCase()
        : (country.isNotEmpty ? country : fallbackGenre);

    return Song(
      id: '$idPrefix$uuid$_urlMarker$url',
      videoId: '$idPrefix$uuid$_urlMarker$url',
      title: name,
      artist: 'Radio • $genre',
      thumbnailUrl: favicon,
      highResThumbnailUrl: favicon,
      duration: Duration.zero, // live stream
    );
  }

  /// Search stations GLOBALLY by name/tag/language via Radio-Browser.
  /// Same HTTPS/broken-station safety rules as [fetchTopStations].
  Future<List<Song>> searchStations(String query, {int limit = 60}) async {
    final clean = query.trim();
    if (clean.isEmpty) return [];
    final cacheKey = clean.toLowerCase();
    final cached = _searchCache[cacheKey];
    if (cached != null) return cached;

    List? data;
    for (final server in _apiServers) {
      try {
        final uri = Uri.parse(
            '$server/json/stations/search?name=${Uri.encodeComponent(clean)}'
            '&limit=$limit&order=clickcount&reverse=true'
            '&hidebroken=true&is_https=true');
        final request =
            await _client.getUrl(uri).timeout(const Duration(seconds: 4));
        request.headers
            .set(HttpHeaders.userAgentHeader, 'MusicApp/1.0 (Flutter)');
        final response =
            await request.close().timeout(const Duration(seconds: 4));
        if (response.statusCode == 200) {
          final body = await response
              .transform(utf8.decoder)
              .join()
              .timeout(const Duration(seconds: 5));
          data = jsonDecode(body) as List?;
          if (data != null && data.isNotEmpty) break;
        }
      } catch (e) {
        debugPrint('[RadioService] search mirror $server failed: $e');
      }
    }

    // Fall back to tag search when a name search finds nothing (e.g. "jazz").
    if (data == null || data.isEmpty) {
      for (final server in _apiServers) {
        try {
          final uri = Uri.parse(
              '$server/json/stations/bytag/${Uri.encodeComponent(clean.toLowerCase())}'
              '?limit=$limit&order=clickcount&reverse=true'
              '&hidebroken=true&is_https=true');
          final request =
              await _client.getUrl(uri).timeout(const Duration(seconds: 4));
          request.headers
              .set(HttpHeaders.userAgentHeader, 'MusicApp/1.0 (Flutter)');
          final response =
              await request.close().timeout(const Duration(seconds: 4));
          if (response.statusCode == 200) {
            final body = await response
                .transform(utf8.decoder)
                .join()
                .timeout(const Duration(seconds: 5));
            data = jsonDecode(body) as List?;
            if (data != null && data.isNotEmpty) break;
          }
        } catch (e) {
          debugPrint('[RadioService] tag-search mirror $server failed: $e');
        }
      }
    }

    final stations = <Song>[];
    final seenUrls = <String>{};
    if (data != null) {
      for (final item in data) {
        final s = _stationFromJson(item, seenUrls, fallbackGenre: 'WORLD');
        if (s != null) stations.add(s);
      }
    }

    _searchCache[cacheKey] = stations;
    return stations;
  }

  Future<List<Song>> fetchTopStations() async {
    // Serve cached list while fresh.
    if (_cache != null &&
        _cacheTime != null &&
        DateTime.now().difference(_cacheTime!) < _cacheTtl) {
      return _cache!;
    }

    List? data;

    for (final server in _apiServers) {
      try {
        // is_https=true  -> only TLS streams (no cleartext problems, no rewriting)
        // hidebroken=true -> API excludes stations that failed its own checks
        final uri = Uri.parse(
            '$server/json/stations/search?limit=60'
            '&order=clickcount&reverse=true&hidebroken=true&is_https=true');
        final request =
            await _client.getUrl(uri).timeout(const Duration(seconds: 4));
        request.headers
            .set(HttpHeaders.userAgentHeader, 'MusicApp/1.0 (Flutter)');
        final response =
            await request.close().timeout(const Duration(seconds: 4));

        if (response.statusCode == 200) {
          final body = await response
              .transform(utf8.decoder)
              .join()
              .timeout(const Duration(seconds: 5));
          data = jsonDecode(body) as List?;
          if (data != null && data.isNotEmpty) break;
        }
      } catch (e) {
        debugPrint('[RadioService] mirror $server failed: $e');
      }
    }

    final stations = <Song>[];
    final seenUrls = <String>{};

    if (data != null) {
      for (final item in data) {
        final uuid = item['stationuuid'] as String?;
        final name = (item['name'] as String? ?? '').trim();
        final url =
            (item['url_resolved'] as String? ?? item['url'] as String? ?? '')
                .trim();
        final tags = item['tags'] as String? ?? '';
        final favicon = item['favicon'] as String? ?? '';

        if (uuid == null || uuid.isEmpty || url.isEmpty || name.isEmpty) {
          continue;
        }
        // Defensive: even with is_https=true, never let cleartext through.
        if (!url.startsWith('https://')) continue;
        // Skip playlists the player can't open directly (.pls/.m3u text
        // playlists — note plain .m3u8 HLS IS playable by just_audio).
        final lower = url.toLowerCase();
        if (lower.endsWith('.pls') ||
            (lower.endsWith('.m3u') && !lower.endsWith('.m3u8'))) {
          continue;
        }
        if (!seenUrls.add(url)) continue;

        final genre =
            tags.isNotEmpty ? tags.split(',')[0].trim().toUpperCase() : 'INDIA';

        stations.add(Song(
          id: '$idPrefix$uuid$_urlMarker$url',
          videoId: '$idPrefix$uuid$_urlMarker$url',
          title: name,
          artist: 'Radio • $genre',
          thumbnailUrl: favicon,
          highResThumbnailUrl: favicon,
          duration: Duration.zero, // live stream
        ));
      }
    }

    // Prepend curated, known-good HTTPS streams (deduped by title).
    final curated = _curatedStations();
    for (final cur in curated.reversed) {
      final curUrl = streamUrlFromId(cur.videoId);
      final exists = stations.any((s) =>
          s.title.toLowerCase() == cur.title.toLowerCase() ||
          streamUrlFromId(s.videoId) == curUrl);
      if (!exists) stations.insert(0, cur);
    }

    _cache = stations;
    _cacheTime = DateTime.now();
    return stations;
  }

  /// Quick reachability probe used right before playback so the UI can
  /// show "station offline" instead of hanging. Radio servers often
  /// reject HEAD, so we issue a GET and abort after headers arrive.
  Future<bool> isStreamAlive(String url) async {
    try {
      final request = await _client
          .getUrl(Uri.parse(url))
          .timeout(const Duration(seconds: 4));
      request.headers.set(
        HttpHeaders.userAgentHeader,
        'Mozilla/5.0 (Linux; Android 10; Mobile) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Mobile Safari/537.36',
      );
      final response =
          await request.close().timeout(const Duration(seconds: 4));
      final ok = response.statusCode >= 200 && response.statusCode < 400;
      // We only needed the headers; detach and destroy the socket.
      unawaited(response.detachSocket().then((s) => s.destroy()).catchError(
          (_) {}));
      return ok;
    } catch (_) {
      return false;
    }
  }

  Song _station(String key, String url, String title, String genre,
      {String icon = ''}) {
    final id = '$idPrefix$key$_urlMarker$url';
    return Song(
      id: id,
      videoId: id,
      title: title,
      artist: 'Radio • $genre',
      thumbnailUrl: icon,
      highResThumbnailUrl: icon,
      duration: Duration.zero,
    );
  }

  /// Curated HTTPS streams verified to work with just_audio.
  List<Song> _curatedStations() {
    return [
      _station(
        'fallback_vividhbharati',
        'https://air.pc.cdn.bitgravity.com/air/live/pbaudio001/playlist.m3u8',
        'Vividh Bharati (All India Radio)',
        'HINDI NATIONAL 🇮🇳',
      ),
      _station(
        'fallback_redfm',
        'https://stream.zeno.fm/q97eczydqrhvv',
        'Red FM 93.5',
        'BOLLYWOOD HITS 🇮🇳',
      ),
      _station(
        'fallback_purane',
        'https://stream.zeno.fm/6n6ewddtad0uv',
        'Bollywood Gaane Purane',
        'RETRO HINDI 🇮🇳',
      ),
      _station(
        'fallback_bollywood90s',
        'https://stream.zeno.fm/rm4i9pdex3cuv',
        'RADIO BOLLYWOOD 90s',
        '90S BOLLYWOOD 🇮🇳',
      ),
      _station(
        'fallback_lata',
        'https://stream.zeno.fm/87xam8pf7tzuv',
        'Lata Mangeshkar Radio',
        'CLASSIC SINGER 🇮🇳',
      ),
      // --- International Radio Channels (100% Verified Active HTTPS Streams) ---
      _station(
        'intl_capital_uk',
        'https://media-ice.musicradio.com/CapitalMP3',
        'Capital FM UK (London)',
        'TOP 40 & POP 🇬🇧',
      ),
      _station(
        'intl_heart_uk',
        'https://media-ice.musicradio.com/HeartLondonMP3',
        'Heart Radio London',
        'HITS & POP 🇬🇧',
      ),
      _station(
        'intl_classic_fm',
        'https://media-ice.musicradio.com/ClassicFM',
        'Classic FM UK',
        'CLASSICAL 🇬🇧',
      ),
      _station(
        'intl_smooth_uk',
        'https://media-ice.musicradio.com/SmoothUK',
        'Smooth Radio UK',
        'SOUL & EASY 🇬🇧',
      ),
      _station(
        'intl_gold_uk',
        'https://media-ice.musicradio.com/GoldMP3',
        'Gold Radio UK',
        'RETRO ROCK 🇬🇧',
      ),
      _station(
        'intl_kexp_seattle',
        'https://kexp-mp3-128.streamguys1.com/kexp128.mp3',
        'KEXP 90.3 Seattle',
        'INDIE & ALTERNATIVE 🇺🇸',
      ),
      _station(
        'intl_npr_news',
        'https://npr-ice.streamguys1.com/live.mp3',
        'NPR News & Music',
        'NEWS & TALK 🇺🇸',
      ),
      _station(
        'intl_chillhop',
        'https://stream.zeno.fm/f3wvbbqmdg8uv',
        'Chillhop & Lo-Fi Beats',
        'LO-FI & CHILL ☕',
      ),
      _station(
        'intl_radio_paradise',
        'https://stream.radioparadise.com/aac-128',
        'Radio Paradise Main (HQ)',
        'ECLECTIC ROCK 🇺🇸',
      ),
      _station(
        'intl_radio_paradise_mellow',
        'https://stream.radioparadise.com/mellow-128',
        'Radio Paradise Mellow',
        'ACOUSTIC & CHILL ☕',
      ),
      _station(
        'intl_fip_france',
        'https://icecast.radiofrance.fr/fip-midfi.mp3',
        'FIP Radio Paris',
        'ECLECTIC & JAZZ 🇫🇷',
      ),
      _station(
        'intl_radio_nova',
        'https://novazz.ice.infomaniak.ch/novazz-128.mp3',
        'Radio Nova France',
        'INDIE & GROOVE 🇫🇷',
      ),
      _station(
        'intl_antenne_bayern',
        'https://stream.antenne.de/antenne',
        'Antenne Bayern',
        'GLOBAL HITS 🇩🇪',
      ),
      _station(
        'intl_somafm_groove',
        'https://ice2.somafm.com/groovesalad-128-mp3',
        'SomaFM Groove Salad',
        'AMBIENT & CHILL ☕',
      ),
      _station(
        'intl_somafm_deepspace',
        'https://ice2.somafm.com/deepspaceone-128-mp3',
        'SomaFM Deep Space One',
        'SPACE AMBIENT 🌌',
      ),
    ];
  }
}
