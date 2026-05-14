/// Tests offline `PlaceLookupCacheService` (P0.5 — cache-first strict).
///
/// Vérifie qu'aucun appel live n'est déclenché silencieusement par
/// `resolveCoords()` :
/// - hit complet → coords cachées, fetcher live jamais appelé ;
/// - hit partiel (legacy) sans opt-in → coords partielles, pas de fetch ;
/// - miss sans opt-in → null, pas de fetch ;
/// - erreur de cache sans opt-in → null, pas de fetch (pas de fallback
///   silencieux quand le store est en panne) ;
/// - miss avec opt-in → fetcher appelé exactement une fois et upsert ;
/// - throw du fetcher live (= ce qui arrive si `LiveApiGuards` bloque
///   Places côté `PlacesService`) avec opt-in → exception propagée.
///
/// On injecte un `PlaceCoordsFetcher` fake (un simple closure) pour
/// éviter d'importer `PlacesService` et ses constantes API.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:voyage/features/planning/services/place_lookup_cache_service.dart';

void main() {
  group('PlaceLookupCacheService.resolveCoords — cache-first strict', () {
    test('hit complet → retourne les coords cachées, pas de fetch live', () async {
      final store = _FakeStore(
        cache: {
          'place-1': {
            'latitude': 48.8566,
            'longitude': 2.3522,
            'name': 'Paris CDG',
            'country_code': 'fr',
            'city': 'Paris',
          },
        },
      );
      final fetcher = _RecordingFetcher();
      final service = PlaceLookupCacheService(store, fetcher.call);

      final result = await service.resolveCoords(
        placeId: 'place-1',
        kind: 'airport',
      );

      expect(result, isNotNull);
      expect(result!.lat, 48.8566);
      expect(result.countryCode, 'fr');
      expect(result.city, 'Paris');
      expect(fetcher.calls, isEmpty);
      expect(store.touched, ['place-1']);
      expect(store.upserts, isEmpty);
    });

    test('miss + allowLiveFallback=false (défaut) → null, pas de fetch', () async {
      final store = _FakeStore();
      final fetcher = _RecordingFetcher();
      final service = PlaceLookupCacheService(store, fetcher.call);

      final result = await service.resolveCoords(
        placeId: 'place-2',
        kind: 'airport',
      );

      expect(result, isNull);
      expect(fetcher.calls, isEmpty);
      expect(store.upserts, isEmpty);
    });

    test('erreur de cache + allowLiveFallback=false → null, pas de fetch', () async {
      // Cas critique : Supabase RLS / réseau qui throw ne doit jamais se
      // traduire en appel Google silencieux.
      final store = _FakeStore(readThrows: StateError('rls denied'));
      final fetcher = _RecordingFetcher();
      final service = PlaceLookupCacheService(store, fetcher.call);

      final result = await service.resolveCoords(
        placeId: 'place-3',
        kind: 'airport',
      );

      expect(result, isNull);
      expect(fetcher.calls, isEmpty);
      expect(store.upserts, isEmpty);
    });

    test('hit partiel (legacy) + allowLiveFallback=false → coords partielles, pas de fetch', () async {
      final store = _FakeStore(
        cache: {
          'place-4': {
            'latitude': 13.6900,
            'longitude': 100.7501,
            'name': 'BKK',
            // country_code et city manquants → legacy entry
          },
        },
      );
      final fetcher = _RecordingFetcher();
      final service = PlaceLookupCacheService(store, fetcher.call);

      final result = await service.resolveCoords(
        placeId: 'place-4',
        kind: 'airport',
      );

      expect(result, isNotNull);
      expect(result!.lat, 13.6900);
      expect(result.name, 'BKK');
      expect(result.countryCode, isNull);
      expect(result.city, isNull);
      expect(fetcher.calls, isEmpty, reason: 'aucun fallback live silencieux');
      expect(store.upserts, isEmpty);
    });

    test('miss + allowLiveFallback=true → fetcher appelé + upsert', () async {
      final store = _FakeStore();
      final fetcher = _RecordingFetcher(
        result: (
          lat: 48.8566,
          lng: 2.3522,
          name: 'Paris',
          countryCode: 'fr',
          city: 'Paris',
        ),
      );
      final service = PlaceLookupCacheService(store, fetcher.call);

      final result = await service.resolveCoords(
        placeId: 'place-5',
        kind: 'airport',
        allowLiveFallback: true,
      );

      expect(result, isNotNull);
      expect(result!.name, 'Paris');
      expect(fetcher.calls, hasLength(1));
      expect(fetcher.calls.single.placeId, 'place-5');
      expect(store.upserts, hasLength(1));
      expect(store.upserts.single['place_id'], 'place-5');
      expect(store.upserts.single['kind'], 'airport');
    });

    test('hit partiel + allowLiveFallback=true → re-fetch pour enrichir', () async {
      final store = _FakeStore(
        cache: {
          'place-6': {
            'latitude': 0.0,
            'longitude': 0.0,
            'name': 'Old',
          },
        },
      );
      final fetcher = _RecordingFetcher(
        result: (
          lat: 1.0,
          lng: 1.0,
          name: 'Old',
          countryCode: 'fr',
          city: 'Paris',
        ),
      );
      final service = PlaceLookupCacheService(store, fetcher.call);

      final result = await service.resolveCoords(
        placeId: 'place-6',
        kind: 'airport',
        allowLiveFallback: true,
      );

      expect(result, isNotNull);
      expect(fetcher.calls, hasLength(1));
      expect(store.upserts, hasLength(1));
    });

    test('opt-in + fetcher throw → exception propagée, pas d\'upsert', () async {
      // Reproduit le cas où `LiveApiGuards` bloque Places côté
      // `PlacesService.resolvePlaceCoords` : l'exception remonte au
      // caller (qui la catch en chemin 3 ou la traduit en
      // `geocoding_failed`).
      final store = _FakeStore();
      final fetcher = _RecordingFetcher(throws: StateError('blocked'));
      final service = PlaceLookupCacheService(store, fetcher.call);

      await expectLater(
        () => service.resolveCoords(
          placeId: 'place-7',
          kind: 'airport',
          allowLiveFallback: true,
        ),
        throwsA(isA<StateError>()),
      );
      expect(fetcher.calls, hasLength(1));
      expect(store.upserts, isEmpty);
    });

    test('placeId vide → null direct, aucun lookup', () async {
      final store = _FakeStore();
      final fetcher = _RecordingFetcher();
      final service = PlaceLookupCacheService(store, fetcher.call);

      final result = await service.resolveCoords(
        placeId: '',
        kind: 'airport',
        allowLiveFallback: true,
      );

      expect(result, isNull);
      expect(store.reads, isEmpty);
      expect(fetcher.calls, isEmpty);
    });
  });
}

class _FakeStore implements PlaceLookupCacheStore {
  _FakeStore({Map<String, Map<String, dynamic>>? cache, this.readThrows})
      : _cache = cache ?? {};

  final Map<String, Map<String, dynamic>> _cache;
  final Object? readThrows;
  final reads = <String>[];
  final touched = <String>[];
  final upserts = <Map<String, dynamic>>[];

  @override
  Future<Map<String, dynamic>?> readByPlaceId(String placeId) async {
    reads.add(placeId);
    if (readThrows != null) throw readThrows!;
    return _cache[placeId];
  }

  @override
  Future<void> upsert({
    required String placeId,
    required String name,
    required double latitude,
    required double longitude,
    required String kind,
    String? countryCode,
    String? city,
  }) async {
    upserts.add({
      'place_id': placeId,
      'name': name,
      'latitude': latitude,
      'longitude': longitude,
      'kind': kind,
      'country_code': ?countryCode,
      'city': ?city,
    });
  }

  @override
  Future<void> touch(String placeId) async {
    touched.add(placeId);
  }
}

class _FetcherCall {
  _FetcherCall(this.placeId, this.sessionToken);
  final String placeId;
  final String? sessionToken;
}

class _RecordingFetcher {
  _RecordingFetcher({this.result, this.throws});

  final ({double lat, double lng, String name, String? countryCode, String? city})? result;
  final Object? throws;
  final calls = <_FetcherCall>[];

  Future<({double lat, double lng, String name, String? countryCode, String? city})?>
      call(String placeId, {String? sessionToken}) async {
    calls.add(_FetcherCall(placeId, sessionToken));
    if (throws != null) throw throws!;
    return result;
  }
}
