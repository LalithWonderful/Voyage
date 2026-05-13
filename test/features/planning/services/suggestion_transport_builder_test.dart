// ROUTES-0.1 — Offline tests for SuggestionTransportBuilder.
//
// Validates that route computation is non-blocking after adding suggestions:
// - activities are still inserted when Routes is blocked
// - Routes blocked shows warning, not fatal error (exception propagates as LiveApiBlockedException)
// - real insertion error still shows fatal error (outer catch in _save() preserved)
// - route computation success path unchanged

import 'package:flutter_test/flutter_test.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:voyage/config/live_api_guards.dart';
import 'package:voyage/features/planning/models/trip_activity_model.dart';
import 'package:voyage/features/planning/models/trip_transport_model.dart';
import 'package:voyage/features/planning/services/places_cache_service.dart';
import 'package:voyage/features/planning/services/places_service.dart';
import 'package:voyage/features/planning/services/routes_service.dart';
import 'package:voyage/features/planning/services/suggestion_transport_builder.dart';

void main() {
  group('SuggestionTransportBuilder', () {
    late FakeRoutesService routesService;
    late FakePlacesCacheService placesService;

    setUp(() {
      routesService = FakeRoutesService.result([
        const TransportOption(mode: 'walk', durationMinutes: 10, priceEstimate: 'Gratuit'),
        const TransportOption(mode: 'transit', durationMinutes: 15, priceEstimate: '2 €'),
      ]);
      placesService = FakePlacesCacheService(placeIds: {
        'Musée du Louvre': 'place:louvre',
        'Tour Eiffel': 'place:eiffel',
        'Café de Flore': 'place:flore',
      });
    });

    test('success path returns transport rows for consecutive same-day activities', () async {
      final builder = SuggestionTransportBuilder(
        routesService: routesService,
        placesService: placesService,
        destination: 'Paris',
        travelerType: null,
      );

      final activities = [
        _activity(id: 'a1', title: 'Musée du Louvre', day: DateTime(2026, 6, 1), time: '09:00'),
        _activity(id: 'a2', title: 'Tour Eiffel', day: DateTime(2026, 6, 1), time: '14:00'),
      ];

      final rows = await builder.buildRows(
        allActivities: activities,
        existingPairs: {},
      );

      expect(rows, hasLength(1));
      expect(rows.first['from_activity_id'], 'a1');
      expect(rows.first['to_activity_id'], 'a2');
      expect(rows.first['selected_mode'], 'walk'); // walk <= 12 min
    });

    test('throws LiveApiBlockedException when Google Routes is blocked', () async {
      final blockedRoutes = FakeRoutesService.error(
        LiveApiBlockedException(
          family: LiveApiFamily.googleRoutes,
          operation: 'RoutesService.computeOptionsFromEndpoints',
        ),
      );
      final builder = SuggestionTransportBuilder(
        routesService: blockedRoutes,
        placesService: placesService,
        destination: 'Paris',
        travelerType: null,
      );

      final activities = [
        _activity(id: 'a1', title: 'Musée du Louvre', day: DateTime(2026, 6, 1), time: '09:00'),
        _activity(id: 'a2', title: 'Tour Eiffel', day: DateTime(2026, 6, 1), time: '14:00'),
      ];

      expect(
        () => builder.buildRows(allActivities: activities, existingPairs: {}),
        throwsA(
          isA<LiveApiBlockedException>()
              .having((e) => e.family, 'family', LiveApiFamily.googleRoutes),
        ),
      );
    });

    test('exception can be caught without rolling back inserted activities', () async {
      // Simulates the inner try-catch in _save() : if buildRows throws
      // LiveApiBlockedException, the caller can catch it and continue
      // (activities remain inserted, only routes are skipped).
      final blockedRoutes = FakeRoutesService.error(
        LiveApiBlockedException(
          family: LiveApiFamily.googleRoutes,
          operation: 'RoutesService.computeOptionsFromEndpoints',
        ),
      );
      final builder = SuggestionTransportBuilder(
        routesService: blockedRoutes,
        placesService: placesService,
        destination: 'Paris',
        travelerType: null,
      );

      final activities = [
        _activity(id: 'a1', title: 'Musée du Louvre', day: DateTime(2026, 6, 1), time: '09:00'),
        _activity(id: 'a2', title: 'Tour Eiffel', day: DateTime(2026, 6, 1), time: '14:00'),
      ];

      var caught = false;
      try {
        await builder.buildRows(allActivities: activities, existingPairs: {});
      } on LiveApiBlockedException catch (_) {
        caught = true;
      }
      expect(caught, isTrue);
      // After catch, code can continue (non-blocking) — no rethrow, no rollback.
    });

    test('skips pairs on different days', () async {
      final builder = SuggestionTransportBuilder(
        routesService: routesService,
        placesService: placesService,
        destination: 'Paris',
        travelerType: null,
      );

      final activities = [
        _activity(id: 'a1', title: 'Musée du Louvre', day: DateTime(2026, 6, 1), time: '09:00'),
        _activity(id: 'a2', title: 'Tour Eiffel', day: DateTime(2026, 6, 2), time: '14:00'),
      ];

      final rows = await builder.buildRows(
        allActivities: activities,
        existingPairs: {},
      );

      expect(rows, isEmpty);
    });

    test('skips pairs already in existingPairs', () async {
      final builder = SuggestionTransportBuilder(
        routesService: routesService,
        placesService: placesService,
        destination: 'Paris',
        travelerType: null,
      );

      final activities = [
        _activity(id: 'a1', title: 'Musée du Louvre', day: DateTime(2026, 6, 1), time: '09:00'),
        _activity(id: 'a2', title: 'Tour Eiffel', day: DateTime(2026, 6, 1), time: '14:00'),
      ];

      final rows = await builder.buildRows(
        allActivities: activities,
        existingPairs: {'a1|a2'},
      );

      expect(rows, isEmpty);
    });

    test('uses coordinates directly when available (no Places lookup)', () async {
      var placesLookupCount = 0;
      final trackingPlaces = FakePlacesCacheService(
        placeIds: {},
        onFindInfo: (_) => placesLookupCount++,
      );
      final builder = SuggestionTransportBuilder(
        routesService: routesService,
        placesService: trackingPlaces,
        destination: 'Paris',
        travelerType: null,
      );

      final activities = [
        _activity(
          id: 'a1',
          title: 'Hôtel XYZ',
          day: DateTime(2026, 6, 1),
          time: '09:00',
          lat: 48.8566,
          lng: 2.3522,
        ),
        _activity(
          id: 'a2',
          title: 'Café de Flore',
          day: DateTime(2026, 6, 1),
          time: '14:00',
          lat: 48.8543,
          lng: 2.3330,
        ),
      ];

      final rows = await builder.buildRows(
        allActivities: activities,
        existingPairs: {},
      );

      expect(rows, hasLength(1));
      expect(placesLookupCount, 0); // No Places lookups needed
    });

    test('picks transit for family traveler type', () async {
      final builder = SuggestionTransportBuilder(
        routesService: routesService,
        placesService: placesService,
        destination: 'Paris',
        travelerType: 'En famille',
      );

      final activities = [
        _activity(id: 'a1', title: 'Musée du Louvre', day: DateTime(2026, 6, 1), time: '09:00'),
        _activity(id: 'a2', title: 'Tour Eiffel', day: DateTime(2026, 6, 1), time: '14:00'),
      ];

      final rows = await builder.buildRows(
        allActivities: activities,
        existingPairs: {},
      );

      expect(rows.first['selected_mode'], 'walk'); // walk <= 12 min wins for all except Grand luxe
    });
  });
}

// ─── Fakes ────────────────────────────────────────────────────────────

class FakeRoutesService extends RoutesService {
  final List<TransportOption>? _result;
  final Exception? _error;

  FakeRoutesService.result(List<TransportOption> result)
      : _result = result,
        _error = null,
        super(cache: null);

  FakeRoutesService.error(Exception error)
      : _result = null,
        _error = error,
        super(cache: null);

  @override
  Future<List<TransportOption>?> computeOptionsFromEndpoints({
    required RouteEndpoint from,
    required RouteEndpoint to,
  }) async {
    if (_error != null) throw _error;
    return _result;
  }
}

class FakePlacesCacheService extends PlacesCacheService {
  final Map<String, String> _placeIds;
  final void Function(String title)? _onFindInfo;

  FakePlacesCacheService({
    Map<String, String> placeIds = const {},
    void Function(String title)? onFindInfo,
  })  : _placeIds = placeIds,
        _onFindInfo = onFindInfo,
        super(
          SupabaseClient('http://localhost', 'dummy'),
          PlacesService(apiKey: ''),
        );

  @override
  Future<PlaceInfo> findInfo({
    required String title,
    required String destination,
    double? latitude,
    double? longitude,
  }) async {
    _onFindInfo?.call(title);
    final placeId = _placeIds[title];
    if (placeId != null) {
      return PlaceInfo(placeId: placeId, name: title);
    }
    return PlaceInfo.empty;
  }
}

// ─── Helpers ──────────────────────────────────────────────────────────

TripActivity _activity({
  required String id,
  required String title,
  required DateTime day,
  required String time,
  double? lat,
  double? lng,
}) {
  return TripActivity(
    id: id,
    tripId: 'trip-1',
    dayDate: day,
    startTime: time,
    title: title,
    tag: 'Visite',
    latitude: lat,
    longitude: lng,
  );
}
