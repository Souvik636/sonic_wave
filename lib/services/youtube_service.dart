import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:youtube_explode_dart/youtube_explode_dart.dart';
import 'package:flutter/foundation.dart';
import 'package:extractor/extractor.dart';
import '../models/song.dart';
import '../providers/settings_provider.dart' show AudioQuality;
import 'ytdlp_runtime.dart';

class YouTubeService {
  final YoutubeExplode _yt = YoutubeExplode();

  /// Streaming quality preference (set from Settings via PlayerProvider).
  /// low ≈ smallest bitrate, medium ≈ ~128kbps balance, high = best bitrate.
  static AudioQuality streamingQuality = AudioQuality.high;

  // Stream URL cache: '<videoId>@<quality>' → (url, timestamp)
  // URLs expire after 5 minutes (YouTube stream URLs are temporary).
  //
  // The key includes the quality because a cached High URL must NOT be served
  // after the user switches to Low. Keying on videoId alone made a quality
  // change appear to do nothing until the 5-minute TTL lapsed. Keying it here
  // also handles the fact that YouTubeService is NOT a singleton — every
  // instance has its own cache, so a static "clear" could not reach them all.
  final Map<String, _CachedUrl> _streamCache = {};
  static const Duration _cacheExpiry = Duration(minutes: 5);

  /// Cache key for [videoId] under the quality currently selected in Settings.
  static String _cacheKey(String videoId) =>
      '$videoId@${streamingQuality.name}';

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
  static final Set<String> _failedInstances = {};
  static final Set<String> _failedPipedInstances = {};

  static final List<YoutubeApiClient> _clientPriority = [
    YoutubeApiClient.ios,
    YoutubeApiClient.androidMusic,
    YoutubeApiClient.android,
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
        YoutubeApiClient.androidVr,
        YoutubeApiClient.android,
        YoutubeApiClient.androidSdkless,
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
    _failedInstances.addAll(failedInvidious);

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
    _failedPipedInstances.addAll(failedPiped);
    
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
    
    // Scan instances that have not failed
    for (final instance in _invidiousInstances) {
      if (_failedInstances.contains(instance)) continue;
      
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
        _failedInstances.add(instance);
        debugPrint('Invidious search failed for instance $instance: $e');
      }
    }
    client.close();
    return null;
  }

  Future<String?> _fetchInvidiousStreamUrl(String videoId) async {
    _loadWorkingInstances();
    final client = HttpClient();
    
    for (final instance in _invidiousInstances) {
      if (_failedInstances.contains(instance)) continue;
      
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
        _failedInstances.add(instance);
        debugPrint('Invidious instance $instance failed for $videoId: $e');
      }
    }
    client.close();
    return null;
  }

  /// Fetch stream URL from Piped API instances.
  /// Piped uses a different API format: /streams/{videoId} → audioStreams[].url
  Future<String?> _fetchPipedStreamUrl(String videoId) async {
    _loadWorkingInstances();
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 5);

    for (final apiUrl in _pipedInstances) {
      if (_failedPipedInstances.contains(apiUrl)) continue;

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
        _failedPipedInstances.add(apiUrl);
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
  Future<String> getAudioStreamUrl(String videoId) async {
    final cacheKey = _cacheKey(videoId);
    final cached = _streamCache[cacheKey];
    if (cached != null && !cached.isExpired) {
      return cached.url;
    }

    final completer = Completer<String>();
    bool fastChainDone = false;
    bool ytDlpStarted = false;
    bool ytDlpDone = false;
    Object? fastError;

    void completeWith(String url) {
      if (!completer.isCompleted) {
        _streamCache[cacheKey] = _CachedUrl(url, DateTime.now());
        completer.complete(url);
      }
    }

    void failIfBothExhausted() {
      if (!completer.isCompleted && fastChainDone && (ytDlpDone || !ytDlpStarted)) {
        completer.completeError(
            fastError ?? Exception('Failed to get audio stream from all sources.'));
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
      // yt-dlp exhausted: if the fast chain has also finished empty, fail.
      failIfBothExhausted();
    }

    Future<void> runFastChain() async {
      try {
        // 1. YouTube Explode clients in priority order
        final List<YoutubeApiClient> clients = List.from(_clientPriority);
        for (final client in clients) {
          if (completer.isCompleted) return;
          try {
            final manifest = await _yt.videos.streamsClient
                .getManifest(videoId, ytClients: [client])
                .timeout(const Duration(seconds: 2, milliseconds: 500));
            final url = _pickBestStream(manifest);
            if (url != null) {
              if (_clientPriority.first != client) {
                _clientPriority.remove(client);
                _clientPriority.insert(0, client);
              }
              completeWith(url);
              return;
            }
          } catch (e) {
            debugPrint('[YT] Client $client failed for $videoId: $e');
          }
        }

        // 2. Invidious direct stream resolution
        if (completer.isCompleted) return;
        try {
          final invidiousUrl = await _fetchInvidiousStreamUrl(videoId);
          if (invidiousUrl != null) {
            completeWith(invidiousUrl);
            return;
          }
        } catch (e) {
          debugPrint('[YT] Invidious stream fallback failed for $videoId: $e');
        }

        // 3. Piped API stream resolution
        if (completer.isCompleted) return;
        try {
          final pipedUrl = await _fetchPipedStreamUrl(videoId);
          if (pipedUrl != null) {
            completeWith(pipedUrl);
            return;
          }
        } catch (e) {
          debugPrint('[YT] Piped stream fallback failed for $videoId: $e');
        }
      } catch (e) {
        fastError = e;
      } finally {
        fastChainDone = true;
        if (!completer.isCompleted) {
          // yt-dlp is already racing (or finished empty) — settle if both done.
          failIfBothExhausted();
        }
      }
    }

    // Kick off BOTH tracks immediately — no delay. First playable URL wins.
    runFastChain();
    runYtDlp();

    return completer.future;
  }

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
  static const List<String> _ytDlpPlayerClients = [
    'android_vr',
    'tv',
    'ios',
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
    switch (quality) {
      case AudioQuality.high:
        // Prefer genuinely higher-bitrate audio (opus 160k / AAC 256k) and fall
        // back to whatever the best audio-only track is.
        return 'bestaudio[abr>=160]/bestaudio/best';
      case AudioQuality.medium:
        // ~128kbps balance. itag 140 first as the reliable AAC 128k baseline.
        return '140/bestaudio[abr<=140]/bestaudio/best';
      case AudioQuality.low:
        // Data saver: the smallest audio-only track available.
        return 'bestaudio[abr<=70]/worstaudio/bestaudio/best';
    }
  }

  String _ytDlpAudioSorter() => ytDlpAudioSorter(streamingQuality);

  /// Resolve stream URL specifically using native yt-dlp binary (JunkFood02/Seal implementation)
  Future<String?> getYtDlpStreamUrl(String videoId) async {
    try {
      // Single-flight init guard — awaits the startup init instead of racing
      // it with a second initialize() call (which broke yt-dlp entirely).
      if (!await YtDlpRuntime.ensureInitialized()) {
        debugPrint('[YT] yt-dlp unavailable (init failed) for $videoId');
        return null;
      }
    } catch (e) {
      debugPrint('[YT] YtDlpRuntime init failed with exception: $e');
      return null;
    }
    final videoUrl = 'https://www.youtube.com/watch?v=$videoId';

    // Try each player client in turn. The first that yields a playable audio
    // URL wins; a client that throws or returns nothing falls through to the
    // next, and only when all are exhausted do we let the resolver chain move
    // on to Explode/Invidious/Piped.
    for (final client in _ytDlpPlayerClients) {
      try {
        debugPrint('[YT] yt-dlp extract $videoId (player_client=$client)');
        final info = await YoutubeDLFlutter.instance
            .getVideoInfoWithOptions(videoUrl, {
              '--no-update': '',
              // Mobile network hardening: fail fast on a dead socket, retry once,
              // and enforce IPv4 to bypass mobile carrier dual-stack DNS delays.
              '--socket-timeout': '4',
              '-R': '1',
              '--no-playlist': '',
              '--force-ipv4': '',
              // Audio-only selection honouring the user's quality setting. The
              // `-f` chain and the `-S` sorter must agree — see
              // [ytDlpFormatChain] for why a hardcoded itag broke this.
              '-f': ytDlpFormatChain(streamingQuality),
              '-S': _ytDlpAudioSorter(),
              // Skip HLS/DASH manifest & webpage HTML fetches — direct audio URLs in
              // the player response are enough for streaming, cutting 2-3 network round-trips.
              '--extractor-args':
                  'youtube:player_client=$client;skip=hls,dash,translated_subs,webpage',
            })
            // Bounded: a hung native extraction must not stall the resolver.
            .timeout(const Duration(seconds: 8));

        // With -f, yt-dlp already picked the best format: top-level url.
        String? url = info.url;
        if (url == null || !url.startsWith('http')) {
          url = _pickYtDlpAudioUrl(info.formats);
        }
        if (url != null) {
          // Log the resolved bitrate/format so the quality setting is verifiable
          // on-device (see the plan's verification step 4).
          debugPrint('[YT] yt-dlp resolved via player_client=$client '
              'quality=${streamingQuality.name} '
              'ext=${info.ext ?? "?"} acodec=${info.acodec ?? "?"}');
          _streamCache[_cacheKey(videoId)] = _CachedUrl(url, DateTime.now());
          return url;
        }
        debugPrint('[YT] yt-dlp client=$client returned no playable audio');
      } on TimeoutException {
        debugPrint('[YT] yt-dlp client=$client timed out');
      } catch (e) {
        debugPrint('[YT] yt-dlp client=$client failed: $e');
      }
    }
    return null;
  }

  /// Pick the best audio-only stream URL from a yt-dlp format list, preferring
  /// audio-only tracks by bitrate, then any track carrying an audio codec.
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
      audioOnly.sort((a, b) => (a.tbr ?? 0).compareTo(b.tbr ?? 0));
      switch (streamingQuality) {
        case AudioQuality.low:
          selected = audioOnly.first; // Data saver (~64kbps)
          break;
        case AudioQuality.high:
          selected = audioOnly.last; // High quality (~160kbps - 256kbps)
          break;
        case AudioQuality.medium:
          for (final f in audioOnly) {
            if ((f.tbr ?? 0) >= 100 && (f.tbr ?? 0) <= 160) {
              selected = f;
              break;
            }
          }
          selected ??= audioOnly[audioOnly.length ~/ 2];
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

  /// Get video details by ID.
  ///
  /// Explode is tried first (one cheap HTTP call), but it is the same client
  /// stack that already fails outright on device for stream resolution, and a
  /// shared YouTube link has nothing else to fall back on — a metadata failure
  /// there kills a download the yt-dlp pipeline could have completed on its
  /// own. So a failure here drops to yt-dlp, which is the extractor the app
  /// actually trusts.
  Future<Song> getVideoDetails(String videoId) async {
    try {
      final video = await _yt.videos.get(videoId);
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
    for (final client in _ytDlpPlayerClients) {
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
            .timeout(const Duration(seconds: 20));

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
