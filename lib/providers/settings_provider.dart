import 'dart:convert';
import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../services/storage_location_service.dart';
import '../services/stream_cache_service.dart';

enum AudioQuality {
  high,
  medium,
  low,
}

enum ThemeAccent {
  purple,
  cyan,
  pink,
  orange,
  emerald,
  amber,
  sapphire,
  sakura,
  lava,
  cyberpunk,
  midnight,
  mint,

  /// Material You — follows the device wallpaper's dynamic color (Android 12+).
  /// Falls back to purple when the platform provides no dynamic palette.
  system,
}

enum SoundEnhancer {
  none,
  bassBoost,
  trebleBoost,
  vocal,
  ambient3d,
}

class SettingsProvider extends ChangeNotifier {
  static const String _qualityKey = 'settings_audio_quality';
  static const String _accentKey = 'settings_theme_accent';
  static const String _fadeKey = 'settings_visualizer_speed';
  static const String _bgPlaybackKey = 'settings_bg_playback';
  static const String _enhancerKey = 'settings_sound_enhancer';
  static const String _ambientKey = 'settings_ambient_mode';
  static const String _volumeKey = 'settings_volume';
  static const String _useCustomEqKey = 'settings_use_custom_eq';
  static const String _customEqGainsKey = 'settings_custom_eq_gains';
  static const String _offlineModeKey = 'settings_offline_mode';
  static const String _visualizerThemeKey = 'settings_visualizer_theme';
  static const String _showVisualizerKey = 'settings_show_visualizer';
  static const String _playerStyleKey = 'settings_player_style';
  static const String _crossfadeKey = 'settings_crossfade_seconds';
  static const String _randomizeThemeKey = 'settings_randomize_theme';

  AudioQuality _audioQuality = AudioQuality.high;
  ThemeAccent _themeAccent = ThemeAccent.purple;
  bool _randomizeThemeOnLaunch = false;
  SoundEnhancer _soundEnhancer = SoundEnhancer.none;
  double _visualizerSpeed = 1.0;
  bool _enableBackgroundPlayback = true;
  bool _enableAmbientMode = true;
  double _volume = 0.8; // Default volume: 80%
  bool _useCustomEqualizer = false;
  List<double> _customEqualizerGains = [0.0, 0.0, 0.0, 0.0, 0.0];
  bool _offlineModeOnly = false;
  bool _noInternetDetected = false;
  Timer? _connectionTimer;
  String _visualizerTheme = 'circle';
  bool _showVisualizer = true;
  String _playerStyle = 'classic'; // 'classic' or 'aurora'
  int _crossfadeSeconds = 0; // 0 = off; global fade-in/out between tracks

  /// Device wallpaper seed color (Material You), injected at app start from
  /// DynamicColorPlugin. Null on Android < 12 / unsupported platforms.
  static Color? systemDynamicColor;
  bool _isInitialized = false;
  StorageType _storageType = StorageType.appInternal;
  final StorageLocationService _storageService = StorageLocationService();

  SettingsProvider() {
    _loadSettings();
    _startConnectionTracker();
  }

  // Getters
  AudioQuality get audioQuality => _audioQuality;
  ThemeAccent get themeAccent => _themeAccent;
  bool get randomizeThemeOnLaunch => _randomizeThemeOnLaunch;
  SoundEnhancer get soundEnhancer => _soundEnhancer;
  double get visualizerSpeed => _visualizerSpeed;
  bool get enableBackgroundPlayback => _enableBackgroundPlayback;
  bool get enableAmbientMode => _enableAmbientMode;
  double get volume => _volume;
  bool get useCustomEqualizer => _useCustomEqualizer;
  List<double> get customEqualizerGains => _customEqualizerGains;
  bool get offlineModeOnly => _offlineModeOnly || _noInternetDetected;
  bool get noInternetDetected => _noInternetDetected;
  String get visualizerTheme => _visualizerTheme;
  bool get showVisualizer => _showVisualizer;
  String get playerStyle => _playerStyle;
  int get crossfadeSeconds => _crossfadeSeconds;
  bool get isInitialized => _isInitialized;
  StorageType get storageType => _storageType;
  StorageLocationService get storageService => _storageService;
  int get streamCacheMaxMB => StreamCacheService().maxMB;

  Color get accentColor {
    return accentColorOf(_themeAccent);
  }

  /// Canonical color for any accent — the settings picker swatches read this
  /// so they always match what the theme actually applies.
  static Color accentColorOf(ThemeAccent accent) {
    switch (accent) {
      case ThemeAccent.purple:
        return const Color(0xFF7C5CFF); // Nebula — electric violet
      case ThemeAccent.cyan:
        return const Color(0xFF00E5C3); // Aurora — glowing teal
      case ThemeAccent.pink:
        return const Color(0xFFFF5C8A); // Blush — vivid rose
      case ThemeAccent.orange:
        return const Color(0xFFFF8A50); // Sunset — warm coral
      case ThemeAccent.emerald:
        return const Color(0xFF00E676); // Emerald — neon green
      case ThemeAccent.amber:
        return const Color(0xFFFFC400); // Gold — rich amber
      case ThemeAccent.sapphire:
        return const Color(0xFF448AFF); // Ocean — deep azure
      case ThemeAccent.sakura:
        return const Color(0xFFFF80AB); // Sakura — soft blossom
      case ThemeAccent.lava:
        return const Color(0xFFFF4B2B); // Inferno — molten red-orange
      case ThemeAccent.cyberpunk:
        return const Color(0xFFD500F9); // Cyberpunk — electric magenta/violet
      case ThemeAccent.midnight:
        return const Color(0xFF651FFF); // Midnight — deep twilight indigo
      case ThemeAccent.mint:
        return const Color(0xFF00BFA5); // Arctic Mint — glowing teal seafoam
      case ThemeAccent.system:
        // Material You wallpaper color; purple fallback pre-Android 12.
        return systemDynamicColor ?? const Color(0xFF7C5CFF);
    }
  }

  LinearGradient get accentGradient {
    final startColor = accentColor;
    Color endColor;
    switch (_themeAccent) {
      case ThemeAccent.purple:
        endColor = const Color(0xFFB388FF); // violet → lavender glow
        break;
      case ThemeAccent.cyan:
        endColor = const Color(0xFF00B0FF); // teal → electric blue
        break;
      case ThemeAccent.pink:
        endColor = const Color(0xFFFF9E80); // rose → peach
        break;
      case ThemeAccent.orange:
        endColor = const Color(0xFFFFC400); // coral → gold
        break;
      case ThemeAccent.emerald:
        endColor = const Color(0xFF69F0AE); // green → mint
        break;
      case ThemeAccent.amber:
        endColor = const Color(0xFFFF8A50); // amber → coral
        break;
      case ThemeAccent.sapphire:
        endColor = const Color(0xFF18FFFF); // azure → cyan spark
        break;
      case ThemeAccent.sakura:
        endColor = const Color(0xFFEA80FC); // blossom → orchid
        break;
      case ThemeAccent.lava:
        endColor = const Color(0xFFFFAB40); // molten → ember
        break;
      case ThemeAccent.cyberpunk:
        endColor = const Color(0xFF00E5FF); // magenta → neon cyan
        break;
      case ThemeAccent.midnight:
        endColor = const Color(0xFF7C4DFF); // indigo → vivid iris
        break;
      case ThemeAccent.mint:
        endColor = const Color(0xFF64FFDA); // teal → glacial mint
        break;
      case ThemeAccent.system:
        // Blend toward a lighter tint of the wallpaper-derived accent.
        endColor = (systemDynamicColor ?? const Color(0xFF6C63FF))
            .withValues(alpha: 0.7);
        break;
    }
    return LinearGradient(
      colors: [startColor, endColor],
      begin: Alignment.topLeft,
      end: Alignment.bottomRight,
    );
  }

  // ── Derived accent palette ──────────────────────────────────────────────
  // Everything below is computed from [accentColor] so ALL 9 accents get a
  // full palette (light/dark shades, glows, tinted backgrounds) without
  // hand-maintaining per-accent tables. Screens should use these instead of
  // the static purple AppColors.primary* constants.

  /// Lighter shade of the accent (replaces AppColors.primaryLight).
  Color get accentColorLight =>
      Color.lerp(accentColor, Colors.white, 0.35)!;

  /// Darker shade of the accent (replaces AppColors.primaryDark).
  Color get accentColorDark =>
      Color.lerp(accentColor, Colors.black, 0.30)!;

  /// Radial glow behind hero elements (replaces AppColors.glowGradient).
  RadialGradient get glowGradient => RadialGradient(
        colors: [
          accentColor.withValues(alpha: 0.20),
          accentColor.withValues(alpha: 0.067),
          const Color(0x00060612),
        ],
        radius: 0.8,
      );

  /// Player screen top wash (replaces AppColors.playerGradient) — the accent
  /// lerped deep into the dark base so every theme gets its own mood.
  LinearGradient get playerGradient => LinearGradient(
        colors: [
          Color.lerp(const Color(0xFF0D0D1A), accentColor, 0.16)!,
          const Color(0xFF0D0D1A),
        ],
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
      );

  /// App-wide background (replaces AppColors.backgroundGradient) — the dark
  /// navy base subtly tinted toward the accent hue so the whole app shifts
  /// mood with the selected theme.
  LinearGradient get tintedBackgroundGradient => LinearGradient(
        colors: [
          Color.lerp(const Color(0xFF060612), accentColor, 0.045)!,
          Color.lerp(const Color(0xFF0A0A20), accentColor, 0.075)!,
          Color.lerp(const Color(0xFF0D0D1A), accentColor, 0.05)!,
        ],
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
      );

  /// Download/progress fill (replaces AppColors.downloadGradient).
  LinearGradient get downloadGradient => LinearGradient(
        colors: [accentColor, const Color(0xFF00C9A7)],
        begin: Alignment.centerLeft,
        end: Alignment.centerRight,
      );

  Future<void> _loadSettings() async {
    try {
      final prefs = await SharedPreferences.getInstance();

      // Load audio quality — guard the index: a downgrade can produce an
      // out-of-range value and a bare list[] throws RangeError, which the outer
      // catch would swallow, leaving the app permanently uninitialized.
      final qualityIdx = prefs.getInt(_qualityKey);
      if (qualityIdx != null &&
          qualityIdx >= 0 &&
          qualityIdx < AudioQuality.values.length) {
        _audioQuality = AudioQuality.values[qualityIdx];
      }

      // Load theme accent
      final accentIdx = prefs.getInt(_accentKey);
      if (accentIdx != null &&
          accentIdx >= 0 &&
          accentIdx < ThemeAccent.values.length) {
        _themeAccent = ThemeAccent.values[accentIdx];
      }

      // Load randomize theme on launch
      _randomizeThemeOnLaunch = prefs.getBool(_randomizeThemeKey) ?? false;
      if (_randomizeThemeOnLaunch) {
        final options = [
          ThemeAccent.purple,
          ThemeAccent.cyan,
          ThemeAccent.pink,
          ThemeAccent.orange,
          ThemeAccent.emerald,
          ThemeAccent.amber,
          ThemeAccent.sapphire,
          ThemeAccent.sakura,
          ThemeAccent.lava,
          ThemeAccent.cyberpunk,
          ThemeAccent.midnight,
          ThemeAccent.mint,
        ];
        _themeAccent = options[Random().nextInt(options.length)];
      }

      // Load sound enhancer
      final enhancerIdx = prefs.getInt(_enhancerKey);
      if (enhancerIdx != null &&
          enhancerIdx >= 0 &&
          enhancerIdx < SoundEnhancer.values.length) {
        _soundEnhancer = SoundEnhancer.values[enhancerIdx];
      }

      // Load visualizer speed
      _visualizerSpeed = prefs.getDouble(_fadeKey) ?? 1.0;

      // Load background playback toggle
      _enableBackgroundPlayback = prefs.getBool(_bgPlaybackKey) ?? true;

      // Load ambient mode toggle
      _enableAmbientMode = prefs.getBool(_ambientKey) ?? true;

      // Load volume level
      _volume = prefs.getDouble(_volumeKey) ?? 0.8;

      // Load custom EQ settings
      _useCustomEqualizer = prefs.getBool(_useCustomEqKey) ?? false;
      final eqStr = prefs.getString(_customEqGainsKey);
      if (eqStr != null) {
        try {
          final decoded = json.decode(eqStr) as List<dynamic>;
          _customEqualizerGains = decoded.map((val) => (val as num).toDouble()).toList();
        } catch (_) {
          _customEqualizerGains = [0.0, 0.0, 0.0, 0.0, 0.0];
        }
      } else {
        _customEqualizerGains = [0.0, 0.0, 0.0, 0.0, 0.0];
      }

      // Load offline mode
      _offlineModeOnly = prefs.getBool(_offlineModeKey) ?? false;

      // Load visualizer theme (circular wave is the default)
      _visualizerTheme = prefs.getString(_visualizerThemeKey) ?? 'circle';

      // Load show visualizer setting
      _showVisualizer = prefs.getBool(_showVisualizerKey) ?? true;

      // Load player style preference
      _playerStyle = prefs.getString(_playerStyleKey) ?? 'classic';

      _crossfadeSeconds = prefs.getInt(_crossfadeKey) ?? 0;

      // Initialize storage location service
      await _storageService.initialize();
      _storageType = _storageService.storageType;

      // Initialize stream cache service (loads persisted size limit)
      await StreamCacheService().initialize();
    } catch (e) {
      debugPrint('Error loading settings: $e');
    } finally {
      // Always mark initialized and notify — even on partial load. Consumers
      // gated on isInitialized would hang permanently if a RangeError or any
      // other exception prevented these two lines from running.
      _isInitialized = true;
      notifyListeners();
    }
  }

  Future<void> setAudioQuality(AudioQuality quality) async {
    _audioQuality = quality;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_qualityKey, quality.index);
  }

  Future<void> setThemeAccent(ThemeAccent accent) async {
    _themeAccent = accent;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_accentKey, accent.index);
  }

  Future<void> setRandomizeThemeOnLaunch(bool enabled) async {
    _randomizeThemeOnLaunch = enabled;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_randomizeThemeKey, enabled);
  }

  /// Material You maps to the wallpaper-derived [ThemeAccent.system].
  bool get useMaterialYou => _themeAccent == ThemeAccent.system;

  // Remembers the manual accent so turning Material You off restores it.
  ThemeAccent _previousAccent = ThemeAccent.purple;

  Future<void> setUseMaterialYou(bool value) async {
    if (value) {
      if (_themeAccent != ThemeAccent.system) _previousAccent = _themeAccent;
      await setThemeAccent(ThemeAccent.system);
    } else {
      final restore =
          _previousAccent == ThemeAccent.system ? ThemeAccent.purple : _previousAccent;
      await setThemeAccent(restore);
    }
  }

  Future<void> setSoundEnhancer(SoundEnhancer enhancer) async {
    _soundEnhancer = enhancer;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_enhancerKey, enhancer.index);
  }

  Future<void> setVisualizerSpeed(double speed) async {
    _visualizerSpeed = speed;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setDouble(_fadeKey, speed);
  }

  Future<void> setBackgroundPlayback(bool enabled) async {
    _enableBackgroundPlayback = enabled;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_bgPlaybackKey, enabled);
  }

  Future<void> setAmbientMode(bool enabled) async {
    _enableAmbientMode = enabled;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_ambientKey, enabled);
  }

  Future<void> setVolume(double val) async {
    _volume = val;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setDouble(_volumeKey, val);
  }

  Future<void> setUseCustomEqualizer(bool val) async {
    _useCustomEqualizer = val;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_useCustomEqKey, val);
  }

  Future<void> setCustomEqualizerGains(List<double> gains) async {
    _customEqualizerGains = List.from(gains);
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_customEqGainsKey, json.encode(gains));
  }

  Future<void> setOfflineModeOnly(bool val) async {
    _offlineModeOnly = val;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_offlineModeKey, val);
  }

  Future<void> setVisualizerTheme(String theme) async {
    _visualizerTheme = theme;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_visualizerThemeKey, theme);
  }

  Future<void> setShowVisualizer(bool val) async {
    _showVisualizer = val;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_showVisualizerKey, val);
  }

  Future<void> setPlayerStyle(String style) async {
    _playerStyle = style;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_playerStyleKey, style);
  }

  /// Global crossfade window (seconds) applied between tracks when a song has
  /// no per-song fade of its own. 0 disables.
  Future<void> setCrossfadeSeconds(int seconds) async {
    _crossfadeSeconds = seconds.clamp(0, 12);
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_crossfadeKey, _crossfadeSeconds);
  }


  /// Set the storage location type and update the storage service.
  Future<void> setStorageType(StorageType type, {String? sdCardPath}) async {
    _storageType = type;
    await _storageService.setStorageType(type, sdCardPath: sdCardPath);
    notifyListeners();
  }

  /// Get resolved storage path for display
  Future<String> getStoragePathDisplay() async {
    return _storageService.getResolvedPathDisplay();
  }

  /// Get available storage volumes for the picker UI
  Future<List<StorageVolume>> getAvailableStorageVolumes() async {
    return _storageService.getAvailableStorageVolumes();
  }

  /// Set the stream cache size limit (in MB) and persist it.
  Future<void> setStreamCacheMaxMB(int mb) async {
    await StreamCacheService().setMaxMB(mb);
    notifyListeners();
  }

  void _startConnectionTracker() {
    _connectionTimer?.cancel();
    _connectionTimer = Timer.periodic(const Duration(seconds: 8), (_) {
      _checkConnection();
    });
  }

  Future<void> _checkConnection() async {
    try {
      final result = await InternetAddress.lookup('google.com').timeout(const Duration(seconds: 3));
      final isOffline = result.isEmpty || result.first.rawAddress.isEmpty;
      if (_noInternetDetected != isOffline) {
        _noInternetDetected = isOffline;
        notifyListeners();
      }
    } catch (_) {
      if (!_noInternetDetected) {
        _noInternetDetected = true;
        notifyListeners();
      }
    }
  }

  @override
  void dispose() {
    _connectionTimer?.cancel();
    super.dispose();
  }
}
