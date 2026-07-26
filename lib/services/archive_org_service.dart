import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import '../models/song.dart';

class ArchiveOrgService {
  static final ArchiveOrgService _instance = ArchiveOrgService._internal();
  factory ArchiveOrgService() => _instance;
  ArchiveOrgService._internal();

  final HttpClient _client = HttpClient()
    ..connectionTimeout = const Duration(seconds: 4);

  /// Search Archive.org for audio tracks matching [query]
  Future<List<Song>> searchSongs(String query, {int maxResults = 5}) async {
    try {
      final uri = Uri.parse(
        'https://archive.org/advancedsearch.php?q=title:(${Uri.encodeComponent(query)})+AND+mediatype:(audio)&fl[]=identifier,title,creator&output=json&rows=$maxResults'
      );
      
      final request = await _client.getUrl(uri).timeout(const Duration(seconds: 4));
      final response = await request.close().timeout(const Duration(seconds: 4));
      
      if (response.statusCode != 200) {
        return [];
      }
      
      final body = await response.transform(utf8.decoder).join();
      final data = jsonDecode(body);
      
      final docs = data['response']?['docs'] as List?;
      if (docs == null || docs.isEmpty) {
        return [];
      }
      
      final songs = <Song>[];
      
      // Fetch metadata in parallel to find if it contains playable MP3s
      final futures = docs.map((doc) async {
        final id = doc['identifier'] as String?;
        final title = doc['title'] as String? ?? 'Unknown Title';
        final artist = doc['creator'] as String? ?? 'Internet Archive';
        
        if (id == null || id.isEmpty) return null;
        
        // Quick verification to see if a valid MP3 file exists
        final mp3Url = await getAudioFileUrl(id);
        if (mp3Url != null) {
          return Song(
            id: 'archive_$id',
            videoId: 'archive_$id',
            title: title,
            artist: artist,
            thumbnailUrl: '', // Deterministic geometric cover art placeholder will be used
            highResThumbnailUrl: '',
            duration: const Duration(minutes: 3, seconds: 0),
          );
        }
        return null;
      });
      
      final results = await Future.wait(futures);
      for (final s in results) {
        if (s != null) {
          songs.add(s);
        }
      }
      
      return songs;
    } catch (e) {
      debugPrint('Archive.org search failed: $e');
      return [];
    }
  }

  /// Query metadata for [identifier] to find the first playable MP3 file URL
  Future<String?> getAudioFileUrl(String identifier) async {
    try {
      final uri = Uri.parse('https://archive.org/metadata/$identifier');
      final request = await _client.getUrl(uri).timeout(const Duration(seconds: 3));
      final response = await request.close().timeout(const Duration(seconds: 3));
      
      if (response.statusCode != 200) {
        return null;
      }
      
      final body = await response.transform(utf8.decoder).join();
      final data = jsonDecode(body);
      
      final files = data['files'] as List?;
      if (files == null) return null;
      
      for (final file in files) {
        final name = file['name'] as String?;
        final format = file['format'] as String?;
        if (name != null && name.endsWith('.mp3') && (format == 'VBR MP3' || format == 'MP3' || format == '128Kbps MP3')) {
          return 'https://archive.org/download/$identifier/${Uri.encodeComponent(name)}';
        }
      }
    } catch (_) {}
    return null;
  }
}
