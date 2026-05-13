import 'package:flutter_test/flutter_test.dart';
import 'package:voyage/config/live_api_guards.dart';
import 'package:voyage/features/planning/services/geocoding_service.dart';
import 'package:voyage/features/planning/services/places_first_pipeline.dart';
import 'package:voyage/features/planning/services/places_nearby_service.dart';
import 'package:voyage/features/poi/data/fake_poi_repository.dart';
import 'package:voyage/features/poi/domain/poi.dart';
import 'package:voyage/features/trips/models/trip_model.dart';

// ─── Fakes ────────────────────────────────────────────────────────────────

class _FakeGeocodingService extends GeocodingService {
  final GeocodingResult? _fixedResult;

  _FakeGeocodingService({GeocodingResult? fixedResult})
    : _fixedResult = fixedResult,
      super(
        guards: const LiveApiGuards(
          allowGooglePlaces: true,
          allowGoogleGeocoding: true,
        ),
      );

  @override
  Future<GeocodingResult?> geocode(String query, {String? regionHint}) async {
    return _fixedResult;
  }
}

class _ThrowingGeocodingService extends GeocodingService {
  _ThrowingGeocodingService()
    : super(
        guards: const LiveApiGuards(
          allowGooglePlaces: false,
          allowGoogleGeocoding: false,
        ),
      );

  @override
  Future<GeocodingResult?> geocode(String query, {String? regionHint}) async {
    throw LiveApiBlockedException(
      family: LiveApiFamily.googleGeocoding,
      operation: 'GeocodingService.geocode',
    );
  }
}

class _RecordingPlacesNearbyService extends PlacesNearbyService {
  var searchNearbyCalls = 0;
  var searchTextCalls = 0;
  final bool _throwIfCalled;

  _RecordingPlacesNearbyService({bool throwIfCalled = false})
    : _throwIfCalled = throwIfCalled,
      super(
        cache: null,
        guards: const LiveApiGuards(
          allowGooglePlaces: true,
          allowGoogleGeocoding: true,
        ),
      );

  @override
  Future<List<NearbyCandidate>> searchNearby({
    required double latitude,
    required double longitude,
    required List<String> includedTypes,
    int radius = 1500,
    int maxResults = 20,
    String? languageCode,
  }) async {
    searchNearbyCalls++;
    if (_throwIfCalled) throw Exception('Places searchNearby should not be called');
    return [];
  }

  @override
  Future<List<NearbyCandidate>> searchText({
    required String textQuery,
    double? latitude,
    double? longitude,
    int radius = 1500,
    int maxResults = 20,
    String? languageCode,
  }) async {
    searchTextCalls++;
    if (_throwIfCalled) throw Exception('Places searchText should not be called');
    return [];
  }
}

// ─── Helpers ──────────────────────────────────────────────────────────────

Trip _buildTrip({
  required String destination,
  required DateTime startDate,
  required DateTime endDate,
  List<String> interests = const ['Culture', 'Spots populaires'],
}) {
  return Trip(
    id: 'test-trip',
    userId: 'test-user',
    title: 'Test Trip',
    destination: destination,
    startDate: startDate,
    endDate: endDate,
    createdAt: DateTime.utc(2026, 1, 1),
    interests: interests,
    destinationKind: 'city',
  );
}

Poi _buildPoi({
  required String poiId,
  required String destinationKey,
  required String name,
  required double lat,
  required double lng,
  PoiCategory category = PoiCategory.museum,
  int? editorialScore,
  String? googlePlaceId,
}) {
  return Poi(
    poiId: poiId,
    destinationKey: destinationKey,
    name: name,
    normalizedName: name.toLowerCase(),
    category: category,
    lat: lat,
    lng: lng,
    sourcePrimaryId: 'source-test',
    editorialScore: editorialScore,
    googlePlaceId: googlePlaceId,
    createdAt: DateTime.utc(2026, 1, 1),
    updatedAt: DateTime.utc(2026, 1, 1),
  );
}

// ─── Tests ────────────────────────────────────────────────────────────────

void main() {
  group('POI-2.4 : POI-only planning for covered destinations', () {
    final parisCenter = GeocodingResult(
      latitude: 48.8566,
      longitude: 2.3522,
      formattedAddress: 'Paris, France',
    );

    test(
      'covered destination with enough POIs does NOT call PlacesNearbyService',
      () async {
        final trip = _buildTrip(
          destination: 'Paris',
          startDate: DateTime.utc(2026, 6, 1),
          endDate: DateTime.utc(2026, 6, 3),
        );
        final pois = <Poi>[
          _buildPoi(
            poiId: 'poi-1',
            destinationKey: 'paris',
            name: 'Louvre',
            lat: 48.8606,
            lng: 2.3376,
            editorialScore: 100,
            googlePlaceId: 'place-louvre',
          ),
          _buildPoi(
            poiId: 'poi-2',
            destinationKey: 'paris',
            name: 'Tour Eiffel',
            lat: 48.8584,
            lng: 2.2945,
            editorialScore: 100,
            googlePlaceId: 'place-eiffel',
          ),
          _buildPoi(
            poiId: 'poi-3',
            destinationKey: 'paris',
            name: 'Musée d\'Orsay',
            lat: 48.8599,
            lng: 2.3266,
            editorialScore: 90,
          ),
          _buildPoi(
            poiId: 'poi-4',
            destinationKey: 'paris',
            name: 'Notre-Dame',
            lat: 48.8530,
            lng: 2.3499,
            editorialScore: 95,
          ),
          _buildPoi(
            poiId: 'poi-5',
            destinationKey: 'paris',
            name: 'Sacré-Cœur',
            lat: 48.8867,
            lng: 2.3431,
            editorialScore: 85,
          ),
          _buildPoi(
            poiId: 'poi-6',
            destinationKey: 'paris',
            name: 'Centre Pompidou',
            lat: 48.8606,
            lng: 2.3522,
            editorialScore: 80,
          ),
        ];
        final poiRepo = FakePoiRepository(pois: pois);
        final geocoder = _FakeGeocodingService(fixedResult: parisCenter);
        final placesService = _RecordingPlacesNearbyService(throwIfCalled: true);

        final pool = await gatherCandidatesForTrip(
          trip: trip,
          hotels: [],
          geocoder: geocoder,
          nearbyService: placesService,
          poiRepository: poiRepo,
        );

        expect(placesService.searchNearbyCalls, equals(0));
        expect(placesService.searchTextCalls, equals(0));
        expect(pool, isNotEmpty);
        expect(pool.length, equals(3)); // 3 days

        // Each day should have POI candidates in every interest
        for (final dayCandidates in pool) {
          expect(dayCandidates.byInterest, isNotEmpty);
          for (final candidates in dayCandidates.byInterest.values) {
            expect(candidates, isNotEmpty);
            // All candidates should be POIs (6 total)
            expect(candidates.length, equals(6));
          }
        }
      },
    );

    test(
      'covered destination with empty POIs falls back to PlacesNearbyService',
      () async {
        final trip = _buildTrip(
          destination: 'Paris',
          startDate: DateTime.utc(2026, 6, 1),
          endDate: DateTime.utc(2026, 6, 3),
        );
        final poiRepo = FakePoiRepository(pois: []);
        final geocoder = _FakeGeocodingService(fixedResult: parisCenter);
        final placesService = _RecordingPlacesNearbyService(throwIfCalled: false);

        final pool = await gatherCandidatesForTrip(
          trip: trip,
          hotels: [],
          geocoder: geocoder,
          nearbyService: placesService,
          poiRepository: poiRepo,
        );

        // Should have fallen back to Places (searchNearby called for interests)
        expect(placesService.searchNearbyCalls, greaterThan(0));
        expect(pool, isNotEmpty);
      },
    );

    test(
      'covered destination with insufficient POIs falls back to PlacesNearbyService',
      () async {
        final trip = _buildTrip(
          destination: 'Paris',
          startDate: DateTime.utc(2026, 6, 1),
          endDate: DateTime.utc(2026, 6, 3),
        );
        // Only 2 POIs for 3 days → below threshold (needs 5 total AND 3 per day)
        final pois = <Poi>[
          _buildPoi(
            poiId: 'poi-1',
            destinationKey: 'paris',
            name: 'Louvre',
            lat: 48.8606,
            lng: 2.3376,
            editorialScore: 100,
          ),
          _buildPoi(
            poiId: 'poi-2',
            destinationKey: 'paris',
            name: 'Tour Eiffel',
            lat: 48.8584,
            lng: 2.2945,
            editorialScore: 100,
          ),
        ];
        final poiRepo = FakePoiRepository(pois: pois);
        final geocoder = _FakeGeocodingService(fixedResult: parisCenter);
        final placesService = _RecordingPlacesNearbyService(throwIfCalled: false);

        final pool = await gatherCandidatesForTrip(
          trip: trip,
          hotels: [],
          geocoder: geocoder,
          nearbyService: placesService,
          poiRepository: poiRepo,
        );

        // Should have fallen back to Places
        expect(placesService.searchNearbyCalls, greaterThan(0));
        expect(pool, isNotEmpty);
      },
    );

    test(
      'non-covered destination keeps existing Places behavior',
      () async {
        final trip = _buildTrip(
          destination: 'Tokyo',
          startDate: DateTime.utc(2026, 6, 1),
          endDate: DateTime.utc(2026, 6, 3),
        );
        final poiRepo = FakePoiRepository(pois: []);
        final geocoder = _FakeGeocodingService(
          fixedResult: GeocodingResult(
            latitude: 35.6762,
            longitude: 139.6503,
            formattedAddress: 'Tokyo, Japan',
          ),
        );
        final placesService = _RecordingPlacesNearbyService(throwIfCalled: false);

        final pool = await gatherCandidatesForTrip(
          trip: trip,
          hotels: [],
          geocoder: geocoder,
          nearbyService: placesService,
          poiRepository: poiRepo,
        );

        // Should call Places because Tokyo is not covered
        expect(placesService.searchNearbyCalls, greaterThan(0));
        expect(pool, isNotEmpty);
      },
    );

    test(
      'null poiRepository falls back to Places for covered destination',
      () async {
        final trip = _buildTrip(
          destination: 'Paris',
          startDate: DateTime.utc(2026, 6, 1),
          endDate: DateTime.utc(2026, 6, 3),
        );
        final geocoder = _FakeGeocodingService(fixedResult: parisCenter);
        final placesService = _RecordingPlacesNearbyService(throwIfCalled: false);

        final pool = await gatherCandidatesForTrip(
          trip: trip,
          hotels: [],
          geocoder: geocoder,
          nearbyService: placesService,
          poiRepository: null,
        );

        expect(placesService.searchNearbyCalls, greaterThan(0));
        expect(pool, isNotEmpty);
      },
    );

    test('POI candidates are present in DayCandidates with correct placeIds', () async {
      final trip = _buildTrip(
        destination: 'Paris',
        startDate: DateTime.utc(2026, 6, 1),
        endDate: DateTime.utc(2026, 6, 2),
      );
      final pois = <Poi>[
        _buildPoi(
          poiId: 'poi-louvre',
          destinationKey: 'paris',
          name: 'Louvre',
          lat: 48.8606,
          lng: 2.3376,
          editorialScore: 100,
          googlePlaceId: 'google-place-louvre',
        ),
        _buildPoi(
          poiId: 'poi-eiffel',
          destinationKey: 'paris',
          name: 'Tour Eiffel',
          lat: 48.8584,
          lng: 2.2945,
          editorialScore: 100,
        ),
        _buildPoi(
          poiId: 'poi-orsay',
          destinationKey: 'paris',
          name: 'Musée d\'Orsay',
          lat: 48.8599,
          lng: 2.3266,
          editorialScore: 90,
        ),
        _buildPoi(
          poiId: 'poi-nd',
          destinationKey: 'paris',
          name: 'Notre-Dame',
          lat: 48.8530,
          lng: 2.3499,
          editorialScore: 95,
        ),
        _buildPoi(
          poiId: 'poi-sc',
          destinationKey: 'paris',
          name: 'Sacré-Cœur',
          lat: 48.8867,
          lng: 2.3431,
          editorialScore: 85,
        ),
      ];
      final poiRepo = FakePoiRepository(pois: pois);
      final geocoder = _FakeGeocodingService(fixedResult: parisCenter);
      final placesService = _RecordingPlacesNearbyService(throwIfCalled: true);

      final pool = await gatherCandidatesForTrip(
        trip: trip,
        hotels: [],
        geocoder: geocoder,
        nearbyService: placesService,
        poiRepository: poiRepo,
      );

      expect(pool, isNotEmpty);
      // Check that POIs with googlePlaceId use it, others use synthetic IDs
      final allCandidates = pool.first.byInterest.values.expand((l) => l);
      final placeIds = allCandidates.map((c) => c.placeId).toSet();
      expect(placeIds, contains('google-place-louvre'));
      expect(placeIds, contains('poi:poi-eiffel'));
      expect(placeIds, contains('poi:poi-orsay'));
    });

    test(
      'covered destination with enough POIs works even when geocoding is blocked',
      () async {
        final trip = _buildTrip(
          destination: 'Paris',
          startDate: DateTime.utc(2026, 6, 1),
          endDate: DateTime.utc(2026, 6, 3),
        );
        final pois = <Poi>[
          _buildPoi(
            poiId: 'poi-1',
            destinationKey: 'paris',
            name: 'Louvre',
            lat: 48.8606,
            lng: 2.3376,
            editorialScore: 100,
          ),
          _buildPoi(
            poiId: 'poi-2',
            destinationKey: 'paris',
            name: 'Tour Eiffel',
            lat: 48.8584,
            lng: 2.2945,
            editorialScore: 100,
          ),
          _buildPoi(
            poiId: 'poi-3',
            destinationKey: 'paris',
            name: 'Musée d\'Orsay',
            lat: 48.8599,
            lng: 2.3266,
            editorialScore: 90,
          ),
          _buildPoi(
            poiId: 'poi-4',
            destinationKey: 'paris',
            name: 'Notre-Dame',
            lat: 48.8530,
            lng: 2.3499,
            editorialScore: 95,
          ),
          _buildPoi(
            poiId: 'poi-5',
            destinationKey: 'paris',
            name: 'Sacré-Cœur',
            lat: 48.8867,
            lng: 2.3431,
            editorialScore: 85,
          ),
          _buildPoi(
            poiId: 'poi-6',
            destinationKey: 'paris',
            name: 'Centre Pompidou',
            lat: 48.8606,
            lng: 2.3522,
            editorialScore: 80,
          ),
        ];
        final poiRepo = FakePoiRepository(pois: pois);
        final geocoder = _ThrowingGeocodingService();
        final placesService = _RecordingPlacesNearbyService(throwIfCalled: true);

        // POI-first should bypass geocoding entirely and not throw.
        final pool = await gatherCandidatesForTrip(
          trip: trip,
          hotels: [],
          geocoder: geocoder,
          nearbyService: placesService,
          poiRepository: poiRepo,
        );

        expect(placesService.searchNearbyCalls, equals(0));
        expect(placesService.searchTextCalls, equals(0));
        expect(pool, isNotEmpty);
        expect(pool.length, equals(3));

        // Centre should be the POI centroid, not from geocoding.
        for (final dayCandidates in pool) {
          expect(dayCandidates.center.source, equals('poi_centroid'));
        }
      },
    );

    test(
      'covered destination with blocked geocoding and empty POIs falls back and throws',
      () async {
        final trip = _buildTrip(
          destination: 'Paris',
          startDate: DateTime.utc(2026, 6, 1),
          endDate: DateTime.utc(2026, 6, 3),
        );
        final poiRepo = FakePoiRepository(pois: []);
        final geocoder = _ThrowingGeocodingService();
        final placesService = _RecordingPlacesNearbyService(throwIfCalled: false);

        // POI-first fails (0 POIs), falls back to geocoding, which throws.
        expect(
          () => gatherCandidatesForTrip(
            trip: trip,
            hotels: [],
            geocoder: geocoder,
            nearbyService: placesService,
            poiRepository: poiRepo,
          ),
          throwsA(isA<LiveApiBlockedException>()),
        );
      },
    );

    test(
      'geocoding is never called for covered destination with enough POIs',
      () async {
        final trip = _buildTrip(
          destination: 'Paris',
          startDate: DateTime.utc(2026, 6, 1),
          endDate: DateTime.utc(2026, 6, 2),
        );
        final pois = <Poi>[
          _buildPoi(
            poiId: 'poi-1',
            destinationKey: 'paris',
            name: 'Louvre',
            lat: 48.8606,
            lng: 2.3376,
            editorialScore: 100,
          ),
          _buildPoi(
            poiId: 'poi-2',
            destinationKey: 'paris',
            name: 'Tour Eiffel',
            lat: 48.8584,
            lng: 2.2945,
            editorialScore: 100,
          ),
          _buildPoi(
            poiId: 'poi-3',
            destinationKey: 'paris',
            name: 'Musée d\'Orsay',
            lat: 48.8599,
            lng: 2.3266,
            editorialScore: 90,
          ),
          _buildPoi(
            poiId: 'poi-4',
            destinationKey: 'paris',
            name: 'Notre-Dame',
            lat: 48.8530,
            lng: 2.3499,
            editorialScore: 95,
          ),
          _buildPoi(
            poiId: 'poi-5',
            destinationKey: 'paris',
            name: 'Sacré-Cœur',
            lat: 48.8867,
            lng: 2.3431,
            editorialScore: 85,
          ),
        ];
        final poiRepo = FakePoiRepository(pois: pois);

        // Use a geocoder that would throw if called.
        final geocoder = _ThrowingGeocodingService();
        final placesService = _RecordingPlacesNearbyService(throwIfCalled: true);

        final pool = await gatherCandidatesForTrip(
          trip: trip,
          hotels: [],
          geocoder: geocoder,
          nearbyService: placesService,
          poiRepository: poiRepo,
        );

        // If geocoding were called, it would have thrown.
        // Success means geocoding was bypassed.
        expect(pool, isNotEmpty);
        expect(pool.length, equals(2));
      },
    );
  });
}
