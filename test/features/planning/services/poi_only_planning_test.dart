import 'package:flutter_test/flutter_test.dart';
import 'package:voyage/config/live_api_guards.dart';
import 'package:voyage/features/planning/services/day_center_service.dart';
import 'package:voyage/features/planning/services/geocoding_service.dart';
import 'package:voyage/features/planning/services/places_first_pipeline.dart';
import 'package:voyage/features/planning/services/places_nearby_service.dart';
import 'package:voyage/features/planning/services/poi_candidate_adapter.dart';
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

    test(
      'POI candidates pass deterministic selector and produce ActivitySuggestions',
      () async {
        final trip = _buildTrip(
          destination: 'Paris',
          startDate: DateTime.utc(2026, 6, 1),
          endDate: DateTime.utc(2026, 6, 2),
          interests: ['Culture', 'Spots populaires'],
        );
        final pois = <Poi>[
          _buildPoi(
            poiId: 'poi-1',
            destinationKey: 'paris',
            name: 'Louvre',
            lat: 48.8606,
            lng: 2.3376,
            category: PoiCategory.museum,
            editorialScore: 100,
          ),
          _buildPoi(
            poiId: 'poi-2',
            destinationKey: 'paris',
            name: 'Tour Eiffel',
            lat: 48.8584,
            lng: 2.2945,
            category: PoiCategory.monument,
            editorialScore: 100,
          ),
          _buildPoi(
            poiId: 'poi-3',
            destinationKey: 'paris',
            name: 'Musée d\'Orsay',
            lat: 48.8599,
            lng: 2.3266,
            category: PoiCategory.museum,
            editorialScore: 90,
          ),
          _buildPoi(
            poiId: 'poi-4',
            destinationKey: 'paris',
            name: 'Notre-Dame',
            lat: 48.8530,
            lng: 2.3499,
            category: PoiCategory.monument,
            editorialScore: 95,
          ),
          _buildPoi(
            poiId: 'poi-5',
            destinationKey: 'paris',
            name: 'Sacré-Cœur',
            lat: 48.8867,
            lng: 2.3431,
            category: PoiCategory.viewpoint,
            editorialScore: 85,
          ),
          _buildPoi(
            poiId: 'poi-6',
            destinationKey: 'paris',
            name: 'Jardin du Luxembourg',
            lat: 48.8462,
            lng: 2.3372,
            category: PoiCategory.park,
            editorialScore: 80,
          ),
        ];
        final poiRepo = FakePoiRepository(pois: pois);
        final adapter = PoiCandidateAdapter(poiRepo);
        final candidates = await adapter.adaptForDestination('paris');

        // Verify candidates pass quality gates
        expect(candidates, isNotEmpty);
        for (final c in candidates) {
          expect(c.rating, isNotNull);
          expect(c.rating! >= 4.0, isTrue);
          expect(c.userRatingCount, isNotNull);
          expect(c.userRatingCount! >= 5, isTrue);
        }

        // Build a PlacesPromptInput and run selector
        final center = DayCenter(
          latitude: 48.8566,
          longitude: 2.3522,
          source: 'test',
        );
        final poolMap = <String, ({NearbyCandidate candidate, List<String> matchedInterests})>{
          for (final c in candidates)
            c.placeId: (candidate: c, matchedInterests: ['Culture', 'Spots populaires']),
        };
        final input = PlacesPromptInput(
          center: center,
          days: [DateTime.utc(2026, 6, 1), DateTime.utc(2026, 6, 2)],
          pool: poolMap,
        );

        final suggestions = selectVisitsDeterministic(
          clusters: [input],
          trip: trip,
          travelerProfile: null,
        );

        expect(suggestions, isNotEmpty);
        expect(suggestions.length, greaterThanOrEqualTo(1));
      },
    );

    // ─── Regression POI-2.5 : destination isolation ─────────────────────────

    test(
      'Barcelona trip returns only Barcelona POIs via PoiCandidateAdapter',
      () async {
        final barcelonaPois = <Poi>[
          _buildPoi(
            poiId: 'b1',
            destinationKey: 'barcelona',
            name: 'Sagrada Família',
            lat: 41.4036,
            lng: 2.1744,
            editorialScore: 100,
          ),
          _buildPoi(
            poiId: 'b2',
            destinationKey: 'barcelona',
            name: 'Park Güell',
            lat: 41.4145,
            lng: 2.1527,
            editorialScore: 95,
          ),
          _buildPoi(
            poiId: 'b3',
            destinationKey: 'barcelona',
            name: 'Casa Batlló',
            lat: 41.3916,
            lng: 2.1649,
            editorialScore: 90,
          ),
          _buildPoi(
            poiId: 'b4',
            destinationKey: 'barcelona',
            name: 'La Rambla',
            lat: 41.3808,
            lng: 2.1734,
            editorialScore: 85,
          ),
          _buildPoi(
            poiId: 'b5',
            destinationKey: 'barcelona',
            name: 'Camp Nou',
            lat: 41.3809,
            lng: 2.1228,
            editorialScore: 80,
          ),
          _buildPoi(
            poiId: 'b6',
            destinationKey: 'barcelona',
            name: 'Picasso Museum',
            lat: 41.3852,
            lng: 2.1809,
            editorialScore: 78,
          ),
        ];
        // Inject Rome POIs with wrong destination_key to simulate DB corruption.
        final romePois = <Poi>[
          _buildPoi(
            poiId: 'r1',
            destinationKey: 'rome',
            name: 'Colosseum',
            lat: 41.8902,
            lng: 12.4924,
            editorialScore: 100,
          ),
          _buildPoi(
            poiId: 'r2',
            destinationKey: 'rome',
            name: 'Pantheon',
            lat: 41.8986,
            lng: 12.4769,
            editorialScore: 95,
          ),
        ];
        final repo = FakePoiRepository(pois: [...barcelonaPois, ...romePois]);
        final adapter = PoiCandidateAdapter(repo);
        final candidates = await adapter.adaptForDestination('barcelona');

        // Must contain only Barcelona names
        final names = candidates.map((c) => c.name).toSet();
        expect(names, contains('Sagrada Família'));
        expect(names, contains('Park Güell'));
        expect(names, isNot(contains('Colosseum')));
        expect(names, isNot(contains('Pantheon')));
        expect(candidates.length, equals(6));
      },
    );

    test(
      'Rome trip returns only Rome POIs via PoiCandidateAdapter',
      () async {
        final romePois = <Poi>[
          _buildPoi(
            poiId: 'r1',
            destinationKey: 'rome',
            name: 'Colosseum',
            lat: 41.8902,
            lng: 12.4924,
            editorialScore: 100,
          ),
          _buildPoi(
            poiId: 'r2',
            destinationKey: 'rome',
            name: 'Pantheon',
            lat: 41.8986,
            lng: 12.4769,
            editorialScore: 95,
          ),
          _buildPoi(
            poiId: 'r3',
            destinationKey: 'rome',
            name: 'Trevi Fountain',
            lat: 41.9009,
            lng: 12.4833,
            editorialScore: 90,
          ),
          _buildPoi(
            poiId: 'r4',
            destinationKey: 'rome',
            name: 'Roman Forum',
            lat: 41.8925,
            lng: 12.4853,
            editorialScore: 88,
          ),
          _buildPoi(
            poiId: 'r5',
            destinationKey: 'rome',
            name: 'Capitoline Museums',
            lat: 41.8931,
            lng: 12.4828,
            editorialScore: 85,
          ),
          _buildPoi(
            poiId: 'r6',
            destinationKey: 'rome',
            name: 'Vatican Museums',
            lat: 41.9065,
            lng: 12.4536,
            editorialScore: 98,
          ),
        ];
        final barcelonaPois = <Poi>[
          _buildPoi(
            poiId: 'b1',
            destinationKey: 'barcelona',
            name: 'Sagrada Família',
            lat: 41.4036,
            lng: 2.1744,
            editorialScore: 100,
          ),
        ];
        final repo = FakePoiRepository(pois: [...romePois, ...barcelonaPois]);
        final adapter = PoiCandidateAdapter(repo);
        final candidates = await adapter.adaptForDestination('rome');

        final names = candidates.map((c) => c.name).toSet();
        expect(names, contains('Colosseum'));
        expect(names, contains('Pantheon'));
        expect(names, isNot(contains('Sagrada Família')));
        expect(candidates.length, equals(6));
      },
    );

    test(
      'gatherCandidatesForTrip isolates Barcelona from Rome POIs in mixed repo',
      () async {
        final trip = _buildTrip(
          destination: 'Barcelona',
          startDate: DateTime.utc(2026, 6, 1),
          endDate: DateTime.utc(2026, 6, 2),
        );
        final mixedPois = <Poi>[
          _buildPoi(
            poiId: 'b1',
            destinationKey: 'barcelona',
            name: 'Sagrada Família',
            lat: 41.4036,
            lng: 2.1744,
            editorialScore: 100,
          ),
          _buildPoi(
            poiId: 'b2',
            destinationKey: 'barcelona',
            name: 'Park Güell',
            lat: 41.4145,
            lng: 2.1527,
            editorialScore: 95,
          ),
          _buildPoi(
            poiId: 'b3',
            destinationKey: 'barcelona',
            name: 'Casa Batlló',
            lat: 41.3916,
            lng: 2.1649,
            editorialScore: 90,
          ),
          _buildPoi(
            poiId: 'b4',
            destinationKey: 'barcelona',
            name: 'La Rambla',
            lat: 41.3808,
            lng: 2.1734,
            editorialScore: 85,
          ),
          _buildPoi(
            poiId: 'b5',
            destinationKey: 'barcelona',
            name: 'Camp Nou',
            lat: 41.3809,
            lng: 2.1228,
            editorialScore: 80,
          ),
          _buildPoi(
            poiId: 'b6',
            destinationKey: 'barcelona',
            name: 'Picasso Museum',
            lat: 41.3852,
            lng: 2.1809,
            editorialScore: 78,
          ),
          _buildPoi(
            poiId: 'r1',
            destinationKey: 'rome',
            name: 'Colosseum',
            lat: 41.8902,
            lng: 12.4924,
            editorialScore: 100,
          ),
          _buildPoi(
            poiId: 'r2',
            destinationKey: 'rome',
            name: 'Pantheon',
            lat: 41.8986,
            lng: 12.4769,
            editorialScore: 95,
          ),
        ];
        final poiRepo = FakePoiRepository(pois: mixedPois);
        final geocoder = _ThrowingGeocodingService();
        final placesService = _RecordingPlacesNearbyService(throwIfCalled: true);

        final pool = await gatherCandidatesForTrip(
          trip: trip,
          hotels: [],
          geocoder: geocoder,
          nearbyService: placesService,
          poiRepository: poiRepo,
        );

        expect(pool, isNotEmpty);
        final allCandidates = pool.expand((d) => d.byInterest.values).expand((l) => l);
        final names = allCandidates.map((c) => c.name).toSet();
        expect(names, contains('Sagrada Família'));
        expect(names, isNot(contains('Colosseum')));
        expect(names, isNot(contains('Pantheon')));
      },
    );

    test(
      'selectVisitsDeterministic from Barcelona POIs produces Barcelona suggestions',
      () async {
        final trip = _buildTrip(
          destination: 'Barcelona',
          startDate: DateTime.utc(2026, 6, 1),
          endDate: DateTime.utc(2026, 6, 2),
          interests: ['Culture', 'Spots populaires'],
        );
        final barcelonaPois = <Poi>[
          _buildPoi(
            poiId: 'b1',
            destinationKey: 'barcelona',
            name: 'Sagrada Família',
            lat: 41.4036,
            lng: 2.1744,
            category: PoiCategory.monument,
            editorialScore: 100,
          ),
          _buildPoi(
            poiId: 'b2',
            destinationKey: 'barcelona',
            name: 'Park Güell',
            lat: 41.4145,
            lng: 2.1527,
            category: PoiCategory.park,
            editorialScore: 95,
          ),
          _buildPoi(
            poiId: 'b3',
            destinationKey: 'barcelona',
            name: 'Casa Batlló',
            lat: 41.3916,
            lng: 2.1649,
            category: PoiCategory.monument,
            editorialScore: 90,
          ),
          _buildPoi(
            poiId: 'b4',
            destinationKey: 'barcelona',
            name: 'La Rambla',
            lat: 41.3808,
            lng: 2.1734,
            category: PoiCategory.neighborhood,
            editorialScore: 85,
          ),
          _buildPoi(
            poiId: 'b5',
            destinationKey: 'barcelona',
            name: 'Camp Nou',
            lat: 41.3809,
            lng: 2.1228,
            category: PoiCategory.monument,
            editorialScore: 80,
          ),
          _buildPoi(
            poiId: 'b6',
            destinationKey: 'barcelona',
            name: 'Picasso Museum',
            lat: 41.3852,
            lng: 2.1809,
            category: PoiCategory.museum,
            editorialScore: 78,
          ),
        ];
        final poiRepo = FakePoiRepository(pois: barcelonaPois);
        final adapter = PoiCandidateAdapter(poiRepo);
        final candidates = await adapter.adaptForDestination('barcelona');

        final center = DayCenter(
          latitude: 41.3851,
          longitude: 2.1734,
          source: 'test',
        );
        final poolMap = <String, ({NearbyCandidate candidate, List<String> matchedInterests})>{
          for (final c in candidates)
            c.placeId: (candidate: c, matchedInterests: ['Culture', 'Spots populaires']),
        };
        final input = PlacesPromptInput(
          center: center,
          days: [DateTime.utc(2026, 6, 1), DateTime.utc(2026, 6, 2)],
          pool: poolMap,
        );

        final suggestions = selectVisitsDeterministic(
          clusters: [input],
          trip: trip,
          travelerProfile: null,
        );

        expect(suggestions, isNotEmpty);
        for (final s in suggestions) {
          expect(s.title, isNot(equals('Colosseum')));
          expect(s.title, isNot(equals('Pantheon')));
          expect(s.title, isNot(equals('Trevi Fountain')));
          expect(s.title, isNot(equals('Roman Forum')));
          expect(s.title, isNot(equals('Capitoline Museums')));
        }
      },
    );
  });

  // ═══════════════════════════════════════════════════════════════════════
  // POI-2.6 — Scoring quality improvements
  // ═══════════════════════════════════════════════════════════════════════

  group('POI-2.6 : POI scoring quality', () {
    test('high editorial_score POIs rank higher in suggestions', () async {
      final trip = _buildTrip(
        destination: 'Paris',
        startDate: DateTime.utc(2026, 6, 1),
        endDate: DateTime.utc(2026, 6, 1),
        interests: ['Culture'],
      );
      final pois = <Poi>[
        _buildPoi(
          poiId: 'low',
          destinationKey: 'paris',
          name: 'Low Score Museum',
          lat: 48.86,
          lng: 2.34,
          category: PoiCategory.museum,
          editorialScore: 40,
        ),
        _buildPoi(
          poiId: 'high',
          destinationKey: 'paris',
          name: 'High Score Museum',
          lat: 48.86,
          lng: 2.35,
          category: PoiCategory.museum,
          editorialScore: 95,
        ),
      ];
      final poiRepo = FakePoiRepository(pois: pois);
      final adapter = PoiCandidateAdapter(poiRepo);
      final candidates = await adapter.adaptForDestination('paris');

      final high = candidates.firstWhere((c) => c.name == 'High Score Museum');
      final low = candidates.firstWhere((c) => c.name == 'Low Score Museum');

      expect(high.editorialScore, 95);
      expect(low.editorialScore, 40);
      expect(high.isCurated, isTrue);
      expect(low.isCurated, isTrue);
      // Rating reflète le score éditorial : 4.0 + score/100
      expect(high.rating, greaterThan(low.rating!));
    });

    test('must-see POIs receive extra scoring bonus', () async {
      final trip = _buildTrip(
        destination: 'Paris',
        startDate: DateTime.utc(2026, 6, 1),
        endDate: DateTime.utc(2026, 6, 1),
        interests: ['Culture'],
      );
      final pois = <Poi>[
        _buildPoi(
          poiId: 'normal',
          destinationKey: 'paris',
          name: 'Normal Museum',
          lat: 48.86,
          lng: 2.34,
          category: PoiCategory.museum,
          editorialScore: 80,
        ),
        _buildPoi(
          poiId: 'mustsee',
          destinationKey: 'paris',
          name: 'Must See Monument',
          lat: 48.86,
          lng: 2.35,
          category: PoiCategory.mustSee,
          editorialScore: 80,
        ),
      ];
      final poiRepo = FakePoiRepository(pois: pois);
      final adapter = PoiCandidateAdapter(poiRepo);
      final candidates = await adapter.adaptForDestination('paris');

      final mustSee = candidates.firstWhere((c) => c.name == 'Must See Monument');
      expect(mustSee.types, contains('must_see'));
    });

    test('suggestions are distributed across days without duplicates', () async {
      final trip = _buildTrip(
        destination: 'Paris',
        startDate: DateTime.utc(2026, 6, 1),
        endDate: DateTime.utc(2026, 6, 2),
        interests: ['Culture', 'Spots populaires'],
      );
      final pois = <Poi>[
        _buildPoi(
          poiId: 'p1',
          destinationKey: 'paris',
          name: 'Louvre',
          lat: 48.8606,
          lng: 2.3376,
          category: PoiCategory.museum,
          editorialScore: 100,
        ),
        _buildPoi(
          poiId: 'p2',
          destinationKey: 'paris',
          name: 'Tour Eiffel',
          lat: 48.8584,
          lng: 2.2945,
          category: PoiCategory.monument,
          editorialScore: 95,
        ),
        _buildPoi(
          poiId: 'p3',
          destinationKey: 'paris',
          name: 'Notre-Dame',
          lat: 48.8530,
          lng: 2.3499,
          category: PoiCategory.monument,
          editorialScore: 90,
        ),
        _buildPoi(
          poiId: 'p4',
          destinationKey: 'paris',
          name: 'Musée d\'Orsay',
          lat: 48.8599,
          lng: 2.3266,
          category: PoiCategory.museum,
          editorialScore: 85,
        ),
        _buildPoi(
          poiId: 'p5',
          destinationKey: 'paris',
          name: 'Jardin du Luxembourg',
          lat: 48.8462,
          lng: 2.3372,
          category: PoiCategory.park,
          editorialScore: 70,
        ),
        _buildPoi(
          poiId: 'p6',
          destinationKey: 'paris',
          name: 'Sacré-Cœur',
          lat: 48.8867,
          lng: 2.3431,
          category: PoiCategory.monument,
          editorialScore: 80,
        ),
      ];
      final poiRepo = FakePoiRepository(pois: pois);
      final adapter = PoiCandidateAdapter(poiRepo);
      final candidates = await adapter.adaptForDestination('paris');

      final center = DayCenter(
        latitude: 48.86,
        longitude: 2.34,
        source: 'test',
      );
      final poolMap = <String, ({NearbyCandidate candidate, List<String> matchedInterests})>{
        for (final c in candidates)
          c.placeId: (candidate: c, matchedInterests: ['Culture', 'Spots populaires']),
      };
      final input = PlacesPromptInput(
        center: center,
        days: [DateTime.utc(2026, 6, 1), DateTime.utc(2026, 6, 2)],
        pool: poolMap,
      );

      final suggestions = selectVisitsDeterministic(
        clusters: [input],
        trip: trip,
        travelerProfile: null,
      );

      // Pas de doublons
      final titles = suggestions.map((s) => s.title).toList();
      expect(titles.toSet().length, titles.length);

      // Au moins 2 jours couverts
      final days = suggestions.map((s) => s.dayDate.day).toSet();
      expect(days.length, greaterThanOrEqualTo(2));
    });

    test('category diversity is respected (not all same tag)', () async {
      final trip = _buildTrip(
        destination: 'Paris',
        startDate: DateTime.utc(2026, 6, 1),
        endDate: DateTime.utc(2026, 6, 1),
        interests: ['Culture', 'Nature'],
      );
      final pois = <Poi>[
        _buildPoi(
          poiId: 'm1',
          destinationKey: 'paris',
          name: 'Musée du Louvre',
          lat: 48.86,
          lng: 2.34,
          category: PoiCategory.museum,
          editorialScore: 90,
        ),
        _buildPoi(
          poiId: 'm2',
          destinationKey: 'paris',
          name: 'Musée d\'Orsay',
          lat: 48.861,
          lng: 2.341,
          category: PoiCategory.museum,
          editorialScore: 88,
        ),
        _buildPoi(
          poiId: 'm3',
          destinationKey: 'paris',
          name: 'Centre Pompidou',
          lat: 48.862,
          lng: 2.342,
          category: PoiCategory.museum,
          editorialScore: 87,
        ),
        _buildPoi(
          poiId: 'park',
          destinationKey: 'paris',
          name: 'Jardin du Luxembourg',
          lat: 48.85,
          lng: 2.33,
          category: PoiCategory.park,
          editorialScore: 85,
        ),
      ];
      final poiRepo = FakePoiRepository(pois: pois);
      final adapter = PoiCandidateAdapter(poiRepo);
      final candidates = await adapter.adaptForDestination('paris');

      final center = DayCenter(
        latitude: 48.86,
        longitude: 2.34,
        source: 'test',
      );
      final poolMap = <String, ({NearbyCandidate candidate, List<String> matchedInterests})>{
        for (final c in candidates)
          c.placeId: (candidate: c, matchedInterests: ['Culture', 'Nature']),
      };
      final input = PlacesPromptInput(
        center: center,
        days: [DateTime.utc(2026, 6, 1)],
        pool: poolMap,
      );

      final suggestions = selectVisitsDeterministic(
        clusters: [input],
        trip: trip,
        travelerProfile: null,
      );

      // Même avec 3 musées très bien notés, le parc doit apparaître
      // grâce à la pénalité de diversité par tag
      final tags = suggestions.map((s) => s.tag).toList();
      expect(tags, contains('Nature'));
    });
  });
}
