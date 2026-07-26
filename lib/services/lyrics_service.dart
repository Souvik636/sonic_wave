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
    final title = song.title.toLowerCase();

    // Check popular tracks offline first for speed
    if (title.contains('starboy') || title.contains('weekend')) {
      return parseLrc(_starboyLrc);
    } else if (title.contains('blinding') || title.contains('lights')) {
      return parseLrc(_blindingLightsLrc);
    } else if (title.contains('perfect') || title.contains('sheeran')) {
      return parseLrc(_perfectLrc);
    } else if (title.contains('lo-fi') || title.contains('chill') || title.contains('relax')) {
      return parseLrc(_lofiLrc);
    }

    // Try online database (LrcLib has excellent Indian/Global time-synced and plain lyrics support)
    try {
      final client = HttpClient();
      client.connectionTimeout = const Duration(seconds: 4);
      
      final queryParams = {
        'track_name': song.title,
        'artist_name': song.artist,
      };
      if (song.duration.inSeconds > 0) {
        queryParams['duration'] = song.duration.inSeconds.toString();
      }
      
      final uri = Uri.https('lrclib.net', '/api/get', queryParams);
      final request = await client.getUrl(uri);
      final response = await request.close();
      
      if (response.statusCode == HttpStatus.ok) {
        final responseBody = await response.transform(utf8.decoder).join();
        final data = json.decode(responseBody) as Map<String, dynamic>;
        
        final syncedLyrics = data['syncedLyrics'] as String?;
        if (syncedLyrics != null && syncedLyrics.isNotEmpty) {
          client.close();
          return parseLrc(syncedLyrics);
        }
        
        final plainLyrics = data['plainLyrics'] as String?;
        if (plainLyrics != null && plainLyrics.isNotEmpty) {
          client.close();
          return _generatePlainLrc(plainLyrics, song);
        }
      }
      client.close();
    } catch (e) {
      debugPrint('Online lyrics fetch failed (falling back to dynamic generation): $e');
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

  // LRC Templates for popular songs
  static const String _starboyLrc = '''
[00:02.00] Starboy - The Weeknd
[00:08.50] I'm tryin' to put you in the worst mood, ah
[00:12.80] P1 cleaner than your church shoes, ah
[00:16.90] Milli point two just to hurt you, ah
[00:21.00] House so empty, need a centerpiece
[00:25.20] Twenty racks a table cut from ebony
[00:29.50] Cut that red line, let it out, let it breathe
[00:33.20] Main bitch out your league too, ah
[00:37.50] Side bitch out of your league too, ah
[00:41.80] House so empty, need a centerpiece
[00:46.00] House so empty, need a centerpiece
[00:50.00] Look what you've done
[00:54.20] I'm a motherfuckin' starboy
[00:58.50] Look what you've done
[01:02.70] I'm a motherfuckin' starboy
[01:07.00] Every day a nigga try to test me, ah
[01:11.20] Every day a nigga try to end me, ah
[01:15.50] Pull off in that Roadster SV, ah
[01:19.80] House so empty, need a centerpiece
[01:23.00] Look what you've done
[01:27.20] I'm a motherfuckin' starboy
[01:31.50] Look what you've done
[01:35.80] I'm a motherfuckin' starboy
''';

  static const String _blindingLightsLrc = '''
[00:01.00] 🎶 Blinding Lights - The Weeknd
[00:06.50] Yeah...
[00:09.80] I've been tryna call
[00:13.20] I've been on my own for long enough
[00:17.00] Maybe you can show me how to love, maybe
[00:24.20] I'm going through withdrawals
[00:27.80] You don't even have to do too much
[00:31.50] You can turn me on with just a touch, baby
[00:38.20] I look around and Sin City's cold and empty
[00:44.80] No one's around to judge me
[00:48.20] I can't see clearly when you're gone
[00:52.00] I said, ooh, I'm blinded by the lights
[00:59.20] No, I can't sleep until I feel your touch
[01:06.00] I said, ooh, I'm drowning in the night
[01:12.80] Oh, when I'm like this, you're the one I trust
[01:18.00] Hey, hey, hey!
''';

  static const String _perfectLrc = '''
[00:02.00] Perfect - Ed Sheeran
[00:10.20] I found a love for me
[00:17.00] Darling, just dive right in and follow my lead
[00:25.50] Well, I found a girl, beautiful and sweet
[00:33.20] Oh, I never knew you were the someone waiting for me
[00:40.80] 'Cause we were just kids when we fell in love
[00:46.50] Not knowing what it was
[00:50.00] I will not give you up this time
[00:57.20] But darling, just kiss me slow
[01:01.80] Your heart is all I own
[01:05.20] And in your eyes, you're holding mine
[01:10.50] Baby, I'm dancing in the dark
[01:16.80] With you between my arms
[01:21.00] Barefoot on the grass
[01:24.80] Listening to our favourite song
[01:29.00] When you said you looked a mess
[01:32.20] I whispered underneath my breath
[01:35.80] But you heard it
[01:38.20] Darling, you look perfect tonight
''';

  static const String _lofiLrc = '''
[00:01.00] Relaxing Lo-Fi beats...
[00:10.00] In the quiet of the night, we watch the stars align
[00:25.00] Slow loops, gentle chords, passing through time
[00:40.00] Rest your mind, let the waves wash the stress away
[00:55.00] Tomorrow is a new chapter, let go of today
[01:10.00] Chill beats pulsing softly in your ears
[01:25.00] Fading out the noise, melting down the fears
[01:40.00] (Subtle Instrumental Scratch)
[02:00.00] Ambient lights glow, steady and low
[02:20.00] That's the visual flow...
[02:40.00] Thanks for chilling with SonicWave.
''';
}
