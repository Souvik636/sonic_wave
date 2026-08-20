import 'package:audio_service/audio_service.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
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
import '../services/download_notification_service.dart';
import '../services/local_metadata_service.dart';
import '../services/recommendation_engine.dart';
import '../services/stream_cache_service.dart';
import '../widgets/app_toast.dart';
import 'settings_provider.dart';

/// Type of delete action available for a song
enum DeleteType {
  /// File is inside the app-managed folder — can be permanently deleted from disk
  permanent,

  /// File is an external reference — only remove from app memory/metadata
  memoryOnly,
}

/// Where a link shared into the app has got to.
///
/// A share is the one download the user cannot watch: it starts from another
/// app's share sheet, so there is no song tile to grow a progress ring and no
/// screen the user chose to be on. The phase is what the floating card renders,
/// which is the only feedback this flow has.
enum SharedDownloadPhase {
  /// Reading the video's title/artist/artwork. No progress to report yet.
  resolving,

  /// Bytes are moving; [SharedDownloadStatus.progress] is meaningful.
  downloading,

  /// Held because the device is offline. Not terminal: the link is kept and
  /// retried the moment connectivity comes back.
  ///
  /// A share arrives from another app, is usually abandoned immediately, and
  /// cannot be re-fired without going back to YouTube and sharing again — so
  /// failing it outright the instant the network happened to be down threw
  /// away the user's request for a condition that typically clears in seconds.
  waitingForNetwork,

  /// Saved to Downloads. Terminal, offers Play.
  done,

  /// Gave up. Terminal, offers Retry unless the share had no link at all.
  failed,

  /// Nothing to do — the song is already downloading, or already downloaded.
  duplicate,
}

/// Immutable snapshot of the shared-link download, rendered by
/// `SharedLinkDownloadCard`.
@immutable
class SharedDownloadStatus {
  final SharedDownloadPhase phase;

  /// Always known: it comes from the shared link itself, before any lookup.
  final String videoId;

  /// Null until the video's details resolve — the card shows a shimmer in the
  /// artwork slot until then rather than a title it had to invent.
  final Song? song;

  /// 0..1, meaningful in [SharedDownloadPhase.downloading].
  final double progress;

  /// Why it failed, or why there was nothing to do. Shown verbatim.
  final String? message;

  /// False for a share that contained no link: there is nothing to retry, so
  /// offering the button would be a dead end.
  final bool canRetry;

  const SharedDownloadStatus({
    required this.phase,
    required this.videoId,
    this.song,
    this.progress = 0.0,
    this.message,
    this.canRetry = true,
  });

  bool get isTerminal =>
      phase == SharedDownloadPhase.done ||
      phase == SharedDownloadPhase.failed ||
      phase == SharedDownloadPhase.duplicate;

  /// True while the download can still be called off. A queued share counts:
  /// the user must be able to abandon a share that is waiting on a network
  /// that may not come back for hours.
  bool get isCancellable =>
      phase == SharedDownloadPhase.resolving ||
      phase == SharedDownloadPhase.downloading ||
      phase == SharedDownloadPhase.waitingForNetwork;

  SharedDownloadStatus copyWith({
    SharedDownloadPhase? phase,
    Song? song,
    double? progress,
    String? message,
    bool? canRetry,
  }) {
    return SharedDownloadStatus(
      phase: phase ?? this.phase,
      videoId: videoId,
      song: song ?? this.song,
      progress: progress ?? this.progress,
      message: message ?? this.message,
      canRetry: canRetry ?? this.canRetry,
    );
  }
}

class PlayerProvider extends ChangeNotifier {
  final SonicWaveAudioHandler _audioHandler;
  final List<HistoryEntry> _history = [];
  final List<Song> _downloadedSongs = [];
  final List<Song> _favorites = [];
  final List<UserAlbum> _albums = [];
  final Map<String, double> _downloadProgress = {};

  /// State of the link most recently shared into the app, or null when there is
  /// nothing to show. Only one is tracked: a share is a foreground, one-at-a-time
  /// gesture, and stacking cards would bury the newest under the oldest.
  SharedDownloadStatus? _sharedDownload;
  SharedDownloadStatus? get sharedDownload => _sharedDownload;

  /// Push a new shared-download state to the card.
  void _setSharedDownload(SharedDownloadStatus? status) {
    _sharedDownload = status;
    notifyListeners();
  }

  /// Take the card down. Called by its dismiss gesture, its auto-dismiss timer,
  /// and by a fresh share replacing whatever was on screen.
  void dismissSharedDownload() {
    if (_sharedDownload == null) return;
    _setSharedDownload(null);
  }

  /// Test seam: put the card into a given phase without a network round-trip.
  /// Every phase but `failed` is otherwise only reachable through a real
  /// download, which a widget test cannot run.
  @visibleForTesting
  void debugSetSharedDownload(SharedDownloadStatus? status) =>
      _setSharedDownload(status);

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

  // Stream subscriptions — cancelled in dispose().
  StreamSubscription<PlaybackState>? _playbackStateSub;
  StreamSubscription<MediaItem?>? _mediaItemSub;
  StreamSubscription<ProcessingState>? _processingStateSub;

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
    _loadLocalDeviceSongs();
    _initFileIntentListener();

    _audioHandler.onQueueNearEnd = () {
      checkAutoRecommendation();
    };

    // When the 8-minute idle timer fires, save session state and refresh UI
    // BEFORE the audio handler tears down the notification and queue.
    _audioHandler.onIdleTimeout = () {
      debugPrint('[PlayerProvider] Idle timeout — saving session and refreshing UI');
      _saveSessionState();
      _loadingSong = null;
      _playbackError = null;
      notifyListeners();
    };

    // Listen to playback state changes
    _playbackStateSub = _audioHandler.playbackState.listen((state) {
      if (state.playing || state.processingState == AudioProcessingState.ready) {
        if (_loadingSong != null) {
          _loadingSong = null;
        }
      }
      notifyListeners();
    });

    // Listen to media item changes
    _mediaItemSub = _audioHandler.mediaItem.listen((_) {
      _saveSessionState();
      notifyListeners();
    });

    restoreLastSession();

    // Listen to processing state changes (buffering/loading)
    _processingStateSub = _audioHandler.player.processingStateStream.listen((state) {
      if (state == ProcessingState.ready || state == ProcessingState.completed) {
        if (_loadingSong != null) {
          _loadingSong = null;
        }
      }
      // "Stop after this song" sleep mode: pause once the track completes.
      if (state == ProcessingState.completed && _sleepAfterCurrentTrack) {
        _sleepAfterCurrentTrack = false;
        pause();
      }
      notifyListeners();
    });

    // Listen to player position stream to clear loading spinner immediately once audio starts
    _audioHandler.player.positionStream.listen((pos) {
      if (pos > Duration.zero && _loadingSong != null) {
        _loadingSong = null;
        notifyListeners();
      }
    });

    // Listen to chunk lifecycle state transitions to synchronize loading animation
    StreamCacheService.chunkStateNotifier.addListener(() {
      final cur = currentSong;
      if (cur != null) {
        final state = StreamCacheService.chunkStateNotifier.value[cur.videoId];
        if (state == ChunkLifecycleState.ready || state == ChunkLifecycleState.completed) {
          if (_loadingSong != null) {
            _loadingSong = null;
            notifyListeners();
          }
        }
      }
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
      } else {
        // Nothing new was shared, so this launch is the chance to pick up a
        // share that was queued offline in an earlier run. Only when there is
        // no fresh share: a new one is what the user is asking for right now
        // and must not be pre-empted by an old one.
        await resumePendingShare();
      }
    }).catchError((e) {
      debugPrint('[PlayerProvider] Error getting initial shared text: $e');
    });
  }

  /// Video ids whose shared-link download is currently being set up, so a
  /// double share (or a share of something already downloading) cannot start
  /// the same job twice.
  final Set<String> _sharedLinkInFlight = {};

  /// The text of the share being handled, kept so Retry can re-run it verbatim.
  String? _lastSharedText;

  /// Share text held because the device was offline when it arrived, persisted
  /// so it survives the process being killed while SonicWave is in the
  /// background — which is exactly when a queued share is most likely to be
  /// waiting.
  static const String _pendingShareKey = 'pending_shared_link';

  /// Polls for connectivity while a share sits in
  /// [SharedDownloadPhase.waitingForNetwork].
  Timer? _shareRetryTimer;

  /// How often a queued share re-checks for a network. The check is a single
  /// DNS lookup — cheap, but not free on battery. 15s makes reconnecting feel
  /// immediate without draining a phone left with a share queued overnight.
  static const Duration _shareRetryInterval = Duration(seconds: 15);

  /// Ceiling on reading a shared video's title/artist/artwork.
  ///
  /// Generous, because this runs once per share and a slow mobile connection
  /// deserves the room — but finite, so the card always reaches a state the user
  /// can act on.
  static const Duration _sharedLinkLookupTimeout = Duration(seconds: 20);

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
  ///
  /// Progress is reported two ways, because a share is fired from another app
  /// and then usually abandoned: `SharedLinkDownloadCard` while SonicWave is on
  /// screen, and a foreground-service notification once it is not — the service
  /// being what stops Android reclaiming the process mid-transfer.
  Future<void> handleSharedText(String text) async {
    _lastSharedText = text;
    final videoId = YouTubeLinkParser.extractVideoId(text);
    if (videoId == null) {
      debugPrint('[PlayerProvider] Shared text has no YouTube video link');
      // No id means no download to retry — the share itself was the problem.
      _setSharedDownload(const SharedDownloadStatus(
        phase: SharedDownloadPhase.failed,
        videoId: '',
        message: 'No YouTube link in what you shared',
        canRetry: false,
      ));
      return;
    }

    if (_sharedLinkInFlight.contains(videoId) ||
        _downloadProgress.containsKey(videoId)) {
      _setSharedDownload(SharedDownloadStatus(
        phase: SharedDownloadPhase.duplicate,
        videoId: videoId,
        song: _songForVideoId(videoId),
        message: 'Already downloading',
      ));
      return;
    }

    _sharedLinkInFlight.add(videoId);
    DownloadNotificationService.onCancelRequested = _onNotificationCancel;

    try {
      await loadDownloads();
      final existing = _downloadedSongs.where((s) => s.videoId == videoId);
      if (existing.isNotEmpty) {
        // Nothing to fetch, but the user still asked for this song — offering
        // Play turns a dead end into the thing they probably wanted.
        _setSharedDownload(SharedDownloadStatus(
          phase: SharedDownloadPhase.duplicate,
          videoId: videoId,
          song: existing.first,
          message: 'Already in your Downloads',
        ));
        return;
      }

      // Offline: hold the share instead of burning it. A share cannot be
      // re-fired without going back to the other app and sharing again, so
      // failing it for a condition that usually clears in seconds threw away
      // the user's request for no good reason.
      if (!await _hasNetwork()) {
        await _queueShareForNetwork(text, videoId);
        return;
      }

      debugPrint('[PlayerProvider] Shared YouTube link -> downloading $videoId');

      _setSharedDownload(SharedDownloadStatus(
        phase: SharedDownloadPhase.resolving,
        videoId: videoId,
      ));
      await DownloadNotificationService.start(
        videoId: videoId,
        title: 'Preparing download',
        subtitle: 'Reading video details',
      );

      // Metadata NEVER blocks the download. The video id alone is everything
      // yt-dlp needs to fetch the audio, and it writes the real title, artist
      // and artwork into the file itself — so a lookup that fails or times out
      // yields a placeholder and the transfer proceeds regardless.
      //
      // Aborting here was discarding downloads that would have completed
      // perfectly well: the metadata call and the download call go out over the
      // same flaky link, but only one of them is what the user actually asked
      // for. The timeout is still enforced, it just no longer decides the
      // outcome of the share.
      final song = await YouTubeService()
          .getVideoDetailsResilient(videoId)
          .timeout(
            _sharedLinkLookupTimeout,
            onTimeout: () => YouTubeService.placeholderSong(videoId),
          );

      // A cancel during the lookup leaves no task to stop, so it is checked here
      // rather than trusting the download to notice.
      if (_sharedDownload?.videoId != videoId) return;

      _setSharedDownload(SharedDownloadStatus(
        phase: SharedDownloadPhase.downloading,
        videoId: videoId,
        song: song,
      ));
      await DownloadNotificationService.update(
        videoId: videoId,
        progress: 0,
        title: song.title,
        subtitle: song.artist,
      );

      // downloadSong swallows its own errors, so success is decided by whether
      // the song actually landed in the downloads list.
      await downloadSong(song, onProgress: (progress) {
        final current = _sharedDownload;
        if (current == null || current.videoId != videoId) return;
        _setSharedDownload(current.copyWith(
          phase: SharedDownloadPhase.downloading,
          progress: progress,
        ));
        unawaited(DownloadNotificationService.update(
          videoId: videoId,
          progress: progress,
          title: song.title,
          subtitle: song.artist,
        ));
      });

      // Cancelled mid-flight: the card has already been cleared and the service
      // stopped, so reporting a failure here would contradict what the user did.
      if (_sharedDownload?.videoId != videoId) return;

      final saved = _downloadedSongs.any((s) => s.videoId == videoId);
      if (saved) {
        _setSharedDownload(SharedDownloadStatus(
          phase: SharedDownloadPhase.done,
          videoId: videoId,
          song: _songForVideoId(videoId) ?? song,
          progress: 1.0,
          message: 'Saved to Downloads',
        ));
        await DownloadNotificationService.complete(
          videoId: videoId,
          title: song.title,
        );
      } else {
        // A download that died because the link dropped is not the same as one
        // that died because the video is unavailable. The first is worth
        // holding onto — the connection usually comes back, and by then the
        // user has long since left the app.
        if (!await _hasNetwork()) {
          await _queueShareForNetwork(text, videoId, song: song);
        } else {
          await _failSharedDownload(videoId, 'Download failed', song: song);
        }
      }
    } finally {
      _sharedLinkInFlight.remove(videoId);
    }
  }

  /// True if the device can currently reach the network.
  ///
  /// Deliberately fail-OPEN in one direction only: this decides whether to
  /// *queue*, never whether to refuse, so a false "online" simply lets the
  /// transfer run and report a real error, while a false "offline" would park a
  /// share that could have downloaded. The 4s ceiling keeps a share from
  /// sitting on a DNS probe.
  Future<bool> _hasNetwork() async {
    try {
      final result = await InternetAddress.lookup('google.com')
          .timeout(const Duration(seconds: 4));
      return result.isNotEmpty && result.first.rawAddress.isNotEmpty;
    } catch (_) {
      return false;
    }
  }

  /// Park [text] until the network returns, and start polling for it.
  Future<void> _queueShareForNetwork(String text, String videoId,
      {Song? song}) async {
    debugPrint('[PlayerProvider] No network — queued shared link $videoId');

    _setSharedDownload(SharedDownloadStatus(
      phase: SharedDownloadPhase.waitingForNetwork,
      videoId: videoId,
      song: song,
      message: 'Waiting for a connection',
    ));

    // Persisted as well as held in memory: a share is usually made from another
    // app, so SonicWave is in the background and eligible to be killed long
    // before the network returns.
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_pendingShareKey, text);
    } catch (e) {
      debugPrint('[PlayerProvider] Could not persist queued share: $e');
    }

    await DownloadNotificationService.update(
      videoId: videoId,
      progress: 0,
      title: song?.title ?? 'Waiting for connection',
      subtitle: 'Download will start when you\'re back online',
    );

    // The in-flight guard has to come off before the retry re-enters
    // handleSharedText, or the retry reports the share as a duplicate of
    // itself. The finally block below would do it, but only after this returns
    // — and the first poll can fire before then.
    _sharedLinkInFlight.remove(videoId);
    _startShareRetryPolling();
  }

  void _startShareRetryPolling() {
    _shareRetryTimer?.cancel();
    _shareRetryTimer = Timer.periodic(_shareRetryInterval, (timer) async {
      // The user dismissed or cancelled the card, or a newer share replaced it.
      if (_sharedDownload?.phase != SharedDownloadPhase.waitingForNetwork) {
        timer.cancel();
        _shareRetryTimer = null;
        return;
      }
      if (!await _hasNetwork()) return;

      timer.cancel();
      _shareRetryTimer = null;

      final text = await _takePendingShare();
      if (text == null) return;
      debugPrint('[PlayerProvider] Network back — resuming queued share');
      await handleSharedText(text);
    });
  }

  /// Read and clear the persisted queued share, so it is retried exactly once
  /// per queueing and cannot be replayed on a later launch.
  Future<String?> _takePendingShare() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final text = prefs.getString(_pendingShareKey);
      if (text != null) await prefs.remove(_pendingShareKey);
      return text;
    } catch (e) {
      debugPrint('[PlayerProvider] Could not read queued share: $e');
      return null;
    }
  }

  /// Pick up a share that was queued offline in a previous run.
  ///
  /// Called once at startup. If the network is already back the download simply
  /// starts; if it is not, the share is re-queued and polling resumes, so it
  /// survives any number of restarts until it either lands or the user cancels.
  Future<void> resumePendingShare() async {
    final text = await _takePendingShare();
    if (text == null || text.isEmpty) return;
    debugPrint('[PlayerProvider] Restoring share queued in a previous session');
    await handleSharedText(text);
  }

  /// The downloaded copy of [videoId], if the library has one.
  Song? _songForVideoId(String videoId) {
    for (final s in _downloadedSongs) {
      if (s.videoId == videoId) return s;
    }
    return null;
  }

  Future<void> _failSharedDownload(String videoId, String message,
      {Song? song}) async {
    if (_sharedDownload?.videoId != videoId) return;
    _setSharedDownload(SharedDownloadStatus(
      phase: SharedDownloadPhase.failed,
      videoId: videoId,
      song: song ?? _sharedDownload?.song,
      message: message,
    ));
    await DownloadNotificationService.fail(
      videoId: videoId,
      title: song?.title ?? 'Shared link',
      reason: message,
    );
  }

  /// Stop the shared download and take everything down with it.
  ///
  /// Used by the card's ✕ and by the notification's Cancel action, so both
  /// routes run the same cleanup rather than drifting apart.
  Future<void> cancelSharedDownload() async {
    final current = _sharedDownload;
    if (current == null) return;
    _setSharedDownload(null);
    // Cancelling a queued share must also drop the persisted copy, or it comes
    // back on the next launch as a download the user already said no to.
    _shareRetryTimer?.cancel();
    _shareRetryTimer = null;
    await _takePendingShare();
    await DownloadNotificationService.stop();
    if (current.videoId.isNotEmpty) {
      _sharedLinkInFlight.remove(current.videoId);
      await cancelDownload(current.videoId);
    }
  }

  /// Cancel arriving from the notification, possibly while the app is not on
  /// screen. Guarded on the id so a stale notification cannot cancel a newer
  /// download that happens to be running.
  void _onNotificationCancel(String videoId) {
    if (_sharedDownload?.videoId != videoId) return;
    unawaited(cancelSharedDownload());
  }

  /// Re-run the last share from the top.
  Future<void> retrySharedDownload() async {
    final text = _lastSharedText;
    final videoId = _sharedDownload?.videoId;
    _setSharedDownload(null);
    await DownloadNotificationService.stop();
    if (videoId != null && videoId.isNotEmpty) {
      _sharedLinkInFlight.remove(videoId);
    }
    if (text == null || text.isEmpty) return;
    await handleSharedText(text);
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
  bool get isBuffering {
    final cur = currentSong;
    if (cur != null) {
      final chunkState = StreamCacheService.chunkStateNotifier.value[cur.videoId];
      if (chunkState == ChunkLifecycleState.ready || chunkState == ChunkLifecycleState.completed) {
        return _audioHandler.player.processingState == ProcessingState.buffering;
      }
    }
    if (_audioHandler.player.playing && _audioHandler.player.position > Duration.zero) {
      return _audioHandler.player.processingState == ProcessingState.buffering;
    }
    return _loadingSong != null ||
        _audioHandler.player.processingState == ProcessingState.loading ||
        _audioHandler.player.processingState == ProcessingState.buffering;
  }
  bool get hasCurrentSong => currentSong != null;

  bool isSongLoading(Song song) {
    final chunkState = StreamCacheService.chunkStateNotifier.value[song.videoId];
    if (chunkState == ChunkLifecycleState.ready || chunkState == ChunkLifecycleState.completed) {
      return currentSong?.videoId == song.videoId &&
          _audioHandler.player.processingState == ProcessingState.buffering;
    }
    return _loadingSong?.videoId == song.videoId ||
        (currentSong?.videoId == song.videoId && isBuffering);
  }

  Duration get position => _audioHandler.player.position;

  Duration get duration {
    final songDuration = currentSong?.duration;
    final playerDuration = _audioHandler.player.duration;
    if (songDuration != null && songDuration > Duration.zero) {
      if (playerDuration != null && playerDuration > songDuration) {
        return playerDuration;
      }
      return songDuration;
    }
    return playerDuration ?? Duration.zero;
  }

  Duration get bufferedPosition {
    final song = currentSong;
    final total = duration;

    // Check if StreamCache has an active progressive download fraction for this song
    if (song != null && !song.isLocalFile) {
      final cacheFraction = StreamCacheService.bufferProgressNotifier.value[song.videoId];
      if (cacheFraction != null && cacheFraction > 0.0 && total > Duration.zero) {
        final calculatedBuffer = Duration(milliseconds: (total.inMilliseconds * cacheFraction).round());
        if (calculatedBuffer >= total) return total;
        if (calculatedBuffer > _audioHandler.player.bufferedPosition) {
          return calculatedBuffer;
        }
      }
    }

    final playerBuf = _audioHandler.player.bufferedPosition;
    final playerDur = _audioHandler.player.duration;

    // For progressive streams, the downloaded chunk's duration acts as the current buffer horizon
    if (playerDur != null && playerDur > playerBuf) {
      return playerDur > total ? total : playerDur;
    }
    return playerBuf > total ? total : playerBuf;
  }

  Stream<Duration> get positionStream => _audioHandler.player.positionStream;
  Stream<Duration?> get durationStream => _audioHandler.player.durationStream;
  Stream<bool> get playingStream => _audioHandler.player.playingStream;
  Stream<ProcessingState> get processingStateStream =>
      _audioHandler.player.processingStateStream;

  /// Guard for "is my playback request still the newest one?".
  ///
  /// EVERY entry point that starts playback bumps this and captures the value,
  /// and per-request state — notably [_loadingSong], which is what the player
  /// screen and song tiles render as the buffering spinner — is only cleared by
  /// the request that still owns it.
  ///
  /// skipNext / skipPrevious / playQueueItem used to sit outside this guard
  /// entirely: their `finally` cleared [_loadingSong] unconditionally, so a skip
  /// that resolved late ripped the spinner off whatever song the user had tapped
  /// in the meantime, and the UI stopped agreeing with what was actually loading.
  int _playGeneration = 0;

  /// Clear the loading marker only if [generation] is still the active request.
  void _finishLoading(int generation) {
    if (_playGeneration != generation) return;
    _loadingSong = null;
    notifyListeners();
  }

  Future<void> skipNext() async {
    final thisGeneration = ++_playGeneration;
    final nextIdx = currentIndex + 1;
    if (nextIdx < playlist.length) {
      _loadingSong = playlist[nextIdx];
      notifyListeners();
    }
    try {
      await _audioHandler.skipToNext();
      if (_playGeneration == thisGeneration && currentSong != null) {
        _addToRecentlyPlayed(currentSong!);
      }
    } catch (e) {
      if (_playGeneration != thisGeneration) return;
      debugPrint('Error skipping to next song: $e');
      _playbackError = 'Track unavailable: ${e.toString().replaceAll('Exception:', '').trim()}';
    } finally {
      _finishLoading(thisGeneration);
    }
  }

  Future<void> skipPrevious() async {
    final thisGeneration = ++_playGeneration;
    final prevIdx = currentIndex - 1;
    if (prevIdx >= 0 && prevIdx < playlist.length) {
      _loadingSong = playlist[prevIdx];
      notifyListeners();
    }
    try {
      await _audioHandler.skipToPrevious();
    } catch (e) {
      if (_playGeneration == thisGeneration) {
        debugPrint('Error skipping to previous song: $e');
      }
    } finally {
      _finishLoading(thisGeneration);
    }
  }

  /// Jump straight to a queue entry by index and start playing it.
  Future<void> playQueueItem(int index) async {
    final thisGeneration = ++_playGeneration;
    if (index >= 0 && index < playlist.length) {
      _loadingSong = playlist[index];
      notifyListeners();
    }
    try {
      await _audioHandler.skipToQueueIndex(index);
      if (_playGeneration == thisGeneration && currentSong != null) {
        _addToRecentlyPlayed(currentSong!);
      }
    } catch (e) {
      if (_playGeneration == thisGeneration) {
        debugPrint('Error playing queue item: $e');
      }
    } finally {
      _finishLoading(thisGeneration);
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
        _playbackError = errorMsg.isNotEmpty ? errorMsg : 'Unable to play this track. Please check connection.';
      }
      // Don't rethrow for superseded requests
    } finally {
      _finishLoading(thisGeneration);
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
      _finishLoading(thisGeneration);
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
        // Extended genre presets — EQ-only profiles, no pitch/speed simulation needed
        case SoundEnhancer.electronic:
        case SoundEnhancer.rockMetal:
        case SoundEnhancer.hipHop:
        case SoundEnhancer.pop:
        case SoundEnhancer.acoustic:
        case SoundEnhancer.jazzBlues:
        case SoundEnhancer.nightMode:
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

  /// Download [song] into the offline library.
  ///
  /// [onProgress] lets a caller observe the transfer without owning a second
  /// download path — the shared-link flow uses it to drive its card and the
  /// notification from the same job every other download already runs through.
  Future<void> downloadSong(
    Song song, {
    BuildContext? context,
    ValueChanged<double>? onProgress,
  }) async {
    if (_downloadProgress.containsKey(song.videoId)) return;
    _downloadProgress[song.videoId] = 0.01;
    notifyListeners();

    if (context != null && context.mounted) {
      AppToast.show(context, 'Downloading "${song.title}"...', type: ToastType.info);
    }

    final isSharedLinkDownload = _sharedDownload?.videoId == song.videoId;
    if (!isSharedLinkDownload) {
      unawaited(DownloadNotificationService.start(
        videoId: song.videoId,
        title: song.title,
        subtitle: song.artist,
      ));
    }

    try {
      await DownloadService().downloadSong(song, (progress) {
        _downloadProgress[song.videoId] = progress;
        onProgress?.call(progress);
        if (!isSharedLinkDownload) {
          unawaited(DownloadNotificationService.update(
            videoId: song.videoId,
            progress: progress,
            title: song.title,
            subtitle: song.artist,
          ));
        }
        notifyListeners();
      }, onStateChanged: () {
        notifyListeners();
      }, quality: _audioQuality);
      _downloadProgress.remove(song.videoId);
      await loadDownloads();
      if (!isSharedLinkDownload) {
        unawaited(DownloadNotificationService.complete(
          videoId: song.videoId,
          title: song.title,
        ));
      }
      if (context != null && context.mounted) {
        AppToast.show(context, 'Downloaded "${song.title}" for offline playback!', type: ToastType.success);
      }
    } catch (e) {
      _downloadProgress.remove(song.videoId);
      notifyListeners();
      debugPrint('Error downloading song in provider: $e');
      if (!isSharedLinkDownload) {
        unawaited(DownloadNotificationService.fail(
          videoId: song.videoId,
          title: song.title,
          reason: e.toString().replaceAll('Exception:', '').trim(),
        ));
      }
      if (context != null && context.mounted) {
        final errText = e.toString().replaceAll('Exception:', '').trim();
        AppToast.show(context, 'Failed to download "${song.title}": $errText', type: ToastType.warning);
      }
    }
  }

  /// Download [song] into offline storage and automatically add/move it into [albumId].
  Future<void> downloadAndAddToAlbum(
    Song song,
    String albumId, {
    BuildContext? context,
  }) async {
    final albumIdx = _albums.indexWhere((a) => a.id == albumId);
    if (albumIdx < 0) {
      if (context != null && context.mounted) {
        AppToast.show(context, 'Selected album not found', type: ToastType.warning);
      }
      return;
    }
    final albumName = _albums[albumIdx].name;

    if (_downloadProgress.containsKey(song.videoId)) {
      if (context != null && context.mounted) {
        AppToast.show(context, '"${song.title}" is already downloading', type: ToastType.info);
      }
      return;
    }

    _downloadProgress[song.videoId] = 0.01;
    notifyListeners();

    if (context != null && context.mounted) {
      AppToast.show(
        context,
        'Downloading "${song.title}" into "$albumName"...',
        type: ToastType.download,
      );
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

      // Find the downloaded song instance with its local filePath
      final downloaded = _downloadedSongs.firstWhere(
        (s) => s.videoId == song.videoId,
        orElse: () => song,
      );

      await addSongToAlbum(albumId, downloaded);
      await _saveAlbums();
      notifyListeners();

      if (context != null && context.mounted) {
        AppToast.show(
          context,
          'Downloaded & added "${song.title}" to album "$albumName"!',
          type: ToastType.success,
          icon: Icons.album_rounded,
        );
      }
    } catch (e) {
      _downloadProgress.remove(song.videoId);
      notifyListeners();
      debugPrint('Error downloading song to album: $e');
      if (context != null && context.mounted) {
        final errText = e.toString().replaceAll('Exception:', '').trim();
        AppToast.show(
          context,
          'Failed to download "${song.title}": $errText',
          type: ToastType.warning,
        );
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
      id: 'alb_${DateTime.now().microsecondsSinceEpoch}_${_albums.length + 1}',
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

  Future<bool> renameAlbum(String albumId, String newName) async {
    final idx = _albums.indexWhere((a) => a.id == albumId);
    if (idx < 0 || newName.trim().isEmpty) return false;
    final cleanName = newName.trim();
    final album = _albums[idx];
    if (album.name == cleanName) return true;

    String? newFolderPath = album.folderPath;
    List<Song> updatedSongs = List<Song>.from(album.songs);

    if (album.isFolderBased && album.folderPath != null) {
      final oldDir = Directory(album.folderPath!);
      if (await oldDir.exists()) {
        try {
          final parentDir = oldDir.parent;
          var safeName = cleanName.replaceAll(RegExp(r'[<>:"/\\|?*\x00-\x1F]'), '_').trim();
          safeName = safeName.replaceAll(RegExp(r'^\.+'), '').trim();
          if (safeName.isEmpty) safeName = 'Album';
          final newDir = Directory('${parentDir.path}${Platform.pathSeparator}$safeName');
          if (!await newDir.exists()) {
            await oldDir.rename(newDir.path);
            newFolderPath = newDir.path;
            // Update all filePaths and albumFolderName for songs in this album
            updatedSongs = album.songs.map((s) {
              final oldPath = s.filePath ?? s.videoId;
              final fileName = oldPath.split(Platform.pathSeparator).last;
              final newPath = '${newDir.path}${Platform.pathSeparator}$fileName';
              return s.copyWith(
                filePath: newPath,
                albumFolderName: cleanName,
              );
            }).toList();
          }
        } catch (e) {
          debugPrint('Error renaming physical album folder: $e');
        }
      }
    } else {
      updatedSongs = album.songs.map((s) => s.copyWith(albumFolderName: cleanName)).toList();
    }

    _albums[idx] = album.copyWith(
      name: cleanName,
      folderPath: newFolderPath,
      songs: updatedSongs,
      lastUpdated: DateTime.now(),
    );

    notifyListeners();
    await _saveAlbums();
    return true;
  }

  bool _isSyncingAlbums = false;
  bool get isSyncingAlbums => _isSyncingAlbums;

  /// Synchronize albums with actual storage directories and files.
  /// Reflected when the user adds, renames, moves, or deletes files/folders in a file manager.
  Future<int> syncAlbumsWithStorage() async {
    if (_isSyncingAlbums) return 0;
    _isSyncingAlbums = true;
    notifyListeners();

    int updatedCount = 0;
    try {
      final storageService = StorageLocationService();
      await storageService.initialize();

      // 1. Scan folder albums in storage
      final folderAlbumInfos = await storageService.scanFolderAlbums();
      final Map<String, FolderAlbumInfo> folderPathToInfo = {
        for (final f in folderAlbumInfos) f.folderPath.replaceAll('\\', '/').toLowerCase(): f
      };
      final Map<String, FolderAlbumInfo> folderNameToInfo = {
        for (final f in folderAlbumInfos) f.folderName.toLowerCase(): f
      };

      final List<UserAlbum> syncedAlbums = [];

      for (final album in _albums) {
        if (album.isFolderBased) {
          final normPath = album.folderPath?.replaceAll('\\', '/').toLowerCase();
          FolderAlbumInfo? matchingInfo = normPath != null ? folderPathToInfo[normPath] : null;
          matchingInfo ??= folderNameToInfo[album.name.toLowerCase()];

          if (matchingInfo != null) {
            // Folder exists on disk! Reconcile audio files
            final diskFiles = matchingInfo.audioFilePaths.toSet();
            final existingSongsMap = {for (final s in album.songs) (s.filePath ?? s.videoId): s};

            final List<Song> updatedSongs = [];

            // Retain existing songs whose file still exists on disk
            for (final s in album.songs) {
              final path = s.filePath ?? s.videoId;
              if (diskFiles.contains(path) && File(path).existsSync()) {
                updatedSongs.add(s.copyWith(albumFolderName: matchingInfo.folderName));
              }
            }

            // Detect and enrich new songs on disk not yet in the album
            final List<Song> newDiskSongs = [];
            for (final filePath in diskFiles) {
              if (!existingSongsMap.containsKey(filePath)) {
                final filename = filePath.split(Platform.pathSeparator).last;
                final nameWithoutExt = filename.contains('.')
                    ? filename.substring(0, filename.lastIndexOf('.'))
                    : filename;
                String title = nameWithoutExt;
                String artist = 'Local Audio';
                if (nameWithoutExt.contains(' - ')) {
                  final parts = nameWithoutExt.split(' - ');
                  artist = parts[0].trim();
                  title = parts.sublist(1).join(' - ').trim();
                } else if (nameWithoutExt.contains('-')) {
                  final parts = nameWithoutExt.split('-');
                  artist = parts[0].trim();
                  title = parts.sublist(1).join('-').trim();
                }

                newDiskSongs.add(Song(
                  id: filePath,
                  title: title,
                  artist: artist,
                  thumbnailUrl: '',
                  highResThumbnailUrl: '',
                  duration: const Duration(minutes: 3),
                  videoId: filePath,
                  filePath: filePath,
                  albumFolderName: matchingInfo.folderName,
                ));
              }
            }

            if (newDiskSongs.isNotEmpty) {
              final enrichedNew = await LocalMetadataService().enrichSongs(newDiskSongs);
              updatedSongs.addAll(enrichedNew);
            }

            // Check if folder name on disk changed
            final actualName = matchingInfo.folderName;

            syncedAlbums.add(album.copyWith(
              name: actualName,
              folderPath: matchingInfo.folderPath,
              songs: updatedSongs,
              lastUpdated: DateTime.now(),
            ));
            updatedCount++;

            // Remove from map so we know it's handled
            folderPathToInfo.remove(matchingInfo.folderPath.replaceAll('\\', '/').toLowerCase());
            folderNameToInfo.remove(matchingInfo.folderName.toLowerCase());
          } else {
            // Folder no longer exists on disk!
            // If it had real files that are gone, skip it (deleted manually by user)
            // But if user made it custom, keep only songs whose files still exist
            final remainingSongs = album.songs.where((s) {
              final path = s.filePath ?? (s.isLocalFile ? s.videoId : null);
              return path == null || File(path).existsSync();
            }).toList();

            if (album.isCustom && remainingSongs.isNotEmpty) {
              syncedAlbums.add(album.copyWith(
                songs: remainingSongs,
                isFolderBased: false,
                lastUpdated: DateTime.now(),
              ));
              updatedCount++;
            }
          }
        } else {
          // Custom virtual album: prune songs whose local files were deleted manually from disk
          final validSongs = album.songs.where((s) {
            if (s.isLocalFile) {
              final path = s.filePath ?? s.videoId;
              return path.isNotEmpty && File(path).existsSync();
            }
            return true;
          }).toList();

          syncedAlbums.add(album.copyWith(
            songs: validSongs,
            lastUpdated: validSongs.length != album.songs.length ? DateTime.now() : album.lastUpdated,
          ));
          if (validSongs.length != album.songs.length) updatedCount++;
        }
      }

      // Add any newly discovered folders on disk that weren't in _albums
      for (final newFolderInfo in folderPathToInfo.values) {
        final folderSongs = newFolderInfo.audioFilePaths.map((audioPath) {
          final filename = audioPath.split(Platform.pathSeparator).last;
          final nameWithoutExt = filename.contains('.')
              ? filename.substring(0, filename.lastIndexOf('.'))
              : filename;
          String title = nameWithoutExt;
          String artist = 'Local Audio';
          if (nameWithoutExt.contains(' - ')) {
            final parts = nameWithoutExt.split(' - ');
            artist = parts[0].trim();
            title = parts.sublist(1).join(' - ').trim();
          } else if (nameWithoutExt.contains('-')) {
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
            albumFolderName: newFolderInfo.folderName,
          );
        }).toList();

        final enriched = await LocalMetadataService().enrichSongs(folderSongs);

        syncedAlbums.add(UserAlbum(
          id: 'folder_${newFolderInfo.folderName.hashCode.abs()}',
          name: newFolderInfo.folderName,
          songs: enriched,
          isCustom: false,
          folderPath: newFolderInfo.folderPath,
          isFolderBased: true,
          lastUpdated: DateTime.now(),
        ));
        updatedCount++;
      }

      _albums.clear();
      _albums.addAll(syncedAlbums);
      await _saveAlbums();
    } catch (e) {
      debugPrint('Error in syncAlbumsWithStorage: $e');
    } finally {
      _isSyncingAlbums = false;
      notifyListeners();
    }
    return updatedCount;
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
            updatedSongs.add(song.copyWith(albumFolderName: targetAlbum.name));
          }
        }
        _albums[targetIdx] = targetAlbum.copyWith(
          songs: updatedSongs,
          lastUpdated: DateTime.now(),
        );
      }
    } else if (moveToRecovery) {
      // Option B: "Move to Recovery" — safely archive physical files & register songs in the Recovery Vault
      try {
        final docsDir = await getApplicationDocumentsDirectory();
        final recoveryDir = Directory('${docsDir.path}${Platform.pathSeparator}sonicwave${Platform.pathSeparator}Recovery');
        if (!await recoveryDir.exists()) {
          await recoveryDir.create(recursive: true);
        }

        final List<Song> recoveredSongs = [];
        final storageService = StorageLocationService();
        await storageService.initialize();

        for (final song in album.songs) {
          String? newPath = song.filePath;
          final srcPath = song.filePath ?? (song.isLocalFile ? song.videoId : null);
          if (srcPath != null && srcPath.isNotEmpty && File(srcPath).existsSync()) {
            try {
              final moved = await storageService.moveFile(srcPath, recoveryDir);
              if (moved != null) {
                newPath = moved;
              }
            } catch (e) {
              debugPrint('Error moving physical file to recovery: $e');
            }
          }

          final recoveredSong = song.copyWith(
            filePath: newPath,
            albumFolderName: 'Recovery',
          );
          recoveredSongs.add(recoveredSong);
        }

        // Find or create "Recovery" album in _albums so user can see, play, and restore them
        final recIdx = _albums.indexWhere((a) => a.id == 'recovery_vault' || a.name.toLowerCase() == 'recovery');
        if (recIdx >= 0) {
          final existingRec = _albums[recIdx];
          final combined = List<Song>.from(existingRec.songs);
          for (final song in recoveredSongs) {
            if (!combined.any((s) => s.videoId == song.videoId)) {
              combined.add(song);
            }
          }
          _albums[recIdx] = existingRec.copyWith(
            songs: combined,
            lastUpdated: DateTime.now(),
          );
        } else {
          final newRecoveryAlbum = UserAlbum(
            id: 'recovery_vault',
            name: 'Recovery',
            songs: recoveredSongs,
            isCustom: true,
            folderPath: recoveryDir.path,
            isFolderBased: false,
            lastUpdated: DateTime.now(),
          );
          _albums.add(newRecoveryAlbum);
        }

        // Keep _localDeviceSongs in sync so recovered songs appear in local library with RECOVERY badge
        for (final song in recoveredSongs) {
          final lIdx = _localDeviceSongs.indexWhere((s) => s.videoId == song.videoId);
          if (lIdx >= 0) {
            _localDeviceSongs[lIdx] = song;
          } else {
            _localDeviceSongs.add(song);
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

    _albums.removeWhere((a) => a.id == id);
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

    // 1. Remove the old song reference from its previous album if any (only on move)
    if (!isCopyMode) {
      for (int i = 0; i < _albums.length; i++) {
        if (_albums[i].id != targetAlbumId) {
          if (_albums[i].songs.any((s) => s.videoId == song.videoId)) {
            final updatedOldSongs = _albums[i].songs.where((s) => s.videoId != song.videoId).toList();
            _albums[i] = _albums[i].copyWith(songs: updatedOldSongs, lastUpdated: DateTime.now());
          }
        }
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
    } else {
      // Physical copy made: register copy in local device songs with thumbnail
      if (physicalMove && newPath != null) {
        final canonNew = PlayerProvider.canonicalizePath(newPath);
        if (!_localDeviceSongs.any((s) => s.filePath != null && PlayerProvider.canonicalizePath(s.filePath!) == canonNew)) {
          _localDeviceSongs.add(updatedSong);
          await _saveLocalDeviceSongs();
        }
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

  /// Normalize and canonicalize storage paths across Android, Linux, and Windows.
  /// Standardizes slashes, strips symlink aliases (/sdcard -> /storage/emulated/0),
  /// and resolves redundant slashes.
  static String canonicalizePath(String rawPath) {
    if (rawPath.isEmpty) return rawPath;
    String p = rawPath.replaceAll('\\', '/');
    if (p.startsWith('/sdcard/')) {
      p = '/storage/emulated/0/${p.substring(8)}';
    } else if (p == '/sdcard') {
      p = '/storage/emulated/0';
    } else if (p.startsWith('/storage/self/primary/')) {
      p = '/storage/emulated/0/${p.substring(22)}';
    } else if (p == '/storage/self/primary') {
      p = '/storage/emulated/0';
    }
    while (p.contains('//')) {
      p = p.replaceAll('//', '/');
    }
    if (p.length > 1 && p.endsWith('/')) {
      p = p.substring(0, p.length - 1);
    }
    return p;
  }

  List<Song> get localSongsMerged {
    final List<Song> merged = [];
    final Set<String> seenIdentifiers = {};

    for (final song in _downloadedSongs) {
      merged.add(song);
      seenIdentifiers.add(song.videoId);
      seenIdentifiers.add(song.id);
      if (song.filePath != null && song.filePath!.isNotEmpty) {
        seenIdentifiers.add(canonicalizePath(song.filePath!));
      }
    }

    for (final song in _localDeviceSongs) {
      final songPath = song.filePath ?? (song.isLocalFile ? song.videoId : null);
      final normPath = songPath != null && songPath.isNotEmpty ? canonicalizePath(songPath) : null;
      final isSeen = seenIdentifiers.contains(song.videoId) ||
          seenIdentifiers.contains(song.id) ||
          (normPath != null && seenIdentifiers.contains(normPath));

      if (!isSeen) {
        merged.add(song);
        seenIdentifiers.add(song.videoId);
        seenIdentifiers.add(song.id);
        if (normPath != null) {
          seenIdentifiers.add(normPath);
        }
      }
    }
    return merged;
  }

  Future<void> _scanDirRecursive(
    Directory dir,
    List<Song> foundSongs,
    Set<String> visitedDirs,
    Set<String> discoveredFiles,
  ) async {
    final normDirPath = canonicalizePath(dir.path);
    if (visitedDirs.contains(normDirPath)) return;
    visitedDirs.add(normDirPath);

    // Skip hidden folders and Android system directories to optimize scan speed and avoid permissions crashes
    final name = normDirPath.split('/').last.toLowerCase();
    if (name.startsWith('.') || name == 'android' || name == 'cache' || name == 'temp') {
      return;
    }

    try {
      await for (final entity in dir.list(followLinks: false)) {
        if (entity is File) {
          final normFilePath = canonicalizePath(entity.path);
          if (discoveredFiles.contains(normFilePath)) continue;

          final ext = normFilePath.split('.').last.toLowerCase();
          final supportedExts = {
            'mp3', 'm4a', 'wav', 'flac', 'aac', 'ogg', 'opus',
            'wma', 'aiff', 'aif', 'alac', 'mka', 'amr', 'm4b', 'mpeg', 'mp2'
          };
          if (supportedExts.contains(ext)) {
            discoveredFiles.add(normFilePath);
            final filename = entity.uri.pathSegments.isNotEmpty
                ? entity.uri.pathSegments.last
                : normFilePath.split('/').last;
            var nameWithoutExt = filename.contains('.')
                ? filename.substring(0, filename.lastIndexOf('.'))
                : filename;

            // Clean common downloader suffixes: (MP3_160K), (MP3_320K), _160k, etc.
            nameWithoutExt = nameWithoutExt
                .replaceAll(RegExp(r'\([mM][pP]3[_\s]*\d+[kK]?\)'), '')
                .replaceAll(RegExp(r'_\d+[kK]$'), '')
                .trim();

            String title = nameWithoutExt;
            String artist = 'Local Audio';
            if (nameWithoutExt.contains(' - ')) {
              final parts = nameWithoutExt.split(' - ');
              artist = parts[0].trim();
              title = parts.sublist(1).join(' - ').trim();
            } else if (nameWithoutExt.contains('-')) {
              final parts = nameWithoutExt.split('-');
              artist = parts[0].trim();
              title = parts.sublist(1).join('-').trim();
            }

            foundSongs.add(Song(
              id: normFilePath,
              title: title,
              artist: artist,
              thumbnailUrl: '',
              highResThumbnailUrl: '',
              duration: const Duration(minutes: 3),
              videoId: normFilePath,
              filePath: normFilePath,
            ));
          }
        } else if (entity is Directory) {
          await _scanDirRecursive(entity, foundSongs, visitedDirs, discoveredFiles);
        }
      }
    } catch (e) {
      debugPrint('Error scanning dir $normDirPath: $e');
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
      final previousPaths = _localDeviceSongs.map((s) => canonicalizePath(s.filePath ?? s.videoId)).toSet();

      final List<Song> foundSongs = [];
      final Set<String> pathsToScan = {};

      if (Platform.isAndroid) {
        // Internal storage root
        pathsToScan.add('/storage/emulated/0');

        // Dynamically probe for external SD cards mounted inside /storage
        final storageDir = Directory('/storage');
        if (await storageDir.exists()) {
          try {
            await for (final entity in storageDir.list(followLinks: false)) {
              if (entity is Directory) {
                final name = entity.path.split('/').last;
                if (name != 'self' && name != 'emulated' && name != 'knox' && !name.startsWith('.')) {
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

      final Set<String> visitedDirs = {};
      final Set<String> discoveredFiles = {};
      for (final path in pathsToScan) {
        final dir = Directory(path);
        if (await dir.exists()) {
          await _scanDirRecursive(dir, foundSongs, visitedDirs, discoveredFiles);
        }
      }

      // Identify newly discovered tracks for session badge tagging
      for (final song in foundSongs) {
        final path = canonicalizePath(song.filePath ?? song.videoId);
        if (!previousPaths.contains(path)) {
          _sessionNewSongIds.add(song.videoId);
          _sessionNewSongIds.add(song.id);
        }
      }

      // Incremental enrich & cached metadata lookup
      _localDeviceSongs = await LocalMetadataService().enrichSongs(foundSongs);

      // Save scanned local device songs so they persist across app restarts
      await _saveLocalDeviceSongs();

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

  Future<File> get _localSongsIndexFile async {
    final dir = await getApplicationDocumentsDirectory();
    return File('${dir.path}${Platform.pathSeparator}local_songs.json');
  }

  Future<void> _saveLocalDeviceSongs() async {
    try {
      final file = await _localSongsIndexFile;
      final jsonList = _localDeviceSongs.map((s) => s.toJson()).toList();
      await file.writeAsString(json.encode(jsonList), flush: true);
    } catch (e) {
      debugPrint('Error saving local songs index: $e');
    }
  }

  Future<void> _loadLocalDeviceSongs() async {
    try {
      final file = await _localSongsIndexFile;
      if (await file.exists()) {
        final content = await file.readAsString();
        final List<dynamic> jsonList = json.decode(content);
        final List<Song> loaded = [];
        for (final item in jsonList) {
          if (item is Map<String, dynamic>) {
            final song = Song.fromJson(item);
            final path = song.filePath ?? song.videoId;
            if (path.isNotEmpty && File(path).existsSync()) {
              loaded.add(song);
            }
          }
        }
        _localDeviceSongs = loaded;
        notifyListeners();
      }
    } catch (e) {
      debugPrint('Error loading local songs index: $e');
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

      // DownloadService caches the download-dir path and an `_isLoaded` flag;
      // after the root just moved both point at the volume the library left.
      // Without this reset every downloaded song "disappears" until restart.
      DownloadService().invalidateStorageCaches();

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

  /// Permanently delete a song — removes the physical file from disk AND all metadata stores.
  Future<bool> deleteSongPermanently(Song song) async {
    try {
      // Delete the physical file
      final filePath = song.filePath ?? (song.isLocalFile ? song.videoId : null);
      if (filePath != null && filePath.isNotEmpty) {
        final file = File(filePath);
        if (await file.exists()) {
          try {
            await file.delete();
          } catch (e) {
            debugPrint('Error deleting physical file: $e');
          }
        }
      }

      // Remove from local device cache (prune by canonical file path if available, or videoId)
      final canonDeleted = song.filePath != null ? PlayerProvider.canonicalizePath(song.filePath!) : null;
      _localDeviceSongs.removeWhere((s) {
        if (canonDeleted != null && s.filePath != null) {
          return PlayerProvider.canonicalizePath(s.filePath!) == canonDeleted;
        }
        return s.videoId == song.videoId;
      });
      await _saveLocalDeviceSongs();

      // Remove from all metadata stores (downloads, favorites, albums, history)
      await _removeSongFromAllStores(song.videoId, deletedFilePath: song.filePath);
      await loadDownloads();

      // If playing this song, stop
      if (currentSong?.videoId == song.videoId) {
        await stop();
      }

      notifyListeners();
      return true;
    } catch (e) {
      debugPrint('Error in deleteSongPermanently: $e');
      return false;
    }
  }

  /// Move a single song to the Recovery Vault — archive the physical file and
  /// register it in the Recovery album so it can be restored later.
  ///
  /// If [sourceAlbumId] is provided, the song is also removed from that album.
  Future<bool> moveSongToRecovery(Song song, {String? sourceAlbumId}) async {
    try {
      final docsDir = await getApplicationDocumentsDirectory();
      final recoveryDir = Directory(
          '${docsDir.path}${Platform.pathSeparator}sonicwave${Platform.pathSeparator}Recovery');
      if (!await recoveryDir.exists()) {
        await recoveryDir.create(recursive: true);
      }

      // Move the physical file to the Recovery directory
      String? newPath = song.filePath;
      final srcPath =
          song.filePath ?? (song.isLocalFile ? song.videoId : null);
      if (srcPath != null &&
          srcPath.isNotEmpty &&
          File(srcPath).existsSync()) {
        try {
          final storageService = StorageLocationService();
          await storageService.initialize();
          final moved =
              await storageService.moveFile(srcPath, recoveryDir);
          if (moved != null) {
            newPath = moved;
          }
        } catch (e) {
          debugPrint('Error moving physical file to recovery: $e');
        }
      }

      final recoveredSong = song.copyWith(
        filePath: newPath,
        albumFolderName: 'Recovery',
      );

      // Find or create "Recovery" album
      final recIdx = _albums.indexWhere(
          (a) => a.id == 'recovery_vault' || a.name.toLowerCase() == 'recovery');
      if (recIdx >= 0) {
        final existingRec = _albums[recIdx];
        final combined = List<Song>.from(existingRec.songs);
        if (!combined.any((s) => s.videoId == song.videoId)) {
          combined.add(recoveredSong);
        }
        _albums[recIdx] = existingRec.copyWith(
          songs: combined,
          lastUpdated: DateTime.now(),
        );
      } else {
        _albums.add(UserAlbum(
          id: 'recovery_vault',
          name: 'Recovery',
          songs: [recoveredSong],
          isCustom: true,
          folderPath: recoveryDir.path,
          isFolderBased: false,
          lastUpdated: DateTime.now(),
        ));
      }

      // Remove from the source album if specified
      if (sourceAlbumId != null) {
        final srcIdx = _albums.indexWhere((a) => a.id == sourceAlbumId);
        if (srcIdx >= 0) {
          final updatedSongs = _albums[srcIdx]
              .songs
              .where((s) => s.videoId != song.videoId)
              .toList();
          _albums[srcIdx] = _albums[srcIdx].copyWith(
            songs: updatedSongs,
            lastUpdated: DateTime.now(),
          );
        }
      }

      // Remove from downloads registry (file is now in Recovery, not downloads)
      await DownloadService().deleteSong(song.videoId);

      // Update local device songs to show RECOVERY badge
      final lIdx =
          _localDeviceSongs.indexWhere((s) => s.videoId == song.videoId);
      if (lIdx >= 0) {
        _localDeviceSongs[lIdx] = recoveredSong;
      } else {
        _localDeviceSongs.add(recoveredSong);
      }

      await _saveAlbums();
      notifyListeners();
      return true;
    } catch (e) {
      debugPrint('Error moving song to recovery: $e');
      return false;
    }
  }

  /// Permanently delete multiple songs from storage
  Future<int> deleteMultipleSongsPermanently(List<Song> songs) async {
    int deletedCount = 0;
    for (final song in songs) {
      final ok = await deleteSongPermanently(song);
      if (ok) deletedCount++;
    }
    return deletedCount;
  }

  /// Remove a song from memory only — the physical file stays on disk.
  ///
  /// Used for externally-scanned songs that are just referenced.
  Future<void> deleteSongMemory(Song song) async {
    await _removeSongFromAllStores(song.videoId);
    _localDeviceSongs.removeWhere((s) => s.videoId == song.videoId);
    await _saveLocalDeviceSongs();
    notifyListeners();
  }

  /// Helper to remove a song from downloads, favorites, albums, and history
  Future<void> _removeSongFromAllStores(String videoId, {String? deletedFilePath}) async {
    final canonDeleted = deletedFilePath != null ? PlayerProvider.canonicalizePath(deletedFilePath) : null;

    // Check if another copy of this song still exists in downloads on disk
    final remainingDownloaded = _downloadedSongs.where((d) {
      if (d.videoId != videoId) return false;
      if (canonDeleted != null && d.filePath != null) {
        return PlayerProvider.canonicalizePath(d.filePath!) != canonDeleted && File(d.filePath!).existsSync();
      }
      return false;
    }).toList();

    if (remainingDownloaded.isEmpty) {
      await DownloadService().deleteSong(videoId);
    }

    // Remove from favorites only if no remaining copies
    if (remainingDownloaded.isEmpty) {
      _favorites.removeWhere((s) => s.videoId == videoId);
      await _saveFavorites();

      _history.removeWhere((e) => e.song.videoId == videoId);
      await _saveHistory();
    }

    // Remove from albums (remove the specific file copy if path matched, or all if no remaining copies)
    bool albumChanged = false;
    for (int i = 0; i < _albums.length; i++) {
      final before = _albums[i].songs.length;
      final updatedSongs = _albums[i].songs.where((s) {
        if (s.videoId != videoId) return true;
        if (canonDeleted != null && s.filePath != null) {
          return PlayerProvider.canonicalizePath(s.filePath!) != canonDeleted;
        }
        return remainingDownloaded.isNotEmpty;
      }).toList();
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

  /// True once [dispose] has run. See [notifyListeners].
  bool _disposed = false;

  /// Swallow notifications that arrive after disposal instead of throwing.
  ///
  /// The constructor starts five independent async loads (history, favorites,
  /// downloads, albums, device songs) and each notifies when it lands. If the
  /// provider is disposed while any of them is still in flight — a share intent
  /// handled and dismissed during startup, a hot restart, a widget test that
  /// creates and disposes a provider — the late notification hits
  /// ChangeNotifier's disposed assertion and throws inside whichever load is
  /// unlucky, which then reports as a spurious "Error loading albums".
  ///
  /// Dropping the notification is the correct response: there is no longer
  /// anyone listening, and the state it would have announced is being discarded.
  @override
  void notifyListeners() {
    if (_disposed) return;
    super.notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _sleepTimer?.cancel();
    _countdownTimer?.cancel();
    _shareRetryTimer?.cancel();
    _playbackStateSub?.cancel();
    _mediaItemSub?.cancel();
    _processingStateSub?.cancel();
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
