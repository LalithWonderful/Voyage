// API-0.4a — Offline guard tests for PlacesNearbyService.
//
// These tests do not call Google. Cache hits are served by an in-memory fake
// GeminiCacheService; cache misses assert that LiveApiBlockedException is
// thrown before any HTTP request can be attempted.

import 'package:flutter_test/flutter_test.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:voyage/config/live_api_guards.dart';
import 'package:voyage/features/planning/services/gemini_cache_service.dart';
import 'package:voyage/features/planning/services/places_nearby_service.dart';

void main() {
  group('PlacesNearbyService live API guards', () {
    test(
      'searchNearby cache hit is allowed when live Google Places is blocked',
      () async {
        final cache = _FakeGeminiCacheService({
          GeminiCacheService.hashKey([
            (k: 'mode', v: 'nearby'),
            (k: 'types', v: ['museum']),
            (k: 'lat', v: '1.235'),
            (k: 'lng', v: '2.346'),
            (k: 'radius', v: 1500),
            (k: 'max', v: 20),
            (k: 'lang', v: 'fr'),
          ]): {
            'places': [
              _cachedPlaceJson(name: 'Museum cached', placeId: 'place-nearby'),
            ],
          },
        });
        final service = PlacesNearbyService(
          cache: cache,
          guards: LiveApiGuards.defaults(),
        );

        final results = await service.searchNearby(
          latitude: 1.23456,
          longitude: 2.34567,
          includedTypes: const ['museum'],
          languageCode: 'fr',
        );

        expect(results, hasLength(1));
        expect(results.single.name, 'Museum cached');
        expect(cache.putCalls, isEmpty);
      },
    );

    test(
      'searchText cache hit is allowed when live Google Places is blocked',
      () async {
        final cache = _FakeGeminiCacheService({
          GeminiCacheService.hashKey([
            (k: 'mode', v: 'text'),
            (k: 'q', v: GeminiCacheService.normKey('rooftop bar')),
            (k: 'lat', v: '1.235'),
            (k: 'lng', v: '2.346'),
            (k: 'radius', v: 5000),
            (k: 'max', v: 20),
            (k: 'lang', v: 'fr'),
          ]): {
            'places': [
              _cachedPlaceJson(name: 'Rooftop cached', placeId: 'place-text'),
            ],
          },
        });
        final service = PlacesNearbyService(
          cache: cache,
          guards: LiveApiGuards.defaults(),
        );

        final results = await service.searchText(
          textQuery: 'rooftop bar',
          latitude: 1.23456,
          longitude: 2.34567,
          languageCode: 'fr',
        );

        expect(results, hasLength(1));
        expect(results.single.name, 'Rooftop cached');
        expect(cache.putCalls, isEmpty);
      },
    );

    test(
      'searchNearby cache miss throws when live Google Places is blocked',
      () async {
        final service = PlacesNearbyService(
          cache: _FakeGeminiCacheService(const {}),
          guards: LiveApiGuards.defaults(),
        );

        expect(
          () => service.searchNearby(
            latitude: 1,
            longitude: 2,
            includedTypes: const ['museum'],
          ),
          throwsA(
            isA<LiveApiBlockedException>()
                .having((e) => e.family, 'family', LiveApiFamily.googlePlaces)
                .having(
                  (e) => e.operation,
                  'operation',
                  'PlacesNearbyService.searchNearby',
                ),
          ),
        );
      },
    );

    test(
      'searchText cache miss throws when live Google Places is blocked',
      () async {
        final service = PlacesNearbyService(
          cache: _FakeGeminiCacheService(const {}),
          guards: LiveApiGuards.defaults(),
        );

        expect(
          () => service.searchText(
            textQuery: 'museum',
            latitude: 1,
            longitude: 2,
          ),
          throwsA(
            isA<LiveApiBlockedException>()
                .having((e) => e.family, 'family', LiveApiFamily.googlePlaces)
                .having(
                  (e) => e.operation,
                  'operation',
                  'PlacesNearbyService.searchText',
                ),
          ),
        );
      },
    );
  });
}

Map<String, dynamic> _cachedPlaceJson({
  required String name,
  required String placeId,
}) {
  return {
    'placeId': placeId,
    'name': name,
    'address': '1 Test Street',
    'rating': 4.7,
    'userRatingCount': 123,
    'priceLevel': 2,
    'types': ['museum'],
    'latitude': 1.234,
    'longitude': 2.345,
  };
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
    if (action != 'places_search') return null;
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
