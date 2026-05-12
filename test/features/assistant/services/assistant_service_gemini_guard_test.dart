// API-0.4c — Offline Gemini guard tests for AssistantService.
//
// These tests use a fake text generator and do not call Gemini.

import 'package:flutter_test/flutter_test.dart';
import 'package:google_generative_ai/google_generative_ai.dart';
import 'package:voyage/config/live_api_guards.dart';
import 'package:voyage/features/assistant/services/assistant_service.dart';

void main() {
  group('AssistantService Gemini guards', () {
    test('sendMessage blocks without live Gemini before generation', () {
      final generator = _FakeAssistantGeminiGenerator();
      final service = AssistantService(
        guards: LiveApiGuards.defaults(),
        geminiTextGenerator: generator.call,
      );

      expect(
        () => service.sendMessage(
          history: const [],
          userMessage: 'Bonjour',
          trip: null,
          travelerType: null,
          interests: const [],
          activities: const [],
        ),
        throwsA(
          isA<LiveApiBlockedException>()
              .having((e) => e.family, 'family', LiveApiFamily.gemini)
              .having(
                (e) => e.operation,
                'operation',
                'AssistantService.sendMessage',
              ),
        ),
      );
      expect(generator.calls, isEmpty);
    });

    test('sendMessage with allowGemini reaches fake generator', () async {
      final generator = _FakeAssistantGeminiGenerator(response: 'Salut !');
      final service = AssistantService(
        guards: const LiveApiGuards(allowGemini: true),
        geminiTextGenerator: generator.call,
      );

      final response = await service.sendMessage(
        history: const [],
        userMessage: 'Bonjour',
        trip: null,
        travelerType: null,
        interests: const [],
        activities: const [],
      );

      expect(response, 'Salut !');
      expect(generator.calls, hasLength(1));
    });

    test('ALLOW_LIVE_APIS=true allows sendMessage', () async {
      final generator = _FakeAssistantGeminiGenerator(
        response: 'Avec plaisir.',
      );
      final service = AssistantService(
        guards: LiveApiGuards.fromEnvironmentMap(const {
          'ALLOW_LIVE_APIS': 'true',
        }),
        geminiTextGenerator: generator.call,
      );

      final response = await service.sendMessage(
        history: const [],
        userMessage: 'Bonjour',
        trip: null,
        travelerType: null,
        interests: const [],
        activities: const [],
      );

      expect(response, 'Avec plaisir.');
      expect(generator.calls, hasLength(1));
    });

    test('LiveApiBlockedException is not converted to transient exception', () {
      final service = AssistantService(
        guards: LiveApiGuards.defaults(),
        geminiTextGenerator: _FakeAssistantGeminiGenerator().call,
      );

      expect(
        () => service.sendMessage(
          history: const [],
          userMessage: 'Bonjour',
          trip: null,
          travelerType: null,
          interests: const [],
          activities: const [],
        ),
        throwsA(isA<LiveApiBlockedException>()),
      );
    });
  });
}

class _FakeAssistantGeminiGenerator {
  final String response;
  final calls = <({String systemPrompt, int contentCount})>[];

  _FakeAssistantGeminiGenerator({this.response = 'OK'});

  Future<String> call({
    required String systemPrompt,
    required List<Content> contents,
  }) async {
    calls.add((systemPrompt: systemPrompt, contentCount: contents.length));
    return response;
  }
}
