import 'dart:io';
import 'dart:async';
import 'package:flutter/foundation.dart';
import '../models/song.dart';
import '../services/youtube_service.dart';

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

  /// Check connectivity status using direct DNS lookup
  Future<void> checkConnection() async {
    try {
      final result = await InternetAddress.lookup('google.com').timeout(const Duration(seconds: 3));
      _isOffline = result.isEmpty || result.first.rawAddress.isEmpty;
    } catch (_) {
      _isOffline = true;
    }
    notifyListeners();
  }

  /// Start background connection check every 10s
  void startConnectionTracker() {
    _connectionTimer?.cancel();
    _connectionTimer = Timer.periodic(const Duration(seconds: 10), (_) {
      checkConnection();
    });
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

  /// Initialize home data
  Future<void> initialize({bool forceRefresh = false}) async {
    if (_isInitialized && !forceRefresh) return;

    _isLoading = !_isInitialized;
    _error = null;
    notifyListeners();

    await checkConnection();
    startConnectionTracker();

    try {
      // Fetch trending songs
      final trending = await _youtubeService.getTrendingMusic(forceRefresh: forceRefresh);
      if (trending.isNotEmpty) {
        _trendingSongs = trending;
      }

      _isInitialized = true;
      _isLoading = false;
      _lastRefreshed = DateTime.now();
      notifyListeners();

      // Load all categories in background
      await _loadRemainingCategories(forceRefresh: forceRefresh);
    } catch (e) {
      _error = 'Failed to load music. Check your connection.';
      _isLoading = false;
      notifyListeners();
    }
  }

  Future<void> _loadRemainingCategories({bool forceRefresh = false}) async {
    // Load all categories concurrently — each row pops in as soon as its
    // data arrives, and one slow/failed category never blocks the rest.
    await Future.wait(
      categories.map(
        (category) => loadCategory(category, forceRefresh: forceRefresh)
            .catchError((e) => debugPrint('Error loading $category: $e')),
      ),
    );
  }

  /// Refresh all data — always bypasses caches so every pull-to-refresh
  /// returns fresh YouTube results. Existing content stays on screen while
  /// new data streams in section by section.
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
    _connectionTimer?.cancel();
    super.dispose();
  }
}
