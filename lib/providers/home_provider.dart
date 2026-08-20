import 'dart:convert';
import 'dart:io';
import 'dart:async';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/song.dart';
import '../services/youtube_service.dart';

/// Provider for dynamic daily Home Screen music discovery with protected local caching.
///
/// Features:
/// - Daily auto-updating trending songs from live YouTube Music & JioSaavn top charts
/// - Live dynamic genre & category discovery (Pop, Hip Hop, Lo-Fi, Bollywood, EDM, Rock, R&B, Jazz)
/// - 1st-time-of-the-day network optimization: caches today's feed locally for instant (0ms) subsequent loads
/// - Automatic lifecycle-driven day rollover detection (auto-refreshes when date changes across midnight/app resume)
/// - Protected permanent storage (immune from being cleared by Settings -> Storage & Cache management)
/// - Seamless offline fallback if network is unavailable
class HomeProvider extends ChangeNotifier {
  final YouTubeService _youtubeService = YouTubeService();

  List<Song> _trendingSongs = [];
  final Map<String, List<Song>> _categorySongs = {};
  bool _isLoading = false;
  bool _isRefreshing = false;
  bool _isInitialized = false;
  String? _error;
  bool _isOffline = false;
  Timer? _connectionTimer;
  DateTime? _lastRefreshed;
  String? _currentLoadedDateKey;
  AppLifecycleListener? _lifecycleListener;

  static const String _prefsDateKey = 'sonic_permanent_daily_home_feed_date';
  static const String _prefsDataKey = 'sonic_permanent_daily_home_feed_data';

  // Genre categories
  static const List<String> categories = [
    'Pop Hits',
    'Hip Hop',
    'Lo-Fi Chill',
    'Bollywood',
    'EDM',
    'Rock',
    'R&B Soul',
    'Jazz',
  ];

  final Set<String> _loadingCategories = {};

  HomeProvider() {
    _initLifecycleListener();
  }

  // Getters
  List<Song> get trendingSongs => _trendingSongs;
  Map<String, List<Song>> get categorySongs => _categorySongs;
  bool get isLoading => _isLoading;
  bool get isRefreshing => _isRefreshing;
  bool get isInitialized => _isInitialized;
  String? get error => _error;
  bool get isOffline => _isOffline;
  DateTime? get lastRefreshed => _lastRefreshed;
  bool isCategoryLoading(String category) => _loadingCategories.contains(category);

  String _todayKey() {
    final now = DateTime.now();
    return '${now.year}-${now.month.toString().padLeft(2, '0')}-${now.day.toString().padLeft(2, '0')}';
  }

  void _initLifecycleListener() {
    _lifecycleListener = AppLifecycleListener(
      onResume: _onAppResumed,
    );
  }

  /// Automatically check if day changed when user returns to app
  void _onAppResumed() {
    final today = _todayKey();
    if (_isInitialized && _currentLoadedDateKey != null && _currentLoadedDateKey != today) {
      debugPrint('[HomeProvider] Day rollover detected ($today != $_currentLoadedDateKey). Auto-refreshing daily feed...');
      initialize(forceRefresh: true);
    }
  }

  /// Check connectivity status using direct DNS lookup
  Future<void> checkConnection() async {
    bool newOfflineState = false;
    try {
      final result = await InternetAddress.lookup('google.com')
          .timeout(const Duration(seconds: 5));
      newOfflineState = result.isEmpty || result.first.rawAddress.isEmpty;
    } on TimeoutException {
      // Fail OPEN on timeout — a slow DNS probe on weak mobile data is not a dead connection.
      newOfflineState = false;
    } catch (_) {
      newOfflineState = true;
    }
    if (_isOffline != newOfflineState) {
      _isOffline = newOfflineState;
      notifyListeners();
    }
  }

  /// Start background connection check every 10s
  void startConnectionTracker() {
    _connectionTimer?.cancel();
    _connectionTimer = Timer.periodic(const Duration(seconds: 10), (_) {
      checkConnection();
    });
  }

  /// Load today's feed from permanent protected cache if available
  Future<bool> _loadFromDailyCache() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final cachedDate = prefs.getString(_prefsDateKey);
      final today = _todayKey();
      if (cachedDate != today) return false;

      final cachedJson = prefs.getString(_prefsDataKey);
      if (cachedJson == null || cachedJson.isEmpty) return false;

      final Map<String, dynamic> data = jsonDecode(cachedJson);
      final List<dynamic> trendingList = data['trending'] ?? [];
      final Map<String, dynamic> categoriesMap = data['categories'] ?? {};

      if (trendingList.isEmpty) return false;

      _trendingSongs = trendingList
          .map((j) => Song.fromJson(j as Map<String, dynamic>))
          .toList();

      _categorySongs.clear();
      categoriesMap.forEach((k, v) {
        if (v is List) {
          _categorySongs[k] =
              v.map((j) => Song.fromJson(j as Map<String, dynamic>)).toList();
        }
      });

      _currentLoadedDateKey = today;
      _isInitialized = true;
      _lastRefreshed = DateTime.now();
      notifyListeners();
      return true;
    } catch (e) {
      debugPrint('[HomeProvider] Error reading daily feed cache: $e');
      return false;
    }
  }

  /// Save today's feed to permanent protected cache
  Future<void> _saveToDailyCache() async {
    try {
      if (_trendingSongs.isEmpty) return;
      final prefs = await SharedPreferences.getInstance();
      final Map<String, dynamic> data = {
        'trending': _trendingSongs.map((s) => s.toJson()).toList(),
        'categories': _categorySongs.map(
          (k, v) => MapEntry(k, v.map((s) => s.toJson()).toList()),
        ),
      };
      final today = _todayKey();
      await prefs.setString(_prefsDateKey, today);
      await prefs.setString(_prefsDataKey, jsonEncode(data));
      _currentLoadedDateKey = today;
      debugPrint('[HomeProvider] Saved daily home feed cache for $today');
    } catch (e) {
      debugPrint('[HomeProvider] Error saving daily feed cache: $e');
    }
  }

  /// Load a category dynamically on-demand
  Future<void> loadCategory(String category, {bool forceRefresh = false}) async {
    if (!forceRefresh &&
        _categorySongs.containsKey(category) &&
        _categorySongs[category]!.isNotEmpty) {
      return;
    }
    if (_loadingCategories.contains(category)) return;

    _loadingCategories.add(category);
    notifyListeners();

    try {
      final songs = await _youtubeService.getSongsByCategory(category, forceRefresh: forceRefresh);
      if (songs.isNotEmpty || !_categorySongs.containsKey(category)) {
        _categorySongs[category] = songs;
      }
    } catch (e) {
      debugPrint('Error loading category $category: $e');
    } finally {
      _loadingCategories.remove(category);
      notifyListeners();
    }
  }

  /// Initialize home data with daily caching optimization
  Future<void> initialize({bool forceRefresh = false}) async {
    if (_isInitialized && !forceRefresh) return;

    // 1. If not forcing refresh, attempt fast local daily cache load first
    if (!forceRefresh) {
      final cacheLoaded = await _loadFromDailyCache();
      if (cacheLoaded) {
        debugPrint('[HomeProvider] Loaded daily feed from permanent cache for ${_todayKey()}');
        return;
      }
    }

    _isLoading = !_isInitialized;
    _error = null;
    notifyListeners();

    await checkConnection();
    startConnectionTracker();

    try {
      // 2. Fetch fresh dynamic trending songs
      final trending = await _youtubeService.getTrendingMusic(forceRefresh: forceRefresh);
      if (trending.isNotEmpty) {
        _trendingSongs = trending;
      } else {
        _trendingSongs = List.from(YouTubeService.trendingNowFallback);
      }

      _currentLoadedDateKey = _todayKey();
      _isInitialized = true;
      _isLoading = false;
      _lastRefreshed = DateTime.now();
      notifyListeners();

      // 3. Concurrently load all categories
      await _loadRemainingCategories(forceRefresh: forceRefresh);

      // 4. Save to daily permanent cache
      await _saveToDailyCache();
    } catch (e) {
      if (_trendingSongs.isEmpty) {
        _trendingSongs = List.from(YouTubeService.trendingNowFallback);
      }
      _error = 'Failed to load music. Check your connection.';
      _isLoading = false;
      notifyListeners();
    }
  }

  Future<void> _loadRemainingCategories({bool forceRefresh = false}) async {
    await Future.wait(
      categories.map(
        (category) => loadCategory(category, forceRefresh: forceRefresh)
            .catchError((e) => debugPrint('Error loading $category: $e')),
      ),
    );
  }

  /// Refresh all data — bypasses cache so pull-to-refresh fetches new online songs
  Future<void> refresh() async {
    if (_isRefreshing) return;
    _isRefreshing = true;
    _loadingCategories.clear();
    notifyListeners();

    try {
      await initialize(forceRefresh: true);
    } finally {
      _isRefreshing = false;
      notifyListeners();
    }
  }

  @override
  void dispose() {
    _lifecycleListener?.dispose();
    _connectionTimer?.cancel();
    super.dispose();
  }
}
