/// Tests unitaires `TripTimelineDiff` (côté service `trip_segment_sync`).
///
/// Couverture des getters V2 introduits 2026-05-09 :
/// - `effectiveTripStartDate` (= timeline.first.startDate ou null)
/// - `tripStartDateNeedsUpdate` (compare au current trip.startDate)
/// - `isEmpty` (factorise startDate need en plus des segments)
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
}
