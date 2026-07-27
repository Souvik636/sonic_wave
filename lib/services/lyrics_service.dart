import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
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

  /// Parse LRC format string into a list of LyricEntry
  List<LyricEntry> parseLrc(String lrcText) {
    final List<LyricEntry> entries = [];
    final RegExp timeRegExp = RegExp(r'\[(\d+):(\d+)\.(\d+)\]');
    final lines = lrcText.split('\n');

    for (final line in lines) {
      final match = timeRegExp.firstMatch(line);
      if (match != null) {
        final minutes = int.parse(match.group(1)!);
        final seconds = int.parse(match.group(2)!);
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

  /// Get time-synced lyrics for a song (Real via LrcLib API or fallback generated)
  Future<List<LyricEntry>> getLyricsForSong(Song song) async {
    // Always try the online database first — LrcLib has excellent coverage for
    // Indian, K-pop, and global tracks with time-synced lyrics.
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 8);
    try {
      final queryParams = {
        'track_name': song.title,
        'artist_name': song.artist,
      };
      if (song.duration.inSeconds > 0) {
        queryParams['duration'] = song.duration.inSeconds.toString();
      }

      final uri = Uri.https('lrclib.net', '/api/get', queryParams);
      final request = await client.getUrl(uri);
      final response = await request.close()
          .timeout(const Duration(seconds: 10));

      if (response.statusCode == HttpStatus.ok) {
        final responseBody = await response.transform(utf8.decoder).join();
        final data = json.decode(responseBody) as Map<String, dynamic>;

        final syncedLyrics = data['syncedLyrics'] as String?;
        if (syncedLyrics != null && syncedLyrics.isNotEmpty) {
          return parseLrc(syncedLyrics);
        }

        final plainLyrics = data['plainLyrics'] as String?;
        if (plainLyrics != null && plainLyrics.isNotEmpty) {
          return _generatePlainLrc(plainLyrics, song);
        }
      } else {
        // Drain response to release the connection.
        await response.drain<void>();
      }
    } catch (e) {
      debugPrint('Online lyrics fetch failed (falling back to dynamic generation): $e');
    } finally {
      client.close();
    }

    // Dynamic generation of synchronized lyrics for other songs based on duration
    return _generateDynamicLrc(song);
  }

  List<LyricEntry> _generatePlainLrc(String plainLyrics, Song song) {
    final List<LyricEntry> entries = [];
    final lines = plainLyrics.split('\n').where((l) => l.trim().isNotEmpty).toList();
    if (lines.isEmpty) return _generateDynamicLrc(song);

    final totalDuration = song.duration;
    final totalSeconds = totalDuration.inSeconds > 0 ? totalDuration.inSeconds : 180;
    
    final startOffset = 5;
    final activeDuration = (totalSeconds * 0.8) - startOffset;
    final interval = lines.length > 1 ? activeDuration / (lines.length - 1) : 10.0;
    
    entries.add(LyricEntry(Duration.zero, '(Intro)'));

    for (int i = 0; i < lines.length; i++) {
      final seconds = startOffset + (i * interval);
      entries.add(LyricEntry(Duration(seconds: seconds.toInt()), lines[i].trim()));
    }
    
    entries.add(LyricEntry(Duration(seconds: (totalSeconds - 4).clamp(startOffset, totalSeconds).toInt()), '(Outro)'));
    return entries;
  }

  bool _hasIndianCharacters(String text) {
    // Unicode block coverage: Devanagari, Bengali, Gurmukhi, Gujarati, Oriya, Tamil, Telugu, Kannada, Malayalam
    final indianRegex = RegExp(r'[\u0900-\u0DFF]');
    return indianRegex.hasMatch(text);
  }

  bool _hasJapaneseCharacters(String text) {
    final japaneseRegex = RegExp(r'[\u3040-\u309F\u30A0-\u30FF\u4E00-\u9FBF]');
    return japaneseRegex.hasMatch(text);
  }

  List<LyricEntry> _generateDynamicLrc(Song song) {
    final List<LyricEntry> entries = [];
    final totalDuration = song.duration;
    final totalSeconds = totalDuration.inSeconds > 0 ? totalDuration.inSeconds : 180;
    
    final title = song.title;
    final artist = song.artist;
    final titleLower = title.toLowerCase();
    final artistLower = artist.toLowerCase();

    bool isIndian = _hasIndianCharacters(title) || 
                    _hasIndianCharacters(artist) ||
                    titleLower.contains('tum') ||
                    titleLower.contains('dil') ||
                    titleLower.contains('ki') ||
                    titleLower.contains('se') ||
                    titleLower.contains('mere') ||
                    titleLower.contains('tera') ||
                    titleLower.contains('meri') ||
                    titleLower.contains('ishq') ||
                    titleLower.contains('singh') ||
                    titleLower.contains('kumar') ||
                    titleLower.contains('naan') ||
                    titleLower.contains('nee') ||
                    titleLower.contains('prema') ||
                    titleLower.contains('kaadhal') ||
                    titleLower.contains('sangeetham') ||
                    titleLower.contains('bollywood') ||
                    titleLower.contains('arijit') ||
                    titleLower.contains('neha') ||
                    titleLower.contains('rahman') ||
                    titleLower.contains('anirudh') ||
                    artistLower.contains('arijit') ||
                    artistLower.contains('lata') ||
                    artistLower.contains('nehra') ||
                    artistLower.contains('kishore') ||
                    artistLower.contains('rahman') ||
                    artistLower.contains('anirudh') ||
                    artistLower.contains('spb') ||
                    artistLower.contains('susheela');

    bool isJapanese = _hasJapaneseCharacters(title) ||
                      _hasJapaneseCharacters(artist) ||
                      titleLower.contains('ost') ||
                      titleLower.contains('theme') ||
                      titleLower.contains('yoasobi') ||
                      titleLower.contains('anime') ||
                      artistLower.contains('yoasobi') ||
                      artistLower.contains('lisa') ||
                      artistLower.contains('radwimps');

    bool isSpanish = titleLower.contains('despacito') ||
                     titleLower.contains('amor') ||
                     titleLower.contains('canto') ||
                     titleLower.contains('cancion') ||
                     titleLower.contains('bonita') ||
                     titleLower.contains('te amo') ||
                     titleLower.contains('sol') ||
                     titleLower.contains('vida') ||
                     artistLower.contains('enrique') ||
                     artistLower.contains('shakira') ||
                     artistLower.contains('bad bunny');

    final List<String> template;
    if (isIndian) {
      template = [
        '(మ్యూజిక్ ఇంట్రో / म्यूज़िक इंट्रो)',
        'हाँ, हम सुन रहे हैं $title - $artist',
        'धड़कनें बढ़ने लगी हैं दिल की...',
        'இந்த இசை நம்மை மெய்சிலிர்க்க வைக்கிறது...',
        'ఈ మధురమైన గీతం మనస్సును తాకుతోంది...',
        'এই সুরের সাগরে হারিয়ে যাও...',
        'ਮਨ ਨੂੰ ਸ਼ਾਂਤੀ ਦੇਣ ਵਾਲਾ ਸੰਗੀਤ...',
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
        'सोनिक वेव पर $title सुनने के लिए धन्यवाद!'
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
        'SonicWaveで $title を聴いてくれてありがとう！'
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
        '¡Amor, gracias por escuchar $title en SonicWave!'
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
        'Thanks for listening to $title on SonicWave!'
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
