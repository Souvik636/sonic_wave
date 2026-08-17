import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';

class GeminiClassificationResult {
  final int index;
  final String category;
  final double confidence;

  const GeminiClassificationResult({
    required this.index,
    required this.category,
    required this.confidence,
  });

  factory GeminiClassificationResult.fromJson(Map<String, dynamic> json) {
    return GeminiClassificationResult(
      index: json['index'] as int,
      category: json['category'] as String,
      confidence: (json['confidence'] as num).toDouble(),
    );
  }
}

/// Gemini API Client for batch song classification.
class GeminiClient {
  /// Dynamically load Gemini API keys from compile-time environment variables
  /// via `--dart-define=GEMINI_KEY=...` or `--dart-define=GEMINI_KEYS=key1,key2`.
  /// Keeps secrets 100% out of version control and Git history.
  static List<String> get apiKeys {
    const keysEnv = String.fromEnvironment('GEMINI_KEYS');
    const singleKeyEnv = String.fromEnvironment('GEMINI_KEY');

    if (keysEnv.isNotEmpty) {
      return keysEnv
          .split(',')
          .map((k) => k.trim())
          .where((k) => k.isNotEmpty)
          .toList();
    }
    if (singleKeyEnv.isNotEmpty) {
      return [singleKeyEnv];
    }
    return const [];
  }

  final HttpClient _client = HttpClient()
    ..connectionTimeout = const Duration(seconds: 20);

  /// Per-request response timeout. Batch classification of up to 50 songs can
  /// take a while on a slow connection, so give it real headroom.
  static const Duration _requestTimeout = Duration(seconds: 30);

  int _consecutiveFailures = 0;
  bool _aborted = false;

  bool get isAborted => _aborted;

  void dispose() {
    _client.close(force: true);
  }

  /// Classify a batch of songs into custom user category labels.
  ///
  /// Returns a list of classification results matching the indices of the input songs.
  Future<List<GeminiClassificationResult>?> classifyBatch(
    List<String> songRepresentations,
    List<String> categories,
  ) async {
    if (_aborted ||
        apiKeys.isEmpty ||
        songRepresentations.isEmpty ||
        categories.isEmpty) {
      return null;
    }

    final url = Uri.parse(
      'https://generativelanguage.googleapis.com/v1beta/models/gemini-3.1-flash-lite:generateContent',
    );

    // Build the batch classification prompt
    final buffer = StringBuffer();
    buffer.write(
      'Classify each song into exactly one of these categories: ${json.encode(categories)}. Songs:\n',
    );
    for (int i = 0; i < songRepresentations.length; i++) {
      buffer.write('${i + 1}. ${songRepresentations[i]}\n');
    }
    buffer.write(
      'If no category fits with confidence >= 0.5, use "UNASSIGNED".',
    );

    final promptText = buffer.toString();

    final body = {
      "contents": [
        {
          "parts": [
            {"text": promptText},
          ],
        },
      ],
      "generationConfig": {
        "temperature": 0.1,
        "responseMimeType": "application/json",
        "responseSchema": {
          "type": "ARRAY",
          "items": {
            "type": "OBJECT",
            "properties": {
              "index": {"type": "INTEGER"},
              "category": {"type": "STRING"},
              "confidence": {"type": "NUMBER"},
            },
            "required": ["index", "category", "confidence"],
          },
        },
      },
    };

    // Rotate keys randomly to distribute load
    final randIndex = DateTime.now().microsecondsSinceEpoch % apiKeys.length;
    final apiKey = apiKeys[randIndex];

    try {
      final request = await _client.postUrl(url);
      request.headers.set('x-goog-api-key', apiKey);
      request.headers.set('Content-Type', 'application/json; charset=utf-8');

      // Explicitly encode to UTF-8 to prevent encoding exceptions on Unicode characters
      request.add(utf8.encode(json.encode(body)));

      final response = await request.close().timeout(_requestTimeout);
      final bodyStr = await response.transform(utf8.decoder).join();

      if (response.statusCode != 200) {
        throw HttpException('HTTP error ${response.statusCode}: $bodyStr');
      }

      final decoded = json.decode(bodyStr);
      final jsonText =
          decoded['candidates'][0]['content']['parts'][0]['text'] as String;

      final resultsList = json.decode(jsonText) as List;
      final results = resultsList
          .map(
            (item) => GeminiClassificationResult.fromJson(
              item as Map<String, dynamic>,
            ),
          )
          .toList();

      _consecutiveFailures = 0;
      return results;
    } catch (e) {
      _consecutiveFailures++;
      debugPrint(
        '[Gemini Client] Batch classification failed ($e). Failure count: $_consecutiveFailures',
      );

      if (_consecutiveFailures >= 3) {
        _aborted = true;
        debugPrint(
          '[Gemini Client] Circuit breaker tripped. Gemini classification disabled.',
        );
      }
      return null;
    }
  }
}
