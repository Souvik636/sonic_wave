import 'dart:convert';
import 'dart:io';
import 'package:audio_metadata_reader/audio_metadata_reader.dart';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import '../models/song.dart';

class LyricEntry {
  final Duration time;
  final String text;

  LyricEntry(this.time, this.text);
}

class LyricsService {
  static final LyricsService _instance = LyricsService._internal();
  factory LyricsService() => _instance;
  LyricsService._internal();

  static const String _userAgent =
      'SonicWave/1.2.10 (https://github.com/sonicwave; contact@sonicwave.app)';

  // ─────────────────────────────────────────────────────────
  // Public API
  // ─────────────────────────────────────────────────────────

  /// Parse LRC format string into a list of LyricEntry
  List<LyricEntry> parseLrc(String lrcText) {
    final List<LyricEntry> entries = [];
    final RegExp timeRegExp = RegExp(r'\[(\d+):(\d+)\.(\d+)\]');
    final lines = lrcText.split('\n');

    for (final line in lines) {
      final match = timeRegExp.firstMatch(line);
      if (match != null) {
        final minutes     = int.parse(match.group(1)!);
        final seconds     = int.parse(match.group(2)!);
        final milliseconds = int.parse(match.group(3)!) * 10;
        final time = Duration(
          minutes: minutes,
          seconds: seconds,
          milliseconds: milliseconds,
        );
        final text = line.replaceAll(timeRegExp, '').trim();
        if (text.isNotEmpty) {
          entries.add(LyricEntry(time, text));
        }
      }
    }
    entries.sort((a, b) => a.time.compareTo(b.time));
    return entries;
  }

  /// Get time-synced lyrics for a song.
  ///
  /// Resolution order:
  ///  1. Local LRC file cache → instant
  ///  2. Embedded USLT tag (offline/downloaded files only)
  ///  3. LRCLIB /api/get (exact title+artist+duration match)
  ///  4. LRCLIB /api/search (fuzzy title+artist fallback)
  ///  5. JioSaavn wrapper  (only for jiosaavn_ IDs)
  ///  6. Dynamic placeholder generation
  Future<List<LyricEntry>> getLyricsForSong(Song song) async {
    // 1. Check local LRC cache first — fastest possible path
    final cached = await _readLrcCache(song.videoId);
    if (cached != null) {
      final entries = parseLrc(cached);
      if (entries.isNotEmpty) return entries;
    }

    // 2. Embedded lyrics in local file (USLT / ID3 tag)
    if (song.filePath != null) {
      final embedded = await _readEmbeddedLyrics(song.filePath!);
      if (embedded != null && embedded.isNotEmpty) {
        // Convert plain embedded lyrics to timed LRC and cache them
        final entries = _generatePlainLrc(embedded, song);
        await _writeLrcCache(song.videoId, _entriesToLrc(entries));
        return entries;
      }
    }

    // 3 & 4. LRCLIB — exact then fuzzy
    final networkEntries = await _fetchFromLrcLib(song);
    if (networkEntries != null) return networkEntries;

    // 5. JioSaavn lyrics (only for saavn-originated songs)
    if (song.videoId.startsWith('jiosaavn_')) {
      final saavnEntries = await _fetchFromJioSaavn(song);
      if (saavnEntries != null) return saavnEntries;
    }

    // 6. Dynamic placeholder
    return _generateDynamicLrc(song);
  }

  // ─────────────────────────────────────────────────────────
  // Step 1 — LRC file cache
  // ─────────────────────────────────────────────────────────

  Future<Directory> _lrcCacheDir() async {
    final base = await getApplicationCacheDirectory();
    final dir  = Directory('${base.path}/lyrics');
    if (!await dir.exists()) await dir.create(recursive: true);
    return dir;
  }

  String _safeCacheId(String videoId) =>
      videoId.replaceAll(RegExp(r'[^\w\-]'), '_');

  Future<String?> _readLrcCache(String videoId) async {
    try {
      final dir  = await _lrcCacheDir();
      final file = File('${dir.path}/${_safeCacheId(videoId)}.lrc');
      if (await file.exists()) return await file.readAsString();
    } catch (e) {
      debugPrint('[LyricsService] Cache read error: $e');
    }
    return null;
  }

  Future<void> _writeLrcCache(String videoId, String lrcText) async {
    try {
      final dir  = await _lrcCacheDir();
      final file = File('${dir.path}/${_safeCacheId(videoId)}.lrc');
      await file.writeAsString(lrcText);
    } catch (e) {
      debugPrint('[LyricsService] Cache write error: $e');
    }
  }

  // ─────────────────────────────────────────────────────────
  // Step 2 — Embedded USLT tag extraction
  // ─────────────────────────────────────────────────────────

  Future<String?> _readEmbeddedLyrics(String filePath) async {
    try {
      final file   = File(filePath);
      if (!await file.exists()) return null;
      final tag    = readMetadata(file, getImage: false);
      final lyrics = tag.lyrics;
      if (lyrics != null && lyrics.trim().isNotEmpty) return lyrics.trim();
    } catch (e) {
      debugPrint('[LyricsService] Embedded lyrics read error: $e');
    }
    return null;
  }

  // ─────────────────────────────────────────────────────────
  // Step 3 & 4 — LRCLIB: exact query then fuzzy search fallback
  // ─────────────────────────────────────────────────────────

  Future<List<LyricEntry>?> _fetchFromLrcLib(Song song) async {
    final cleanTitle  = _cleanQuery(song.title);
    final cleanArtist = _cleanQuery(song.artist);
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 8);

    try {
      // — Step 3: /api/get (exact match with duration) —
      final getParams = <String, String>{
        'track_name':  cleanTitle,
        'artist_name': cleanArtist,
      };
      if (song.duration.inSeconds > 0) {
        getParams['duration'] = song.duration.inSeconds.toString();
      }

      final getUri  = Uri.https('lrclib.net', '/api/get', getParams);
      final getReq  = await client.getUrl(getUri);
      getReq.headers.add('User-Agent', _userAgent);
      final getResp = await getReq.close().timeout(const Duration(seconds: 10));

      if (getResp.statusCode == HttpStatus.ok) {
        final body    = await getResp.transform(utf8.decoder).join();
        final data    = json.decode(body) as Map<String, dynamic>;
        final entries = _extractLrcLibEntries(data, song);
        if (entries != null) {
          await _writeLrcCache(song.videoId, _entriesToLrc(entries));
          return entries;
        }
      } else {
        await getResp.drain<void>();
      }

      // — Step 4: /api/search (fuzzy fallback) —
      final searchUri  = Uri.https('lrclib.net', '/api/search', {
        'q': '$cleanTitle $cleanArtist',
      });
      final searchReq  = await client.getUrl(searchUri);
      searchReq.headers.add('User-Agent', _userAgent);
      final searchResp = await searchReq.close().timeout(const Duration(seconds: 10));

      if (searchResp.statusCode == HttpStatus.ok) {
        final body    = await searchResp.transform(utf8.decoder).join();
        final results = json.decode(body) as List<dynamic>;

        // Pick the best result: prefer synced lyrics, match duration ±5s
        final durationSecs = song.duration.inSeconds;
        Map<String, dynamic>? best;

        for (final item in results.cast<Map<String, dynamic>>()) {
          final itemDur = (item['duration'] as num?)?.toInt() ?? 0;
          final withinWindow = durationSecs == 0 ||
              (itemDur - durationSecs).abs() <= 5;
          if (!withinWindow) continue;

          final hasSynced = (item['syncedLyrics'] as String? ?? '').isNotEmpty;
          if (best == null) {
            best = item;
          } else {
            final bestSynced = (best['syncedLyrics'] as String? ?? '').isNotEmpty;
            if (!bestSynced && hasSynced) best = item;
          }
        }

        if (best != null) {
          final entries = _extractLrcLibEntries(best, song);
          if (entries != null) {
            await _writeLrcCache(song.videoId, _entriesToLrc(entries));
            return entries;
          }
        }
      } else {
        await searchResp.drain<void>();
      }
    } catch (e) {
      debugPrint('[LyricsService] LRCLIB fetch failed: $e');
    } finally {
      client.close();
    }
    return null;
  }

  List<LyricEntry>? _extractLrcLibEntries(Map<String, dynamic> data, Song song) {
    final synced = data['syncedLyrics'] as String?;
    if (synced != null && synced.isNotEmpty) return parseLrc(synced);

    final plain = data['plainLyrics'] as String?;
    if (plain != null && plain.isNotEmpty) return _generatePlainLrc(plain, song);

    return null;
  }

  // ─────────────────────────────────────────────────────────
  // Step 5 — JioSaavn lyrics via the existing API wrapper
  // ─────────────────────────────────────────────────────────

  Future<List<LyricEntry>?> _fetchFromJioSaavn(Song song) async {
    // Strip the 'jiosaavn_' prefix to get the raw PID
    final pid    = song.videoId.replaceFirst('jiosaavn_', '');
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 6);

    const List<String> wrapperBases = [
      'https://saavn.sumit.co',
      'https://nepotuneapi.vercel.app',
    ];

    for (final base in wrapperBases) {
      try {
        final uri     = Uri.parse('$base/api/songs/$pid');
        final request = await client.getUrl(uri);
        request.headers.add('User-Agent', _userAgent);
        final response = await request.close().timeout(const Duration(seconds: 8));

        if (response.statusCode == HttpStatus.ok) {
          final body = await response.transform(utf8.decoder).join();
          final data = json.decode(body);

          // Wrapper may return { success: true, data: { ... } } or direct list
          Map<String, dynamic>? songData;
          if (data is Map && data['data'] is Map) {
            songData = data['data'] as Map<String, dynamic>;
          } else if (data is Map && data['data'] is List) {
            final list = data['data'] as List;
            if (list.isNotEmpty) songData = list.first as Map<String, dynamic>;
          } else if (data is Map) {
            songData = data.cast<String, dynamic>();
          }

          // Extract lyrics: prefer 'lyrics' field; check 'hasLyrics' flag as a gate
          String? lyrics = songData?['lyrics'] as String?;
          if ((lyrics == null || lyrics.isEmpty) &&
              songData?['hasLyrics'] == true) {
            lyrics = songData?['lyrics'] as String?;
          }

          if (lyrics != null && lyrics.trim().isNotEmpty) {
            final entries = _generatePlainLrc(lyrics.trim(), song);
            await _writeLrcCache(song.videoId, _entriesToLrc(entries));
            client.close();
            return entries;
          }
        } else {
          await response.drain<void>();
        }
      } catch (e) {
        debugPrint('[LyricsService] JioSaavn wrapper $base failed: $e');
      }
    }
    client.close();
    return null;
  }

  // ─────────────────────────────────────────────────────────
  // Helpers
  // ─────────────────────────────────────────────────────────

  /// Light query cleaning: remove feat./ft./parenthetical suffixes so LRCLIB
  /// can match the clean title.
  String _cleanQuery(String input) {
    return input
        .replaceAll(RegExp(r'\(feat\..*?\)', caseSensitive: false), '')
        .replaceAll(RegExp(r'\(ft\..*?\)',   caseSensitive: false), '')
        .replaceAll(RegExp(r'\(.*?version.*?\)', caseSensitive: false), '')
        .replaceAll(RegExp(r'\(.*?remix.*?\)',   caseSensitive: false), '')
        .replaceAll(RegExp(r'\[.*?\]'),  '')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
  }

  /// Convert LyricEntry list back to an LRC string for caching.
  String _entriesToLrc(List<LyricEntry> entries) {
    final buf = StringBuffer();
    for (final e in entries) {
      final m  = e.time.inMinutes.toString().padLeft(2, '0');
      final s  = (e.time.inSeconds % 60).toString().padLeft(2, '0');
      final ms = ((e.time.inMilliseconds % 1000) ~/ 10).toString().padLeft(2, '0');
      buf.writeln('[$m:$s.$ms]${e.text}');
    }
    return buf.toString();
  }

  List<LyricEntry> _generatePlainLrc(String plainLyrics, Song song) {
    final List<LyricEntry> entries = [];
    final lines = plainLyrics.split('\n').where((l) => l.trim().isNotEmpty).toList();
    if (lines.isEmpty) return _generateDynamicLrc(song);

    final totalSeconds  = song.duration.inSeconds > 0 ? song.duration.inSeconds : 180;
    const startOffset   = 5;
    final activeDuration = (totalSeconds * 0.8) - startOffset;
    final interval       = lines.length > 1 ? activeDuration / (lines.length - 1) : 10.0;

    entries.add(LyricEntry(Duration.zero, '(Intro)'));
    for (int i = 0; i < lines.length; i++) {
      final seconds = startOffset + (i * interval);
      entries.add(LyricEntry(Duration(seconds: seconds.toInt()), lines[i].trim()));
    }
    entries.add(LyricEntry(
      Duration(seconds: (totalSeconds - 4).clamp(startOffset, totalSeconds).toInt()),
      '(Outro)',
    ));
    return entries;
  }

  bool _hasIndianCharacters(String text) {
    // Unicode blocks: Devanagari, Bengali, Gurmukhi, Gujarati, Oriya, Tamil, Telugu, Kannada, Malayalam
    return RegExp(r'[\u0900-\u0DFF]').hasMatch(text);
  }

  bool _hasJapaneseCharacters(String text) {
    return RegExp(r'[\u3040-\u309F\u30A0-\u30FF\u4E00-\u9FBF]').hasMatch(text);
  }

  List<LyricEntry> _generateDynamicLrc(Song song) {
    final List<LyricEntry> entries = [];
    final totalSeconds = song.duration.inSeconds > 0 ? song.duration.inSeconds : 180;

    final title       = song.title;
    final artist      = song.artist;
    final titleLower  = title.toLowerCase();
    final artistLower = artist.toLowerCase();

    final bool isIndian = _hasIndianCharacters(title) ||
                    _hasIndianCharacters(artist) ||
                    titleLower.contains('tum')  || titleLower.contains('dil')   ||
                    titleLower.contains('ki')   || titleLower.contains('se')    ||
                    titleLower.contains('mere') || titleLower.contains('tera')  ||
                    titleLower.contains('meri') || titleLower.contains('ishq')  ||
                    titleLower.contains('naan') || titleLower.contains('nee')   ||
                    titleLower.contains('prema')|| titleLower.contains('kaadhal')||
                    artistLower.contains('arijit')  || artistLower.contains('lata') ||
                    artistLower.contains('kishore') || artistLower.contains('rahman')||
                    artistLower.contains('anirudh') || artistLower.contains('spb');

    final bool isJapanese = _hasJapaneseCharacters(title) ||
                      _hasJapaneseCharacters(artist) ||
                      artistLower.contains('yoasobi') || artistLower.contains('lisa') ||
                      artistLower.contains('radwimps');

    final bool isSpanish = titleLower.contains('despacito') || titleLower.contains('amor') ||
                     titleLower.contains('cancion')   || titleLower.contains('te amo') ||
                     artistLower.contains('enrique')  || artistLower.contains('shakira') ||
                     artistLower.contains('bad bunny');

    final List<String> template;
    if (isIndian) {
      template = [
        '(మ్యూజిక్ ఇంట్రో / म्यूज़िक इंट्रो)',
        'हाँ, हम सुन रहे हैं $title - $artist',
        'धड़कनें बढ़ने लगी हैं दिल की...',
        'இந்த இசை நம்மை மெய்சிலிர்க்க வைக்கிறது...',
        'ఈ మధురమైన గీతం మనస్సును తాకుతోంది...',
        'এই সুরের সাগরে হারিয়ে যাও...',
        'ਮਨ ਨੂੰ ਸ਼ਾਂਤੀ ਦੇਣ ਵਾਲਾ ਸੰਗੀਤ...',
        'कोरस: संगीत की तरंगों में डूब जाएँ',
        'ये संगीत की वो लहर है जो हम जानते हैं',
        'कोई सीमा नहीं, कोई बंदिश नहीं, बस आवाज़',
        'सुरों को अपने आस-पास बिखरने दो',
        '(मधुर आलाप / மெல்லிசை ஆலாபனை)',
        'அன்பே, இந்த இனிமையான தருணத்தை அனுபவி...',
        'ಮನಸ್ಸಿನ ಭಾವನೆಗಳನ್ನು ಹಂಚಿಕೊಳ್ಳುವ ಸಮಯ...',
        'कदमों को ताल से ताल मिलाने दो',
        'हर एक सुर के साथ ज़िंदगी को जीने दो',
        'कोरस: संगीत की तरंगों में डूब जाएँ',
        'ये संगीत की वो लहर है जो हम जानते हैं',
        'कोई सीमा नहीं, कोई बंदिश नहीं, बस आवाज़',
        'सुरों को अपने आस-पास बिखरने दो',
        '(आउट्रो / అవుట్రో)',
        'सोनिक वेव पर $title सुनने के लिए धन्यवाद!',
      ];
    } else if (isJapanese) {
      template = [
        '(イントロ インストゥルメンタル)',
        'そう、私たちが聴いているのは $title - $artist',
        'ビートが高鳴り、心拍数が上がる...',
        'このメロディに身を任せて、すべてを忘れよう',
        '夜空に瞬く星たちの光を浴びて',
        'サビ: 波を捕まえて、流れに乗ろう',
        'これが私たちの知っているソニックウェーブ',
        '限界なんてない、ルールもない、ただこの音だけ',
        'ハーモニーが私たちを包み込む',
        '(ブリッジ ボーカル)',
        '暗闇の中で踊る light lines を見つめて',
        'イコライザーが火花を散らす',
        'リズムに合わせてステップを踏もう',
        'すべてのベースドロップで、私たちは生き返る',
        'サビ: 波を捕まえて、流れに乗ろう',
        'これが私たちの知っているソニックウェーブ',
        '限界なんてない、ルールもない、ただこの音だけ',
        'ハーモニーが私たちを包み込む',
        '(アウトロ インストゥルメンタル)',
        'SonicWaveで $title を聴いてくれてありがとう！',
      ];
    } else if (isSpanish) {
      template = [
        '(Instrumental de Introducción)',
        'Sí, escuchando $title por $artist',
        'Siente cómo sube el ritmo...',
        'En esta melodía perdemos el control',
        'Las luces de neón brillan sobre nosotros',
        'Coro: Captura las olas, déjalas fluir',
        'Esta es la onda sónica que conocemos',
        'Sin fronteras, sin límites, solo el sonido',
        'Dejando que la armonía nos rodee',
        '(Puente Vocal)',
        'Mirando las frecuencias bailar en la oscuridad',
        'Un ecualizador brillante enciende la chispa',
        'Damos un paso al ritmo, sintiéndonos vivos',
        'Con cada golpe de bajo, sobrevivimos',
        'Coro: Captura las olas, déjalas fluir',
        'Esta es la onda sónica que conocemos',
        'Sin fronteras, sin límites, solo el sonido',
        'Dejando que la armonía nos rodee',
        '(Instrumental de Salida)',
        '¡Amor, gracias por escuchar $title en SonicWave!',
      ];
    } else {
      template = [
        '(Intro Instrumental)',
        'Yeah, listening to $title by $artist',
        'Feel the beat rising up...',
        'In this melody, we lose control',
        'The neon lights shine down on us',
        'Chorus: Capture the waves, let it flow',
        'This is the sonic wave we know',
        'No boundaries, no limits, just the sound',
        'Letting the harmony surround',
        '(Vocal Bridge)',
        'Watching the frequencies dance in the dark',
        'A glowing visualizer ignites the spark',
        'We step to the rhythm, feeling alive',
        'With every bass drop, we survive',
        'Chorus: Capture the waves, let it flow',
        'This is the sonic wave we know',
        'No boundaries, no limits, just the sound',
        'Letting the harmony surround',
        '(Outro Instrumental)',
        'Thanks for listening to $title on SonicWave!',
      ];
    }

    final int intervals = totalSeconds ~/ (template.length + 1);
    for (int i = 0; i < template.length; i++) {
      final time = Duration(seconds: (i + 1) * intervals);
      entries.add(LyricEntry(time, template[i]));
    }

    return entries;
  }
}
