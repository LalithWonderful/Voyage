// API-0.4c — Offline Gemini guard tests for AiSuggestionsService.
//
// These tests do not instantiate a real GenerativeModel and do not call Gemini
// or Supabase. Cache behavior is covered by an in-memory GeminiCacheService.

import 'package:flutter_test/flutter_test.dart';
import 'package:google_generative_ai/google_generative_ai.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:voyage/config/live_api_guards.dart';
import 'package:voyage/features/planning/services/ai_suggestions_service.dart';
import 'package:voyage/features/planning/services/gemini_cache_service.dart';

void main() {
  group('AiSuggestionsService Gemini guards', () {
    test('describeActivity cache hit does not require live Gemini', () async {
      final generator = _FakeAiGeminiGenerator();
      final service = _service(
        cache: _FakeGeminiCacheService({
          _describeActivityKey(
            title: 'Musee',
            destination: 'Paris',
            tag: 'Culture',
          ): {
            'description': 'Description deja cachee.',
          },
        }),
        guards: LiveApiGuards.defaults(),
        generator: generator,
      );

      final description = await service.describeActivity(
        title: 'Musee',
        destination: 'Paris',
        tag: 'Culture',
      );

      expect(description, 'Description deja cachee.');
      expect(generator.calls, isEmpty);
    });

    test(
      'describeActivity cache miss throws before generation when blocked',
      () {
        final generator = _FakeAiGeminiGenerator();
        final service = _service(
          cache: _FakeGeminiCacheService(const {}),
          guards: LiveApiGuards.defaults(),
          generator: generator,
        );

        expect(
          () => service.describeActivity(
            title: 'Musee',
            destination: 'Paris',
            tag: 'Culture',
          ),
          throwsA(
            isA<LiveApiBlockedException>()
                .having((e) => e.family, 'family', LiveApiFamily.gemini)
                .having(
                  (e) => e.operation,
                  'operation',
                  'AiSuggestionsService.describeActivity',
                ),
          ),
        );
        expect(generator.calls, isEmpty);
      },
    );

    test('ALLOW_LIVE_GEMINI allows describeActivity fake generation', () async {
      final cache = _FakeGeminiCacheService(const {});
      final generator = _FakeAiGeminiGenerator(
        response: '{"description":"Description generee."}',
      );
      final service = _service(
        cache: cache,
        guards: const LiveApiGuards(allowGemini: true),
        generator: generator,
      );

      final description = await service.describeActivity(
        title: 'Musee',
        destination: 'Paris',
        tag: 'Culture',
      );

      expect(description, 'Description generee.');
      expect(generator.calls.single.tag, 'describe_activity');
      expect(cache.putCalls.single.action, 'describe_activity');
    });

    test('generateRaw cache hit does not require live Gemini', () async {
      final generator = _FakeAiGeminiGenerator();
      final service = _service(
        cache: _FakeGeminiCacheService({
          'raw-key': {'raw': '{"cached":true}'},
        }),
        guards: LiveApiGuards.defaults(),
        generator: generator,
      );

      final raw = await service.generateRaw(
        prompt: 'prompt',
        cacheKey: 'raw-key',
      );

      expect(raw, '{"cached":true}');
      expect(generator.calls, isEmpty);
    });

    test('generateRaw without cache key is blocked without live flag', () {
      final generator = _FakeAiGeminiGenerator();
      final service = _service(
        cache: _FakeGeminiCacheService(const {}),
        guards: LiveApiGuards.defaults(),
        generator: generator,
      );

      expect(
        () => service.generateRaw(prompt: 'prompt'),
        throwsA(isA<LiveApiBlockedException>()),
      );
      expect(generator.calls, isEmpty);
    });

    test('ALLOW_LIVE_APIS allows generateRaw fake generation', () async {
      final generator = _FakeAiGeminiGenerator(response: '{"ok":true}');
      final service = _service(
        cache: _FakeGeminiCacheService(const {}),
        guards: LiveApiGuards.fromEnvironmentMap(const {
          'ALLOW_LIVE_APIS': 'true',
        }),
        generator: generator,
      );

      final raw = await service.generateRaw(prompt: 'prompt');

      expect(raw, '{"ok":true}');
      expect(generator.calls.single.tag, 'raw');
    });

    test(
      'describeActivitiesBatch all cache hits do not require live Gemini',
      () async {
        final generator = _FakeAiGeminiGenerator();
        final service = _service(
          cache: _FakeGeminiCacheService({
            _describeActivityKey(title: 'A', destination: 'Paris'): {
              'description': 'Desc A',
            },
            _describeActivityKey(title: 'B', destination: 'Paris'): {
              'description': 'Desc B',
            },
          }),
          guards: LiveApiGuards.defaults(),
          generator: generator,
        );

        final descriptions = await service.describeActivitiesBatch(
          destination: 'Paris',
          items: const [
            (title: 'A', detail: null, tag: null),
            (title: 'B', detail: null, tag: null),
          ],
        );

        expect(descriptions, ['Desc A', 'Desc B']);
        expect(generator.calls, isEmpty);
      },
    );

    test(
      'describeActivitiesBatch partial miss is blocked without live flag',
      () {
        final generator = _FakeAiGeminiGenerator();
        final service = _service(
          cache: _FakeGeminiCacheService({
            _describeActivityKey(title: 'A', destination: 'Paris'): {
              'description': 'Desc A',
            },
          }),
          guards: LiveApiGuards.defaults(),
          generator: generator,
        );

        expect(
          () => service.describeActivitiesBatch(
            destination: 'Paris',
            items: const [
              (title: 'A', detail: null, tag: null),
              (title: 'B', detail: null, tag: null),
            ],
          ),
          throwsA(isA<LiveApiBlockedException>()),
        );
        expect(generator.calls, isEmpty);
      },
    );

    test(
      'extractDocumentFromText is blocked before generation without flag',
      () {
        final generator = _FakeAiGeminiGenerator();
        final service = _service(
          cache: _FakeGeminiCacheService(const {}),
          guards: LiveApiGuards.defaults(),
          generator: generator,
        );

        expect(
          () => service.extractDocumentFromText('booking text'),
          throwsA(isA<LiveApiBlockedException>()),
        );
        expect(generator.calls, isEmpty);
      },
    );
  });
}

AiSuggestionsService _service({
  required _FakeGeminiCacheService cache,
  required LiveApiGuards guards,
  required _FakeAiGeminiGenerator generator,
}) {
  return AiSuggestionsService(
    SupabaseClient('https://example.supabase.co', 'anon-key'),
    cache: cache,
    guards: guards,
    geminiTextGenerator: generator.call,
  );
}

String _describeActivityKey({
  required String title,
  required String destination,
  String? tag,
}) {
  return GeminiCacheService.hashKey([
    (k: 'title', v: GeminiCacheService.normKey(title)),
    (k: 'dest', v: GeminiCacheService.normKey(destination)),
    (k: 'tag', v: GeminiCacheService.normKey(tag ?? '')),
  ]);
}

class _FakeGeminiCacheService extends GeminiCacheService {
  final Map<String, Map<String, dynamic>> entries;
  final putCalls = <({String action, String cacheKey})>[];

  _FakeGeminiCacheService(this.entries)
    : super(SupabaseClient('https://example.supabase.co', 'anon-key'));

  @override
  Future<Map<String, dynamic>?> get(
    String action,
    String cacheKey, {
    Duration? ttl,
  }) async {
    return entries[cacheKey];
  }

  @override
  Future<void> put(
    String action,
    String cacheKey,
    Map<String, dynamic> payload,
  ) async {
    putCalls.add((action: action, cacheKey: cacheKey));
  }
}

class _FakeAiGeminiGenerator {
  final String response;
  final calls = <({String tag, double temperature, bool retry})>[];

  _FakeAiGeminiGenerator({this.response = '{"description":"Generated"}'});

  Future<String> call({
    required List<Content> contents,
    required double temperature,
    required String tag,
    required bool retry,
  }) async {
    calls.add((tag: tag, temperature: temperature, retry: retry));
    return response;
  }
}
