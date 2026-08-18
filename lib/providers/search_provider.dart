import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/song.dart';
import '../services/youtube_service.dart';
import '../services/archive_org_service.dart';
import '../services/jiosaavn_service.dart';

class SearchProvider extends ChangeNotifier {
  final YouTubeService _youtubeService = YouTubeService();
  final ArchiveOrgService _archiveOrgService = ArchiveOrgService();
  final JioSaavnService _jioSaavnService = JioSaavnService();

  String _query = '';
  List<Song> _results = [];
  List<String> _suggestions = [];
  List<String> _recentSearches = [];
  bool _isLoading = false;
  bool _isLoadingSuggestions = false;
  String? _error;
  Timer? _debounceTimer;
  Timer? _suggestionTimer;

  static const String _recentSearchesKey = 'recent_searches_list';

  // Search result cache: query → results (expires after 5 min)
  final Map<String, _CachedSearch> _searchCache = {};

  SearchProvider() {
    _loadRecentSearches();
  }

  // Getters
  String get query => _query;
  List<Song> get results => _results;
  List<String> get suggestions => _suggestions;
  List<String> get recentSearches => List.unmodifiable(_recentSearches);
  bool get isLoading => _isLoading;
  bool get isLoadingSuggestions => _isLoadingSuggestions;
  String? get error => _error;
  bool get hasResults => _results.isNotEmpty;

  /// Load recent searches from SharedPreferences
  Future<void> _loadRecentSearches() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      _recentSearches = prefs.getStringList(_recentSearchesKey) ?? [];
      notifyListeners();
    } catch (_) {}
  }

  /// Save recent searches to SharedPreferences
  Future<void> _saveRecentSearches() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setStringList(_recentSearchesKey, _recentSearches);
    } catch (_) {}
  }

  /// Add a search query to history
  void addToRecentSearches(String query) {
    final trimmed = query.trim();
    if (trimmed.isEmpty) return;
    _recentSearches.removeWhere((item) => item.toLowerCase() == trimmed.toLowerCase());
    _recentSearches.insert(0, trimmed);
    if (_recentSearches.length > 15) {
      _recentSearches = _recentSearches.sublist(0, 15);
    }
    _saveRecentSearches();
    notifyListeners();
  }

  /// Remove a single item from recent searches
  void removeFromRecentSearches(String query) {
    _recentSearches.removeWhere((item) => item.toLowerCase() == query.toLowerCase());
    _saveRecentSearches();
    notifyListeners();
  }

  /// Clear all recent searches
  void clearRecentSearches() {
    _recentSearches.clear();
    _saveRecentSearches();
    notifyListeners();
  }

  /// Update query and trigger debounced suggestions
  void updateQuery(String query, {bool offlineOnly = false, List<Song> downloadedSongs = const []}) {
    _query = query;
    _error = null;

    if (query.isEmpty) {
      _suggestions = [];
      _results = [];
      notifyListeners();
      return;
    }

    // Debounce suggestions
    _suggestionTimer?.cancel();
    _suggestionTimer = Timer(const Duration(milliseconds: 300), () {
      _fetchSuggestions(query, offlineOnly, downloadedSongs);
    });

    notifyListeners();
  }

  /// Execute search
  Future<void> search({String? searchQuery, bool offlineOnly = false, List<Song> downloadedSongs = const []}) async {
    final q = searchQuery ?? _query;
    if (q.isEmpty) return;

    _query = q;
    _isLoading = true;
    _error = null;
    _suggestions = [];
    addToRecentSearches(q);
    notifyListeners();

    try {
      if (offlineOnly) {
        final queryLower = q.toLowerCase();
        _results = downloadedSongs.where((song) {
          return song.title.toLowerCase().contains(queryLower) ||
                 song.artist.toLowerCase().contains(queryLower);
        }).toList();
      } else {
        // Check cache first for instant results
        final cacheKey = q.toLowerCase().trim();
        final cached = _searchCache[cacheKey];
        if (cached != null && !cached.isExpired) {
          _results = cached.results;
          _isLoading = false;
          notifyListeners();
          return;
        }

        final ytFuture = _youtubeService.searchSongs(q);
        final archiveFuture = _archiveOrgService.searchSongs(q);
        final jioFuture = _jioSaavnService.searchSongs(q);
        final searchResults = await Future.wait([
          ytFuture.catchError((_) => <Song>[]),
          archiveFuture.catchError((_) => <Song>[]),
          jioFuture.catchError((_) => <Song>[]),
        ]);
        final ytResults = searchResults[0];
        final archiveResults = searchResults[1];
        final jioResults = searchResults[2];
        
        final ytWithQuery = ytResults.map((s) => s.copyWith(searchQuery: q)).toList();
        final jioWithQuery = jioResults.map((s) => s.copyWith(searchQuery: q)).toList();
        _results = [...ytWithQuery, ...jioWithQuery, ...archiveResults];

        // Store in cache
        _searchCache[cacheKey] = _CachedSearch(_results, DateTime.now());
      }
      _isLoading = false;
      notifyListeners();
    } catch (e) {
      _error = 'Failed to search. Please try again.';
      _isLoading = false;
      notifyListeners();
    }
  }

  /// Fetch search suggestions
  Future<void> _fetchSuggestions(String query, bool offlineOnly, List<Song> downloadedSongs) async {
    if (query.length < 2) return;

    _isLoadingSuggestions = true;
    notifyListeners();

    try {
      if (offlineOnly) {
        final queryLower = query.toLowerCase();
        final Set<String> localSuggestions = {};
        for (final song in downloadedSongs) {
          if (song.title.toLowerCase().contains(queryLower)) {
            localSuggestions.add(song.title);
          }
          if (song.artist.toLowerCase().contains(queryLower)) {
            localSuggestions.add(song.artist);
          }
        }
        _suggestions = localSuggestions.take(8).toList();
      } else {
        _suggestions = await _youtubeService.getSearchSuggestions(query);
      }
    } catch (e) {
      _suggestions = [];
    }

    _isLoadingSuggestions = false;
    notifyListeners();
  }

  /// Clear search
  void clearSearch() {
    _query = '';
    _results = [];
    _suggestions = [];
    _error = null;
    _debounceTimer?.cancel();
    _suggestionTimer?.cancel();
    notifyListeners();
  }

  @override
  void dispose() {
    _debounceTimer?.cancel();
    _suggestionTimer?.cancel();
    super.dispose();
  }
}

class _CachedSearch {
  final List<Song> results;
  final DateTime timestamp;
  _CachedSearch(this.results, this.timestamp);

  bool get isExpired =>
      DateTime.now().difference(timestamp) > const Duration(minutes: 5);
}
