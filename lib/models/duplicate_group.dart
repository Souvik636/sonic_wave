import 'song.dart';

/// Represents a cluster of duplicate songs found on local storage
class DuplicateGroup {
  final String key;
  final String displayTitle;
  final String displayArtist;
  final List<Song> songs;

  DuplicateGroup({
    required this.key,
    required this.displayTitle,
    required this.displayArtist,
    required this.songs,
  });

  /// The highest quality / recommended copy to keep
  Song get recommendedToKeep {
    if (songs.isEmpty) throw StateError('Empty duplicate group');
    final sorted = List<Song>.from(songs);
    sorted.sort((a, b) {
      // 1. Quality by file format
      int score(Song s) {
        final ext = (s.filePath ?? s.videoId).split('.').last.toLowerCase();
        if (ext == 'flac' || ext == 'wav' || ext == 'aiff') return 4;
        if (ext == 'm4a' || ext == 'aac') return 3;
        if (ext == 'mp3') return 2;
        return 1;
      }
      final sA = score(a);
      final sB = score(b);
      if (sA != sB) return sB.compareTo(sA);

      // 2. File size (larger file is usually better bitrate/uncompressed)
      final sizeA = a.fileSizeInBytes;
      final sizeB = b.fileSizeInBytes;
      if (sizeA != sizeB) return sizeB.compareTo(sizeA);

      return 0;
    });
    return sorted.first;
  }
}
