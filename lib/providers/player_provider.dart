import 'package:audio_service/audio_service.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter/services.dart';
import 'package:just_audio/just_audio.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';
import 'dart:convert';
import 'dart:async';
import 'dart:io';
import '../models/song.dart';
import '../models/album.dart';
import '../services/audio_handler.dart';
import '../services/download_service.dart';
import '../services/storage_location_service.dart';
import '../services/youtube_service.dart';
import '../services/youtube_link_parser.dart';
import '../services/app_messenger.dart';
import '../services/local_metadata_service.dart';
import '../services/recommendation_engine.dart';
import '../widgets/app_toast.dart';
import 'settings_provider.dart';

/// Type of delete action available for a song
enum DeleteType {
  /// File is inside the app-managed folder — can be permanently deleted from disk
  permanent,

  /// File is an external reference — only remove from app memory/metadata
  memoryOnly,
}

class PlayerProvider extends ChangeNotifier {
  final SonicWaveAudioHandler _audioHandler;
  final List<HistoryEntry> _history = [];
  final List<Song> _downloadedSongs = [];
  final List<Song> _favorites = [];
  final List<UserAlbum> _albums = [];
  final Map<String, double> _downloadProgress = {};
  static const int _maxRecentlyPlayed = 30;
  static const String _recentlyPlayedKey = 'recently_played';
  static const String _favoritesKey = 'favorites_songs';
  static const String _albumsKey = 'user_albums';
  Song? _loadingSong;
  AudioQuality _audioQuality = AudioQuality.high;
  Timer? _sleepTimer;
  Timer? _countdownTimer;
  int _sleepTimerMinutes = 0;
  bool _sleepAfterCurrentTrack = false;
  double _playbackSpeed = 1.0;
  SoundEnhancer _lastEnhancerMode = SoundEnhancer.none;
  bool _useCustomEqualizer = false;
  List<double> _customEqualizerGains = [0.0, 0.0, 0.0, 0.0, 0.0];
  bool _offlineModeOnly = false;
  bool _isKaraokeMode = false;
  String? _playbackError;

  bool get useCustomEqualizer => _useCustomEqualizer;
  List<double> get customEqualizerGains => _customEqualizerGains;
  bool get offlineModeOnly => _offlineModeOnly;
  bool get isKaraokeMode => _isKaraokeMode;
  String? get playbackError => _playbackError;

  void clearPlaybackError() {
    _playbackError = null;
    notifyListeners();
  }

  PlayerProvider(this._audioHandler) {
    _loadHistory();
    _loadFavorites();
    loadDownloads();
    _loadAlbums();
    _initFileIntentListener();

    _audioHandler.onQueueNearEnd = () {
      checkAutoRecommendation();
    };

    // Listen to playback state changes
    _audioHandler.playbackState.listen((_) {
      notifyListeners();
    });

    // Listen to media item changes
    _audioHandler.mediaItem.listen((_) {
      _saveSessionState();
      notifyListeners();
    });

    restoreLastSession();

    // Listen to processing state changes (buffering/loading)
    _audioHandler.player.processingStateStream.listen((state) {
      // "Stop after this song" sleep mode: pause once the track completes.
      if (state == ProcessingState.completed && _sleepAfterCurrentTrack) {
        _sleepAfterCurrentTrack = false;
        pause();
      }
      notifyListeners();
    });
  }

  static const MethodChannel _intentChannel = MethodChannel('com.sonicwave.sonic_wave/intent');

  void _initFileIntentListener() {
    // 1. Listen for new intents when app is running / resumed
    _intentChannel.setMethodCallHandler((call) async {
      if (call.method == 'onFileOpened') {
        final uriStr = call.arguments as String?;
        if (uriStr != null && uriStr.isNotEmpty) {
          await handleOpenedFileUri(uriStr);
        }
      } else if (call.method == 'onTextShared') {
        final text = call.arguments as String?;
        if (text != null && text.isNotEmpty) {
          // Reply as soon as the share is accepted — the native side keeps the
          // text parked until this call succeeds, and a download can take
          // minutes. Awaiting it here would leave that ack outstanding for the
          // whole download.
          unawaited(handleSharedText(text));
        }
      }
    });

    // 2. Check if the app was launched by opening a file
    _intentChannel.invokeMethod<String>('getInitialFileUri').then((uriStr) async {
      if (uriStr != null && uriStr.isNotEmpty) {
        await handleOpenedFileUri(uriStr);
      }
    }).catchError((e) {
      debugPrint('[PlayerProvider] Error getting initial file uri: $e');
    });

    // 3. …or by sharing a link into it from another app.
    _intentChannel
        .invokeMethod<String>('getInitialSharedText')
        .then((text) async {
      if (text != null && text.isNotEmpty) {
        await handleSharedText(text);
      }
    }).catchError((e) {
      debugPrint('[PlayerProvider] Error getting initial shared text: $e');
    });
  }

  /// Video ids whose shared-link download is currently being set up, so a
  /// double share (or a share of something already downloading) cannot start
  /// the same job twice.
  final Set<String> _sharedLinkInFlight = {};

  /// Handle text shared into the app from another app's share sheet.
  ///
  /// The only thing we act on is a YouTube video link. Anything else is left
  /// alone with a short explanation — silently swallowing a share the user
  /// deliberately performed is worse than saying it is not supported.
  ///
  /// The download itself runs through the ordinary [downloadSong] path, so it
  /// uses the yt-dlp pipeline (native container + embedded artwork), respects
  /// the configured audio quality, reports progress through `downloadProgress`,
  /// and lands in Downloads exactly like a download started from the UI.
  Future<void> handleSharedText(String text) async {
    final videoId = YouTubeLinkParser.extractVideoId(text);
    if (videoId == null) {
      debugPrint('[PlayerProvider] Shared text has no YouTube video link');
      AppMessenger.show(
        'No YouTube video link found in what you shared.',
        isError: true,
      );
      return;
    }

    if (_sharedLinkInFlight.contains(videoId) ||
        _downloadProgress.containsKey(videoId)) {
      AppMessenger.show('That song is already downloading.');
      return;
    }

    _sharedLinkInFlight.add(videoId);
    try {
      await loadDownloads();
      final existing = _downloadedSongs.where((s) => s.videoId == videoId);
      if (existing.isNotEmpty) {
        AppMessenger.show('"${existing.first.title}" is already downloaded.');
        return;
      }

      debugPrint('[PlayerProvider] Shared YouTube link -> downloading $videoId');

      Song song;
      try {
        song = await YouTubeService().getVideoDetails(videoId);
      } catch (e) {
        debugPrint('[PlayerProvider] Shared link lookup failed: $e');
        AppMessenger.show(
          'Couldn\'t read that video\'s details. Check your connection.',
          isError: true,
        );
        return;
      }

      AppMessenger.show('Downloading "${song.title}"…');

      // downloadSong swallows its own errors, so success is decided by whether
      // the song actually landed in the downloads list.
      await downloadSong(song);

      final saved = _downloadedSongs.any((s) => s.videoId == videoId);
      if (saved) {
        AppMessenger.show('Saved "${song.title}" to Downloads.');
      } else {
        AppMessenger.show(
          'Download failed for "${song.title}".',
          isError: true,
        );
      }
    } finally {
      _sharedLinkInFlight.remove(videoId);
    }
  }

  Future<void> handleOpenedFileUri(String uriStr) async {
    try {
      debugPrint('[PlayerProvider] Handling opened file URI: $uriStr');
      String realPath = uriStr;
      String displayName = uriStr.split(RegExp(r'[/\\]')).last;

      if (uriStr.startsWith('content://')) {
        final res = await _intentChannel.invokeMapMethod<String, String>('resolveContentUri', uriStr);
        if (res != null && res['path'] != null) {
          realPath = res['path']!;
          if (res['name'] != null && res['name']!.isNotEmpty) {
            displayName = res['name']!;
          }
        }
      } else if (uriStr.startsWith('file://')) {
        realPath = Uri.parse(uriStr).toFilePath();
        displayName = realPath.split(Platform.pathSeparator).last;
      }

      final cleanTitle = displayName.replaceAll(RegExp(r'\.[a-zA-Z0-9]+$'), '').replaceAll('_', ' ');

      Song initialSong = Song(
        id: 'local_${realPath.hashCode}',
        title: cleanTitle,
        artist: 'Local Media',
        thumbnailUrl: '',
        highResThumbnailUrl: '',
        duration: Duration.zero,
        videoId: realPath,
        filePath: realPath,
        albumFolderName: 'Opened File',
      );

      // Try enriching with real ID3 metadata tags (title, artist, artwork)
      try {
        initialSong = await LocalMetadataService().enrichSong(initialSong);
      } catch (e) {
        debugPrint('[PlayerProvider] ID3 enrich error: $e');
      }

      // Play song immediately and notify listeners
      await playSong(initialSong);
      notifyListeners();
    } catch (e) {
      debugPrint('[PlayerProvider] Error handling opened file: $e');
    }
  }

  Future<void> _saveSessionState() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      if (playlist.isNotEmpty) {
        final songsJson = playlist.map((s) => s.toJson()).toList();
        await prefs.setString('saved_session_playlist', json.encode(songsJson));
        await prefs.setInt('saved_session_index', currentIndex);
        await prefs.setInt('saved_session_position', _audioHandler.player.position.inSeconds);
      }
    } catch (_) {}
  }

  Future<void> restoreLastSession() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString('saved_session_playlist');
      if (raw != null && raw.isNotEmpty) {
        final List<dynamic> jsonList = json.decode(raw);
        final songs = jsonList.map((j) => Song.fromJson(j as Map<String, dynamic>)).toList();
        final index = prefs.getInt('saved_session_index') ?? 0;
        final posSec = prefs.getInt('saved_session_position') ?? 0;
        if (songs.isNotEmpty) {
          _audioHandler.restoreQueue(songs, index, Duration(seconds: posSec));
          notifyListeners();
        }
      }
    } catch (e) {
      debugPrint('Error restoring session state: $e');
    }
  }

  // Getters
  SonicWaveAudioHandler get audioHandler => _audioHandler;
  AudioPlayer get player => _audioHandler.player;
  Song? get currentSong => _audioHandler.currentSong;
  List<Song> get playlist => _audioHandler.playlist;
  int get currentIndex => _audioHandler.currentIndex;
  bool get isShuffled => _audioHandler.isShuffled;
  AudioServiceRepeatMode get repeatMode => _audioHandler.repeatMode;

  Song? get loadingSong => _loadingSong;
  bool get isPlaying => _audioHandler.player.playing;
  bool get isBuffering =>
      _loadingSong != null ||
      _audioHandler.player.processingState == ProcessingState.loading ||
      _audioHandler.player.processingState == ProcessingState.buffering;
  bool get hasCurrentSong => currentSong != null;

  bool isSongLoading(Song song) {
    return _loadingSong?.videoId == song.videoId ||
        (currentSong?.videoId == song.videoId && isBuffering);
  }

  Duration get position => _audioHandler.player.position;
  Duration get duration => _audioHandler.player.duration ?? Duration.zero;
  Duration get bufferedPosition => _audioHandler.player.bufferedPosition;

  Stream<Duration> get positionStream => _audioHandler.player.positionStream;
  Stream<Duration?> get durationStream => _audioHandler.player.durationStream;
  Stream<bool> get playingStream => _audioHandler.player.playingStream;
  Stream<ProcessingState> get processingStateStream =>
      _audioHandler.player.processingStateStream;

  // Generation counter to handle rapid song switching
  int _playGeneration = 0;

  Future<void> skipNext() async {
    final nextIdx = currentIndex + 1;
    if (nextIdx < playlist.length) {
      _loadingSong = playlist[nextIdx];
      notifyListeners();
    }
    try {
      await _audioHandler.skipToNext();
      if (currentSong != null) {
        _addToRecentlyPlayed(currentSong!);
      }
    } catch (e) {
      debugPrint('Error skipping to next song: $e');
      _playbackError = 'Track unavailable. Skipping to next...';
      if (playlist.length > 1 && currentIndex < playlist.length - 1) {
        Future.delayed(const Duration(milliseconds: 1000), () {
          skipNext();
        });
      }
    } finally {
      _loadingSong = null;
      notifyListeners();
    }
  }

  Future<void> skipPrevious() async {
    final prevIdx = currentIndex - 1;
    if (prevIdx >= 0 && prevIdx < playlist.length) {
      _loadingSong = playlist[prevIdx];
      notifyListeners();
    }
    try {
      await _audioHandler.skipToPrevious();
    } catch (e) {
      debugPrint('Error skipping to previous song: $e');
    } finally {
      _loadingSong = null;
      notifyListeners();
    }
  }

  /// Jump straight to a queue entry by index and start playing it.
  Future<void> playQueueItem(int index) async {
    if (index >= 0 && index < playlist.length) {
      _loadingSong = playlist[index];
      notifyListeners();
    }
    try {
      await _audioHandler.skipToQueueIndex(index);
      if (currentSong != null) {
        _addToRecentlyPlayed(currentSong!);
      }
    } catch (e) {
      debugPrint('Error playing queue item: $e');
    } finally {
      _loadingSong = null;
      notifyListeners();
    }
  }

  /// Context-aware dynamic queue auto-recommendation engine trigger.
  Future<void> checkAutoRecommendation() async {
    final current = currentSong;
    if (current == null) return;
    final queue = playlist;
    final remaining = queue.length - currentIndex - 1;

    if (remaining <= 2) {
      final recommended = RecommendationEngine().generateRecommendations(
        currentSong: current,
        activeQueue: queue,
        librarySongs: localDeviceSongs,
        favoriteSongs: favoriteSongs,
        recentlyPlayed: recentlyPlayed,
        count: 4,
      );
      if (recommended.isNotEmpty) {
        for (final rec in recommended) {
          _audioHandler.addSongToQueue(rec);
        }
        notifyListeners();
      }
    }
  }

  /// Play a song — handles rapid tapping by cancelling stale requests
  Future<void> playSong(Song song) async {
    final thisGeneration = ++_playGeneration;
    _loadingSong = song;
    _playbackError = null;
    notifyListeners();
    try {
      await _audioHandler.playSong(song);
      // Only update history if this is still the active request
      if (_playGeneration == thisGeneration) {
        _addToRecentlyPlayed(song);
      }
    } catch (e) {
      if (_playGeneration == thisGeneration) {
        debugPrint('Error playing song: $e');
        final errorMsg = e.toString().replaceAll('Exception:', '').trim();
        _playbackError = 'Track unavailable. Skipping to next... ($errorMsg)';
        // Self-healing auto-skip to next track if available
        if (playlist.length > 1 && currentIndex < playlist.length - 1) {
          Future.delayed(const Duration(milliseconds: 1200), () {
            skipNext();
          });
        }
      }
      // Don't rethrow for superseded requests
    } finally {
      // Only clear loading state if this is still the active request
      if (_playGeneration == thisGeneration) {
        _loadingSong = null;
        notifyListeners();
      }
    }
  }

  void addSongToQueue(Song song) {
    _audioHandler.addSongToQueue(song);
    notifyListeners();
  }

  void playSongNext(Song song) {
    _audioHandler.insertSongNext(song);
    notifyListeners();
  }

  /// Play a playlist starting from index — handles rapid tapping
  Future<void> playPlaylist(List<Song> songs, {int startIndex = 0}) async {
    final thisGeneration = ++_playGeneration;
    if (startIndex < songs.length) {
      _loadingSong = songs[startIndex];
      _playbackError = null;
      notifyListeners();
    }
    try {
      await _audioHandler.playPlaylist(songs, startIndex: startIndex);
      if (_playGeneration == thisGeneration && startIndex < songs.length) {
        _addToRecentlyPlayed(songs[startIndex]);
      }
    } catch (e) {
      if (_playGeneration == thisGeneration) {
        debugPrint('Error playing playlist: $e');
        _playbackError = e.toString().replaceAll('Exception:', '').trim();
      }
    } finally {
      if (_playGeneration == thisGeneration) {
        _loadingSong = null;
        notifyListeners();
      }
    }
  }

  Future<void> play() async {
    await _audioHandler.play();
    notifyListeners();
  }

  Future<void> pause() async {
    await _audioHandler.pause();
    notifyListeners();
  }

  Future<void> togglePlayPause() async {
    if (isPlaying) {
      await pause();
    } else {
      await play();
    }
  }

  Future<void> seek(Duration position) async {
    await _audioHandler.seek(position);
  }

  /// Immediately stop playback and cancel any in-flight fetch/stream resolution.
  Future<void> stop() async {
    _playGeneration++;
    _loadingSong = null;
    await _audioHandler.stop();
    notifyListeners();
  }

  /// Move a song within the play queue (used by the queue sheet's drag-reorder).
  void reorderQueue(int oldIndex, int newIndex) {
    _audioHandler.reorderQueue(oldIndex, newIndex);
    notifyListeners();
  }

  /// Current download status for [videoId], or null if it has no active task.
  DownloadStatus? getDownloadStatus(String videoId) {
    final task = DownloadService().activeTasks[videoId];
    return task?.status;
  }

  void toggleShuffle() {
    _audioHandler.toggleShuffle();
    notifyListeners();
  }

  void cycleRepeatMode() {
    _audioHandler.cycleRepeatMode();
    notifyListeners();
  }

  void removeFromPlaylist(int index) {
    _audioHandler.removeFromPlaylist(index);
    notifyListeners();
  }

  // History management
  List<Song> get recentlyPlayed => _history.map((e) => e.song).toList();
  List<HistoryEntry> get historyList => _history;

  void _addToRecentlyPlayed(Song song) {
    _history.removeWhere((e) => e.song.videoId == song.videoId);
    _history.insert(0, HistoryEntry(song: song, playedAt: DateTime.now()));
    if (_history.length > _maxRecentlyPlayed) {
      _history.removeLast();
    }
    _saveHistory();
  }

  Future<void> _loadHistory() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final jsonString = prefs.getString(_recentlyPlayedKey);
      if (jsonString != null) {
        final List<dynamic> jsonList = json.decode(jsonString);
        _history.clear();
        _history.addAll(
          jsonList.map((j) => HistoryEntry.fromJson(j as Map<String, dynamic>)).toList(),
        );
        notifyListeners();
      }
    } catch (e) {
      debugPrint('Error loading history: $e');
    }
  }

  Future<void> _saveHistory() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final jsonString = json.encode(
        _history.map((e) => e.toJson()).toList(),
      );
      await prefs.setString(_recentlyPlayedKey, jsonString);
    } catch (e) {
      debugPrint('Error saving history: $e');
    }
  }

  double get playbackSpeed => _playbackSpeed;

  void setPlaybackSpeed(double speed) {
    _playbackSpeed = speed;
    _updatePlayerSpeedAndPitch();
    notifyListeners();
  }

  void updateSettings(SettingsProvider settings) {
    // Set player volume
    _audioHandler.updateVolume(settings.volume);
    // Track current audio quality for downloads AND streaming stream-pick
    final qualityChanged = _audioQuality != settings.audioQuality;
    _audioQuality = settings.audioQuality;
    YouTubeService.streamingQuality = settings.audioQuality;
    // A quality switch must take effect on the NEXT play, not whenever the
    // 5-minute URL TTL happens to lapse. YouTubeService's own cache is keyed by
    // quality so it self-invalidates, but the handler's prefetched streams are
    // keyed by videoId alone and would still hand back the old quality's URL.
    if (qualityChanged) {
      _audioHandler.clearPrefetchedStreams();
    }
    // Track custom equalizer settings
    _useCustomEqualizer = settings.useCustomEqualizer;
    _customEqualizerGains = settings.customEqualizerGains;
    // Track offline mode settings
    _offlineModeOnly = settings.offlineModeOnly;
    // Global crossfade between tracks
    _audioHandler.crossfadeSeconds = settings.crossfadeSeconds;
    // Apply pitch/speed effects representing sound enhancer
    _lastEnhancerMode = settings.soundEnhancer;
    _updatePlayerSpeedAndPitch();
  }

  void toggleKaraokeMode() {
    _isKaraokeMode = !_isKaraokeMode;
    _audioHandler.setKaraokeMode(_isKaraokeMode);
    notifyListeners();
  }

  void _updatePlayerSpeedAndPitch() {
    double speedMultiplier = 1.0;
    double pitchMultiplier = 1.0;

    final useSimulation = !kIsWeb && !Platform.isAndroid;

    if (_useCustomEqualizer) {
      // Manual Equalizer overrides preset effects
      _audioHandler.setSpeedAndPitch(_playbackSpeed, 1.0);
      _audioHandler.setCustomEqualizerGains(_customEqualizerGains);
    } else {
      switch (_lastEnhancerMode) {
        case SoundEnhancer.none:
          speedMultiplier = 1.0;
          pitchMultiplier = 1.0;
          break;
        case SoundEnhancer.bassBoost:
          if (useSimulation) {
            speedMultiplier = 1.0;
            pitchMultiplier = 0.95;
          }
          break;
        case SoundEnhancer.trebleBoost:
          if (useSimulation) {
            speedMultiplier = 1.0;
            pitchMultiplier = 1.06;
          }
          break;
        case SoundEnhancer.vocal:
          if (useSimulation) {
            speedMultiplier = 0.98;
            pitchMultiplier = 1.03;
          }
          break;
        case SoundEnhancer.ambient3d:
          if (useSimulation) {
            speedMultiplier = 1.02;
            pitchMultiplier = 0.97;
          }
          break;
      }

      _audioHandler.setSpeedAndPitch(speedMultiplier * _playbackSpeed, pitchMultiplier);
      _audioHandler.setEqualizerPreset(_lastEnhancerMode);
    }
  }

  // Sleep Timer
  int get sleepTimerMinutes => _sleepTimerMinutes;

  /// When true, playback pauses automatically once the current track finishes.
  bool get sleepAfterCurrentTrack => _sleepAfterCurrentTrack;

  void setSleepAfterCurrentTrack(bool value) {
    _sleepAfterCurrentTrack = value;
    // Turning on the "end of track" mode cancels any minute-based timer so the
    // two sleep modes never fight each other.
    if (value) {
      _sleepTimer?.cancel();
      _countdownTimer?.cancel();
      _sleepTimerMinutes = 0;
    }
    notifyListeners();
  }

  void setSleepTimer(int minutes) {
    _sleepTimer?.cancel();
    _countdownTimer?.cancel();
    _sleepTimerMinutes = minutes;
    // Minute-based timer and "end of track" mode are mutually exclusive.
    if (minutes > 0) _sleepAfterCurrentTrack = false;
    notifyListeners();

    if (minutes > 0) {
      _sleepTimer = Timer(Duration(minutes: minutes), () {
        _fadeOutAndPause();
        _sleepTimerMinutes = 0;
        notifyListeners();
      });

      _countdownTimer = Timer.periodic(const Duration(minutes: 1), (timer) {
        if (_sleepTimerMinutes > 0) {
          _sleepTimerMinutes--;
          notifyListeners();
        } else {
          timer.cancel();
        }
      });
    }
  }

  Future<void> _fadeOutAndPause() async {
    final originalVolume = player.volume;
    const steps = 15;
    const fadeDuration = Duration(milliseconds: 2500); // 2.5 seconds fade-out
    final interval = Duration(milliseconds: fadeDuration.inMilliseconds ~/ steps);

    for (int i = steps; i >= 0; i--) {
      final vol = originalVolume * (i / steps);
      await player.setVolume(vol);
      await Future.delayed(interval);
    }

    await pause();
    
    // Restore original volume so that playback is normal when started next time
    await player.setVolume(originalVolume);

    // Smoothly minimize/close the app on Android / iOS
    await SystemNavigator.pop();
  }

  // Favorites & Downloads Management
  List<Song> get favoriteSongs => _favorites;
  List<Song> get downloadedSongs => _downloadedSongs;
  Map<String, double> get downloadProgress => _downloadProgress;

  // Rich download items for UI
  List<DownloadItem> get activeDownloadItems {
    final service = DownloadService();
    final items = <DownloadItem>[];

    for (final entry in service.activeTasks.entries) {
      final task = entry.value;
      items.add(DownloadItem(
        song: task.song,
        status: task.status,
        progress: task.progress,
        speedBytesPerSec: task.speedBytesPerSec,
        eta: task.eta,
        bytesDownloaded: task.bytesDownloaded,
        totalBytes: task.totalSize,
        errorMessage: task.errorMessage,
        retryCount: task.retryCount,
      ));
    }

    // Sort: downloading → retrying → paused → queued → failed
    items.sort((a, b) {
      const order = {
        DownloadStatus.downloading: 0,
        DownloadStatus.retrying: 1,
        DownloadStatus.paused: 2,
        DownloadStatus.queued: 3,
        DownloadStatus.failed: 4,
        DownloadStatus.completed: 5,
        DownloadStatus.cancelled: 6,
      };
      return (order[a.status] ?? 9).compareTo(order[b.status] ?? 9);
    });

    return items;
  }

  /// Combined download speed across all active tasks (bytes/sec)
  double get totalDownloadSpeed {
    double total = 0;
    for (final task in DownloadService().activeTasks.values) {
      if (task.status == DownloadStatus.downloading) {
        total += task.speedBytesPerSec;
      }
    }
    return total;
  }

  String get formattedTotalDownloadSpeed {
    final speed = totalDownloadSpeed;
    if (speed <= 0) return '';
    if (speed >= 1024 * 1024) {
      return '${(speed / (1024 * 1024)).toStringAsFixed(1)} MB/s';
    } else if (speed >= 1024) {
      return '${(speed / 1024).toStringAsFixed(0)} KB/s';
    }
    return '${speed.toStringAsFixed(0)} B/s';
  }

  int _storageUsedBytes = 0;
  int get storageUsedBytes => _storageUsedBytes;
  String get formattedStorageUsed => DownloadItem.formatFileSize(_storageUsedBytes);

  Future<void> refreshStorageUsed() async {
    _storageUsedBytes = await DownloadService().getStorageUsed();
    notifyListeners();
  }

  Future<void> loadDownloads() async {
    final songs = await DownloadService().getDownloadedSongs();
    _downloadedSongs.clear();
    _downloadedSongs.addAll(songs);
    await refreshStorageUsed();
    notifyListeners();
  }

  /// Active Storage Integrity & Sync Engine:
  /// Verifies physical existence of files across all collections (Downloads, Albums, Favorites, History).
  /// Auto-prunes deleted files and syncs all JSON stores.
  Future<void> verifyAndSyncAllStores() async {
    // 1. Download Service Integrity
    await DownloadService().verifyStorageIntegrity();
    final freshDownloads = await DownloadService().getDownloadedSongs();
    _downloadedSongs.clear();
    _downloadedSongs.addAll(freshDownloads);

    // 2. Albums Integrity
    bool albumsChanged = false;
    for (int i = 0; i < _albums.length; i++) {
      final album = _albums[i];
      final validSongs = <Song>[];
      bool songPruned = false;

      for (final song in album.songs) {
        final path = song.filePath ?? (song.isLocalFile ? song.videoId : null);
        if (path == null || path.isEmpty || File(path).existsSync()) {
          validSongs.add(song);
        } else {
          songPruned = true;
          debugPrint('[PlayerProvider] Pruned missing song "${song.title}" from album "${album.name}"');
        }
      }

      if (songPruned) {
        _albums[i] = album.copyWith(songs: validSongs);
        albumsChanged = true;
      }
    }

    if (albumsChanged) {
      await _saveAlbums();
    }

    // 3. Favorites Integrity
    final validFavorites = _favorites.where((song) {
      final path = song.filePath ?? (song.isLocalFile ? song.videoId : null);
      if (path != null && path.isNotEmpty && (song.isLocalFile || path.contains('/') || path.contains('\\'))) {
        return File(path).existsSync();
      }
      return true;
    }).toList();

    if (validFavorites.length != _favorites.length) {
      _favorites.clear();
      _favorites.addAll(validFavorites);
      await _saveFavorites();
    }

    notifyListeners();
  }

  Future<void> updateSongMetadata(
    String videoId,
    String title,
    String artist, {
    double? speed,
    double? pitch,
    double? fadeIn,
    double? fadeOut,
    String? isolationMode,
  }) async {
    await DownloadService().updateSongMetadata(
      videoId,
      title,
      artist,
      speed: speed,
      pitch: pitch,
      fadeIn: fadeIn,
      fadeOut: fadeOut,
      isolationMode: isolationMode,
    );
    await loadDownloads();

    final localIdx = _localDeviceSongs.indexWhere((s) => s.videoId == videoId);
    if (localIdx >= 0) {
      _localDeviceSongs[localIdx] = _localDeviceSongs[localIdx].copyWith(
        title: title,
        artist: artist,
        speed: speed,
        pitch: pitch,
        fadeIn: fadeIn,
        fadeOut: fadeOut,
        isEdited: true,
        isolationMode: isolationMode,
      );
    }

    final recentIdx = _history.indexWhere((e) => e.song.videoId == videoId);
    if (recentIdx >= 0) {
      _history[recentIdx] = HistoryEntry(
        song: _history[recentIdx].song.copyWith(
          title: title,
          artist: artist,
          speed: speed,
          pitch: pitch,
          fadeIn: fadeIn,
          fadeOut: fadeOut,
          isEdited: true,
          isolationMode: isolationMode,
        ),
        playedAt: _history[recentIdx].playedAt,
      );
      await _saveHistory();
    }

    final favIdx = _favorites.indexWhere((s) => s.videoId == videoId);
    if (favIdx >= 0) {
      _favorites[favIdx] = _favorites[favIdx].copyWith(
        title: title,
        artist: artist,
        speed: speed,
        pitch: pitch,
        fadeIn: fadeIn,
        fadeOut: fadeOut,
        isEdited: true,
        isolationMode: isolationMode,
      );
      await _saveFavorites();
    }

    bool albumChanged = false;
    for (int i = 0; i < _albums.length; i++) {
      final sIdx = _albums[i].songs.indexWhere((s) => s.videoId == videoId);
      if (sIdx >= 0) {
        final updatedSongs = List<Song>.from(_albums[i].songs);
        updatedSongs[sIdx] = updatedSongs[sIdx].copyWith(
          title: title,
          artist: artist,
          speed: speed,
          pitch: pitch,
          fadeIn: fadeIn,
          fadeOut: fadeOut,
          isEdited: true,
          isolationMode: isolationMode,
        );
        _albums[i] = _albums[i].copyWith(songs: updatedSongs);
        albumChanged = true;
      }
    }
    if (albumChanged) {
      await _saveAlbums();
    }

    _audioHandler.updatePlaylistSong(
      videoId,
      title,
      artist,
      null,
      speed: speed,
      pitch: pitch,
      fadeIn: fadeIn,
      fadeOut: fadeOut,
    );

    notifyListeners();
  }

  Future<void> updateSongDuration(String videoId, Duration newDuration) async {
    await DownloadService().updateSongDuration(videoId, newDuration);
    await loadDownloads();

    final localIdx = _localDeviceSongs.indexWhere((s) => s.videoId == videoId);
    if (localIdx >= 0) {
      _localDeviceSongs[localIdx] = _localDeviceSongs[localIdx].copyWith(duration: newDuration);
    }

    final recentIdx = _history.indexWhere((e) => e.song.videoId == videoId);
    if (recentIdx >= 0) {
      _history[recentIdx] = HistoryEntry(
        song: _history[recentIdx].song.copyWith(duration: newDuration),
        playedAt: _history[recentIdx].playedAt,
      );
      await _saveHistory();
    }

    final favIdx = _favorites.indexWhere((s) => s.videoId == videoId);
    if (favIdx >= 0) {
      _favorites[favIdx] = _favorites[favIdx].copyWith(duration: newDuration);
      await _saveFavorites();
    }

    bool albumChanged = false;
    for (int i = 0; i < _albums.length; i++) {
      final sIdx = _albums[i].songs.indexWhere((s) => s.videoId == videoId);
      if (sIdx >= 0) {
        final updatedSongs = List<Song>.from(_albums[i].songs);
        updatedSongs[sIdx] = updatedSongs[sIdx].copyWith(duration: newDuration);
        _albums[i] = _albums[i].copyWith(songs: updatedSongs);
        albumChanged = true;
      }
    }
    if (albumChanged) {
      await _saveAlbums();
    }

    String title = '';
    String artist = '';
    final found = _downloadedSongs.firstWhere((s) => s.videoId == videoId, orElse: () => 
      _localDeviceSongs.firstWhere((s) => s.videoId == videoId, orElse: () =>
        _favorites.firstWhere((s) => s.videoId == videoId, orElse: () =>
          _history.map((e) => e.song).firstWhere((s) => s.videoId == videoId, orElse: () =>
            Song(id: '', title: '', artist: '', thumbnailUrl: '', highResThumbnailUrl: '', duration: Duration.zero, videoId: videoId)
          )
        )
      )
    );
    title = found.title;
    artist = found.artist;

    _audioHandler.updatePlaylistSong(videoId, title, artist, newDuration);

    notifyListeners();
  }

  Future<void> saveNewSongCopy(Song originalSong, Song newSong, String sourceFilePath) async {
    await DownloadService().saveNewSongCopy(originalSong, newSong, sourceFilePath);
    await loadDownloads();
    notifyListeners();
  }

  Future<void> downloadSong(Song song, {BuildContext? context}) async {
    if (_downloadProgress.containsKey(song.videoId)) return;
    _downloadProgress[song.videoId] = 0.01;
    notifyListeners();

    if (context != null && context.mounted) {
      AppToast.show(context, 'Downloading "${song.title}"...', type: ToastType.info);
    }

    try {
      await DownloadService().downloadSong(song, (progress) {
        _downloadProgress[song.videoId] = progress;
        notifyListeners();
      }, onStateChanged: () {
        notifyListeners();
      }, quality: _audioQuality);
      _downloadProgress.remove(song.videoId);
      await loadDownloads();
      if (context != null && context.mounted) {
        AppToast.show(context, 'Downloaded "${song.title}" for offline playback!', type: ToastType.success);
      }
    } catch (e) {
      _downloadProgress.remove(song.videoId);
      notifyListeners();
      debugPrint('Error downloading song in provider: $e');
      if (context != null && context.mounted) {
        final errText = e.toString().replaceAll('Exception:', '').trim();
        AppToast.show(context, 'Failed to download "${song.title}": $errText', type: ToastType.warning);
      }
    }
  }

  void pauseDownload(String videoId) {
    DownloadService().pauseDownload(videoId);
    notifyListeners();
  }

  void resumeDownload(String videoId) {
    DownloadService().resumeDownload(videoId);
    notifyListeners();
  }

  Future<void> cancelDownload(String videoId) async {
    await DownloadService().cancelDownload(videoId);
    _downloadProgress.remove(videoId);
    notifyListeners();
  }

  Future<void> cancelAllDownloads() async {
    await DownloadService().cancelAllDownloads();
    _downloadProgress.clear();
    notifyListeners();
  }

  Future<void> retryDownload(Song song) async {
    // Remove failed task then re-enqueue
    await DownloadService().cancelDownload(song.videoId);
    _downloadProgress.remove(song.videoId);
    notifyListeners();
    await downloadSong(song);
  }

  Future<void> deleteDownload(String videoId) async {
    await DownloadService().deleteSong(videoId);
    await verifyAndSyncAllStores();
  }

  // Recently deleted for undo support
  Song? _lastDeletedSong;
  Song? get lastDeletedSong => _lastDeletedSong;

  Future<void> deleteDownloadWithUndo(String videoId) async {
    _lastDeletedSong = _downloadedSongs.firstWhere(
      (s) => s.videoId == videoId,
      orElse: () => _downloadedSongs.first,
    );
    await deleteDownload(videoId);
  }

  Future<void> undoDelete() async {
    if (_lastDeletedSong != null) {
      // Re-download the song
      await downloadSong(_lastDeletedSong!);
      _lastDeletedSong = null;
    }
  }

  Future<void> deleteAllDownloads() async {
    await DownloadService().deleteAllDownloads();
    await loadDownloads();
  }

  /// Auto-pause when network drops
  void onNetworkLost() {
    DownloadService().pauseAllDownloads();
    notifyListeners();
  }

  /// Auto-resume when network returns
  void onNetworkRestored() {
    DownloadService().resumeAllDownloads();
    notifyListeners();
  }

  // Favorites Management

  List<Song> get favorites => List.unmodifiable(_favorites);

  bool isFavorite(String videoId) {
    return _favorites.any((s) => s.videoId == videoId);
  }

  Future<void> toggleFavorite(Song song) async {
    final idx = _favorites.indexWhere((s) => s.videoId == song.videoId);
    if (idx >= 0) {
      _favorites.removeAt(idx);
    } else {
      _favorites.add(song);
    }
    notifyListeners();
    await _saveFavorites();
  }

  Future<void> _loadFavorites() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final jsonString = prefs.getString(_favoritesKey);
      if (jsonString != null) {
        final List<dynamic> jsonList = json.decode(jsonString);
        _favorites.clear();
        _favorites.addAll(
          jsonList.map((j) => Song.fromJson(j as Map<String, dynamic>)).toList(),
        );
        notifyListeners();
      }
    } catch (e) {
      debugPrint('Error loading favorites: $e');
    }
  }

  Future<void> _saveFavorites() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final jsonString = json.encode(
        _favorites.map((s) => s.toJson()).toList(),
      );
      await prefs.setString(_favoritesKey, jsonString);
    } catch (e) {
      debugPrint('Error saving favorites: $e');
    }
  }

  // History clearing method
  Future<void> clearHistory() async {
    _history.clear();
    notifyListeners();
    await _saveHistory();
  }

  // Albums Management
  List<UserAlbum> get albums => List.unmodifiable(_albums);

  Future<void> _loadAlbums() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final jsonString = prefs.getString(_albumsKey);
      if (jsonString != null) {
        final List<dynamic> jsonList = json.decode(jsonString);
        _albums.clear();
        _albums.addAll(
          jsonList.map((j) => UserAlbum.fromJson(j as Map<String, dynamic>)).toList(),
        );
      } else {
        // First run: clean initialization with no pre-defined albums.
        // Albums are created dynamically via AI Smart Organize or manually by the user.
        _albums.clear();
        await _saveAlbums();
      }
      notifyListeners();
    } catch (e) {
      debugPrint('Error loading albums: $e');
    }
  }

  Future<void> _saveAlbums() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final jsonString = json.encode(
        _albums.map((a) => a.toJson()).toList(),
      );
      await prefs.setString(_albumsKey, jsonString);
    } catch (e) {
      debugPrint('Error saving albums: $e');
    }
  }

  Future<UserAlbum> createAlbum(String name, {bool isCustom = true}) async {
    String? folderPath;
    bool isFolderBased = false;

    final storageService = StorageLocationService();
    await storageService.initialize();
    if (storageService.storageType != StorageType.appInternal) {
      try {
        final albumDir = await storageService.getAlbumDir(name);
        folderPath = albumDir.path;
        isFolderBased = true;
      } catch (e) {
        debugPrint('Error creating physical album folder: $e');
      }
    }

    final newAlbum = UserAlbum(
      id: DateTime.now().millisecondsSinceEpoch.toString(),
      name: name,
      songs: [],
      isCustom: isCustom,
      folderPath: folderPath,
      isFolderBased: isFolderBased,
    );
    _albums.add(newAlbum);
    notifyListeners();
    await _saveAlbums();
    return newAlbum;
  }

  Future<void> deleteAlbumWithProtection(
    String id, {
    String? targetAlbumId,
    bool moveToRecovery = true,
  }) async {
    final idx = _albums.indexWhere((a) => a.id == id);
    if (idx < 0) return;
    final album = _albums[idx];

    // Option A: User chose to batch-move songs to another existing album
    if (targetAlbumId != null && targetAlbumId.isNotEmpty) {
      final targetIdx = _albums.indexWhere((a) => a.id == targetAlbumId);
      if (targetIdx >= 0) {
        final targetAlbum = _albums[targetIdx];
        final updatedSongs = List<Song>.from(targetAlbum.songs);
        for (final song in album.songs) {
          if (!updatedSongs.any((s) => s.videoId == song.videoId)) {
            updatedSongs.add(song);
          }
        }
        _albums[targetIdx] = targetAlbum.copyWith(songs: updatedSongs);
      }
    } else if (moveToRecovery) {
      // Option B: "Do anyway" — move physical files into hidden recovery backup folder
      try {
        final docsDir = await getApplicationDocumentsDirectory();
        final recoveryDir = Directory('${docsDir.path}${Platform.pathSeparator}sonicwave${Platform.pathSeparator}.recovery');
        if (!await recoveryDir.exists()) {
          await recoveryDir.create(recursive: true);
        }

        for (final song in album.songs) {
          final srcPath = song.filePath ?? (song.isLocalFile ? song.videoId : null);
          if (srcPath != null && srcPath.isNotEmpty && File(srcPath).existsSync()) {
            try {
              await StorageLocationService().moveFile(srcPath, recoveryDir);
            } catch (_) {}
          }
        }
      } catch (e) {
        debugPrint('Error moving deleted album songs to recovery: $e');
      }
    }

    // Clean up empty folder if folder-based
    if (album.isFolderBased && album.folderPath != null) {
      try {
        final dir = Directory(album.folderPath!);
        if (await dir.exists()) {
          final list = await dir.list().toList();
          if (list.isEmpty) {
            await dir.delete();
          }
        }
      } catch (_) {}
    }

    _albums.removeAt(idx);
    notifyListeners();
    await _saveAlbums();
  }

  Future<void> deleteAlbum(String id) async {
    await deleteAlbumWithProtection(id, moveToRecovery: true);
  }

  Future<void> updateAlbumCover(String albumId, String? imagePath) async {
    final idx = _albums.indexWhere((a) => a.id == albumId);
    if (idx < 0) return;
    final album = _albums[idx];

    // Evict old image from Flutter PaintingBinding imageCache
    if (album.coverImagePath != null) {
      try {
        await FileImage(File(album.coverImagePath!)).evict();
      } catch (_) {}
    }
    try {
      PaintingBinding.instance.imageCache.clear();
      PaintingBinding.instance.imageCache.clearLiveImages();
    } catch (_) {}

    String? coverPath;

    if (imagePath == null) {
      // User removed album cover
      if (album.coverImagePath != null) {
        try {
          final oldFile = File(album.coverImagePath!);
          if (await oldFile.exists()) {
            await oldFile.delete();
          }
        } catch (e) {
          debugPrint('Error deleting physical cover image: $e');
        }
      }
      coverPath = null;
    } else {
      try {
        final sourceFile = File(imagePath);
        if (await sourceFile.exists()) {
          final timestamp = DateTime.now().millisecondsSinceEpoch;

          if (album.isFolderBased && album.folderPath != null) {
            // Remove previous cover_*.jpg or cover.jpg files in album directory
            try {
              final albumDir = Directory(album.folderPath!);
              if (await albumDir.exists()) {
                await for (final entity in albumDir.list()) {
                  if (entity is File) {
                    final name = entity.path.split(Platform.pathSeparator).last.toLowerCase();
                    if (name.startsWith('cover') && (name.endsWith('.jpg') || name.endsWith('.jpeg') || name.endsWith('.png'))) {
                      try {
                        await entity.delete();
                      } catch (_) {}
                    }
                  }
                }
              }
            } catch (_) {}

            final targetPath = '${album.folderPath}${Platform.pathSeparator}cover_$timestamp.jpg';
            final copied = await sourceFile.copy(targetPath);
            coverPath = copied.path;
          } else {
            // Custom virtual album cover saved into meta directory
            final metaDir = await StorageLocationService().getMetaDir();
            final targetPath = '${metaDir.path}${Platform.pathSeparator}album_${album.id}_$timestamp.jpg';

            if (album.coverImagePath != null) {
              try {
                final oldFile = File(album.coverImagePath!);
                if (await oldFile.exists()) {
                  await oldFile.delete();
                }
              } catch (_) {}
            }

            final copied = await sourceFile.copy(targetPath);
            coverPath = copied.path;
          }

          try {
            await FileImage(File(coverPath)).evict();
          } catch (_) {}
        }
      } catch (e) {
        debugPrint('Error copying cover image to album folder: $e');
      }
    }

    _albums[idx] = album.copyWith(
      coverImagePath: coverPath,
      clearCoverImage: coverPath == null,
      lastUpdated: DateTime.now(),
    );

    notifyListeners();
    await _saveAlbums();
  }

  Future<void> updateAlbumSongs(String albumId, List<Song> songs) async {
    final idx = _albums.indexWhere((a) => a.id == albumId);
    if (idx >= 0) {
      final album = _albums[idx];
      final List<Song> finalSongs = [];
      
      for (final song in songs) {
        if (album.isFolderBased && album.folderPath != null) {
          final sourcePath = song.filePath ?? (song.isLocalFile ? song.videoId : null);
          if (sourcePath != null && await File(sourcePath).exists()) {
            final fileName = sourcePath.split(Platform.pathSeparator).last;
            final expectedPath = '${album.folderPath}${Platform.pathSeparator}$fileName';
            
            if (sourcePath != expectedPath && !await File(expectedPath).exists()) {
              final storageService = StorageLocationService();
              final albumDir = Directory(album.folderPath!);
              final newPath = await storageService.moveFile(sourcePath, albumDir);
              if (newPath != null) {
                final updatedSong = song.copyWith(
                  filePath: newPath,
                  albumFolderName: album.name,
                );
                finalSongs.add(updatedSong);
                
                // Keep download service metadata in sync
                await DownloadService().updateDownloadedSong(updatedSong);
                continue;
              }
            }
          }
        }
        finalSongs.add(song);
      }

      _albums[idx] = _albums[idx].copyWith(
        songs: finalSongs,
        lastUpdated: DateTime.now(),
      );
      notifyListeners();
      await _saveAlbums();
    }
  }

  Future<void> addSongToAlbum(String albumId, Song song) async {
    final idx = _albums.indexWhere((a) => a.id == albumId);
    if (idx >= 0) {
      final album = _albums[idx];
      if (!album.songs.any((s) => s.videoId == song.videoId)) {
        Song finalSong = song;
        
        if (album.isFolderBased && album.folderPath != null) {
          final sourcePath = song.filePath ?? (song.isLocalFile ? song.videoId : null);
          if (sourcePath != null && await File(sourcePath).exists()) {
            final storageService = StorageLocationService();
            final albumDir = Directory(album.folderPath!);
            final newPath = await storageService.moveFile(sourcePath, albumDir);
            if (newPath != null) {
              finalSong = song.copyWith(
                filePath: newPath,
                albumFolderName: album.name,
              );
              // Keep download service metadata in sync
              await DownloadService().updateDownloadedSong(finalSong);
            }
          }
        }
        
        final updatedSongs = List<Song>.from(album.songs)..add(finalSong);
        await updateAlbumSongs(albumId, updatedSongs);
      }
    }
  }

  /// Physically or logically move or copy a song file to another album's folder.
  Future<bool> moveSongToAnotherAlbumFolder(Song song, String targetAlbumId, {required bool physicalMove, bool isCopyMode = false}) async {
    final albumIdx = _albums.indexWhere((a) => a.id == targetAlbumId);
    if (albumIdx < 0) return false;
    final targetAlbum = _albums[albumIdx];

    String? newPath = song.filePath;

    if (physicalMove) {
      if (targetAlbum.folderPath == null) return false;
      final sourcePath = song.filePath ?? (song.isLocalFile ? song.videoId : null);
      if (sourcePath == null) return false;

      final sourceFile = File(sourcePath);
      if (!await sourceFile.exists()) return false;

      final storageService = StorageLocationService();
      final targetDir = Directory(targetAlbum.folderPath!);
      
      if (isCopyMode) {
        // "Make a Copy": duplicate into target album while preserving original
        newPath = await storageService.copyFile(sourcePath, targetDir);
      } else {
        // "Permanently Move": physically transfer file to destination folder
        newPath = await storageService.moveFile(sourcePath, targetDir);
      }
      if (newPath == null) return false;
    }

    // Update the song's filePath and albumFolderName
    final updatedSong = isCopyMode
        ? song.copyWith(
            id: 'copy_${DateTime.now().millisecondsSinceEpoch}_${song.id}',
            videoId: newPath ?? song.videoId,
            filePath: newPath,
            albumFolderName: targetAlbum.name,
          )
        : song.copyWith(
            filePath: newPath,
            albumFolderName: targetAlbum.name,
          );

    // 1. Remove the old song reference from its previous folder album if any (only on move)
    if (!isCopyMode && song.albumFolderName != null) {
      final oldAlbumIdx = _albums.indexWhere((a) => a.name == song.albumFolderName);
      if (oldAlbumIdx >= 0) {
        final oldAlbum = _albums[oldAlbumIdx];
        final updatedOldSongs = oldAlbum.songs.where((s) => s.videoId != song.videoId).toList();
        _albums[oldAlbumIdx] = oldAlbum.copyWith(songs: updatedOldSongs, lastUpdated: DateTime.now());
      }
    }

    // 2. Add the updated song to the target album
    if (!targetAlbum.songs.any((s) => s.videoId == updatedSong.videoId)) {
      final updatedTargetSongs = List<Song>.from(targetAlbum.songs)..add(updatedSong);
      _albums[albumIdx] = targetAlbum.copyWith(songs: updatedTargetSongs, lastUpdated: DateTime.now());
    }

    if (!isCopyMode) {
      // 3. Update the download list if it is tracked as a download
      final downloadIdx = _downloadedSongs.indexWhere((s) => s.videoId == song.videoId);
      if (downloadIdx >= 0) {
        _downloadedSongs[downloadIdx] = updatedSong;
      }
      
      // 4. Update the local scanned list if it is scanned
      final localIdx = _localDeviceSongs.indexWhere((s) => s.videoId == song.videoId);
      if (localIdx >= 0) {
        _localDeviceSongs[localIdx] = updatedSong;
      }

      // 5. Update download service if physical move happened
      if (physicalMove && newPath != null) {
        await DownloadService().updateDownloadedSong(updatedSong);
      }
    }

    notifyListeners();
    await _saveAlbums();
    return true;
  }

  List<Song> _localDeviceSongs = [];
  bool _isScanningLocal = false;
  bool _hasStoragePermission = false;
  final Set<String> _sessionNewSongIds = {};

  List<Song> get localDeviceSongs => _localDeviceSongs;
  bool get isScanningLocal => _isScanningLocal;
  bool get hasStoragePermission => _hasStoragePermission;
  
  bool isNewInSession(Song song) {
    return _sessionNewSongIds.contains(song.videoId) || _sessionNewSongIds.contains(song.id);
  }

  List<Song> get localSongsMerged {
    final List<Song> merged = [];
    final Set<String> paths = {};

    for (final song in _downloadedSongs) {
      merged.add(song);
      paths.add(song.videoId);
    }

    for (final song in _localDeviceSongs) {
      if (!paths.contains(song.videoId) && !paths.contains(song.id)) {
        merged.add(song);
        paths.add(song.videoId);
      }
    }
    return merged;
  }

  Future<void> _scanDirRecursive(Directory dir, List<Song> foundSongs, Set<String> visited) async {
    final path = dir.path;
    if (visited.contains(path)) return;
    visited.add(path);

    // Skip hidden folders and Android system directories to optimize scan speed and avoid permissions crashes
    final name = path.split(Platform.isWindows ? '\\' : '/').last.toLowerCase();
    if (name.startsWith('.') || name == 'android' || name == 'cache' || name == 'temp') {
      return;
    }

    try {
      await for (final entity in dir.list(followLinks: false)) {
        if (entity is File) {
          final ext = entity.path.split('.').last.toLowerCase();
          final supportedExts = {'mp3', 'm4a', 'wav', 'flac', 'aac', 'ogg', 'opus', 'wma', 'aiff', 'aif', 'alac', 'mka', 'amr', 'm4b'};
          if (supportedExts.contains(ext)) {
            final filename = entity.uri.pathSegments.last;
            final nameWithoutExt = filename.contains('.')
                ? filename.substring(0, filename.lastIndexOf('.'))
                : filename;
            String title = nameWithoutExt;
            String artist = 'Local Audio';
            if (nameWithoutExt.contains('-')) {
              final parts = nameWithoutExt.split('-');
              artist = parts[0].trim();
              title = parts.sublist(1).join('-').trim();
            }

            foundSongs.add(Song(
              id: entity.path,
              title: title,
              artist: artist,
              thumbnailUrl: '',
              highResThumbnailUrl: '',
              duration: const Duration(minutes: 3),
              videoId: entity.path,
              filePath: entity.path,
            ));
          }
        } else if (entity is Directory) {
          await _scanDirRecursive(entity, foundSongs, visited);
        }
      }
    } catch (e) {
      debugPrint('Error scanning dir $path: $e');
    }
  }

  Future<void> scanLocalSongs() async {
    _isScanningLocal = true;
    notifyListeners();

    try {
      if (Platform.isAndroid) {
        if (await Permission.audio.request().isGranted) {
          _hasStoragePermission = true;
        } else if (await Permission.storage.request().isGranted) {
          _hasStoragePermission = true;
        } else {
          _hasStoragePermission = false;
        }
      } else {
        _hasStoragePermission = true;
      }

      if (!_hasStoragePermission) {
        _isScanningLocal = false;
        notifyListeners();
        return;
      }

      // Track existing known paths before scan to tag new items
      final previousPaths = _localDeviceSongs.map((s) => s.filePath ?? s.videoId).toSet();

      final List<Song> foundSongs = [];
      final Set<String> pathsToScan = {};

      if (Platform.isAndroid) {
        // Internal storage root
        pathsToScan.add('/storage/emulated/0');
        pathsToScan.add('/sdcard');

        // Dynamically probe for external SD cards mounted inside /storage
        final storageDir = Directory('/storage');
        if (await storageDir.exists()) {
          try {
            await for (final entity in storageDir.list(followLinks: false)) {
              if (entity is Directory) {
                final name = entity.path.split('/').last;
                if (name != 'self' && name != 'emulated') {
                  pathsToScan.add(entity.path);
                }
              }
            }
          } catch (_) {}
        }

        try {
          final extDirs = await getExternalStorageDirectories(type: StorageDirectory.music);
          if (extDirs != null) {
            for (final dir in extDirs) {
              pathsToScan.add(dir.path);
            }
          }
        } catch (_) {}
      }

      try {
        final docDir = await getApplicationDocumentsDirectory();
        pathsToScan.add(docDir.path);
      } catch (_) {}

      final Set<String> visited = {};
      for (final path in pathsToScan) {
        final dir = Directory(path);
        if (await dir.exists()) {
          await _scanDirRecursive(dir, foundSongs, visited);
        }
      }

      // Identify newly discovered tracks for session badge tagging
      for (final song in foundSongs) {
        final path = song.filePath ?? song.videoId;
        if (!previousPaths.contains(path)) {
          _sessionNewSongIds.add(song.videoId);
          _sessionNewSongIds.add(song.id);
        }
      }

      // Incremental enrich & cached metadata lookup
      _localDeviceSongs = await LocalMetadataService().enrichSongs(foundSongs);

      // Auto-detect folder-based albums in the app's root directory
      await _syncFolderAlbums();
      await verifyAndSyncAllStores();
    } catch (e) {
      debugPrint('Error in scanLocalSongs: $e');
    } finally {
      _isScanningLocal = false;
      notifyListeners();
    }
  }

  /// Migrate existing downloaded files, physical album folders, cover artwork, and metadata to the new storage location.
  Future<bool> migrateDownloadedFiles(StorageType currentType, StorageType targetType, {String? sdCardPath}) async {
    try {
      final storageService = StorageLocationService();
      await storageService.setStorageType(currentType);
      final oldRootDir = await storageService.getAppRootDir();

      // Temporarily switch configuration to resolve target root
      await storageService.setStorageType(targetType, sdCardPath: sdCardPath);
      final newRootDir = await storageService.getAppRootDir();

      // Revert configuration back during initial copy phase
      await storageService.setStorageType(currentType);

      final oldRootPath = oldRootDir.path.replaceAll('\\', '/');
      final newRootPath = newRootDir.path.replaceAll('\\', '/');

      if (oldRootPath == newRootPath) return true;

      // 1. Recursively copy all files, custom album folders, and metadata to the new target root
      if (await oldRootDir.exists()) {
        await _copyDirectoryRecursive(oldRootDir, newRootDir);
        try {
          await oldRootDir.delete(recursive: true);
        } catch (e) {
          debugPrint('Error deleting old root directory: $e');
        }
      }

      // 2. Permanently update StorageLocationService configuration
      await storageService.setStorageType(targetType, sdCardPath: sdCardPath);

      // Helper to update file paths
      String updatePath(String originalPath) {
        final normOriginal = originalPath.replaceAll('\\', '/');
        if (normOriginal.startsWith(oldRootPath)) {
          return normOriginal.replaceFirst(oldRootPath, newRootPath);
        }
        return originalPath;
      }

      // 3. Synchronize in-memory paths for Downloaded Songs
      for (int i = 0; i < _downloadedSongs.length; i++) {
        final s = _downloadedSongs[i];
        if (s.filePath != null) {
          final newPath = updatePath(s.filePath!);
          String newThumb = s.thumbnailUrl;
          if (newThumb.isNotEmpty && !newThumb.startsWith('http')) {
            newThumb = updatePath(newThumb);
          }
          _downloadedSongs[i] = s.copyWith(
            filePath: newPath,
            thumbnailUrl: newThumb,
            highResThumbnailUrl: newThumb,
          );
        }
      }

      // 4. Synchronize in-memory paths for User Albums
      for (int i = 0; i < _albums.length; i++) {
        final album = _albums[i];
        String? newFolderPath = album.folderPath != null ? updatePath(album.folderPath!) : null;
        String? newCoverPath = album.coverImagePath != null ? updatePath(album.coverImagePath!) : null;

        final updatedSongs = album.songs.map((s) {
          if (s.filePath != null) {
            return s.copyWith(filePath: updatePath(s.filePath!));
          }
          return s;
        }).toList();

        _albums[i] = album.copyWith(
          folderPath: newFolderPath,
          coverImagePath: newCoverPath,
          songs: updatedSongs,
        );
      }

      // 5. Synchronize in-memory paths for Favorites
      for (int i = 0; i < _favorites.length; i++) {
        final s = _favorites[i];
        if (s.filePath != null) {
          _favorites[i] = s.copyWith(filePath: updatePath(s.filePath!));
        }
      }

      // 6. Save metadata to the new location and sync JSON stores
      await DownloadService().updateAllSongPaths(_downloadedSongs);
      await _saveAlbums();
      await _saveFavorites();
      await verifyAndSyncAllStores();

      notifyListeners();
      return true;
    } catch (e) {
      debugPrint('Error in migrateDownloadedFiles: $e');
      return false;
    }
  }

  Future<void> _copyDirectoryRecursive(Directory source, Directory destination) async {
    if (!await destination.exists()) {
      await destination.create(recursive: true);
    }
    await for (final entity in source.list(followLinks: false)) {
      final name = entity.uri.pathSegments.where((s) => s.isNotEmpty).last;
      final newPath = '${destination.path}${Platform.pathSeparator}$name';
      if (entity is Directory) {
        await _copyDirectoryRecursive(entity, Directory(newPath));
      } else if (entity is File) {
        final newFile = File(newPath);
        if (!await newFile.parent.exists()) {
          await newFile.parent.create(recursive: true);
        }
        await entity.copy(newPath);
      }
    }
  }

  /// Synchronize folder-based albums from the app's storage directory.
  ///
  /// Each subfolder in the SonicWave root (excluding Downloads) containing audio
  /// files is treated as a folder-based album. Manually created folders by the
  /// user are auto-detected here.
  Future<void> _syncFolderAlbums() async {
    try {
      final storageService = StorageLocationService();
      await storageService.initialize();

      // Only scan for folder albums if using external storage
      if (storageService.storageType == StorageType.appInternal) return;

      final folderAlbums = await storageService.scanFolderAlbums();

      for (final folderInfo in folderAlbums) {
        // Check if this folder album already exists
        final existingIdx = _albums.indexWhere(
          (a) => a.folderPath == folderInfo.folderPath || 
                 (a.isFolderBased && a.name == folderInfo.folderName),
        );

        // Build Song objects for the folder's audio files
        final folderSongs = folderInfo.audioFilePaths.map((audioPath) {
          final filename = audioPath.split(Platform.pathSeparator).last;
          final nameWithoutExt = filename.contains('.')
              ? filename.substring(0, filename.lastIndexOf('.'))
              : filename;
          String title = nameWithoutExt;
          String artist = 'Local Audio';
          if (nameWithoutExt.contains('-')) {
            final parts = nameWithoutExt.split('-');
            artist = parts[0].trim();
            title = parts.sublist(1).join('-').trim();
          }
          return Song(
            id: audioPath,
            title: title,
            artist: artist,
            thumbnailUrl: '',
            highResThumbnailUrl: '',
            duration: const Duration(minutes: 3),
            videoId: audioPath,
            filePath: audioPath,
            albumFolderName: folderInfo.folderName,
          );
        }).toList();

        final enrichedFolderSongs = await LocalMetadataService().enrichSongs(folderSongs);

        if (existingIdx >= 0) {
          // Update existing folder album with current files
          _albums[existingIdx] = _albums[existingIdx].copyWith(
            songs: enrichedFolderSongs,
            folderPath: folderInfo.folderPath,
            isFolderBased: true,
          );
        } else {
          // Create new folder-based album
          _albums.add(UserAlbum(
            id: 'folder_${folderInfo.folderName.hashCode.abs()}',
            name: folderInfo.folderName,
            songs: enrichedFolderSongs,
            isCustom: false,
            folderPath: folderInfo.folderPath,
            isFolderBased: true,
          ));
        }
      }

      await _saveAlbums();
    } catch (e) {
      debugPrint('Error syncing folder albums: $e');
    }
  }

  // ===== Smart Delete System =====

  /// Determine the delete type for a song.
  ///
  /// - [DeleteType.permanent] — file is in the app-created folder, can be truly deleted
  /// - [DeleteType.memoryOnly] — file is an external reference, only remove metadata
  Future<DeleteType> getDeleteType(Song song) async {
    final isInAppFolder = await DownloadService().isFileInAppFolder(song);
    return isInAppFolder ? DeleteType.permanent : DeleteType.memoryOnly;
  }

  /// Permanently delete a song — removes the physical file from disk AND metadata.
  ///
  /// Only use when the file is inside the app-managed folder.
  Future<void> deleteSongPermanently(Song song) async {
    // Delete the physical file
    final filePath = song.filePath ?? song.videoId;
    try {
      final file = File(filePath);
      if (await file.exists()) {
        await file.delete();
      }
    } catch (e) {
      debugPrint('Error deleting physical file: $e');
    }

    // Remove from all metadata stores
    await _removeSongFromAllStores(song.videoId);
    await loadDownloads();
  }

  /// Remove a song from memory only — the physical file stays on disk.
  ///
  /// Used for externally-scanned songs that are just referenced.
  Future<void> deleteSongMemory(Song song) async {
    await _removeSongFromAllStores(song.videoId);
    _localDeviceSongs.removeWhere((s) => s.videoId == song.videoId);
    notifyListeners();
  }

  /// Helper to remove a song from downloads, favorites, albums, and history
  Future<void> _removeSongFromAllStores(String videoId) async {
    // Remove from downloads service
    await DownloadService().deleteSong(videoId);

    // Remove from favorites
    _favorites.removeWhere((s) => s.videoId == videoId);
    await _saveFavorites();

    // Remove from history
    _history.removeWhere((e) => e.song.videoId == videoId);
    await _saveHistory();

    // Remove from albums
    bool albumChanged = false;
    for (int i = 0; i < _albums.length; i++) {
      final before = _albums[i].songs.length;
      final updatedSongs = _albums[i].songs.where((s) => s.videoId != videoId).toList();
      if (updatedSongs.length != before) {
        _albums[i] = _albums[i].copyWith(songs: updatedSongs);
        albumChanged = true;
      }
    }
    if (albumChanged) await _saveAlbums();

    notifyListeners();
  }

  // ===== Move to App Folder =====

  /// Move scanned songs into the app's storage folder, optionally into an album subfolder.
  Future<List<Song>> moveScannedSongsToAppFolder(List<Song> songs, {String? albumName}) async {
    final movedSongs = await DownloadService().moveAllToAppFolder(songs, albumName: albumName);
    await loadDownloads();

    // If album name specified, update or create the album
    if (albumName != null && movedSongs.isNotEmpty) {
      final existingIdx = _albums.indexWhere((a) => a.name == albumName);
      if (existingIdx >= 0) {
        final existingAlbum = _albums[existingIdx];
        final mergedSongs = List<Song>.from(existingAlbum.songs);
        for (final song in movedSongs) {
          if (!mergedSongs.any((s) => s.videoId == song.videoId)) {
            mergedSongs.add(song);
          }
        }
        _albums[existingIdx] = existingAlbum.copyWith(songs: mergedSongs);
      } else {
        final storageService = StorageLocationService();
        final albumDir = await storageService.getAlbumDir(albumName);
        _albums.add(UserAlbum(
          id: 'folder_${albumName.hashCode.abs()}',
          name: albumName,
          songs: movedSongs,
          isCustom: true,
          folderPath: albumDir.path,
          isFolderBased: true,
        ));
      }
      await _saveAlbums();
    }

    notifyListeners();
    return movedSongs;
  }

  /// Move a single downloaded song into an album folder
  Future<void> moveSongToAlbumFolder(String videoId, String albumName) async {
    final newPath = await DownloadService().moveFileToAlbumFolder(videoId, albumName);
    if (newPath != null) {
      await loadDownloads();
      notifyListeners();
    }
  }

  @override
  void dispose() {
    _sleepTimer?.cancel();
    _countdownTimer?.cancel();
    super.dispose();
  }
}

class HistoryEntry {
  final Song song;
  final DateTime playedAt;

  HistoryEntry({required this.song, required this.playedAt});

  Map<String, dynamic> toJson() => {
    'song': song.toJson(),
    'playedAt': playedAt.toIso8601String(),
  };

  factory HistoryEntry.fromJson(Map<String, dynamic> json) => HistoryEntry(
    song: Song.fromJson(json['song']),
    playedAt: DateTime.parse(json['playedAt']),
  );
}
