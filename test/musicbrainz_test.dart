import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sonic_wave/services/categorization/musicbrainz_client.dart';

class MockHttpClient implements HttpClient {
  @override
  dynamic noSuchMethod(Invocation invocation) {
    if (invocation.memberName == #getUrl) {
      return Future.value(MockHttpClientRequest());
    }
    return null;
  }
}

class MockHttpClientRequest implements HttpClientRequest {
  @override
  final HttpHeaders headers = MockHttpHeaders();

  @override
  dynamic noSuchMethod(Invocation invocation) {
    if (invocation.memberName == #close) {
      return Future.value(MockHttpClientResponse());
    }
    return null;
  }
}

class MockHttpHeaders implements HttpHeaders {
  @override
  void set(String name, Object value, {bool preserveHeaderCase = false}) {}

  @override
  dynamic noSuchMethod(Invocation invocation) {
    return null;
  }
}

class MockHttpClientResponse implements HttpClientResponse {
  @override
  int get statusCode => 200;

  @override
  Stream<S> transform<S>(StreamTransformer<List<int>, S> streamTransformer) {
    final jsonResponse = json.encode({
      'recordings': [
        {
          'score': 100,
          'tags': [
            {'name': 'Rock', 'count': 10}
          ],
          'releases': [
            {
              'title': 'Test Album',
              'release-group': {'primary-type': 'Album'}
            }
          ],
          'artist-credit': [
            {
              'artist': {'name': 'Test Artist'}
            }
          ]
        }
      ]
    });
    final controller = StreamController<List<int>>();
    controller.add(utf8.encode(jsonResponse));
    controller.close();
    return controller.stream.transform(streamTransformer);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) {
    return super.noSuchMethod(invocation);
  }
}

class TestHttpOverrides extends HttpOverrides {
  @override
  HttpClient createHttpClient(SecurityContext? context) {
    return MockHttpClient();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    HttpOverrides.global = TestHttpOverrides();
  });

  tearDown(() {
    HttpOverrides.global = null;
  });

  test('MusicBrainzClient budget exhaustion works and prints exactly once', () async {
    final client = MusicBrainzClient();
    
    // Capture debug print statements
    final List<String> logs = [];
    final originalDebugPrint = debugPrint;
    debugPrint = (String? message, {int? wrapWidth}) {
      if (message != null) logs.add(message);
    };

    try {
      // Perform 5 lookups with maxLookups set to 3.
      // The first 3 should succeed/attempt network query.
      // The 4th and 5th should hit the budget limit.
      for (int i = 1; i <= 5; i++) {
        final result = await client.lookup(
          'song_$i',
          'Title $i',
          'Artist $i',
          maxLookups: 3,
        );
        if (i <= 3) {
          expect(result.found, isTrue);
          expect(result.genre, equals('Rock'));
          expect(result.albumTitle, equals('Test Album'));
        } else {
          expect(result.found, isFalse);
        }
      }

      // Verify that lookupsCount is capped at the number of real lookups attempted
      expect(client.lookupsCount, equals(3));

      // Verify that the budget exhausted log was printed EXACTLY once
      final budgetExhaustedLogs = logs.where(
        (log) => log.contains('[MusicBrainz] Lookup budget') && log.contains('exhausted'),
      ).toList();

      expect(budgetExhaustedLogs.length, equals(1));
      expect(
        budgetExhaustedLogs.first,
        contains('[MusicBrainz] Lookup budget (3) exhausted. Skipping remaining network lookups.'),
      );
    } finally {
      debugPrint = originalDebugPrint;
      client.dispose();
    }
  });
}
