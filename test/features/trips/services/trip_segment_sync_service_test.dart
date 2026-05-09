/// Tests unitaires `TripTimelineDiff` (côté service `trip_segment_sync`).
///
/// Couverture des getters V2 introduits 2026-05-09 :
/// - `effectiveTripStartDate` (= timeline.first.startDate ou null)
/// - `tripStartDateNeedsUpdate` (compare au current trip.startDate)
/// - `isEmpty` (factorise startDate need en plus des segments)
///
/// V4 (2026-05-10) : régression du bug critique « Mettre à jour mon
/// voyage corrompt l'itinéraire » via `computeDiffForTesting`.
///
/// Hors scope (touche Supabase) : `findTimelineDiff` / `applyTimelineDiff`.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:voyage/features/trips/models/trip_model.dart';
import 'package:voyage/features/trips/services/flight_timeline_builder.dart';
import 'package:voyage/features/trips/services/trip_segment_sync_service.dart';

DateTime _d(int y, int m, int d) => DateTime(y, m, d);

FlightStayCandidate _stay({
  required String city,
  required DateTime startDate,
  required DateTime endDate,
}) =>
    FlightStayCandidate(
      city: city,
      country: null,
      countryCode: null,
      latitude: null,
      longitude: null,
      startDate: startDate,
      endDate: endDate,
      sourceDocName: 'doc',
    );

TripTimelineDiff _diff({
  required DateTime currentTripStartDate,
  required List<FlightStayCandidate> timeline,
  List<TripSegment> added = const [],
  List<UpdatedSegment> updated = const [],
  List<TripSegment> removed = const [],
}) =>
    TripTimelineDiff(
      added: added,
      updated: updated,
      removed: removed,
      preservedManual: const [],
      warnings: const [],
      timeline: timeline,
      mergedSegments: const [],
      tripDestination: 'Bangkok',
      tripDurationDays: 47,
      currentTripStartDate: currentTripStartDate,
    );

void main() {
  group('TripTimelineDiff — effectiveTripStartDate', () {
    test('timeline non-vide → première arrivée', () {
      final diff = _diff(
        currentTripStartDate: _d(2026, 6, 21),
        timeline: [
          _stay(
            city: 'Bangkok',
            startDate: _d(2026, 6, 22),
            endDate: _d(2026, 7, 2),
          ),
          _stay(
            city: 'Phú Quốc',
            startDate: _d(2026, 7, 2),
            endDate: _d(2026, 7, 7),
          ),
        ],
      );
      expect(diff.effectiveTripStartDate, _d(2026, 6, 22));
    });

    test('timeline vide → null', () {
      final diff = _diff(
        currentTripStartDate: _d(2026, 6, 21),
        timeline: const [],
      );
      expect(diff.effectiveTripStartDate, isNull);
    });
  });

  group('TripTimelineDiff — tripStartDateNeedsUpdate', () {
    test('arrivée ≠ trip.startDate → true (cas bug rapporté Lalith '
        '2026-05-09)', () {
      // trip.startDate = 21/06 (= jour départ Lux), arrivée Bangkok
      // = 22/06 (vol overnight). Le voyage doit être réaligné.
      final diff = _diff(
        currentTripStartDate: _d(2026, 6, 21),
        timeline: [
          _stay(
            city: 'Bangkok',
            startDate: _d(2026, 6, 22),
            endDate: _d(2026, 7, 2),
          ),
        ],
      );
      expect(diff.tripStartDateNeedsUpdate, isTrue);
    });

    test('arrivée == trip.startDate → false', () {
      final diff = _diff(
        currentTripStartDate: _d(2026, 6, 22),
        timeline: [
          _stay(
            city: 'Bangkok',
            startDate: _d(2026, 6, 22),
            endDate: _d(2026, 7, 2),
          ),
        ],
      );
      expect(diff.tripStartDateNeedsUpdate, isFalse);
    });

    test('timeline vide → false (rien à aligner)', () {
      final diff = _diff(
        currentTripStartDate: _d(2026, 6, 21),
        timeline: const [],
      );
      expect(diff.tripStartDateNeedsUpdate, isFalse);
    });
  });

  group('TripTimelineDiff — isEmpty', () {
    test('rien à appliquer ET start_date OK → true', () {
      final diff = _diff(
        currentTripStartDate: _d(2026, 6, 22),
        timeline: [
          _stay(
            city: 'Bangkok',
            startDate: _d(2026, 6, 22),
            endDate: _d(2026, 7, 2),
          ),
        ],
      );
      expect(diff.isEmpty, isTrue);
      expect(diff.hasChanges, isFalse);
    });

    test('rien dans segments mais start_date doit bouger → false', () {
      // Cas typique du fix : segments déjà bons (10 jours Bangkok), mais
      // trip.startDate=21/06 alors qu'arrivée=22/06. Le diff doit
      // déclencher l'apply pour réaligner start_date.
      final diff = _diff(
        currentTripStartDate: _d(2026, 6, 21),
        timeline: [
          _stay(
            city: 'Bangkok',
            startDate: _d(2026, 6, 22),
            endDate: _d(2026, 7, 2),
          ),
        ],
      );
      expect(diff.isEmpty, isFalse);
      expect(diff.hasChanges, isTrue);
    });

    test('segments à ajouter → non-empty (comportement legacy)', () {
      final diff = _diff(
        currentTripStartDate: _d(2026, 6, 22),
        timeline: [
          _stay(
            city: 'Bangkok',
            startDate: _d(2026, 6, 22),
            endDate: _d(2026, 7, 2),
          ),
        ],
        added: [const TripSegment(city: 'Bangkok', days: 10)],
      );
      expect(diff.isEmpty, isFalse);
    });
  });

  group('TripSegmentSyncService.debugComputeDiff — V4 régression "Mettre '
      'à jour mon voyage corrompt l\'itinéraire"', () {
    Trip mkTrip({
      required DateTime start,
      required int durationDays,
      required List<TripSegment> segments,
    }) =>
        Trip(
          id: 't1',
          userId: 'u1',
          title: 'Thaïlande/Vietnam',
          destination: 'Bangkok, Thaïlande',
          startDate: start,
          endDate: start.add(Duration(days: durationDays)),
          itinerarySegments: segments,
          createdAt: _d(2026, 1, 1),
        );

    test('itinéraire messy avec étapes manuelles → squelette doc-derived '
        'seul, manuels surfacés, total ≤ durée du voyage', () {
      // Reproduction du bug rapporté : un voyage Thaï/Vietnam de 46 jours
      // avec un itinéraire bricolé. Quand l'user re-ouvre un vol et clique
      // « Mettre à jour mon voyage », l'ancienne logique appendait les
      // étapes manuelles APRÈS le squelette doc-derived → 65 jours placés.
      // V4 : on garde uniquement le squelette propre, les manuels
      // remontent dans `preservedManual` (UI les liste comme à recréer).
      final trip = mkTrip(
        start: _d(2026, 6, 22),
        durationDays: 46,
        segments: [
          // État messy après suppressions / ajouts manuels
          const TripSegment(city: 'Bangkok', days: 11),
          const TripSegment(city: 'Tokyo', days: 5), // manuel JP
          const TripSegment(city: 'Bangkok', days: 5),
          const TripSegment(city: 'Kyoto', days: 3), // manuel JP
          const TripSegment(city: 'Krabi', days: 2,
              sourceAnchorCity: 'Bangkok'), // suggestion
          const TripSegment(city: 'Bangkok', days: 17),
        ],
      );
      // Timeline propre déduite des vols (= ce que l'user voit dans la
      // sheet « Lunao a détecté tes étapes »).
      final timeline = [
        _stay(
          city: 'Bangkok',
          startDate: _d(2026, 6, 22),
          endDate: _d(2026, 7, 3),
        ),
        _stay(
          city: 'Phú Quốc',
          startDate: _d(2026, 7, 3),
          endDate: _d(2026, 7, 8),
        ),
        _stay(
          city: 'Hanoï',
          startDate: _d(2026, 7, 8),
          endDate: _d(2026, 7, 12),
        ),
        _stay(
          city: 'Da Nang',
          startDate: _d(2026, 7, 12),
          endDate: _d(2026, 7, 15),
        ),
        _stay(
          city: 'Bangkok',
          startDate: _d(2026, 7, 15),
          endDate: _d(2026, 8, 6),
        ),
      ];

      final diff = TripSegmentSyncService.debugComputeDiff(
        trip: trip,
        timeline: timeline,
      );

      // mergedSegments = squelette doc-derived UNIQUEMENT (5 segs).
      expect(diff.mergedSegments.length, 5);
      expect(
        diff.mergedSegments.map((s) => s.city).toList(),
        ['Bangkok', 'Phú Quốc', 'Hanoï', 'Da Nang', 'Bangkok'],
      );

      // Total ≤ trip.durationDays — règle dure « never exceed total
      // trip duration ».
      final placedDays =
          diff.mergedSegments.fold<int>(0, (acc, s) => acc + s.days);
      expect(placedDays, lessThanOrEqualTo(trip.durationDays));

      // Les manuels (Tokyo/Kyoto/Krabi) sont surfacés mais NON insérés.
      expect(
        diff.preservedManual.map((m) => m.city).toSet(),
        containsAll(['Tokyo', 'Kyoto', 'Krabi']),
      );

      // Aucun manuel n'a fui dans la liste finale.
      final mergedCities =
          diff.mergedSegments.map((s) => s.city.toLowerCase()).toSet();
      expect(mergedCities.contains('tokyo'), isFalse);
      expect(mergedCities.contains('kyoto'), isFalse);
      expect(mergedCities.contains('krabi'), isFalse);

      // Warning explicite invitant l'user à recréer via Affiner.
      expect(
        diff.warnings.any((w) => w.contains('Affiner les étapes')),
        isTrue,
      );
    });

    test('aucun manuel détecté → mergedSegments = squelette, pas de '
        'warning manuel', () {
      final trip = mkTrip(
        start: _d(2026, 6, 22),
        durationDays: 11,
        segments: const [TripSegment(city: 'Bangkok', days: 11)],
      );
      final timeline = [
        _stay(
          city: 'Bangkok',
          startDate: _d(2026, 6, 22),
          endDate: _d(2026, 7, 3),
        ),
      ];
      final diff = TripSegmentSyncService.debugComputeDiff(
        trip: trip,
        timeline: timeline,
      );
      expect(diff.mergedSegments.length, 1);
      expect(diff.preservedManual, isEmpty);
      expect(
        diff.warnings.any((w) => w.contains('manuelle')),
        isFalse,
      );
    });

    test('squelette dépassant durée du voyage → warning explicite', () {
      // Cas anormal mais possible : les vols décrivent un voyage plus
      // long que `trip.endDate` (user a mal saisi les dates du voyage).
      final trip = mkTrip(
        start: _d(2026, 6, 22),
        durationDays: 10,
        segments: const [],
      );
      final timeline = [
        _stay(
          city: 'Bangkok',
          startDate: _d(2026, 6, 22),
          endDate: _d(2026, 7, 15),
        ),
      ];
      final diff = TripSegmentSyncService.debugComputeDiff(
        trip: trip,
        timeline: timeline,
      );
      expect(
        diff.warnings.any((w) => w.contains('dépasse la durée')),
        isTrue,
      );
    });

    test('manuel ré-applique de façon idempotente : 2e exécution sur '
        'un voyage déjà clean ne ré-introduit pas les manuels', () {
      // Scénario : user a déjà appliqué le diff (squelette clean), puis
      // ré-ouvre le doc et re-clique. Le mergedSegments doit rester clean.
      final trip = mkTrip(
        start: _d(2026, 6, 22),
        durationDays: 46,
        segments: const [
          TripSegment(city: 'Bangkok', days: 11),
          TripSegment(city: 'Phú Quốc', days: 5),
          TripSegment(city: 'Hanoï', days: 4),
          TripSegment(city: 'Da Nang', days: 3),
          TripSegment(city: 'Bangkok', days: 22),
        ],
      );
      final timeline = [
        _stay(
          city: 'Bangkok',
          startDate: _d(2026, 6, 22),
          endDate: _d(2026, 7, 3),
        ),
        _stay(
          city: 'Phú Quốc',
          startDate: _d(2026, 7, 3),
          endDate: _d(2026, 7, 8),
        ),
        _stay(
          city: 'Hanoï',
          startDate: _d(2026, 7, 8),
          endDate: _d(2026, 7, 12),
        ),
        _stay(
          city: 'Da Nang',
          startDate: _d(2026, 7, 12),
          endDate: _d(2026, 7, 15),
        ),
        _stay(
          city: 'Bangkok',
          startDate: _d(2026, 7, 15),
          endDate: _d(2026, 8, 6),
        ),
      ];
      final diff = TripSegmentSyncService.debugComputeDiff(
        trip: trip,
        timeline: timeline,
      );
      expect(diff.preservedManual, isEmpty);
      expect(diff.mergedSegments.length, 5);
      final placedDays =
          diff.mergedSegments.fold<int>(0, (acc, s) => acc + s.days);
      expect(placedDays, 45); // = 11+5+4+3+22, ≤ 46 OK.
    });
  });
}
