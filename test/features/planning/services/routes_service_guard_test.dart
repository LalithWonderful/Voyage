// API-0.4b — Offline guard tests for RoutesService.
//
// These tests do not call Google. Cache hits are served by an in-memory fake
// GeminiCacheService; live-allowed paths use a fake http client.

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:voyage/config/live_api_guards.dart';
import 'package:voyage/features/planning/models/trip_transport_model.dart';
import 'package:voyage/features/planning/services/gemini_cache_service.dart';
import 'package:voyage/features/planning/services/routes_service.dart';

void main() {
  group('RoutesService live API guards', () {
    test('cache miss throws when live Google Routes is blocked', () async {
      final httpClient = _FakeRoutesHttpClient();
      final service = RoutesService(
        cache: _FakeGeminiCacheService(const {}),
        guards: LiveApiGuards.defaults(),
        httpClient: httpClient,
      );

      expect(
        () => service.computeOptionsFromEndpoints(
          from: const RouteEndpoint.placeId('from-place'),
          to: const RouteEndpoint.placeId('to-place'),
        ),
        throwsA(
          isA<LiveApiBlockedException>()
              .having((e) => e.family, 'family', LiveApiFamily.googleRoutes)
              .having(
                (e) => e.operation,
                'operation',
                'RoutesService.computeOptionsFromEndpoints',
              ),
        ),
      );
      expect(httpClient.requests, isEmpty);
    });

    test(
      'cache miss with allowGoogleRoutes reaches fake http client',
      () async {
        final cache = _FakeGeminiCacheService(const {});
        final httpClient = _FakeRoutesHttpClient();
        final service = RoutesService(
          cache: cache,
          guards: const LiveApiGuards(allowGoogleRoutes: true),
          httpClient: httpClient,
        );

        final options = await service.computeOptionsFromEndpoints(
          from: const RouteEndpoint.placeId('from-place'),
          to: const RouteEndpoint.placeId('to-place'),
        );

        expect(options, isNotNull);
        expect(options, hasLength(4));
        expect(httpClient.requests, hasLength(4));
        expect(cache.putCalls, hasLength(1));
        expect(cache.putCalls.single.action, 'routes_pair');
      },
    );

    test(
      'cache hit returns cached options without requiring live flag',
      () async {
        final cache = _FakeGeminiCacheService({
          _routesCacheKey: {
            'options': [
              const TransportOption(
                mode: 'walk',
                durationMinutes: 12,
                priceEstimate: 'Gratuit',
                detail: '0.8 km',
              ).toJson(),
            ],
          },
        });
        final httpClient = _FakeRoutesHttpClient();
        final service = RoutesService(
          cache: cache,
          guards: LiveApiGuards.defaults(),
          httpClient: httpClient,
        );

        final options = await service.computeOptionsFromEndpoints(
          from: const RouteEndpoint.placeId('from-place'),
          to: const RouteEndpoint.placeId('to-place'),
        );

        expect(options, isNotNull);
        expect(options, hasLength(1));
        expect(options!.single.mode, 'walk');
        expect(httpClient.requests, isEmpty);
        expect(cache.putCalls, isEmpty);
      },
    );

    test('ALLOW_LIVE_APIS=true allows Routes via global flag', () async {
      final httpClient = _FakeRoutesHttpClient();
      final service = RoutesService(
        cache: _FakeGeminiCacheService(const {}),
        guards: LiveApiGuards.fromEnvironmentMap(const {
          'ALLOW_LIVE_APIS': 'true',
        }),
        httpClient: httpClient,
      );

      final options = await service.computeOptionsFromEndpoints(
        from: const RouteEndpoint.placeId('from-place'),
        to: const RouteEndpoint.placeId('to-place'),
      );

      expect(options, isNotNull);
      expect(httpClient.requests, hasLength(4));
    });
  });
}

final _routesCacheKey = GeminiCacheService.hashKey([
  (k: 'from', v: 'P:from-place'),
  (k: 'to', v: 'P:to-place'),
]);

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
    if (action != 'routes_pair') return null;
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

class _FakeRoutesHttpClient extends http.BaseClient {
  final requests = <http.BaseRequest>[];

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    requests.add(request);
    final body = jsonEncode({
      'routes': [
        {'duration': '600s', 'distanceMeters': 1000, 'legs': const []},
      ],
    });
    return http.StreamedResponse(
      Stream.value(utf8.encode(body)),
      200,
      headers: const {'content-type': 'application/json'},
    );
  }
}
