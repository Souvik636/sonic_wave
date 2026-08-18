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
  bool _isLoadingMore = false;
  bool _isLoadingSuggestions = false;
  bool _hasMore = true;
  int _currentPage = 1;
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
  bool get isLoadingMore => _isLoadingMore;
  bool get isLoadingSuggestions => _isLoadingSuggestions;
  bool get hasMore => _hasMore;
  int get currentPage => _currentPage;
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
    _currentPage = 1;
    _hasMore = true;
    addToRecentSearches(q);
    notifyListeners();

    try {
      if (offlineOnly) {
        final queryLower = q.toLowerCase();
        _results = downloadedSongs.where((song) {
          return song.title.toLowerCase().contains(queryLower) ||
                 song.artist.toLowerCase().contains(queryLower);
        }).toList();
        _hasMore = false;
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

        final jioFuture = _jioSaavnService.searchSongs(q, maxResults: 12, page: 1);
        final ytFuture = _youtubeService.searchSongs(q, maxResults: 20, page: 1);
        final archiveFuture = _archiveOrgService.searchSongs(q, maxResults: 5, page: 1);
        final searchResults = await Future.wait([
          jioFuture.catchError((_) => <Song>[]),
          ytFuture.catchError((_) => <Song>[]),
          archiveFuture.catchError((_) => <Song>[]),
        ]);
        final jioResults = searchResults[0];
        final ytResults = searchResults[1];
        final archiveResults = searchResults[2];
        
        final jioWithQuery = jioResults.map((s) => s.copyWith(searchQuery: q)).toList();
        final ytWithQuery = ytResults.map((s) => s.copyWith(searchQuery: q)).toList();
        
        // 1) JioSaavn results first, then YouTube, then Archive
        _results = [...jioWithQuery, ...ytWithQuery, ...archiveResults];
        _hasMore = (jioResults.length + ytResults.length + archiveResults.length) >= 8;

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

  /// Load more songs for pagination from all sources
  Future<void> loadMore({bool offlineOnly = false, List<Song> downloadedSongs = const []}) async {
    if (_isLoadingMore || _isLoading || _query.isEmpty || !_hasMore || offlineOnly) return;

    _isLoadingMore = true;
    notifyListeners();

    try {
      final nextPage = _currentPage + 1;
      final jioFuture = _jioSaavnService.searchSongs(_query, maxResults: 10, page: nextPage);
      final ytFuture = _youtubeService.searchSongs(_query, maxResults: 15, page: nextPage);
      final archiveFuture = _archiveOrgService.searchSongs(_query, maxResults: 5, page: nextPage);

      final searchResults = await Future.wait([
        jioFuture.catchError((_) => <Song>[]),
        ytFuture.catchError((_) => <Song>[]),
        archiveFuture.catchError((_) => <Song>[]),
      ]);

      final jioResults = searchResults[0];
      final ytResults = searchResults[1];
      final archiveResults = searchResults[2];

      final existingIds = _results.map((s) => s.videoId).toSet();
      final newSongs = <Song>[];

      for (final song in jioResults) {
        if (!existingIds.contains(song.videoId)) {
          existingIds.add(song.videoId);
          newSongs.add(song.copyWith(searchQuery: _query));
        }
      }
      for (final song in ytResults) {
        if (!existingIds.contains(song.videoId)) {
          existingIds.add(song.videoId);
          newSongs.add(song.copyWith(searchQuery: _query));
        }
      }
      for (final song in archiveResults) {
        if (!existingIds.contains(song.videoId)) {
          existingIds.add(song.videoId);
          newSongs.add(song);
        }
      }

      if (newSongs.isNotEmpty) {
        _results.addAll(newSongs);
        _currentPage = nextPage;
        _hasMore = newSongs.length >= 5;
      } else {
        _hasMore = false;
      }
    } catch (e) {
      debugPrint('[SearchProvider] loadMore failed: $e');
    } finally {
      _isLoadingMore = false;
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
