import 'dart:io';

class Song {
  final String id;
  final String title;
  final String artist;
  final String thumbnailUrl;
  final String highResThumbnailUrl;
  final Duration duration;
  final String videoId;
  final double speed;
  final double pitch;
  final double fadeIn;
  final double fadeOut;
  final String? searchQuery;

  /// Absolute path to the physical audio file on disk.
  /// Null for streamed / online-only songs.
  final String? filePath;

  /// The folder-based album name this song belongs to, if any.
  final String? albumFolderName;

  /// True if metadata, trimming, or studio effects were modified by the user.
  final bool isEdited;

  /// Audio isolation filter mode ('none', 'vocal', 'instrument').
  final String isolationMode;

  const Song({
    required this.id,
    required this.title,
    required this.artist,
    required this.thumbnailUrl,
    required this.highResThumbnailUrl,
    required this.duration,
    required this.videoId,
    this.speed = 1.0,
    this.pitch = 0.0,
    this.fadeIn = 0.0,
    this.fadeOut = 0.0,
    this.searchQuery,
    this.filePath,
    this.albumFolderName,
    this.isEdited = false,
    this.isolationMode = 'none',
  });

  String get formattedDuration {
    final minutes = duration.inMinutes;
    final seconds = duration.inSeconds % 60;
    return '$minutes:${seconds.toString().padLeft(2, '0')}';
  }

  /// True if song physically resides in or was recovered from the recovery backup folder.
  bool get isRecovered {
    if (filePath != null && (filePath!.contains('.recovery') || filePath!.contains('Recovery'))) {
      return true;
    }
    if (videoId.contains('.recovery') || videoId.contains('Recovery')) {
      return true;
    }
    return false;
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'title': title,
      'artist': artist,
      'thumbnailUrl': thumbnailUrl,
      'highResThumbnailUrl': highResThumbnailUrl,
      'duration': duration.inMilliseconds,
      'videoId': videoId,
      'speed': speed,
      'pitch': pitch,
      'fadeIn': fadeIn,
      'fadeOut': fadeOut,
      'searchQuery': searchQuery,
      'filePath': filePath,
      'albumFolderName': albumFolderName,
      'isEdited': isEdited,
      'isolationMode': isolationMode,
    };
  }

  factory Song.fromJson(Map<String, dynamic> json) {
    return Song(
      id: json['id'] as String,
      title: json['title'] as String,
      artist: json['artist'] as String,
      thumbnailUrl: json['thumbnailUrl'] as String,
      highResThumbnailUrl: json['highResThumbnailUrl'] as String,
      duration: Duration(milliseconds: json['duration'] as int),
      videoId: json['videoId'] as String,
      speed: (json['speed'] as num?)?.toDouble() ?? 1.0,
      pitch: (json['pitch'] as num?)?.toDouble() ?? 0.0,
      fadeIn: (json['fadeIn'] as num?)?.toDouble() ?? 0.0,
      fadeOut: (json['fadeOut'] as num?)?.toDouble() ?? 0.0,
      searchQuery: json['searchQuery'] as String?,
      filePath: json['filePath'] as String?,
      albumFolderName: json['albumFolderName'] as String?,
      isEdited: (json['isEdited'] as bool?) ?? false,
      isolationMode: (json['isolationMode'] as String?) ?? 'none',
    );
  }

  Song copyWith({
    String? id,
    String? title,
    String? artist,
    String? thumbnailUrl,
    String? highResThumbnailUrl,
    Duration? duration,
    String? videoId,
    double? speed,
    double? pitch,
    double? fadeIn,
    double? fadeOut,
    String? searchQuery,
    String? filePath,
    String? albumFolderName,
    bool? isEdited,
    String? isolationMode,
  }) {
    return Song(
      id: id ?? this.id,
      title: title ?? this.title,
      artist: artist ?? this.artist,
      thumbnailUrl: thumbnailUrl ?? this.thumbnailUrl,
      highResThumbnailUrl: highResThumbnailUrl ?? this.highResThumbnailUrl,
      duration: duration ?? this.duration,
      videoId: videoId ?? this.videoId,
      speed: speed ?? this.speed,
      pitch: pitch ?? this.pitch,
      fadeIn: fadeIn ?? this.fadeIn,
      fadeOut: fadeOut ?? this.fadeOut,
      searchQuery: searchQuery ?? this.searchQuery,
      filePath: filePath ?? this.filePath,
      albumFolderName: albumFolderName ?? this.albumFolderName,
      isEdited: isEdited ?? this.isEdited,
      isolationMode: isolationMode ?? this.isolationMode,
    );
  }

  String get source {
    if (id.startsWith('jiosaavn_')) return 'JioSaavn';
    if (id.startsWith('archive_')) return 'Archive';
    if (id.startsWith('audius_')) return 'Audius';
    if (id.startsWith('jamendo_')) return 'Jamendo';
    if (id.startsWith('radio_')) return 'Radio';
    if (id.startsWith('local_') ||
        filePath != null ||
        videoId.startsWith('/') ||
        (videoId.length >= 3 && videoId[1] == ':' && (videoId[2] == '/' || videoId[2] == '\\')) ||
        videoId.startsWith('content://') ||
        videoId.startsWith('file://') ||
        (thumbnailUrl.isNotEmpty && !thumbnailUrl.startsWith('http://') && !thumbnailUrl.startsWith('https://'))) {
      return 'Local';
    }
    return 'YouTube';
  }

  bool get isLiveRadio {
    return id.startsWith('radio_') || videoId.startsWith('radio_');
  }

  bool get isLocalFile {
    return filePath != null ||
        id.startsWith('local_') ||
        videoId.startsWith('/') ||
        (videoId.length >= 3 && videoId[1] == ':' && (videoId[2] == '/' || videoId[2] == '\\')) ||
        videoId.startsWith('content://') ||
        videoId.startsWith('file://') ||
        videoId.startsWith('local_');
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is Song && runtimeType == other.runtimeType && videoId == other.videoId;

  @override
  int get hashCode => videoId.hashCode;

  int get fileSizeInBytes {
    if (filePath != null && filePath!.isNotEmpty) {
      try {
        final file = File(filePath!);
        if (file.existsSync()) {
          return file.lengthSync();
        }
      } catch (_) {}
    }
    return 0;
  }

  String get formattedFileSize {
    final bytes = fileSizeInBytes;
    if (bytes == 0) return '';
    final mb = bytes / (1024 * 1024);
    return '${mb.toStringAsFixed(1)} MB';
  }
}
