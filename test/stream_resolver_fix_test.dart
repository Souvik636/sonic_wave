import 'package:flutter_test/flutter_test.dart';
import 'package:sonic_wave/models/song.dart';
import 'package:sonic_wave/services/stream_resolver_service.dart';

void main() {
  test('StreamResolverService ignores non-existent filePath and resolves online songs via JioSaavn/YouTube', () async {
    final unDownloadedOnlineSong = Song(
      id: 'jiosaavn_7I9urT8B',
      videoId: 'jiosaavn_7I9urT8B',
      title: 'Online Song',
      artist: 'Test Artist',
      thumbnailUrl: '',
      highResThumbnailUrl: '',
      duration: const Duration(minutes: 3),
      filePath: 'C:\\NonExistentPath\\song.mp3', // Non-existent file path
    );

    final resolved = await StreamResolverService().resolve(unDownloadedOnlineSong);

    // Must NOT return local file stream because file does not exist on disk
    expect(resolved, isNotNull);
    expect(resolved!.source, equals('jiosaavn'));
    expect(resolved.url.startsWith('file://'), isFalse);
    expect(resolved.url.startsWith('http'), isTrue);
  });
}
