import 'dart:io';
import 'dart:async';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:path_provider/path_provider.dart';
import '../models/song.dart';
import '../providers/player_provider.dart';
import '../providers/settings_provider.dart';
import '../services/download_service.dart';
import '../services/storage_location_service.dart';
import '../theme/app_colors.dart';
import 'audio_waveform_timeline.dart';
import 'song_album_art.dart';

class SoundStudioEditingView extends StatefulWidget {
  final Song song;
  final PageController pageController;

  const SoundStudioEditingView({
    super.key,
    required this.song,
    required this.pageController,
  });

  @override
  State<SoundStudioEditingView> createState() => _SoundStudioEditingViewState();
}

class _SoundStudioEditingViewState extends State<SoundStudioEditingView> {
  late TextEditingController _titleController;
  late TextEditingController _artistController;
  double _trimStartSecs = 0.0;
  double _trimEndSecs = 1.0;
  bool _isTrimmingFile = false;
  double _speed = 1.0;
  double _pitch = 0.0;
  double _fadeIn = 0.0;
  double _fadeOut = 0.0;

  double _currentPreviewSecs = 0.0;
  bool _isPreviewPlaying = false;
  Timer? _previewTimer;
  double? _originalVolume;
  String _isolationMode = 'none'; // 'none', 'vocal', 'instrument'
  String _fadeCurve = 'scurve'; // 'linear' or 'scurve'

  @override
  void initState() {
    super.initState();
    _initFields(widget.song);
  }

  @override
  void didUpdateWidget(covariant SoundStudioEditingView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.song.videoId != widget.song.videoId) {
      _stopPreview();
      _initFields(widget.song);
    }
  }

  void _initFields(Song song) {
    _titleController = TextEditingController(text: song.title);
    _artistController = TextEditingController(text: song.artist);
    _trimStartSecs = 0.0;
    _trimEndSecs = song.duration.inSeconds.toDouble();
    if (_trimEndSecs <= 0.0) _trimEndSecs = 1.0;
    _speed = song.speed;
    _pitch = song.pitch;
    _fadeIn = song.fadeIn;
    _fadeOut = song.fadeOut;
    _isolationMode = song.isolationMode;
  }

  @override
  void dispose() {
    _stopPreview();
    _titleController.dispose();
    _artistController.dispose();
    super.dispose();
  }

  void _stopPreview() {
    _previewTimer?.cancel();
    _previewTimer = null;
    if (_isPreviewPlaying) {
      final playerProvider = Provider.of<PlayerProvider>(context, listen: false);
      playerProvider.pause();
      if (_originalVolume != null) {
        playerProvider.player.setVolume(_originalVolume!);
      }
      playerProvider.audioHandler.setKaraokeMode(playerProvider.isKaraokeMode);
      if (playerProvider.useCustomEqualizer) {
        playerProvider.audioHandler.setCustomEqualizerGains(playerProvider.customEqualizerGains);
      }
      if (mounted) {
        setState(() {
          _isPreviewPlaying = false;
          _currentPreviewSecs = 0.0;
        });
      }
    }
  }

  void _startPreview(Song song, PlayerProvider playerProvider) {
    if (_isPreviewPlaying) {
      _stopPreview();
      return;
    }

    final double start = _trimStartSecs;
    final double end = _trimEndSecs;

    _originalVolume = playerProvider.player.volume;

    if (_isolationMode == 'vocal') {
      playerProvider.audioHandler.setKaraokeMode(false);
      playerProvider.audioHandler.setCustomEqualizerGains(const [-12.0, -12.0, 12.0, 12.0, -12.0]);
    } else if (_isolationMode == 'instrument') {
      playerProvider.audioHandler.setKaraokeMode(true);
    } else {
      playerProvider.audioHandler.setKaraokeMode(false);
      if (playerProvider.useCustomEqualizer) {
        playerProvider.audioHandler.setCustomEqualizerGains(playerProvider.customEqualizerGains);
      }
    }

    playerProvider.seek(Duration(seconds: start.toInt()));
    playerProvider.play();

    setState(() {
      _isPreviewPlaying = true;
      _currentPreviewSecs = start;
    });

    _previewTimer = Timer.periodic(const Duration(milliseconds: 50), (timer) {
      if (!mounted || !playerProvider.isPlaying) {
        _stopPreview();
        return;
      }

      final double posSecs = playerProvider.position.inSeconds.toDouble();

      setState(() {
        _currentPreviewSecs = posSecs;
      });

      if (posSecs >= end || posSecs < start - 2) {
        _stopPreview();
        return;
      }

      double volumeMultiplier = 1.0;
      final double elapsed = posSecs - start;
      final double remaining = end - posSecs;

      if (_fadeIn > 0 && elapsed < _fadeIn) {
        final double ratio = (elapsed / _fadeIn).clamp(0.0, 1.0);
        if (_fadeCurve == 'scurve') {
          volumeMultiplier = 0.5 * (1.0 - math.cos(ratio * math.pi));
        } else {
          volumeMultiplier = ratio;
        }
      } else if (_fadeOut > 0 && remaining < _fadeOut) {
        final double ratio = (remaining / _fadeOut).clamp(0.0, 1.0);
        if (_fadeCurve == 'scurve') {
          volumeMultiplier = 0.5 * (1.0 - math.cos(ratio * math.pi));
        } else {
          volumeMultiplier = ratio;
        }
      }

      final double newVol = (_originalVolume ?? 1.0) * volumeMultiplier.clamp(0.0, 1.0);
      playerProvider.player.setVolume(newVol);
    });
  }

  Future<void> _saveSongEdits(Song song, PlayerProvider provider, {required bool saveAsCopy}) async {
    setState(() {
      _isTrimmingFile = true;
    });

    try {
      final newTitle = _titleController.text.trim();
      final newArtist = _artistController.text.trim();

      if (newTitle.isEmpty || newArtist.isEmpty) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Title and Artist cannot be empty')),
        );
        return;
      }

      final int originalSecs = song.duration.inSeconds;
      final int startSecs = _trimStartSecs.toInt();
      final int endSecs = _trimEndSecs.toInt();

      Duration finalDuration = song.duration;
      final isLocal = song.isLocalFile;
      String originalFilePath = '';
      if (isLocal) {
        originalFilePath = song.videoId;
      } else {
        originalFilePath = await DownloadService().getLocalAudioPath(song.videoId);
      }

      String targetVideoId = song.videoId;
      if (saveAsCopy) {
        final timestamp = DateTime.now().millisecondsSinceEpoch;
        targetVideoId = '${song.videoId}_edited_$timestamp';
      }

      if (originalFilePath.isNotEmpty) {
        final file = File(originalFilePath);
        if (await file.exists()) {
          final bytes = await file.readAsBytes();
          final totalBytes = bytes.length;
          final totalMs = song.duration.inMilliseconds;

          List<int> processedBytes = bytes;

          if (startSecs > 0 || endSecs < originalSecs) {
            if (totalMs > 0 && totalBytes > 0) {
              final double bytesPerMs = totalBytes / totalMs;
              final int startByte = (startSecs * 1000 * bytesPerMs).toInt().clamp(0, totalBytes);
              final int endByte = (endSecs * 1000 * bytesPerMs).toInt().clamp(0, totalBytes);

              if (startByte < endByte) {
                processedBytes = bytes.sublist(startByte, endByte);
                finalDuration = Duration(seconds: endSecs - startSecs);
              }
            }
          }

          if (saveAsCopy) {
            final newSong = Song(
              id: targetVideoId,
              title: '$newTitle (Edit)',
              artist: newArtist,
              thumbnailUrl: song.thumbnailUrl,
              highResThumbnailUrl: song.highResThumbnailUrl,
              duration: finalDuration,
              videoId: targetVideoId,
              speed: _speed,
              pitch: _pitch,
              fadeIn: _fadeIn,
              fadeOut: _fadeOut,
              isolationMode: _isolationMode,
            );

            final tempDir = await getTemporaryDirectory();
            final tempFile = File('${tempDir.path}/$targetVideoId.mp3');
            await tempFile.writeAsBytes(processedBytes);

            await provider.saveNewSongCopy(song, newSong, tempFile.path);
            try {
              await tempFile.delete();
            } catch (_) {}
          } else {
            await file.writeAsBytes(processedBytes);
            await provider.updateSongMetadata(
              song.videoId,
              newTitle,
              newArtist,
              speed: _speed,
              pitch: _pitch,
              fadeIn: _fadeIn,
              fadeOut: _fadeOut,
              isolationMode: _isolationMode,
            );
            if (finalDuration != song.duration) {
              await provider.updateSongDuration(song.videoId, finalDuration);
            }
          }
        }
      }

      if (!mounted) return;
      widget.pageController.animateToPage(0, duration: const Duration(milliseconds: 400), curve: Curves.easeOutCubic);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(saveAsCopy ? 'New copy saved successfully!' : 'Song metadata & trim saved successfully!')),
      );
    } catch (e) {
      debugPrint('Error saving song edits: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error saving changes: $e')),
        );
      }
    } finally {
      if (mounted) {
        setState(() {
          _isTrimmingFile = false;
        });
      }
    }
  }

  void _showSaveOptionsSheet(BuildContext context, Song song, PlayerProvider provider) {
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (context) {
        return Container(
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 28),
          decoration: BoxDecoration(
            color: const Color(0xFF161622),
            borderRadius: const BorderRadius.vertical(top: Radius.circular(28)),
            border: Border.all(color: Colors.white.withValues(alpha: 0.08)),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.6),
                blurRadius: 20,
                offset: const Offset(0, -5),
              )
            ],
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Center(
                child: Container(
                  width: 40,
                  height: 4,
                  decoration: BoxDecoration(
                    color: Colors.white24,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
              const SizedBox(height: 20),
              Text(
                'SAVE AUDIO OPTIONS',
                textAlign: TextAlign.center,
                style: GoogleFonts.outfit(
                  color: Colors.white,
                  fontSize: 16,
                  fontWeight: FontWeight.bold,
                  letterSpacing: 2.0,
                ),
              ),
              const SizedBox(height: 8),
              const Text(
                'Choose how you want to save your customized audio file and metadata.',
                textAlign: TextAlign.center,
                style: TextStyle(color: AppColors.textTertiary, fontSize: 12),
              ),
              const SizedBox(height: 24),
              ElevatedButton.icon(
                onPressed: () {
                  Navigator.pop(context);
                  _saveSongEdits(song, provider, saveAsCopy: false);
                },
                icon: const Icon(Icons.edit_document, size: 20),
                label: const Text('Update & Overwrite Original', style: TextStyle(fontWeight: FontWeight.bold)),
                style: ElevatedButton.styleFrom(
                  foregroundColor: Colors.white,
                  backgroundColor: Theme.of(context).colorScheme.primary,
                  padding: const EdgeInsets.symmetric(vertical: 14),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                ),
              ),
              const SizedBox(height: 12),
              OutlinedButton.icon(
                onPressed: () {
                  Navigator.pop(context);
                  _saveSongEdits(song, provider, saveAsCopy: true);
                },
                icon: const Icon(Icons.copy_rounded, size: 20),
                label: const Text('Save as a New Copy', style: TextStyle(fontWeight: FontWeight.bold)),
                style: OutlinedButton.styleFrom(
                  foregroundColor: Colors.white,
                  side: const BorderSide(color: Colors.white24),
                  padding: const EdgeInsets.symmetric(vertical: 14),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                ),
              ),
              const SizedBox(height: 16),
            ],
          ),
        );
      },
    );
  }

  String _formatDuration(Duration duration) {
    final minutes = duration.inMinutes;
    final seconds = duration.inSeconds % 60;
    return '$minutes:${seconds.toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    final screenWidth = MediaQuery.of(context).size.width;
    final primaryColor = Theme.of(context).colorScheme.primary;
    final settings = Provider.of<SettingsProvider>(context);
    final playerProvider = Provider.of<PlayerProvider>(context);

    final trimLengthSecs = (_trimEndSecs - _trimStartSecs).clamp(0.0, double.infinity);

    return SingleChildScrollView(
      physics: const BouncingScrollPhysics(),
      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Header Row
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              IconButton(
                icon: const Icon(Icons.arrow_back_ios_new_rounded, color: Colors.white, size: 20),
                onPressed: () {
                  widget.pageController.animateToPage(0, duration: const Duration(milliseconds: 400), curve: Curves.easeOutCubic);
                },
              ),
              Row(
                children: [
                  Text(
                    'SOUND ENHANCER',
                    style: GoogleFonts.outfit(
                      color: Colors.white,
                      fontSize: 18,
                      fontWeight: FontWeight.w900,
                      letterSpacing: 2.0,
                    ),
                  ),
                  if (widget.song.isEdited) ...[
                    const SizedBox(width: 8),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
                      decoration: BoxDecoration(
                        color: Colors.amber.shade800,
                        borderRadius: BorderRadius.circular(6),
                        boxShadow: [
                          BoxShadow(
                            color: Colors.amber.shade800.withValues(alpha: 0.4),
                            blurRadius: 8,
                          )
                        ],
                      ),
                      child: const Text(
                        'EDITED',
                        style: TextStyle(color: Colors.white, fontSize: 9, fontWeight: FontWeight.bold),
                      ),
                    ),
                  ],
                ],
              ),
              _isTrimmingFile
                  ? const SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(strokeWidth: 2, valueColor: AlwaysStoppedAnimation(Colors.white)),
                    )
                  : IconButton(
                      icon: Icon(Icons.check_circle_rounded, color: primaryColor, size: 26),
                      onPressed: () => _showSaveOptionsSheet(context, widget.song, playerProvider),
                    ),
            ],
          ),
          const SizedBox(height: 12),

          // Active Drive Storage Pill
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
            decoration: BoxDecoration(
              color: Colors.white.withValues(alpha: 0.04),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: Colors.white.withValues(alpha: 0.06)),
            ),
            child: Row(
              children: [
                Icon(
                  settings.storageType == StorageType.sdCard ? Icons.sd_card_rounded : Icons.folder_special_rounded,
                  color: primaryColor,
                  size: 16,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    'Target Drive: ${settings.storageType == StorageType.sdCard ? 'External SD Card' : 'SonicWave App Drive'}',
                    style: GoogleFonts.inter(
                      color: AppColors.textSecondary,
                      fontSize: 11,
                      fontWeight: FontWeight.w500,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                  decoration: BoxDecoration(
                    color: primaryColor.withValues(alpha: 0.2),
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: Text(
                    'AUTO-SAVE',
                    style: TextStyle(color: primaryColor, fontSize: 8, fontWeight: FontWeight.bold),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 20),

          // Album Art Preview Card with Visualizer Pulse
          Center(
            child: Stack(
              alignment: Alignment.center,
              children: [
                if (_isPreviewPlaying)
                  Container(
                    width: screenWidth * 0.44,
                    height: screenWidth * 0.44,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      border: Border.all(color: primaryColor.withValues(alpha: 0.4), width: 3),
                    ),
                  ),
                Container(
                  width: screenWidth * 0.40,
                  height: screenWidth * 0.40,
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(22),
                    boxShadow: [
                      BoxShadow(
                        color: primaryColor.withValues(alpha: _isPreviewPlaying ? 0.45 : 0.2),
                        blurRadius: _isPreviewPlaying ? 28 : 14,
                        offset: const Offset(0, 8),
                      ),
                    ],
                  ),
                  child: SongAlbumArt(
                    song: widget.song,
                    borderRadius: 22,
                    fit: BoxFit.cover,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 24),

          // Metadata Fields Group Header
          Text(
            'TAG & METADATA EDITOR',
            style: GoogleFonts.inter(
              color: AppColors.textTertiary,
              fontSize: 11,
              fontWeight: FontWeight.bold,
              letterSpacing: 1.0,
            ),
          ),
          const SizedBox(height: 10),

          // Title Input Field
          TextField(
            controller: _titleController,
            style: const TextStyle(color: Colors.white, fontSize: 13, fontWeight: FontWeight.w600),
            decoration: InputDecoration(
              labelText: 'Song Title',
              labelStyle: const TextStyle(color: AppColors.textTertiary, fontSize: 11),
              prefixIcon: const Icon(Icons.music_note_rounded, color: AppColors.textTertiary, size: 16),
              filled: true,
              fillColor: Colors.white.withValues(alpha: 0.04),
              contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(14),
                borderSide: BorderSide(color: Colors.white.withValues(alpha: 0.08)),
              ),
              focusedBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(14),
                borderSide: BorderSide(color: primaryColor, width: 1.5),
              ),
            ),
          ),
          const SizedBox(height: 12),

          // Artist Input Field
          TextField(
            controller: _artistController,
            style: const TextStyle(color: Colors.white, fontSize: 13, fontWeight: FontWeight.w600),
            decoration: InputDecoration(
              labelText: 'Artist Name',
              labelStyle: const TextStyle(color: AppColors.textTertiary, fontSize: 11),
              prefixIcon: const Icon(Icons.person_rounded, color: AppColors.textTertiary, size: 16),
              filled: true,
              fillColor: Colors.white.withValues(alpha: 0.04),
              contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(14),
                borderSide: BorderSide(color: Colors.white.withValues(alpha: 0.08)),
              ),
              focusedBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(14),
                borderSide: BorderSide(color: primaryColor, width: 1.5),
              ),
            ),
          ),
          const SizedBox(height: 24),

          // Audio Trimming Section Header
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                'AUDIO TRIM STUDIO (VISUAL TIMELINE)',
                style: GoogleFonts.inter(
                  color: AppColors.textTertiary,
                  fontSize: 11,
                  fontWeight: FontWeight.bold,
                  letterSpacing: 1.0,
                ),
              ),
              Text(
                'Cut: ${_formatDuration(Duration(seconds: trimLengthSecs.toInt()))}',
                style: GoogleFonts.spaceMono(
                  color: primaryColor,
                  fontSize: 11,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),

          // Waveform Timeline Cutter
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: Colors.white.withValues(alpha: 0.03),
              borderRadius: BorderRadius.circular(20),
              border: Border.all(color: Colors.white.withValues(alpha: 0.05)),
            ),
            child: Column(
              children: [
                AudioWaveformTimeline(
                  startVal: _trimStartSecs,
                  endVal: _trimEndSecs,
                  maxVal: widget.song.duration.inSeconds.toDouble() <= 0.0 ? 1.0 : widget.song.duration.inSeconds.toDouble(),
                  currentPosition: _currentPreviewSecs,
                  fadeInVal: _fadeIn,
                  fadeOutVal: _fadeOut,
                  onChanged: (values) {
                    setState(() {
                      _trimStartSecs = values.start;
                      _trimEndSecs = values.end;
                    });
                  },
                ),
                const SizedBox(height: 10),
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text('Trim Start', style: TextStyle(color: AppColors.textTertiary, fontSize: 10)),
                        Text(
                          _formatDuration(Duration(seconds: _trimStartSecs.toInt())),
                          style: GoogleFonts.spaceMono(color: Colors.tealAccent, fontSize: 12, fontWeight: FontWeight.bold),
                        ),
                      ],
                    ),
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.end,
                      children: [
                        const Text('Trim End', style: TextStyle(color: AppColors.textTertiary, fontSize: 10)),
                        Text(
                          _formatDuration(Duration(seconds: _trimEndSecs.toInt())),
                          style: GoogleFonts.spaceMono(color: Colors.orangeAccent, fontSize: 12, fontWeight: FontWeight.bold),
                        ),
                      ],
                    ),
                  ],
                ),
              ],
            ),
          ),
          const SizedBox(height: 24),

          // Audio Isolation section
          Text(
            'AUDIO ISOLATION (STUDIO FX)',
            style: GoogleFonts.inter(
              color: AppColors.textTertiary,
              fontSize: 11,
              fontWeight: FontWeight.bold,
              letterSpacing: 1.0,
            ),
          ),
          const SizedBox(height: 10),

          // Isolation Mode Selector Buttons
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: Colors.white.withValues(alpha: 0.03),
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: Colors.white.withValues(alpha: 0.05)),
            ),
            child: Row(
              children: [
                Expanded(
                  child: _buildIsolationButton(
                    label: 'No Isolation',
                    icon: Icons.music_note_rounded,
                    active: _isolationMode == 'none',
                    onTap: () {
                      setState(() {
                        _isolationMode = 'none';
                      });
                      if (_isPreviewPlaying) {
                        _stopPreview();
                        _startPreview(widget.song, playerProvider);
                      }
                    },
                    primaryColor: primaryColor,
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: _buildIsolationButton(
                    label: 'Vocal Cut',
                    icon: Icons.voicemail_rounded,
                    active: _isolationMode == 'instrument',
                    onTap: () {
                      setState(() {
                        _isolationMode = 'instrument';
                      });
                      if (_isPreviewPlaying) {
                        _stopPreview();
                        _startPreview(widget.song, playerProvider);
                      }
                    },
                    primaryColor: Colors.orangeAccent,
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: _buildIsolationButton(
                    label: 'Voice Only',
                    icon: Icons.record_voice_over_rounded,
                    active: _isolationMode == 'vocal',
                    onTap: () {
                      setState(() {
                        _isolationMode = 'vocal';
                      });
                      if (_isPreviewPlaying) {
                        _stopPreview();
                        _startPreview(widget.song, playerProvider);
                      }
                    },
                    primaryColor: Colors.tealAccent,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 24),

          // Advanced Audio Tuning parameters
          Text(
            'SPEED & PITCH CHANGER',
            style: GoogleFonts.inter(
              color: AppColors.textTertiary,
              fontSize: 11,
              fontWeight: FontWeight.bold,
              letterSpacing: 1.0,
            ),
          ),
          const SizedBox(height: 10),

          // Speed & Pitch Sliders
          Container(
            padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 16),
            decoration: BoxDecoration(
              color: Colors.white.withValues(alpha: 0.03),
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: Colors.white.withValues(alpha: 0.05)),
            ),
            child: Column(
              children: [
                Row(
                  children: [
                    const Icon(Icons.speed_rounded, color: AppColors.textTertiary, size: 18),
                    const SizedBox(width: 10),
                    const Text('Speed', style: TextStyle(color: Colors.white, fontSize: 12)),
                    const Spacer(),
                    Text('${_speed.toStringAsFixed(2)}x', style: GoogleFonts.spaceMono(color: primaryColor, fontSize: 12, fontWeight: FontWeight.bold)),
                  ],
                ),
                Slider(
                  value: _speed,
                  min: 0.5,
                  max: 2.0,
                  activeColor: primaryColor,
                  inactiveColor: Colors.white12,
                  onChanged: (val) {
                    setState(() {
                      _speed = val;
                    });
                    if (!_isPreviewPlaying) {
                      playerProvider.player.setSpeed(val);
                    }
                  },
                ),
                const SizedBox(height: 8),
                Row(
                  children: [
                    const Icon(Icons.tune_rounded, color: AppColors.textTertiary, size: 18),
                    const SizedBox(width: 10),
                    const Text('Pitch Shift', style: TextStyle(color: Colors.white, fontSize: 12)),
                    const Spacer(),
                    Text('${_pitch > 0 ? '+' : ''}${_pitch.toInt()} semitones', style: GoogleFonts.spaceMono(color: primaryColor, fontSize: 12, fontWeight: FontWeight.bold)),
                  ],
                ),
                Slider(
                  value: _pitch,
                  min: -6.0,
                  max: 6.0,
                  divisions: 12,
                  activeColor: primaryColor,
                  inactiveColor: Colors.white12,
                  onChanged: (val) {
                    setState(() {
                      _pitch = val;
                    });
                    if (!_isPreviewPlaying) {
                      playerProvider.player.setPitch(1.0 + (val / 12.0));
                    }
                  },
                ),
              ],
            ),
          ),
          const SizedBox(height: 24),

          // FADES STUDIO
          Text(
            'FADE-IN & FADE-OUT ENVELOPES',
            style: GoogleFonts.inter(
              color: AppColors.textTertiary,
              fontSize: 11,
              fontWeight: FontWeight.bold,
              letterSpacing: 1.0,
            ),
          ),
          const SizedBox(height: 10),

          // Fades Container
          Container(
            padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 16),
            decoration: BoxDecoration(
              color: Colors.white.withValues(alpha: 0.03),
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: Colors.white.withValues(alpha: 0.05)),
            ),
            child: Column(
              children: [
                Row(
                  children: [
                    const Icon(Icons.arrow_upward_rounded, color: Colors.tealAccent, size: 18),
                    const SizedBox(width: 10),
                    const Text('Fade-In Duration', style: TextStyle(color: Colors.white, fontSize: 12)),
                    const Spacer(),
                    Text('${_fadeIn.toStringAsFixed(1)}s', style: GoogleFonts.spaceMono(color: Colors.tealAccent, fontSize: 12, fontWeight: FontWeight.bold)),
                  ],
                ),
                Slider(
                  value: _fadeIn,
                  min: 0.0,
                  max: 5.0,
                  activeColor: Colors.tealAccent,
                  inactiveColor: Colors.white12,
                  onChanged: (val) {
                    setState(() {
                      _fadeIn = val;
                    });
                  },
                ),
                const SizedBox(height: 8),
                Row(
                  children: [
                    const Icon(Icons.arrow_downward_rounded, color: Colors.orangeAccent, size: 18),
                    const SizedBox(width: 10),
                    const Text('Fade-Out Duration', style: TextStyle(color: Colors.white, fontSize: 12)),
                    const Spacer(),
                    Text('${_fadeOut.toStringAsFixed(1)}s', style: GoogleFonts.spaceMono(color: Colors.orangeAccent, fontSize: 12, fontWeight: FontWeight.bold)),
                  ],
                ),
                Slider(
                  value: _fadeOut,
                  min: 0.0,
                  max: 5.0,
                  activeColor: Colors.orangeAccent,
                  inactiveColor: Colors.white12,
                  onChanged: (val) {
                    setState(() {
                      _fadeOut = val;
                    });
                  },
                ),
                const Divider(color: Colors.white10, height: 16),
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    const Text('Fade Curve Shape', style: TextStyle(color: Colors.white70, fontSize: 11)),
                    Row(
                      children: [
                        _buildCurveSegment('Linear', _fadeCurve == 'linear', () {
                          setState(() {
                            _fadeCurve = 'linear';
                          });
                        }),
                        const SizedBox(width: 8),
                        _buildCurveSegment('S-Curve', _fadeCurve == 'scurve', () {
                          setState(() {
                            _fadeCurve = 'scurve';
                          });
                        }),
                      ],
                    ),
                  ],
                ),
              ],
            ),
          ),
          const SizedBox(height: 24),

          // Preview & Save Buttons
          Row(
            children: [
              Expanded(
                child: TextButton.icon(
                  onPressed: () => _startPreview(widget.song, playerProvider),
                  icon: Icon(
                    _isPreviewPlaying ? Icons.stop_circle_rounded : Icons.play_circle_filled_rounded,
                    size: 20,
                    color: _isPreviewPlaying ? Colors.redAccent : Colors.white,
                  ),
                  label: Text(
                    _isPreviewPlaying ? 'Stop Preview' : 'Preview Edit',
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.bold,
                      color: _isPreviewPlaying ? Colors.redAccent : Colors.white,
                    ),
                  ),
                  style: TextButton.styleFrom(
                    foregroundColor: Colors.white,
                    backgroundColor: _isPreviewPlaying ? Colors.redAccent.withValues(alpha: 0.1) : Colors.white10,
                    padding: const EdgeInsets.symmetric(vertical: 14),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: ElevatedButton.icon(
                  onPressed: () => _showSaveOptionsSheet(context, widget.song, playerProvider),
                  icon: const Icon(Icons.save_rounded, size: 20),
                  label: const Text('Save Output...', style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold)),
                  style: ElevatedButton.styleFrom(
                    foregroundColor: Colors.white,
                    backgroundColor: primaryColor,
                    padding: const EdgeInsets.symmetric(vertical: 14),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 20),
          Center(
            child: Text(
              'Swipe left to return to the player screen',
              style: TextStyle(color: AppColors.textTertiary.withValues(alpha: 0.6), fontSize: 11),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildIsolationButton({
    required String label,
    required IconData icon,
    required bool active,
    required VoidCallback onTap,
    required Color primaryColor,
  }) {
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 250),
        padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 4),
        decoration: BoxDecoration(
          color: active ? primaryColor.withValues(alpha: 0.1) : Colors.white.withValues(alpha: 0.02),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: active ? primaryColor : Colors.white.withValues(alpha: 0.06),
            width: active ? 1.5 : 1.0,
          ),
        ),
        child: Column(
          children: [
            Icon(
              icon,
              color: active ? primaryColor : Colors.white60,
              size: 20,
            ),
            const SizedBox(height: 6),
            Text(
              label,
              textAlign: TextAlign.center,
              style: GoogleFonts.inter(
                color: active ? Colors.white : AppColors.textTertiary,
                fontSize: 10,
                fontWeight: active ? FontWeight.bold : FontWeight.normal,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildCurveSegment(String label, bool active, VoidCallback onTap) {
    final primaryColor = Theme.of(context).colorScheme.primary;
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
        decoration: BoxDecoration(
          color: active ? primaryColor.withValues(alpha: 0.2) : Colors.transparent,
          borderRadius: BorderRadius.circular(6),
          border: Border.all(color: active ? primaryColor : Colors.white24),
        ),
        child: Text(
          label,
          style: TextStyle(
            color: active ? Colors.white : Colors.white60,
            fontSize: 10,
            fontWeight: active ? FontWeight.bold : FontWeight.normal,
          ),
        ),
      ),
    );
  }
}
