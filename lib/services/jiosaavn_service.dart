import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import '../models/song.dart';

class JioSaavnService {
  static final JioSaavnService _instance = JioSaavnService._internal();
  factory JioSaavnService() => _instance;
  JioSaavnService._internal();

  final HttpClient _client = HttpClient()
    ..connectionTimeout = const Duration(seconds: 4);

  static const List<String> _wrapperUrls = [
    'https://saavn.sumit.co',
    'https://nepotuneapi.vercel.app',
  ];

  static const String _officialApiBase = 'https://www.jiosaavn.com/api.php';

  // Simple in-memory cache: query → (url, timestamp)
  final Map<String, _CachedResult> _cache = {};
  static const Duration _cacheExpiry = Duration(minutes: 10);

  /// Search for songs on JioSaavn using direct official endpoints + song details resolution.
  Future<List<Song>> searchSongs(String query, {int maxResults = 12}) async {
    final cleanQuery = query.trim();
    if (cleanQuery.isEmpty) return [];

    try {
      final Set<String> pids = {};

      // 1. Search albums via official JioSaavn API
      final albumSearchUrl = '$_officialApiBase?__call=search.getAlbumResults&_format=json&_marker=0&api_version=4&ctx=web64bit&q=${Uri.encodeComponent(cleanQuery)}&n=6';
      try {
        final request = await _client.getUrl(Uri.parse(albumSearchUrl)).timeout(const Duration(seconds: 4));
        final response = await request.close().timeout(const Duration(seconds: 4));
        if (response.statusCode == 200) {
          final body = await response.transform(utf8.decoder).join();
          final data = jsonDecode(body);
          if (data is Map && data['results'] is List) {
            for (final album in data['results']) {
              final songPidsStr = album['more_info']?['song_pids']?.toString() ?? '';
              if (songPidsStr.isNotEmpty) {
                for (final pid in songPidsStr.split(',')) {
                  final clean = pid.trim();
                  if (clean.isNotEmpty) pids.add(clean);
                }
              }
            }
          }
        }
      } catch (e) {
        debugPrint('[JioSaavn] album search failed: $e');
      }

      // 2. Search autocomplete via official JioSaavn API
      final autoUrl = '$_officialApiBase?__call=autocomplete.get&_format=json&_marker=0&api_version=4&ctx=web64bit&query=${Uri.encodeComponent(cleanQuery)}';
      try {
        final request = await _client.getUrl(Uri.parse(autoUrl)).timeout(const Duration(seconds: 4));
        final response = await request.close().timeout(const Duration(seconds: 4));
        if (response.statusCode == 200) {
          final body = await response.transform(utf8.decoder).join();
          final data = jsonDecode(body);
          if (data is Map) {
            final albumsData = data['albums']?['data'] as List?;
            if (albumsData != null) {
              for (final album in albumsData) {
                final songPidsStr = album['more_info']?['song_pids']?.toString() ?? '';
                if (songPidsStr.isNotEmpty) {
                  for (final pid in songPidsStr.split(',')) {
                    final clean = pid.trim();
                    if (clean.isNotEmpty) pids.add(clean);
                  }
                }
              }
            }
          }
        }
      } catch (e) {
        debugPrint('[JioSaavn] autocomplete failed: $e');
      }

      // 3. Fallback: try wrapper /api/search?query=...
      if (pids.isEmpty) {
        for (final base in _wrapperUrls) {
          try {
            final searchUrl = '$base/api/search?query=${Uri.encodeComponent(cleanQuery)}';
            final request = await _client.getUrl(Uri.parse(searchUrl)).timeout(const Duration(seconds: 4));
            final response = await request.close().timeout(const Duration(seconds: 4));
            if (response.statusCode == 200) {
              final body = await response.transform(utf8.decoder).join();
              final data = jsonDecode(body);
              if (data is Map && data['success'] == true && data['data'] != null) {
                final albums = data['data']['albums']?['results'] as List?;
                if (albums != null) {
                  for (final album in albums) {
                    final songIds = album['songIds']?.toString() ?? '';
                    if (songIds.isNotEmpty) {
                      for (final pid in songIds.split(',')) {
                        final clean = pid.trim();
                        if (clean.isNotEmpty) pids.add(clean);
                      }
                    }
                  }
                }
              }
            }
          } catch (_) {}
        }
      }

      if (pids.isEmpty) return [];

      // 4. Fetch full song details for collected PIDs
      final pidsChunk = pids.take(maxResults).join(',');
      final detailsUrl = '$_officialApiBase?__call=song.getDetails&pids=$pidsChunk&_format=json';

      final request = await _client.getUrl(Uri.parse(detailsUrl)).timeout(const Duration(seconds: 4));
      final response = await request.close().timeout(const Duration(seconds: 4));

      if (response.statusCode != 200) {
        await response.drain();
        return [];
      }

      final body = await response.transform(utf8.decoder).join();
      final Map<String, dynamic> songMap = jsonDecode(body) as Map<String, dynamic>;

      final List<Song> songs = [];
      for (final entry in songMap.entries) {
        final data = entry.value;
        if (data is! Map) continue;

        final id = entry.key;
        final name = (data['song'] ?? data['title'] ?? '').toString().trim();
        if (id.isEmpty || name.isEmpty) continue;

        final artistName = (data['primary_artists'] ?? data['singers'] ?? 'JioSaavn Artist').toString();

        final imageUrl = (data['image'] ?? '').toString().replaceAll('150x150', '500x500');
        final lowResImage = (data['image'] ?? '').toString();

        final durationSecs = data['duration'] is num
            ? (data['duration'] as num).toInt()
            : int.tryParse(data['duration']?.toString() ?? '0') ?? 0;

        songs.add(Song(
          id: 'jiosaavn_$id',
          videoId: 'jiosaavn_$id',
          title: name,
          artist: artistName,
          thumbnailUrl: lowResImage,
          highResThumbnailUrl: imageUrl,
          duration: Duration(seconds: durationSecs),
        ));
      }

      return songs;
    } catch (e) {
      debugPrint('[JioSaavn] searchSongs failed: $e');
      return [];
    }
  }

  /// Get direct stream URL of a song by JioSaavn ID (PID)
  Future<String?> getStreamUrlById(String id) async {
    final cleanId = id.replaceFirst('jiosaavn_', '').trim();
    if (cleanId.isEmpty) return null;

    // Check cache
    final cached = _cache[cleanId];
    if (cached != null && !cached.isExpired) {
      return cached.url;
    }

    // 1. Try wrapper endpoints for 320kbps / 160kbps decoded audio links
    for (final base in _wrapperUrls) {
      final url = '$base/api/songs/$cleanId';
      try {
        final request = await _client.getUrl(Uri.parse(url)).timeout(const Duration(seconds: 4));
        final response = await request.close().timeout(const Duration(seconds: 4));
        if (response.statusCode != 200) {
          await response.drain();
          continue;
        }

        final body = await response.transform(utf8.decoder).join();
        final data = jsonDecode(body);

        List? results;
        if (data is Map && data['success'] == true && data['data'] != null) {
          final rawData = data['data'];
          if (rawData is List) {
            results = rawData;
          } else if (rawData is Map) {
            results = [rawData];
          }
        }

        if (results == null || results.isEmpty) continue;

        final item = results.first;
        final downloadUrls = item['downloadUrl'] as List?;
        if (downloadUrls != null && downloadUrls.isNotEmpty) {
          String? fallbackLink;
          for (final dl in downloadUrls) {
            final quality = dl['quality']?.toString() ?? '';
            final link = dl['link']?.toString() ?? dl['url']?.toString() ?? '';
            if (link.isEmpty) continue;
            if (quality == '320kbps' || quality == '160kbps') {
              _cache[cleanId] = _CachedResult(link, DateTime.now());
              return link;
            }
            if (quality == '128kbps' || quality == '96kbps') {
              fallbackLink = link;
            }
          }
          if (fallbackLink != null) {
            _cache[cleanId] = _CachedResult(fallbackLink, DateTime.now());
            return fallbackLink;
          }

          final lastLink = downloadUrls.last['link']?.toString() ?? downloadUrls.last['url']?.toString();
          if (lastLink != null && lastLink.isNotEmpty) {
            _cache[cleanId] = _CachedResult(lastLink, DateTime.now());
            return lastLink;
          }
        }
      } catch (e) {
        debugPrint('[JioSaavn] getStreamUrlById failed for $base: $e');
      }
    }

    // 2. Fallback: try official JioSaavn song.getDetails endpoint for media_preview_url / vlink
    try {
      final detailsUrl = '$_officialApiBase?__call=song.getDetails&pids=$cleanId&_format=json';
      final request = await _client.getUrl(Uri.parse(detailsUrl)).timeout(const Duration(seconds: 4));
      final response = await request.close().timeout(const Duration(seconds: 4));

      if (response.statusCode == 200) {
        final body = await response.transform(utf8.decoder).join();
        final data = jsonDecode(body);
        if (data is Map && data.containsKey(cleanId)) {
          final item = data[cleanId];
          final mediaPreviewUrl = item['media_preview_url']?.toString() ?? '';
          final vlink = item['vlink']?.toString() ?? '';

          if (mediaPreviewUrl.isNotEmpty && mediaPreviewUrl.startsWith('http')) {
            _cache[cleanId] = _CachedResult(mediaPreviewUrl, DateTime.now());
            return mediaPreviewUrl;
          }
          if (vlink.isNotEmpty && vlink.startsWith('http')) {
            _cache[cleanId] = _CachedResult(vlink, DateTime.now());
            return vlink;
          }
        }
      }
    } catch (e) {
      debugPrint('[JioSaavn] official getStreamUrlById failed: $e');
    }

    return null;
  }

  /// Lookup matching song on JioSaavn by Title & Artist and get its direct streaming URL.
  Future<String?> getStreamUrl(String title, String artist) async {
    final query = artist.isNotEmpty ? '$title $artist' : title;
    final cached = _cache[query.toLowerCase()];
    if (cached != null && !cached.isExpired) {
      return cached.url;
    }

    final songs = await searchSongs(query, maxResults: 5);
    if (songs.isEmpty) return null;

    final song = songs.first;
    final url = await getStreamUrlById(song.videoId);
    if (url != null) {
      _cache[query.toLowerCase()] = _CachedResult(url, DateTime.now());
    }
    return url;
  }
}

class _CachedResult {
  final String url;
  final DateTime timestamp;
  _CachedResult(this.url, this.timestamp);

  bool get isExpired =>
      DateTime.now().difference(timestamp) > JioSaavnService._cacheExpiry;
}
