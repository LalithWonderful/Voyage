// ALTERNATIVES-0.1 — Offline tests for PoiAlternativesProvider.
//
// Validates that "Voir des alternatives" is POI-first:
// - POI-covered destination returns POI alternatives without Gemini
// - current activity is excluded
// - already planned activities are excluded
// - same-category POIs rank higher
// - non-covered destination returns empty (Gemini fallback path)

import 'package:flutter_test/flutter_test.dart';
import 'package:voyage/features/planning/models/activity_suggestion_model.dart';
import 'package:voyage/features/planning/models/trip_activity_model.dart';
import 'package:voyage/features/planning/services/poi_alternatives_provider.dart';
import 'package:voyage/features/poi/data/fake_poi_repository.dart';
import 'package:voyage/features/poi/domain/poi.dart';
import 'package:voyage/features/trips/models/trip_model.dart';

void main() {
  group('PoiAlternativesProvider', () {
    late FakePoiRepository repo;

    setUp(() {
      repo = FakePoiRepository(pois: [
        _poi(
          poiId: 'p1',
          name: 'Musée du Louvre',
          destinationKey: 'paris',
          category: PoiCategory.museum,
          editorialScore: 95,
          touristicImportance: 5,
          lat: 48.86,
          lng: 2.34,
        ),
        _poi(
          poiId: 'p2',
          name: 'Tour Eiffel',
          destinationKey: 'paris',
          category: PoiCategory.monument,
          editorialScore: 90,
          touristicImportance: 5,
          lat: 48.86,
          lng: 2.29,
        ),
        _poi(
          poiId: 'p3',
          name: 'Jardin du Luxembourg',
          destinationKey: 'paris',
          category: PoiCategory.park,
          editorialScore: 70,
          touristicImportance: 3,
          lat: 48.85,
          lng: 2.34,
        ),
        _poi(
          poiId: 'p4',
          name: 'Musée d\'Orsay',
          destinationKey: 'paris',
          category: PoiCategory.museum,
          editorialScore: 80,
          touristicImportance: 4,
          lat: 48.86,
          lng: 2.33,
        ),
        _poi(
          poiId: 'p5',
          name: 'Colosseum',
          destinationKey: 'rome',
          category: PoiCategory.monument,
          editorialScore: 92,
          touristicImportance: 5,
          lat: 41.89,
          lng: 12.49,
        ),
      ]);
    });

    test('returns POI alternatives for covered destination', () async {
      final provider = PoiAlternativesProvider(repo);
      final current = _activity(title: 'Musée du Louvre');
      final trip = _trip(destination: 'Paris');
      final all = [current];

      final alts = await provider.suggestAlternatives(
        current: current,
        trip: trip,
        allActivities: all,
      );

      expect(alts, isNotEmpty);
      expect(alts.length, lessThanOrEqualTo(5));
      // Current activity excluded
      expect(alts.map((a) => a.title), isNot(contains('Musée du Louvre')));
    });

    test('excludes current activity by title', () async {
      final provider = PoiAlternativesProvider(repo);
      final current = _activity(title: 'Tour Eiffel');
      final trip = _trip(destination: 'Paris');
      final all = [current];

      final alts = await provider.suggestAlternatives(
        current: current,
        trip: trip,
        allActivities: all,
      );

      expect(alts.map((a) => a.title), isNot(contains('Tour Eiffel')));
    });

    test('excludes already planned activities', () async {
      final provider = PoiAlternativesProvider(repo);
      final current = _activity(title: 'Musée du Louvre');
      final planned = _activity(title: 'Jardin du Luxembourg');
      final trip = _trip(destination: 'Paris');
      final all = [current, planned];

      final alts = await provider.suggestAlternatives(
        current: current,
        trip: trip,
        allActivities: all,
      );

      expect(alts.map((a) => a.title), isNot(contains('Jardin du Luxembourg')));
    });

    test('same-category POIs rank higher', () async {
      final provider = PoiAlternativesProvider(repo);
      // Current is a museum → other museums should rank higher than parks
      final current = _activity(title: 'Musée du Louvre', tag: 'Culture');
      final trip = _trip(destination: 'Paris');
      final all = [current];

      final alts = await provider.suggestAlternatives(
        current: current,
        trip: trip,
        allActivities: all,
      );

      // Musée d'Orsay (museum, score 80) should be before Jardin du Luxembourg (park, score 70)
      final titles = alts.map((a) => a.title).toList();
      final orsayIndex = titles.indexOf('Musée d\'Orsay');
      final luxembourgIndex = titles.indexOf('Jardin du Luxembourg');
      expect(orsayIndex, isNot(-1));
      expect(luxembourgIndex, isNot(-1));
      expect(orsayIndex, lessThan(luxembourgIndex));
    });

    test('non-covered destination returns empty list', () async {
      final provider = PoiAlternativesProvider(repo);
      final current = _activity(title: 'Senso-ji');
      final trip = _trip(destination: 'Tokyo');
      final all = [current];

      final alts = await provider.suggestAlternatives(
        current: current,
        trip: trip,
        allActivities: all,
      );

      expect(alts, isEmpty);
    });

    test('destination isolation — Paris query does not return Rome POIs', () async {
      final provider = PoiAlternativesProvider(repo);
      final current = _activity(title: 'Musée du Louvre');
      final trip = _trip(destination: 'Paris');
      final all = [current];

      final alts = await provider.suggestAlternatives(
        current: current,
        trip: trip,
        allActivities: all,
      );

      expect(alts.map((a) => a.title), isNot(contains('Colosseum')));
    });

    test('maps POI fields to ActivitySuggestion correctly', () async {
      final provider = PoiAlternativesProvider(repo);
      final current = _activity(title: 'Musée du Louvre');
      final trip = _trip(destination: 'Paris');
      final all = [current];

      final alts = await provider.suggestAlternatives(
        current: current,
        trip: trip,
        allActivities: all,
      );

      final first = alts.first;
      expect(first.dayDate, current.dayDate);
      expect(first.startTime, current.startTime);
      expect(first.tag, isNotNull);
      expect(first.latitude, isNotNull);
      expect(first.longitude, isNotNull);
    });
  });
}

// ─── Helpers ──────────────────────────────────────────────────────────

Poi _poi({
  required String poiId,
  required String name,
  required String destinationKey,
  required PoiCategory category,
  int? editorialScore,
  int? touristicImportance,
  double? lat,
  double? lng,
}) {
  return Poi(
    poiId: poiId,
    destinationKey: destinationKey,
    name: name,
    normalizedName: name.toLowerCase(),
    category: category,
    editorialScore: editorialScore,
    touristicImportance: touristicImportance,
    lat: lat,
    lng: lng,
    sourcePrimaryId: 'source-1',
    createdAt: DateTime(2026, 1, 1),
    updatedAt: DateTime(2026, 1, 1),
  );
}

TripActivity _activity({
  required String title,
  String tag = 'Culture',
}) {
  return TripActivity(
    id: 'act-1',
    tripId: 'trip-1',
    dayDate: DateTime(2026, 6, 1),
    startTime: '10:00',
    title: title,
    tag: tag,
  );
}

Trip _trip({required String destination}) {
  return Trip(
    id: 'trip-1',
    userId: 'user-1',
    title: 'Test Trip',
    destination: destination,
    startDate: DateTime(2026, 6, 1),
    endDate: DateTime(2026, 6, 3),
    createdAt: DateTime(2026, 1, 1),
  );
}
