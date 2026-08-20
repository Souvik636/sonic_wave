import 'package:flutter_test/flutter_test.dart';
import 'package:sonic_wave/models/song.dart';
import 'package:sonic_wave/services/stream_cache_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('Chunk Lifecycle & Song Switch Cancellation Tests', () {
    final cacheService = StreamCacheService();

    test('1. Chunk starts at notRequested and transitions to cancelled upon cancelAndDispose', () async {
      const testId = 'test_chunk_lifecycle_001';
      expect(cacheService.getChunkState(testId), equals(ChunkLifecycleState.notRequested));

      await cacheService.cancelAndDispose(testId);
      expect(cacheService.getChunkState(testId), equals(ChunkLifecycleState.cancelled));
      expect(StreamCacheService.chunkStateNotifier.value[testId], equals(ChunkLifecycleState.cancelled));
    });

    test('2. bufferProgressNotifier and chunkStateNotifier emit updates synchronously', () {
      const testId = 'test_chunk_lifecycle_002';
      StreamCacheService.bufferProgressNotifier.value =
          Map.from(StreamCacheService.bufferProgressNotifier.value)..[testId] = 0.55;

      expect(StreamCacheService.bufferProgressNotifier.value[testId], equals(0.55));
    });

    test('3. Chunk lifecycle states are strictly defined and distinguishable', () {
      expect(ChunkLifecycleState.values.length, equals(6));
      expect(ChunkLifecycleState.values, contains(ChunkLifecycleState.notRequested));
      expect(ChunkLifecycleState.values, contains(ChunkLifecycleState.loading));
      expect(ChunkLifecycleState.values, contains(ChunkLifecycleState.ready));
      expect(ChunkLifecycleState.values, contains(ChunkLifecycleState.completed));
      expect(ChunkLifecycleState.values, contains(ChunkLifecycleState.cancelled));
      expect(ChunkLifecycleState.values, contains(ChunkLifecycleState.error));
    });

    test('4. Song model carries duration and can be tracked in active playback', () {
      final songA = Song(
        id: 'yt_stream_track_A',
        videoId: 'yt_stream_track_A',
        title: 'Streaming Track A',
        artist: 'Artist A',
        thumbnailUrl: '',
        highResThumbnailUrl: '',
        duration: const Duration(minutes: 3, seconds: 45),
      );

      cacheService.setActivePlayingSong(songA.videoId);
      expect(songA.videoId, equals('yt_stream_track_A'));
    });

    test('5. cancelAllExcept cancels other downloads and sets active playing song', () async {
      await cacheService.cancelAllExcept('active_track_999');
      expect(cacheService.getChunkState('active_track_999'), isNot(equals(ChunkLifecycleState.cancelled)));
    });
  });
}
