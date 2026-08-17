import 'dart:io';

import '../models/song.dart';

/// Whether an album is purely virtual (in-memory) or backed by a physical folder
enum AlbumStorageType {
  /// Virtual album — songs are referenced by metadata only (current behavior)
  virtual,

  /// Physical album — maps to a folder on disk (e.g., SonicWave/MyAlbum/)
  physical,
}

class UserAlbum {
  final String id;
  final String name;
  final List<Song> songs;
  final bool isCustom;

  /// Absolute path to the physical folder this album maps to, if any.
  final String? folderPath;

  /// Whether this album was auto-discovered from a filesystem folder.
  final bool isFolderBased;

  /// Path to a custom cover image file chosen from the gallery.
  final String? coverImagePath;

  /// Timestamp of the last time this album was updated (songs added/moved/deleted/cover changed).
  final DateTime lastUpdated;

  UserAlbum({
    required this.id,
    required this.name,
    required this.songs,
    this.isCustom = true,
    this.folderPath,
    this.isFolderBased = false,
    this.coverImagePath,
    DateTime? lastUpdated,
  }) : lastUpdated = lastUpdated ?? DateTime.now();

  String get thumbnail =>
      coverImagePath ?? (songs.isNotEmpty ? songs.first.thumbnailUrl : '');

  int get songCount => songs.length;

  /// Whether this album is backed by a real folder on disk
  AlbumStorageType get storageType =>
      (folderPath != null && folderPath!.isNotEmpty)
      ? AlbumStorageType.physical
      : AlbumStorageType.virtual;

  /// Total size of all audio files in this album, in bytes.
  ///
  /// Cached as a `late final` so the computation runs at most once per album
  /// instance rather than on every sort comparison. Previously each comparison
  /// during "Sort by size" triggered a `File.lengthSync()` call per song,
  /// blocking the UI on every sort rebuild.
  late final int totalSizeInBytes = () {
    int total = 0;
    for (final song in songs) {
      if (song.filePath != null && song.filePath!.isNotEmpty) {
        try {
          final f = File(song.filePath!);
          if (f.existsSync()) total += f.lengthSync();
        } catch (_) {}
      }
    }
    return total;
  }();

  String get formattedTotalSize {
    final bytes = totalSizeInBytes;
    if (bytes == 0) return '0.0 MB';
    final mb = bytes / (1024 * 1024);
    if (mb >= 1024) {
      final gb = mb / 1024;
      return '${gb.toStringAsFixed(1)} GB';
    }
    return '${mb.toStringAsFixed(1)} MB';
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'songs': songs.map((s) => s.toJson()).toList(),
    'isCustom': isCustom,
    'folderPath': folderPath,
    'isFolderBased': isFolderBased,
    'coverImagePath': coverImagePath,
    'lastUpdated': lastUpdated.millisecondsSinceEpoch,
  };

  factory UserAlbum.fromJson(Map<String, dynamic> json) {
    return UserAlbum(
      id: json['id'] as String,
      name: json['name'] as String,
      songs: (json['songs'] as List<dynamic>)
          .map((s) => Song.fromJson(s as Map<String, dynamic>))
          .toList(),
      isCustom: json['isCustom'] as bool? ?? true,
      folderPath: json['folderPath'] as String?,
      isFolderBased: json['isFolderBased'] as bool? ?? false,
      coverImagePath: json['coverImagePath'] as String?,
      lastUpdated: json['lastUpdated'] != null
          ? DateTime.fromMillisecondsSinceEpoch(json['lastUpdated'] as int)
          : null,
    );
  }

  UserAlbum copyWith({
    String? name,
    List<Song>? songs,
    String? folderPath,
    bool? isFolderBased,
    String? coverImagePath,
    bool clearCoverImage = false,
    DateTime? lastUpdated,
  }) {
    return UserAlbum(
      id: id,
      name: name ?? this.name,
      songs: songs ?? this.songs,
      isCustom: isCustom,
      folderPath: folderPath ?? this.folderPath,
      isFolderBased: isFolderBased ?? this.isFolderBased,
      coverImagePath: clearCoverImage
          ? null
          : (coverImagePath ?? this.coverImagePath),
      lastUpdated: lastUpdated ?? this.lastUpdated,
    );
  }
}
