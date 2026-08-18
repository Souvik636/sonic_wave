import 'dart:io';
import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:audio_session/audio_session.dart';
import 'package:audio_service/audio_service.dart';
import 'package:just_audio/just_audio.dart';
import '../models/song.dart';
import '../providers/settings_provider.dart';
import 'youtube_service.dart';
import 'download_service.dart';
import 'stream_cache_service.dart';
import 'stream_resolver_service.dart';
import 'audio_format_sniffer.dart';

class SonicWaveAudioHandler extends BaseAudioHandler with SeekHandler, QueueHandler {
  late final AudioPlayer _player;
  final YouTubeService _youtubeService = YouTubeService();
  AndroidEqualizer? _equalizer;
  SoundEnhancer _lastAppliedEnhancerMode = SoundEnhancer.none;

  final List<Song> _playlist = [];
  int _currentIndex = -1;
  bool _isShuffled = false;
  AudioServiceRepeatMode _repeatMode = AudioServiceRepeatMode.none;

  // Generation counter to cancel stale play requests
  int _playGeneration = 0;

  /// Serializes every mutation of [_player] in the play path.
  ///
  /// The generation counter alone is NOT enough: it is only read *between*
  /// awaits, and `setAudioSource` is a multi-second network probe. Tapping song
  /// B while song A sat inside that await left two calls mutating the same
  /// ExoPlayer instance, and whichever finished LAST won — so the screen and
  /// the notification showed B while A was audible. Chaining the operations
  /// means B waits for A's call to land, then the generation re-check inside
  /// [_withPlayerLock] discards A's result before it can be heard.
  Future<void> _playerOp = Future<void>.value();

  /// Run [body] with exclusive access to [_player], skipping it entirely if a
  /// newer play request arrived while this one was queued.
  Future<void> _withPlayerLock(int generation, Future<void> Function() body) {
    final run = _playerOp.then((_) async {
      if (_playGeneration != generation) return;
      await body();
    });
    // Swallow errors on the chain itself so one failed load can't poison every
    // subsequent operation; the awaiting caller still sees the exception.
    _playerOp = run.catchError((_) {});
    return run;
  }

  Timer? _prefetchTimer;

  /// Sleep-timer "end of track": when true, playback stops after the current
  /// song completes instead of advancing the queue. One-shot — reset on fire.
  bool stopAfterCurrentSong = false;

  /// Called when the end-of-track sleep stop fires, so UI state can update.
  VoidCallback? onStopAfterCurrentFired;

  /// Called when the 8-minute idle timeout fires so PlayerProvider can save
  /// session state and refresh the UI before the notification is torn down.
  VoidCallback? onIdleTimeout;

  /// 8-minute idle timer: fires when playback has been paused continuously.
  Timer? _idleTimer;

  /// 2-minute timer to clear prefetched stream URLs after pause, freeing
  /// stale network resources whose YouTube tokens are expiring anyway.
  Timer? _prefetchCleanupTimer;

  /// Duration after which a paused session auto-stops (notification dismissed).
  static const Duration _idleTimeoutDuration = Duration(minutes: 8);

  /// Duration after which prefetched stream cache is cleared on pause.
  static const Duration _prefetchCleanupDelay = Duration(minutes: 2);

  /// Called when approaching the end of queue so PlayerProvider can auto-inject recommendations.
  VoidCallback? onQueueNearEnd;

  /// Global crossfade duration in seconds (0 = off). Applied as a volume
  /// envelope at track edges when the song has no explicit fade of its own.
  int crossfadeSeconds = 0;

  /// Queue index we already ran the near-end prefetch for (avoids re-firing
  /// every position tick in the final seconds).
  int _nearEndPrefetchedIndex = -1;

  /// Restore-on-launch: when [playSong] loads this exact song next, seek here
  /// once, then clear. Set by [restoreQueue].
  Duration? _pendingRestorePosition;
  String? _pendingRestoreSongId;

  List<double>? _customGains;
  bool _useCustomGains = false;
  bool _isKaraokeMode = false;
  List<double> _currentGains = [0.0, 0.0, 0.0, 0.0, 0.0];

  Future<void> setSpeedAndPitch(double speed, double pitch) async {
    await _player.setSpeed(speed);
    await _player.setPitch(pitch);
  }

  Future<void> setEqualizerPreset(SoundEnhancer mode) async {
    _useCustomGains = false;
    _lastAppliedEnhancerMode = mode;
    await _applyEqualizerPreset(mode, smooth: true);
  }

  Future<void> setCustomEqualizerGains(List<double> gains) async {
    _useCustomGains = true;
    _customGains = List.from(gains);
    await _applyCustomEqualizerGains(gains, smooth: true);
  }

  Future<void> setKaraokeMode(bool enabled) async {
    _isKaraokeMode = enabled;
    if (_useCustomGains && _customGains != null) {
      await _applyCustomEqualizerGains(_customGains!, smooth: true);
    } else {
      await _applyEqualizerPreset(_lastAppliedEnhancerMode, smooth: true);
    }
  }

  /// ExoPlayer's stock buffering is tuned for video: it withholds playback until
  /// ~2.5s is buffered, which is dead air at the start of every track. Music is
  /// a fraction of the bitrate of video, so a much smaller pre-roll is safe and
  /// audio starts noticeably sooner. The max buffer is set high (120s) so on
  /// slow connections ExoPlayer will greedily cache up to 2 minutes ahead,
  /// preventing rebuffers on spotty 2G/3G networks. The back buffer keeps a
  /// seek-back window in memory so scrubbing backwards doesn't force a re-fetch.
  static AudioLoadConfiguration get _loadConfiguration => AudioLoadConfiguration(
        androidLoadControl: const AndroidLoadControl(
          minBufferDuration: Duration(seconds: 30),
          maxBufferDuration: Duration(seconds: 120),
          // Start playing as soon as this much is ready (default 2.5s).
          bufferForPlaybackDuration: Duration(milliseconds: 600),
          // After a rebuffer, resume this quickly (default 5s).
          bufferForPlaybackAfterRebufferDuration: Duration(seconds: 2),
          backBufferDuration: Duration(seconds: 30),
        ),
      );

  SonicWaveAudioHandler() {
    if (Platform.isAndroid) {
      _equalizer = AndroidEqualizer();
      final pipeline = AudioPipeline(androidAudioEffects: [_equalizer!]);
      _player = AudioPlayer(
        audioPipeline: pipeline,
        audioLoadConfiguration: _loadConfiguration,
        userAgent: 'com.google.android.youtube/20.10.38 (Linux; U; Android 11) gzip',
      );
    } else {
      _player = AudioPlayer(
        audioLoadConfiguration: _loadConfiguration,
        userAgent: 'com.google.android.youtube/20.10.38 (Linux; U; Android 11) gzip',
      );
    }
    _init();
  }

  void _init() {
    // Listen to playback event streams and map to playbackState.
    // IMPORTANT: must be .listen(playbackState.add), NOT .pipe(playbackState).
    // pipe() locks the subject via addStream, after which BaseAudioHandler.stop()'s
    // own playbackState.add() throws "Bad state: You cannot add items while items
    // are being added from addStream" — an unhandled exception that kills the
    // audio service mid-stop and crashes the app on next launch (see run_log.txt).
    _player.playbackEventStream.map(_transformEvent).listen(
      playbackState.add,
      onError: (Object e, StackTrace st) {
        // just_audio surfaces player errors on this stream; reflect them in
        // playbackState instead of letting them escape as unhandled errors.
        debugPrint('[AudioHandler] playbackEventStream error: $e');
        playbackState.add(playbackState.value.copyWith(
          processingState: AudioProcessingState.error,
        ));
      },
    );

    // Listen for when current song completes
    _player.processingStateStream.listen((state) {
      if (state == ProcessingState.completed) {
        _handleSongCompletion();
      }
    });

    // Sync idle timer with play/pause transitions.
    _player.playerStateStream.listen((playerState) {
      if (playerState.playing) {
        _cancelIdleTimer();
        _cancelPrefetchCleanupTimer();
      } else {
        // Paused, stopped, or completed — arm the 8-minute idle timer and prefetch cleanup.
        _armIdleTimer();
        _armPrefetchCleanupTimer();
      }
    });

    // Listen for headphone unplug / Bluetooth disconnection events ("Becoming Noisy")
    AudioSession.instance.then((session) async {
      try {
        await session.configure(const AudioSessionConfiguration.music());
        session.becomingNoisyEventStream.listen((_) {
          debugPrint('[AudioHandler] Headphones/Bluetooth disconnected. Auto-pausing.');
          pause();
        });
      } catch (e) {
        debugPrint('[AudioHandler] Error configuring AudioSession: $e');
      }
    });

    // Listen to position updates to modulate volume for fade in / out envelopes
    _player.positionStream.listen((_) {
      _applyVolumeModulation();
      _maybePrefetchNearEnd();
    });
  }

  // ---------------------------------------------------------------------------
  // Idle timer management
  // ---------------------------------------------------------------------------

  /// Start (or restart) the 8-minute idle countdown.
  void _armIdleTimer() {
    _idleTimer?.cancel();
    _idleTimer = Timer(_idleTimeoutDuration, _onIdleTimeout);
  }

  /// Cancel the idle timer (user resumed playback).
  void _cancelIdleTimer() {
    _idleTimer?.cancel();
    _idleTimer = null;
  }

  /// Start the 2-minute prefetch cleanup countdown.
  void _armPrefetchCleanupTimer() {
    _prefetchCleanupTimer?.cancel();
    _prefetchCleanupTimer = Timer(_prefetchCleanupDelay, () {
      if (!_player.playing) {
        _prefetchedStreams.clear();
        debugPrint('[AudioHandler] Prefetch cache cleared after idle');
      }
    });
  }

  /// Cancel the prefetch cleanup timer.
  void _cancelPrefetchCleanupTimer() {
    _prefetchCleanupTimer?.cancel();
    _prefetchCleanupTimer = null;
  }

  /// Fires after 8 minutes of continuous pause. Stops the player, clears
  /// all network resources, and tells audio_service to tear down the
  /// foreground service — which dismisses the media notification.
  void _onIdleTimeout() {
    debugPrint('[AudioHandler] 8-minute idle timeout — stopping player and dismissing notification');

    // Let the provider save session state BEFORE we wipe the queue.
    onIdleTimeout?.call();

    _prefetchedStreams.clear();
    _prefetchTimer?.cancel();
    _cancelPrefetchCleanupTimer();

    _player.stop();
    _playlist.clear();
    _currentIndex = -1;
    _playGeneration++;

    // Clear the media item so audio_service removes the notification.
    mediaItem.add(null);

    // Emit a terminal playback state so the service can shut down.
    playbackState.add(playbackState.value.copyWith(
      controls: [],
      processingState: AudioProcessingState.idle,
      playing: false,
    ));
  }

  double _userVolume = 1.0;

  /// Last volume actually pushed to the player, so identical values aren't
  /// re-sent. This runs on every position tick (~every 200ms), and each call is
  /// a platform-channel round-trip — but the volume only actually changes
  /// during a fade, which is a few seconds out of a whole track.
  double? _lastAppliedVolume;

  void updateVolume(double val) {
    _userVolume = val;
    _applyVolumeModulation();
  }

  /// Push [volume] to the player only when it differs from the last value sent.
  void _setVolumeIfChanged(double volume) {
    final last = _lastAppliedVolume;
    // Sub-half-percent differences are inaudible; skip the channel hop.
    if (last != null && (last - volume).abs() < 0.005) return;
    _lastAppliedVolume = volume;
    _player.setVolume(volume);
  }

  void _applyVolumeModulation() {
    final song = currentSong;
    if (song == null) {
      _setVolumeIfChanged(_userVolume);
      return;
    }

    final pos = _player.position.inMilliseconds;
    final total = song.duration.inMilliseconds;

    // Per-song fades (Sound Studio) win; global crossfade fills in when the
    // song has none of its own, giving smooth edges on automatic transitions.
    final fadeInMs = song.fadeIn > 0
        ? song.fadeIn * 1000
        : (crossfadeSeconds > 0 ? crossfadeSeconds * 1000.0 : 0.0);
    final fadeOutMs = song.fadeOut > 0
        ? song.fadeOut * 1000
        : (crossfadeSeconds > 0 ? crossfadeSeconds * 1000.0 : 0.0);

    double factor = 1.0;

    if (fadeInMs > 0 && pos < fadeInMs) {
      factor = pos / fadeInMs;
    } else if (fadeOutMs > 0 && total > 0 && total - pos < fadeOutMs) {
      final double remaining = (total - pos).toDouble();
      factor = (remaining / fadeOutMs).clamp(0.0, 1.0);
    }

    _setVolumeIfChanged(_userVolume * factor);
  }

  /// In the final stretch of the current track, warm the NEXT track's stream
  /// URL cache so the automatic transition (or a late manual skip) is
  /// near-instant. Runs once per queue index.
  void _maybePrefetchNearEnd() {
    if (!_player.playing) return;
    if (_currentIndex < 0 || _currentIndex >= _playlist.length - 1) return;
    if (_nearEndPrefetchedIndex == _currentIndex) return;

    final song = currentSong;
    if (song == null) return;
    final total = song.duration.inMilliseconds;
    if (total <= 0) return;

    final remaining = total - _player.position.inMilliseconds;
    // 20s before the end (or crossfade window + 10s, whichever is larger).
    final triggerMs = (crossfadeSeconds > 0 ? (crossfadeSeconds + 10) * 1000 : 20000);
    if (remaining > 0 && remaining <= triggerMs) {
      _nearEndPrefetchedIndex = _currentIndex;
      final nextSong = _playlist[_currentIndex + 1];
      if (!nextSong.isLocalFile) {
        debugPrint('[AudioHandler] Near-end prefetch for next track: ${nextSong.title}');
        _youtubeService.prefetchStreamUrl(nextSong.videoId);
      }
    }
  }

  AudioPlayer get player => _player;
  List<Song> get playlist => List.unmodifiable(_playlist);
  int get currentIndex => _currentIndex;
  Song? get currentSong => _currentIndex >= 0 && _currentIndex < _playlist.length
      ? _playlist[_currentIndex]
      : null;
  bool get isShuffled => _isShuffled;
  AudioServiceRepeatMode get repeatMode => _repeatMode;

  /// Play a song by fetching its stream URL or using downloaded file.
  /// Uses a generation counter so if a newer request comes in, the older one
  /// aborts gracefully without overriding the player.
  Future<void> playSong(Song song) async {
    // Increment generation — any in-flight play with an older generation
    // will detect this and bail out before setting the audio source.
    final thisGeneration = ++_playGeneration;

    // Playing anything other than the restored song discards the saved resume
    // position — it belonged to a previous session's context.
    if (_pendingRestoreSongId != null && _pendingRestoreSongId != song.videoId) {
      _pendingRestoreSongId = null;
      _pendingRestorePosition = null;
    }

    // Pause current audio so previous track stops smoothly without tearing down ExoPlayer audio session
    try {
      if (_player.playing) {
        await _player.pause();
      }
    } catch (_) {}

    try {
      // Update playlist immediately so UI reflects the correct song
      final existingIndex = _playlist.indexWhere((s) => s.videoId == song.videoId);
      if (existingIndex >= 0) {
        _currentIndex = existingIndex;
      } else {
        _playlist.add(song);
        _currentIndex = _playlist.length - 1;
      }

      // Update media item immediately for responsive UI
      _updateMediaItem(song);

      // Instant Fast-Path for Local Media & Offline Downloads (0ms resolution)
      String? localPath;
      if (song.filePath != null && song.filePath!.isNotEmpty && File(song.filePath!).existsSync()) {
        localPath = song.filePath;
      } else if (song.videoId.startsWith('content://') || song.videoId.startsWith('file://') || song.videoId.startsWith('/')) {
        final cleanPath = song.videoId.startsWith('file://') ? Uri.parse(song.videoId).toFilePath() : song.videoId;
        if (cleanPath.startsWith('content://') || File(cleanPath).existsSync()) {
          localPath = cleanPath;
        }
      } else {
        localPath = DownloadService().getCachedLocalPathSync(song.videoId);
      }

      if (_playGeneration != thisGeneration) return;

      if (localPath != null && localPath.isNotEmpty) {
        final mediaItem = MediaItem(
          id: song.videoId,
          album: song.albumFolderName ?? (song.isLocalFile ? 'Local Storage' : 'Downloads'),
          title: song.title,
          artist: song.artist,
          artUri: song.thumbnailUrl.isNotEmpty
              ? (song.thumbnailUrl.startsWith('http')
                  ? Uri.parse(song.thumbnailUrl)
                  : Uri.file(song.thumbnailUrl))
              : null,
          duration: song.duration,
        );

        await _withPlayerLock(thisGeneration, () async {
          if (localPath!.startsWith('content://') ||
              localPath.startsWith('file://')) {
            await _player.setAudioSource(
              AudioSource.uri(Uri.parse(localPath), tag: mediaItem),
            );
          } else {
            await _player.setAudioSource(
              AudioSource.file(localPath, tag: mediaItem),
            );
          }
        });
      } else {
        // Online stream, or a late local lookup when the index isn't ready yet.
        //
        // Once the download index is loaded, the synchronous probe above is
        // authoritative — it already checked song.filePath, the metadata list
        // and every candidate extension. Re-running the async isSongDownloaded
        // + _resolveLocalPath pair here would repeat that same disk work on the
        // way to every streamed song, so only fall back to it before the first
        // loadDownloads() has populated the index.
        String? resolvedLocalPath;
        if (!DownloadService().isIndexLoaded) {
          final isDownloaded =
              await DownloadService().isSongDownloaded(song.videoId);
          if (_playGeneration != thisGeneration) return;

          resolvedLocalPath = await _resolveLocalPath(song, isDownloaded);
          if (_playGeneration != thisGeneration) return;
        }

        if (resolvedLocalPath != null) {
          await _withPlayerLock(thisGeneration, () async {
            await _player.setAudioSource(
              AudioSource.file(
                resolvedLocalPath!,
                tag: MediaItem(
                  id: song.videoId,
                  album: song.albumFolderName ?? 'Downloads',
                  title: song.title,
                  artist: song.artist,
                  artUri: song.thumbnailUrl.isNotEmpty
                      ? (song.thumbnailUrl.startsWith('http')
                          ? Uri.parse(song.thumbnailUrl)
                          : Uri.file(song.thumbnailUrl))
                      : null,
                  duration: song.duration,
                ),
              ),
            );
          });
        } else {
          await _resolveAndLoadStream(song, thisGeneration);
        }
      }

      // Final check before starting playback
      if (_playGeneration != thisGeneration) return;

      // Everything from here is ordered around ONE goal: make sound come out as
      // soon as ExoPlayer has the first bytes, and do the rest behind it.
      // AndroidLoadControl already releases playback at 600ms buffered and keeps
      // filling to 120s in the background, so the only thing that can delay
      // first audio now is work we insist on awaiting before play().

      // Speed/pitch DO have to precede play() — starting at the wrong rate and
      // correcting is audible. But they only matter when the song actually
      // carries a non-default value, which is the rare case, so the normal path
      // pays nothing. (just_audio resets both when the source changes, hence the
      // re-apply.)
      if (song.speed != 1.0) {
        await _player.setSpeed(song.speed);
      }
      if (song.pitch != 0) {
        await _player.setPitch(1.0 + (song.pitch / 12.0));
      }

      // Session restore: resume where the user left off (one-shot). Also before
      // play(), otherwise playback starts at 0:00 and audibly jumps.
      if (_pendingRestoreSongId == song.videoId &&
          _pendingRestorePosition != null) {
        final restorePos = _pendingRestorePosition!;
        _pendingRestoreSongId = null;
        _pendingRestorePosition = null;
        try {
          await _player.seek(restorePos);
        } catch (_) {}
      }

      // Re-check: the awaits above can each yield to a newer request.
      if (_playGeneration != thisGeneration) return;

      _nearEndPrefetchedIndex = -1;
      _player.play();

      // The equalizer is a pure effect on an already-running stream, so it does
      // NOT gate first audio — applying it used to cost several awaits ahead of
      // play(). Unawaited, it settles a frame or two in.
      unawaited(_applyPlaybackEffects(song, thisGeneration));

      // Prefetch next song's stream URL in background for instant skip
      _prefetchNext();
    } catch (e) {
      // Only touch the player if this request is still the active one. A
      // superseded request that fails must stay silent: it used to call stop()
      // unconditionally, so song A failing to resolve tore down song B — the
      // one the user had actually tapped and which was already playing.
      if (_playGeneration != thisGeneration) return;

      // Clean player reset on failure so player engine doesn't freeze or lock up
      try {
        await _player.stop();
      } catch (_) {}
      throw Exception(_friendlyErrorMessage(e));
    }
  }

  /// Apply the equalizer / isolation-mode effect for [song] once playback has
  /// already started. Runs off the critical path — a wrong EQ curve for a
  /// fraction of a second is invisible next to delaying the first note.
  Future<void> _applyPlaybackEffects(Song song, int thisGeneration) async {
    if (_playGeneration != thisGeneration) return;
    try {
      if (song.isolationMode == 'vocal') {
        _isKaraokeMode = false;
        await _applyCustomEqualizerGains(const [-12.0, -12.0, 12.0, 12.0, -12.0]);
      } else if (song.isolationMode == 'instrument') {
        _isKaraokeMode = true;
        await _applyEqualizerPreset(_lastAppliedEnhancerMode);
      } else if (_useCustomGains && _customGains != null) {
        _isKaraokeMode = false;
        await _applyCustomEqualizerGains(_customGains!);
      } else {
        _isKaraokeMode = false;
        await _applyEqualizerPreset(_lastAppliedEnhancerMode);
      }
    } catch (e) {
      debugPrint('[AudioHandler] Failed to apply playback effects: $e');
    }
  }

  final Map<String, _PrefetchedStream> _prefetchedStreams = {};

  /// How long a pre-resolved stream stays usable.
  ///
  /// This tracked an assumed 5-minute expiry on YouTube stream URLs, which is
  /// not what they actually carry — the signed links are good for hours, which
  /// is why [YouTubeService] now caches them for 90 minutes. 30 minutes covers
  /// any realistic queue lookahead without pretending a prefetch is good
  /// forever, and an entry that does go stale is not a failure: the load falls
  /// into the same fallback ladder as any other, which re-resolves with
  /// `forceRefresh`.
  static const Duration _prefetchTtl = Duration(minutes: 30);

  /// Drop every pre-resolved stream. Called when the audio-quality setting
  /// changes — entries are keyed by videoId only, so without this a queued song
  /// would still play at the previous quality.
  void clearPrefetchedStreams() {
    _prefetchedStreams.clear();
  }

  /// Take a prefetched stream if one is present and still fresh.
  ///
  /// Consuming removes the entry: a stream URL is single-use here, and leaving
  /// a stale entry behind meant a failed play would keep re-reading the same
  /// dead URL on every retry.
  ResolvedStream? _takePrefetched(String videoId) {
    final entry = _prefetchedStreams.remove(videoId);
    if (entry == null) return null;
    if (DateTime.now().difference(entry.resolvedAt) > _prefetchTtl) {
      debugPrint('[AudioHandler] Discarded stale prefetch for $videoId');
      return null;
    }
    return entry.stream;
  }

  /// Resolve stream URL and load it, with multi-stage fallback and automatic retry.
  Future<void> _resolveAndLoadStream(Song song, int thisGeneration) async {
    ResolvedStream? resolved = _takePrefetched(song.videoId);
    if (resolved != null) {
      debugPrint('[AudioHandler] Pre-fetched stream hit for instant skip: ${song.title}');
    } else {
      resolved = await StreamResolverService().resolve(song);
    }

    if (resolved == null) {
      throw Exception('Could not find a playable stream. Please check your internet connection and try again.');
    }
    if (_playGeneration != thisGeneration) return;

    try {
      await _loadResolvedSource(resolved, song, thisGeneration);
    } catch (playerError) {
      debugPrint('[AudioHandler] Primary source failed (${resolved.source}): $playerError');

      // The url just proved unplayable, so it must not be served again from the
      // 90-minute cache. Resolution cannot detect this — the url resolved fine;
      // it was the *fetch* that failed (403, IP rebinding, a format ExoPlayer
      // rejects). Dropping it here is what stops the rest of this ladder, and
      // every later attempt in this session, from retrying the same dead link.
      YouTubeService.invalidateStreamUrl(song.videoId);

      if (resolved.source == 'jiosaavn') {
        // JioSaavn failed → try YouTube (via full resolve which now uses cache-first)
        if (_playGeneration != thisGeneration) return;
        try {
          final ytResolved = await StreamResolverService().resolve(
            Song(
              id: song.id,
              title: song.title,
              artist: song.artist,
              thumbnailUrl: song.thumbnailUrl,
              highResThumbnailUrl: song.highResThumbnailUrl,
              duration: song.duration,
              videoId: song.videoId, // stripped of jiosaavn_ prefix context
            ),
          );
          if (ytResolved != null && _playGeneration == thisGeneration) {
            await _loadResolvedSource(ytResolved, song, thisGeneration);
            return;
          }
        } catch (ytError) {
          debugPrint('[AudioHandler] YouTube fallback for JioSaavn also failed: $ytError');
          YouTubeService.invalidateStreamUrl(song.videoId);
        }
      }

      // Primary failed → try forceRefresh resolution (bypasses all caches)
      if (_playGeneration != thisGeneration) return;
      debugPrint('[AudioHandler] Primary source failed. Retrying with forceRefresh...');
      try {
        final retryResolved = await StreamResolverService()
            .resolve(song, forceRefresh: true);
        if (retryResolved != null && _playGeneration == thisGeneration) {
          await _loadResolvedSource(retryResolved, song, thisGeneration);
          return;
        }
      } catch (retryError) {
        debugPrint('[AudioHandler] ForceRefresh retry failed: $retryError');
      }

      // Leave nothing behind. The user's next tap on this song should start
      // from a clean resolution, not inherit whatever this attempt cached.
      YouTubeService.invalidateStreamUrl(song.videoId);
      throw Exception(
        'Unable to play this song. Your internet connection may be too slow or the song is temporarily unavailable. Please try again later.'
      );
    }
  }

  /// Convert raw exception messages into user-friendly error messages.
  String _friendlyErrorMessage(dynamic error) {
    final msg = error.toString().toLowerCase();

    if (msg.contains('socketexception') || msg.contains('connection refused') || msg.contains('network is unreachable')) {
      return 'No internet connection. Please check your network and try again.';
    }
    if (msg.contains('handshakeexception') || msg.contains('certificate')) {
      return 'Secure connection failed. Please check your network settings.';
    }
    if (msg.contains('timeout') || msg.contains('timed out')) {
      return 'Connection timed out. Your internet may be slow — please try again.';
    }
    if (msg.contains('429') || msg.contains('too many requests')) {
      return 'Too many requests. Please wait a moment and try again.';
    }
    if (msg.contains('403') || msg.contains('forbidden')) {
      return 'This song is currently restricted. Please try a different song.';
    }
    if (msg.contains('404') || msg.contains('not found')) {
      return 'This song is no longer available. Please try a different song.';
    }
    if (msg.contains('source error') || msg.contains('playback error')) {
      return 'Unable to play this song. Please try again or choose a different song.';
    }
    if (msg.contains('could not find') || msg.contains('unavailable')) {
      return error.toString().replaceAll('Exception:', '').trim();
    }

    // Default
    return 'Something went wrong. Please try again.';
  }

  /// Build matching HTTP client headers for a stream URL.
  /// Matches GoogleVideo's expected User-Agent by player client token (c=ANDROID, c=IOS, c=TV, c=ANDROID_VR, c=WEB).
  static Map<String, String> _buildStreamHeaders(ResolvedStream resolved) {
    if (resolved.headers != null && resolved.headers!.isNotEmpty) {
      return resolved.headers!;
    }

    final url = resolved.url.toLowerCase();
    if (url.contains('googlevideo.com') ||
        resolved.source == 'youtube' ||
        resolved.source == 'youtube_fallback') {
      if (url.contains('c=android_vr')) {
        return const {
          'User-Agent': 'Mozilla/5.0 (Linux; Android 10; Quest 2) AppleWebKit/537.36 (KHTML, like Gecko) OculusBrowser/15.0.0.4.58.291776510 SamsungBrowser/4.0 Chrome/89.0.4389.90 VR Safari/537.36',
          'Accept': '*/*',
          'Accept-Encoding': 'identity',
        };
      } else if (url.contains('c=android') || url.contains('c=android_music') || url.contains('c=android_creator')) {
        // Official YouTube Android client headers — NO desktop referer, as CDN checks client signature
        return const {
          'User-Agent': 'com.google.android.youtube/19.44.38 (Linux; U; Android 14; en_US; Pixel 8 Pro) gzip',
          'Accept': '*/*',
          'Accept-Encoding': 'identity',
        };
      } else if (url.contains('c=ios') || url.contains('c=ios_music')) {
        return const {
          'User-Agent': 'com.google.ios.youtube/19.45.4 (iPhone14,3; U; CPU iOS 18_1 like Mac OS X; en_US)',
          'Accept': '*/*',
          'Accept-Encoding': 'identity',
        };
      } else if (url.contains('c=tv') || url.contains('c=tv_embedded')) {
        return const {
          'User-Agent': 'Mozilla/5.0 (SmartHub; SMART-TV; U; Linux/SmartTV) Cobalt/20.master.0-qa (unlike Gecko) v8/8.8.278.8-bpt',
          'Accept': '*/*',
          'Accept-Encoding': 'identity',
        };
      } else if (url.contains('c=web') || url.contains('c=mweb')) {
        return const {
          'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36',
          'Accept': '*/*',
          'Accept-Encoding': 'identity',
          'Referer': 'https://www.youtube.com/',
        };
      } else {
        // Universal clean header for Google Video streams: matches mobile client without forbidden referer
        return const {
          'User-Agent': 'com.google.android.youtube/19.44.38 (Linux; U; Android 14; en_US; Pixel 8 Pro) gzip',
          'Accept': '*/*',
          'Accept-Encoding': 'identity',
        };
      }
    }

    return const {
      'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36',
      'Accept': '*/*',
    };
  }

  Future<void> _loadResolvedSource(
      ResolvedStream resolved, Song song, int thisGeneration) async {
    final isLocal = song.isLocalFile || song.filePath != null || resolved.source == 'local';

    final defaultAlbum = isLocal
        ? 'Local Storage'
        : (resolved.source == 'radio'
            ? 'Live Radio'
            : (resolved.source == 'jamendo'
                ? 'Jamendo'
                : (resolved.source == 'jiosaavn'
                    ? 'JioSaavn'
                    : (resolved.source == 'archive'
                        ? 'Archive'
                        : 'YouTube')))); // youtube, youtube_cached, youtube_proxy all show as YouTube

    final mediaItem = MediaItem(
      id: song.videoId,
      album: song.albumFolderName ?? defaultAlbum,
      title: song.title,
      artist: song.artist,
      artUri: song.thumbnailUrl.isNotEmpty
          ? (song.thumbnailUrl.startsWith('http')
              ? Uri.parse(song.thumbnailUrl)
              : Uri.file(song.thumbnailUrl))
          : null,
      duration: song.duration,
    );

    await _withPlayerLock(thisGeneration, () async {
      if (resolved.isLive) {
        final headers = _buildStreamHeaders(resolved);
        await _player.setAudioSource(
          AudioSource.uri(
            Uri.parse(resolved.url),
            headers: headers,
            tag: mediaItem,
          ),
        );
      } else if (resolved.url.startsWith('file://') ||
          resolved.url.startsWith('/') ||
          (resolved.url.length >= 3 && resolved.url[1] == ':' && (resolved.url[2] == '/' || resolved.url[2] == '\\'))) {
        final filePath = resolved.url.startsWith('file://')
            ? Uri.parse(resolved.url).toFilePath()
            : resolved.url;
        final rawFile = File(filePath);
        final playableFile = await AudioFormatSniffer().getPlayableFile(rawFile);
        debugPrint('[AudioHandler] Playing local audio file: ${playableFile.path}');
        await _player.setAudioSource(
          AudioSource.file(playableFile.path, tag: mediaItem),
        );
      } else {
        debugPrint('[AudioHandler] Playing HTTP stream URL: ${resolved.url}');
        final headers = _buildStreamHeaders(resolved);
        await _player.setAudioSource(
          await _cachingSourceFor(resolved, song, mediaItem, headers),
        );
      }
    });
  }

  /// Build the audio source for a streamed song, serving from disk if previously cached
  /// or streaming natively via ExoPlayer's high-performance DefaultHttpDataSource.
  Future<AudioSource> _cachingSourceFor(
    ResolvedStream resolved,
    Song song,
    MediaItem mediaItem,
    Map<String, String> headers,
  ) async {
    final cacheable = !resolved.isLive &&
        song.videoId.isNotEmpty &&
        resolved.url.startsWith('http');
    if (cacheable) {
      try {
        final cache = StreamCacheService();
        final file = await cache.fileFor(
            song.videoId, YouTubeService.streamingQuality.name);
        final alreadyCached = await file.exists();
        if (alreadyCached && (await file.length()) > 1024) {
          debugPrint('[AudioHandler] Stream cache hit: ${song.title}');
          return AudioSource.file(file.path, tag: mediaItem);
        }
      } catch (e) {
        debugPrint('[AudioHandler] Stream cache probe error: $e');
      }
    }

    // Direct native streaming via ExoPlayer's DefaultHttpDataSource
    return AudioSource.uri(
      Uri.parse(resolved.url),
      headers: headers,
      tag: mediaItem,
    );
  }

  /// Prefetch the next 2 songs' stream URLs so skipping is instant
  /// Returns a playable on-disk path for [song], or null to fall through to
  /// streaming. Order: real `song.filePath` (album/moved/folder songs) → the
  /// reconstructed Download path (only if it exists). Never returns a path that
  /// isn't actually on disk, so a stale reference cleanly falls back to stream.
  Future<String?> _resolveLocalPath(Song song, bool isDownloaded) async {
    final fp = song.filePath;
    if (fp != null && fp.isNotEmpty) {
      try {
        if (await File(fp).exists()) return fp;
      } catch (_) {}
    }
    try {
      final cachedPath = DownloadService().getCachedLocalPathSync(song.videoId);
      if (cachedPath != null && await File(cachedPath).exists()) return cachedPath;
    } catch (_) {}
    if (isDownloaded) {
      try {
        final localPath = await DownloadService().getLocalAudioPath(song.videoId);
        if (await File(localPath).exists()) return localPath;
      } catch (_) {}
    }
    return null;
  }

  void _prefetchNext() {
    // Only rearm if nothing is already pending. The timer used to be cancelled
    // and restarted on every playSong, so skipping faster than the 2s delay
    // meant prefetch never fired at all — exactly when it is most useful.
    if (_prefetchTimer?.isActive ?? false) return;
    // The delay exists only to keep the prefetch resolves off the same event
    // loop turn as the current song's setAudioSource, so they can't compete
    // with first audio. 2s was far longer than that needs: resolution itself
    // takes several seconds, so a user skipping in the first ~5s of a track —
    // the common way people move through a queue — arrived before the prefetch
    // had even started and paid the full price anyway. 300ms clears the
    // critical path and still has the +1 song resolving while the current one
    // is barely into its first bar.
    _prefetchTimer = Timer(const Duration(milliseconds: 300), () async {
      // Snapshot the index: by the time these resolves finish the user may have
      // skipped again, and we don't want to write prefetches for a stale queue.
      final baseIndex = _currentIndex;
      final targets = <Song>[];
      for (int offset = 1; offset <= 2; offset++) {
        final nextIdx = baseIndex + offset;
        if (nextIdx < _playlist.length) {
          final nextSong = _playlist[nextIdx];
          if (!_prefetchedStreams.containsKey(nextSong.videoId) &&
              !nextSong.isLocalFile) {
            targets.add(nextSong);
          }
        }
      }
      if (targets.isEmpty) return;

      // Resolve both in parallel — the old sequential await made the +2 song
      // wait for the +1 song's full network round-trip.
      await Future.wait(targets.map((nextSong) async {
        try {
          final resolved = await StreamResolverService().resolve(nextSong);
          if (resolved != null) {
            _prefetchedStreams[nextSong.videoId] =
                _PrefetchedStream(resolved, DateTime.now());
            debugPrint('[AudioHandler] Pre-resolved stream: ${nextSong.title}');
          }
        } catch (_) {}
      }));
    });
  }

  void _updateMediaItem(Song song) {
    final bool isHttp = song.thumbnailUrl.startsWith('http://') || song.thumbnailUrl.startsWith('https://');
    final bool isLocal = song.thumbnailUrl.isNotEmpty && !isHttp &&
        (song.thumbnailUrl.startsWith('/') ||
         (song.thumbnailUrl.length >= 3 && song.thumbnailUrl[1] == ':' && (song.thumbnailUrl[2] == '/' || song.thumbnailUrl[2] == '\\')));
        
    Uri? artUri;
    if (song.thumbnailUrl.isNotEmpty) {
      try {
        artUri = isLocal ? Uri.file(song.thumbnailUrl) : Uri.parse(song.thumbnailUrl);
      } catch (e) {
        debugPrint('Error parsing artUri: $e');
      }
    }

    mediaItem.add(MediaItem(
      id: song.videoId,
      title: song.title,
      artist: song.artist,
      artUri: artUri,
      duration: song.duration,
    ));
  }

  void updateMediaItemCustom(Song song) {
    _updateMediaItem(song);
  }

  void updatePlaylistSong(
    String videoId,
    String title,
    String artist,
    Duration? duration, {
    double? speed,
    double? pitch,
    double? fadeIn,
    double? fadeOut,
  }) {
    for (int i = 0; i < _playlist.length; i++) {
      if (_playlist[i].videoId == videoId) {
        _playlist[i] = _playlist[i].copyWith(
          title: title,
          artist: artist,
          duration: duration ?? _playlist[i].duration,
          speed: speed ?? _playlist[i].speed,
          pitch: pitch ?? _playlist[i].pitch,
          fadeIn: fadeIn ?? _playlist[i].fadeIn,
          fadeOut: fadeOut ?? _playlist[i].fadeOut,
        );
        if (_currentIndex == i) {
          _updateMediaItem(_playlist[i]);
          if (speed != null) {
            _player.setSpeed(speed);
          }
          if (pitch != null) {
            _player.setPitch(1.0 + (pitch / 12.0));
          }
        }
      }
    }
  }

  /// Play a list of songs starting from an index
  Future<void> playPlaylist(List<Song> songs, {int startIndex = 0}) async {
    _playlist.clear();
    _playlist.addAll(songs);
    _currentIndex = startIndex;

    if (songs.isNotEmpty && startIndex < songs.length) {
      await playSong(songs[startIndex]);
    }
  }

  /// Restore a previously saved queue WITHOUT starting playback. The current
  /// song's stream is loaded lazily on the first play() so a cold start never
  /// hits the network. [position] is where playback resumes from.
  void restoreQueue(List<Song> songs, int index, Duration position) {
    if (songs.isEmpty) return;
    _playlist
      ..clear()
      ..addAll(songs);
    _currentIndex = index.clamp(0, songs.length - 1);
    _pendingRestoreSongId = _playlist[_currentIndex].videoId;
    _pendingRestorePosition = position;
    _updateMediaItem(_playlist[_currentIndex]);
  }

  /// Move a queue entry from [oldIndex] to [newIndex], keeping the playing
  /// song's index pointer correct.
  void reorderQueue(int oldIndex, int newIndex) {
    if (oldIndex < 0 || oldIndex >= _playlist.length) return;
    if (newIndex < 0 || newIndex >= _playlist.length) return;
    if (oldIndex == newIndex) return;

    final song = _playlist.removeAt(oldIndex);
    _playlist.insert(newIndex, song);

    if (oldIndex == _currentIndex) {
      _currentIndex = newIndex;
    } else if (oldIndex < _currentIndex && newIndex >= _currentIndex) {
      _currentIndex--;
    } else if (oldIndex > _currentIndex && newIndex <= _currentIndex) {
      _currentIndex++;
    }
  }

  @override
  Future<void> play() async {
    // Lazy restore: queue was restored from disk but no source loaded yet.
    if (_pendingRestoreSongId != null &&
        _player.processingState == ProcessingState.idle &&
        currentSong != null) {
      await playSong(currentSong!);
      return;
    }
    await _player.play();
  }

  @override
  Future<void> pause() async {
    await _player.pause();
  }

  @override
  Future<void> stop() async {
    _playGeneration++;
    _prefetchTimer?.cancel();
    _cancelIdleTimer();
    _cancelPrefetchCleanupTimer();
    // The queue is gone, so every pre-resolved URL is now dead weight. Without
    // this the map only ever grew for the life of the process.
    _prefetchedStreams.clear();
    await _player.stop();
    _currentIndex = -1;
    _playlist.clear();
    mediaItem.add(null);
    await super.stop();
  }

  @override
  Future<void> seek(Duration position) async {
    await _player.seek(position);
  }

  /// Move the queue pointer to [index] and play it, restoring the pointer if
  /// the song fails to load.
  ///
  /// The pointer has to move BEFORE playback so the UI reacts instantly, but
  /// leaving it moved after a failure desynced the app from what was audible:
  /// the player screen, queue sheet and notification all advanced past a track
  /// that never started, and the next skip then jumped two songs ahead.
  Future<void> _moveToIndexAndPlay(int index,
      {bool announceNearEnd = false}) async {
    final previousIndex = _currentIndex;
    _currentIndex = index;
    _updateMediaItem(_playlist[_currentIndex]);
    if (announceNearEnd && _currentIndex >= _playlist.length - 2) {
      onQueueNearEnd?.call();
    }
    try {
      await playSong(_playlist[_currentIndex]);
    } catch (e) {
      // Only roll back if nothing newer has claimed the pointer meanwhile.
      if (_currentIndex == index &&
          previousIndex >= 0 &&
          previousIndex < _playlist.length) {
        _currentIndex = previousIndex;
        _updateMediaItem(_playlist[_currentIndex]);
      }
      // Rethrow so PlayerProvider's self-healing auto-skip still runs.
      rethrow;
    }
  }

  @override
  Future<void> skipToNext() async {
    if (_playlist.isEmpty) return;

    if (_currentIndex < _playlist.length - 1) {
      await _moveToIndexAndPlay(_currentIndex + 1, announceNearEnd: true);
    } else if (_repeatMode == AudioServiceRepeatMode.all) {
      await _moveToIndexAndPlay(0);
    }
  }

  /// Jump straight to a queue entry by index (used by the queue sheet).
  Future<void> skipToQueueIndex(int index) async {
    if (index < 0 || index >= _playlist.length) return;
    if (index == _currentIndex) return;
    await _moveToIndexAndPlay(index, announceNearEnd: true);
  }

  @override
  Future<void> skipToPrevious() async {
    if (_playlist.isEmpty) return;

    // If we're more than 3 seconds into the song, restart it
    if (_player.position.inSeconds > 3) {
      await _player.seek(Duration.zero);
      return;
    }

    if (_currentIndex > 0) {
      await _moveToIndexAndPlay(_currentIndex - 1);
    } else if (_repeatMode == AudioServiceRepeatMode.all) {
      await _moveToIndexAndPlay(_playlist.length - 1);
    }
  }

  void toggleShuffle() {
    _isShuffled = !_isShuffled;
    if (_isShuffled && _playlist.length > 1) {
      final current = currentSong;
      _playlist.shuffle();
      if (current != null) {
        _playlist.remove(current);
        _playlist.insert(0, current);
        _currentIndex = 0;
      }
    }
  }

  void cycleRepeatMode() {
    switch (_repeatMode) {
      case AudioServiceRepeatMode.none:
        _repeatMode = AudioServiceRepeatMode.all;
        break;
      case AudioServiceRepeatMode.all:
        _repeatMode = AudioServiceRepeatMode.one;
        break;
      case AudioServiceRepeatMode.one:
        _repeatMode = AudioServiceRepeatMode.none;
        break;
      default:
        _repeatMode = AudioServiceRepeatMode.none;
    }
  }

  void _handleSongCompletion() {
    // Sleep timer "end of track": stop here instead of advancing.
    if (stopAfterCurrentSong) {
      stopAfterCurrentSong = false;
      _player.pause();
      _player.seek(Duration.zero);
      onStopAfterCurrentFired?.call();
      return;
    }

    switch (_repeatMode) {
      case AudioServiceRepeatMode.one:
        _player.seek(Duration.zero);
        _player.play();
        break;
      case AudioServiceRepeatMode.all:
        skipToNext();
        break;
      case AudioServiceRepeatMode.none:
        if (_currentIndex < _playlist.length - 1) {
          skipToNext();
        }
        break;
      default:
        break;
    }
  }

  void removeFromPlaylist(int index) {
    if (index < 0 || index >= _playlist.length) return;
    _playlist.removeAt(index);
    if (index < _currentIndex) {
      _currentIndex--;
    } else if (index == _currentIndex) {
      if (_playlist.isNotEmpty) {
        _currentIndex = _currentIndex.clamp(0, _playlist.length - 1);
        playSong(_playlist[_currentIndex]);
      } else {
        _currentIndex = -1;
        stop();
      }
    }
  }

  void addSongToQueue(Song song) {
    if (!_playlist.any((s) => s.videoId == song.videoId)) {
      _playlist.add(song);
      _updateMediaItem(song);
    }
  }

  void insertSongNext(Song song) {
    if (_playlist.isEmpty) {
      _playlist.add(song);
      _currentIndex = 0;
      _updateMediaItem(song);
      return;
    }
    
    // Remove if already in playlist
    final existingIndex = _playlist.indexWhere((s) => s.videoId == song.videoId);
    if (existingIndex >= 0) {
      if (existingIndex == _currentIndex) return; // Already playing
      final existingSong = _playlist.removeAt(existingIndex);
      if (existingIndex < _currentIndex) {
        _currentIndex--;
      }
      _playlist.insert(_currentIndex + 1, existingSong);
    } else {
      _playlist.insert(_currentIndex + 1, song);
      _updateMediaItem(song);
    }
  }

  PlaybackState _transformEvent(PlaybackEvent event) {
    return PlaybackState(
      controls: [
        MediaControl.skipToPrevious,
        _player.playing ? MediaControl.pause : MediaControl.play,
        MediaControl.skipToNext,
      ],
      systemActions: const {
        MediaAction.seek,
        MediaAction.seekForward,
        MediaAction.seekBackward,
      },
      androidCompactActionIndices: const [0, 1, 2],
      processingState: const {
        ProcessingState.idle: AudioProcessingState.idle,
        ProcessingState.loading: AudioProcessingState.loading,
        ProcessingState.buffering: AudioProcessingState.buffering,
        ProcessingState.ready: AudioProcessingState.ready,
        ProcessingState.completed: AudioProcessingState.completed,
      }[_player.processingState]!,
      playing: _player.playing,
      updatePosition: _player.position,
      bufferedPosition: _player.bufferedPosition,
      speed: _player.speed,
      queueIndex: _currentIndex,
    );
  }

  Future<void> _applyEqualizerPreset(SoundEnhancer mode, {bool smooth = false}) async {
    if (_equalizer == null) return;
    try {
      await _equalizer!.setEnabled(true);
      final parameters = await _equalizer!.parameters;
      final bands = parameters.bands;
      if (bands.isEmpty) return;

      // Professional acoustic profiles mapping to 5 standard bands (typically 60Hz, 230Hz, 910Hz, 4kHz, 14kHz)
      final Map<SoundEnhancer, List<double>> presets = {
        SoundEnhancer.none:        [ 0.0,  0.0,  0.0,  0.0,  0.0],
        SoundEnhancer.bassBoost:   [ 9.0,  5.0, -1.5,  0.0,  1.0],
        SoundEnhancer.trebleBoost: [-2.0, -1.0,  1.0,  6.0, 10.0],
        SoundEnhancer.vocal:       [-4.0,  2.0,  7.0,  5.0,  2.0],
        SoundEnhancer.ambient3d:   [ 7.0,  3.0, -5.0,  3.0,  8.0],
        // Genre presets
        SoundEnhancer.electronic:  [ 5.0, -2.0, -3.0,  4.0,  6.0], // Sub punch, scooped mids, crisp highs
        SoundEnhancer.rockMetal:   [ 4.0,  3.0,  4.0,  3.0, -1.0], // Tight bass, full mids, warm highs
        SoundEnhancer.hipHop:      [ 8.0,  6.0, -2.0, -1.0,  2.0], // Deep sub, warm bass, controlled highs
        SoundEnhancer.pop:         [-1.0,  2.0,  1.0,  4.0,  5.0], // V-curve: warm bass + bright presence
        SoundEnhancer.acoustic:    [ 0.0,  3.0,  2.0,  3.0,  1.0], // Flat sub, warm natural mids
        SoundEnhancer.jazzBlues:   [ 3.0,  4.0,  0.0,  2.0,  3.0], // Warm bottom, natural mids, airy highs
        SoundEnhancer.nightMode:   [-3.0,  1.0,  3.0,  1.0, -4.0], // Vocal-forward, reduced sub & treble
      };


      final targetGains = presets[mode] ?? [0.0, 0.0, 0.0, 0.0, 0.0];
      await _applyGains(bands, targetGains, parameters.minDecibels, parameters.maxDecibels, smooth);
    } catch (e) {
      // Fail silently
    }
  }

  Future<void> _applyCustomEqualizerGains(List<double> gains, {bool smooth = false}) async {
    if (_equalizer == null) return;
    try {
      await _equalizer!.setEnabled(true);
      final parameters = await _equalizer!.parameters;
      final bands = parameters.bands;
      if (bands.isEmpty) return;

      final double minLimit = parameters.minDecibels;
      final double maxLimit = parameters.maxDecibels;

      final List<double> mappedGains = [];
      for (int i = 0; i < bands.length; i++) {
        if (i < gains.length) {
          final double rawGain = gains[i]; // slider value from -12 to 12
          // Normalize rawGain from [-12, 12] to [minLimit, maxLimit] to leverage full hardware range
          final double ratio = (rawGain + 12.0) / 24.0; // 0.0 to 1.0
          final double mappedGain = minLimit + ratio * (maxLimit - minLimit);
          mappedGains.add(mappedGain);
        } else {
          mappedGains.add(0.0);
        }
      }

      await _applyGains(bands, mappedGains, minLimit, maxLimit, smooth);
    } catch (e) {
      // Fail silently
    }
  }

  Future<void> _applyGains(
    List<AndroidEqualizerBand> bands,
    List<double> targets,
    double minLimit,
    double maxLimit,
    bool smooth,
  ) async {
    final List<double> clampedTargets = [];
    for (int i = 0; i < bands.length; i++) {
      double target = 0.0;
      if (i < targets.length) {
        target = targets[i];
      }

      // Scoop vocals if Karaoke mode is enabled (mids/vocals are located in band 2 and 3)
      if (_isKaraokeMode && (i == 2 || i == 3)) {
        target = minLimit;
      }

      clampedTargets.add(target.clamp(minLimit, maxLimit));
    }

    // Ensure _currentGains is same length as bands
    while (_currentGains.length < bands.length) {
      _currentGains.add(0.0);
    }

    if (smooth) {
      const int steps = 6;
      for (int step = 1; step <= steps; step++) {
        final List<Future<void>> futures = [];
        for (int i = 0; i < bands.length; i++) {
          final double start = _currentGains[i];
          final double end = clampedTargets[i];
          final double intermediate = start + (end - start) * (step / steps);
          futures.add(bands[i].setGain(intermediate));
        }
        await Future.wait(futures);
        await Future.delayed(const Duration(milliseconds: 30)); // 180ms total transition time
      }
    } else {
      final List<Future<void>> futures = [];
      for (int i = 0; i < bands.length; i++) {
        futures.add(bands[i].setGain(clampedTargets[i]));
      }
      await Future.wait(futures);
    }

    _currentGains = List.from(clampedTargets);
  }

  @override
  Future<void> onTaskRemoved() async {
    _cancelIdleTimer();
    _cancelPrefetchCleanupTimer();
    await stop();
    await super.onTaskRemoved();
  }
}

/// A pre-resolved stream plus the moment it was resolved, so staleness can be
/// judged before handing the URL to the player.
class _PrefetchedStream {
  final ResolvedStream stream;
  final DateTime resolvedAt;

  _PrefetchedStream(this.stream, this.resolvedAt);
}
