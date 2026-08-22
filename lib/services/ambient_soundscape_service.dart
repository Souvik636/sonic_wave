import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:just_audio/just_audio.dart';

enum AmbientType {
  rain,
  ocean,
  cafe,
  campfire,
  binaural,
}

class AmbientSoundscape {
  final AmbientType type;
  final String title;
  final String description;
  final String icon;
  final String streamUrl;

  const AmbientSoundscape({
    required this.type,
    required this.title,
    required this.description,
    required this.icon,
    required this.streamUrl,
  });
}

/// Service managing background ambient soundscapes (Rain, Ocean, Cafe, Campfire, Binaural Beats)
/// that layer smoothly underneath active music playback or play independently.
class AmbientSoundscapeService {
  static final AmbientSoundscapeService _instance = AmbientSoundscapeService._internal();
  factory AmbientSoundscapeService() => _instance;
  AmbientSoundscapeService._internal();

  final AudioPlayer _ambientPlayer = AudioPlayer();

  final ValueNotifier<AmbientType?> activeTypeNotifier = ValueNotifier<AmbientType?>(null);
  final ValueNotifier<double> volumeNotifier = ValueNotifier<double>(0.45);
  final ValueNotifier<bool> isPlayingNotifier = ValueNotifier<bool>(false);

  final List<AmbientSoundscape> soundscapes = const [
    AmbientSoundscape(
      type: AmbientType.rain,
      title: 'Rain on Window',
      description: 'Gentle raindrops & distant soothing thunder',
      icon: '🌧️',
      // High reliability open CC0 ambient stream
      streamUrl: 'https://cdn.pixabay.com/download/audio/2022/05/16/audio_db6591201e.mp3?filename=soft-rain-ambient-111154.mp3',
    ),
    AmbientSoundscape(
      type: AmbientType.ocean,
      title: 'Pacific Ocean Waves',
      description: 'Rhythmic deep tide and shoreline foam',
      icon: '🌊',
      streamUrl: 'https://cdn.pixabay.com/download/audio/2022/03/15/audio_c8c8a73467.mp3?filename=ocean-waves-ambient-23912.mp3',
    ),
    AmbientSoundscape(
      type: AmbientType.cafe,
      title: 'Warm Coffee Shop',
      description: 'Background espresso cups & cozy murmur',
      icon: '☕',
      streamUrl: 'https://cdn.pixabay.com/download/audio/2021/08/04/audio_349942a690.mp3?filename=coffee-shop-ambience-6967.mp3',
    ),
    AmbientSoundscape(
      type: AmbientType.campfire,
      title: 'Pine Campfire Crackle',
      description: 'Warm glowing embers & wood pops',
      icon: '🔥',
      streamUrl: 'https://cdn.pixabay.com/download/audio/2022/01/18/audio_d0a13f69d2.mp3?filename=campfire-crackling-fireplace-10492.mp3',
    ),
    AmbientSoundscape(
      type: AmbientType.binaural,
      title: 'Binaural Alpha Waves',
      description: '10Hz pure harmonic tone for deep focus',
      icon: '🧠',
      streamUrl: 'https://cdn.pixabay.com/download/audio/2022/05/27/audio_1808fbf07a.mp3?filename=meditation-soundscape-alpha-112191.mp3',
    ),
  ];

  bool _initialized = false;

  void initialize() {
    if (_initialized) return;
    _initialized = true;
    _ambientPlayer.setLoopMode(LoopMode.one);
    _ambientPlayer.setVolume(volumeNotifier.value);
    _ambientPlayer.playerStateStream.listen((state) {
      isPlayingNotifier.value = state.playing;
    });
  }

  Future<void> selectAndPlay(AmbientType type) async {
    initialize();
    if (activeTypeNotifier.value == type && isPlayingNotifier.value) {
      await stop();
      return;
    }

    final scape = soundscapes.firstWhere((s) => s.type == type);
    activeTypeNotifier.value = type;

    try {
      await _ambientPlayer.setUrl(scape.streamUrl);
      await _ambientPlayer.play();
    } catch (e) {
      debugPrint('[AmbientSoundscape] Error playing $type: $e');
    }
  }

  Future<void> setVolume(double val) async {
    final clamped = val.clamp(0.0, 1.0);
    volumeNotifier.value = clamped;
    await _ambientPlayer.setVolume(clamped);
  }

  Future<void> stop() async {
    activeTypeNotifier.value = null;
    await _ambientPlayer.stop();
  }

  void dispose() {
    _ambientPlayer.dispose();
  }
}
