import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Cached metadata for a song from MusicBrainz lookup.
class CachedMetadata {
  final String? genre;
  final String? albumTitle;
  final String? artistName;
  final DateTime timestamp;

  CachedMetadata({
    this.genre,
    this.albumTitle,
    this.artistName,
    required this.timestamp,
  });

  bool isExpired(Duration ttl) {
    return DateTime.now().difference(timestamp) > ttl;
  }

  Map<String, dynamic> toJson() => {
        'g': genre,
        'a': albumTitle,
        'ar': artistName,
        't': timestamp.millisecondsSinceEpoch,
      };

  factory CachedMetadata.fromJson(Map<String, dynamic> json) {
    return CachedMetadata(
      genre: json['g'] as String?,
      albumTitle: json['a'] as String?,
      artistName: json['ar'] as String?,
      timestamp: DateTime.fromMillisecondsSinceEpoch(json['t'] as int),
    );
  }
}

/// Persistent cache for MusicBrainz lookups.
/// Positive entries (found): 30 days TTL.
/// Negative entries (not found): 7 days TTL.
class MetadataCache {
  static final MetadataCache _instance = MetadataCache._internal();
  factory MetadataCache() => _instance;
  MetadataCache._internal();

  static const String _prefsKey = 'mb_cache_v1';
  static const Duration positiveTtl = Duration(days: 30);
  static const Duration negativeTtl = Duration(days: 7);

  final Map<String, CachedMetadata> _cache = {};
  bool _loaded = false;

  /// Load cache from SharedPreferences.
  Future<void> load() async {
    if (_loaded) return;
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_prefsKey);
      if (raw != null) {
        final Map<String, dynamic> decoded = json.decode(raw);
        decoded.forEach((key, value) {
          try {
            _cache[key] = CachedMetadata.fromJson(value as Map<String, dynamic>);
          } catch (_) {}
        });
      }
      _loaded = true;
    } catch (e) {
      debugPrint('[MetadataCache] Load failed: $e');
    }
  }

  /// Flush cache to SharedPreferences.
  Future<void> flush() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final Map<String, dynamic> encoded = {};
      _cache.forEach((key, val) {
        // Only keep non-expired entries
        final ttl = (val.genre != null || val.albumTitle != null || val.artistName != null)
            ? positiveTtl
            : negativeTtl;
        if (!val.isExpired(ttl)) {
          encoded[key] = val.toJson();
        }
      });
      await prefs.setString(_prefsKey, json.encode(encoded));
    } catch (e) {
      debugPrint('[MetadataCache] Flush failed: $e');
    }
  }

  /// Get cached metadata for a song.
  CachedMetadata? get(String songId) {
    final entry = _cache[songId];
    if (entry == null) return null;

    final ttl = (entry.genre != null || entry.albumTitle != null || entry.artistName != null)
        ? positiveTtl
        : negativeTtl;

    if (entry.isExpired(ttl)) {
      _cache.remove(songId);
      return null;
    }

    return entry;
  }

  /// Put metadata into the cache.
  void put(String songId, {String? genre, String? albumTitle, String? artistName}) {
    _cache[songId] = CachedMetadata(
      genre: genre,
      albumTitle: albumTitle,
      artistName: artistName,
      timestamp: DateTime.now(),
    );
  }
}
