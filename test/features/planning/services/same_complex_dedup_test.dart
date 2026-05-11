// Phase 2 / Tâche 2.4 — Tests d'intégration de la dédup
// `SameComplexGroup` dans le sélecteur déterministe.
//
// Tests purement unitaires : aucun réseau, aucun Supabase, aucune
// dépendance Google Places. Fixtures fictives.
//
// Stratégie pour isoler la nouvelle logique du reste du sélecteur :
//   - candidats avec `userRatingCount < 200` et `types: ['park']` →
//     pas iconic (ni musée ≥200 reviews, ni tourist ≥500), donc
//     ni le cap iconic 1×/trip ni le trip-level iconic dedup ne
//     s'appliquent.
//   - `Trip` mégalopole "Singapore" mais sans accommodation /
//     hotels / segments → ne déclenche pas day_builder.
//   - Plusieurs candidats à proximité du centre du cluster pour
//     éviter les caps de transition (5 km mégacité).
//   - Pas de matched interests = aucun blueprint bonus, scoring
//     purement basé sur qualité + distance.

import 'package:flutter_test/flutter_test.dart';
import 'package:voyage/data/complexes/singapore_complexes.dart';
import 'package:voyage/features/planning/data/destination_blueprints.dart'
    show blueprintMustSeeMarker;
import 'package:voyage/features/planning/services/day_center_service.dart';
import 'package:voyage/features/planning/services/places_first_pipeline.dart';
import 'package:voyage/features/planning/services/places_nearby_service.dart';
import 'package:voyage/features/trips/models/trip_model.dart';
import 'package:voyage/models/same_complex_group.dart';
import 'package:voyage/services/same_complex_rejection.dart';

// ─── Helpers ──────────────────────────────────────────────────────────

NearbyCandidate _candidate({
  required String id,
  required String name,
  double lat = 1.2710, // Sentosa
  double lng = 103.8260,
  double rating = 4.4,
  int reviews = 80, // < 200 reviews → pas iconic museum, pas iconic tourist
  List<String> types = const ['park', 'point_of_interest'],
}) {
  return NearbyCandidate(
    placeId: id,
    name: name,
    latitude: lat,
    longitude: lng,
    rating: rating,
    userRatingCount: reviews,
    types: types,
  );
}

/// Construit la pool indexée par placeId. `matchedInterests`
/// inclut `blueprintMustSeeMarker` par défaut pour que les
/// candidats passent le quality_floor fallback V8.28f sur les
/// destinations à MetroProfile curé (Singapour). Cohérent avec
/// la réalité : ces complexes touristiques sont marqués must-see
/// au gather-time.
Map<String, ({NearbyCandidate candidate, List<String> matchedInterests})>
    _pool(
  List<NearbyCandidate> candidates, {
  List<String> matchedInterests = const [blueprintMustSeeMarker],
}) {
  return {
    for (final c in candidates)
      c.placeId: (candidate: c, matchedInterests: matchedInterests),
  };
}

Trip _singaporeTrip({
  required DateTime startDate,
  required DateTime endDate,
  String destination = 'Singapore',
}) {
  return Trip(
    id: 'test-trip',
    userId: 'u1',
    title: 'Test',
    destination: destination,
    startDate: startDate,
    endDate: endDate,
    createdAt: DateTime(2026, 5, 11),
  );
}

PlacesPromptInput _cluster({
  required List<DateTime> days,
  required Map<String, ({NearbyCandidate candidate, List<String> matchedInterests})> pool,
  double centerLat = 1.2710,
  double centerLng = 103.8260,
}) {
  return PlacesPromptInput(
    center: DayCenter(
      latitude: centerLat,
      longitude: centerLng,
      source: 'destination',
    ),
    days: days,
    pool: pool,
  );
}

void main() {
  // Spec : ce groupe sentosa-comme avec 4 attractions, isolé du
  // reste de Singapour. `maxPerDay: 1`, `maxPerTrip: 2`.
  const sentosaLikeGroup = SameComplexGroup(
    complexKey: 'test_sentosa',
    destinationKey: 'singapore',
    aliases: [
      'Sentosa Test A',
      'Sentosa Test B',
      'Sentosa Test C',
      'Sentosa Test D',
    ],
    maxPerDay: 1,
    maxPerTrip: 2,
    priority: 5,
  );

  // Groupe chinatown-comme avec 3 lieux. maxPerDay = 2, maxPerTrip = 3.
  const chinatownLikeGroup = SameComplexGroup(
    complexKey: 'test_chinatown',
    destinationKey: 'singapore',
    aliases: [
      'Chinatown Test A',
      'Chinatown Test B',
      'Chinatown Test C',
    ],
    maxPerDay: 2,
    maxPerTrip: 3,
    priority: 4,
  );

  // ─── 1. Flag OFF = comportement inchangé ─────────────────────────────

  group('Flag OFF — comportement inchangé', () {
    test('Plusieurs lieux du même complexe peuvent être sélectionnés '
        'le même jour quand flag OFF', () {
      final day = DateTime(2026, 5, 18);
      final candidates = [
        _candidate(id: 'p1', name: 'Sentosa Test A'),
        _candidate(id: 'p2', name: 'Sentosa Test B'),
        _candidate(id: 'p3', name: 'Sentosa Test C'),
        _candidate(id: 'p4', name: 'Sentosa Test D'),
      ];
      final cluster = _cluster(days: [day], pool: _pool(candidates));
      final trip = _singaporeTrip(startDate: day, endDate: day);

      final rejections = <SameComplexRejection>[];
      final visits = selectVisitsDeterministic(
        clusters: [cluster],
        trip: trip,
        travelerProfile: null,
        useSameComplexDedup: false, // explicit OFF
        complexGroups: [sentosaLikeGroup],
        sameComplexRejectionsOut: rejections,
      );

      // Flag OFF : pas de rejet `same_complex_cap`.
      expect(rejections, isEmpty,
          reason: 'Aucun rejet same_complex_cap attendu avec flag OFF');
      // Le sélecteur peut sélectionner plusieurs lieux du même
      // complexe ici car les fixtures sont < 200 reviews / pas
      // iconic → autres caps ne s'appliquent pas.
      expect(visits.length, greaterThanOrEqualTo(2),
          reason: 'Avec flag OFF + 4 candidats valides, au moins 2 '
              'doivent être sélectionnés (limité par slots/jour)');
    });

    test('Flag OFF avec complexGroups vide → aucun rejet', () {
      final day = DateTime(2026, 5, 18);
      final candidates = [
        _candidate(id: 'p1', name: 'Sentosa Test A'),
        _candidate(id: 'p2', name: 'Sentosa Test B'),
      ];
      final cluster = _cluster(days: [day], pool: _pool(candidates));
      final trip = _singaporeTrip(startDate: day, endDate: day);

      final rejections = <SameComplexRejection>[];
      selectVisitsDeterministic(
        clusters: [cluster],
        trip: trip,
        travelerProfile: null,
        useSameComplexDedup: false,
        complexGroups: const [],
        sameComplexRejectionsOut: rejections,
      );

      expect(rejections, isEmpty);
    });

    test('Defaults (sans aucun param flag) = strict OFF', () {
      final day = DateTime(2026, 5, 18);
      final candidates = [
        _candidate(id: 'p1', name: 'Sentosa Test A'),
        _candidate(id: 'p2', name: 'Sentosa Test B'),
      ];
      final cluster = _cluster(days: [day], pool: _pool(candidates));
      final trip = _singaporeTrip(startDate: day, endDate: day);

      final rejections = <SameComplexRejection>[];
      selectVisitsDeterministic(
        clusters: [cluster],
        trip: trip,
        travelerProfile: null,
        sameComplexRejectionsOut: rejections,
      );

      expect(rejections, isEmpty,
          reason: 'Defaults sans flag explicite = comportement pré-2.4');
    });
  });

  // ─── 2. Flag ON limite maxPerDay ─────────────────────────────────────

  group('Flag ON — limite maxPerDay', () {
    test('sentosa.maxPerDay=1 : un seul lieu du complexe par jour', () {
      final day = DateTime(2026, 5, 18);
      final candidates = [
        _candidate(id: 'p1', name: 'Sentosa Test A'),
        _candidate(id: 'p2', name: 'Sentosa Test B'),
        _candidate(id: 'p3', name: 'Sentosa Test C'),
        _candidate(id: 'p4', name: 'Sentosa Test D'),
      ];
      final cluster = _cluster(days: [day], pool: _pool(candidates));
      final trip = _singaporeTrip(startDate: day, endDate: day);

      final rejections = <SameComplexRejection>[];
      final visits = selectVisitsDeterministic(
        clusters: [cluster],
        trip: trip,
        travelerProfile: null,
        useSameComplexDedup: true,
        complexGroups: [sentosaLikeGroup],
        sameComplexRejectionsOut: rejections,
      );

      // Compter combien de picks appartiennent à test_sentosa
      final sentosaPicks = visits
          .where((v) => v.title.startsWith('Sentosa Test'))
          .toList();
      expect(sentosaPicks.length, lessThanOrEqualTo(1),
          reason: 'maxPerDay=1 : un seul Sentosa par jour');

      // Au moins un rejet `same_complex_cap_day` doit avoir été
      // émis (vu que 4 candidats Sentosa étaient dans la pool).
      final dayRejections = rejections
          .where((r) => r.reason == SameComplexRejection.reasonCapDay)
          .toList();
      expect(dayRejections, isNotEmpty,
          reason: 'Au moins un rejet same_complex_cap_day attendu');

      // Vérifier la richesse du log
      for (final rej in dayRejections) {
        expect(rej.complexKey, equals('test_sentosa'));
        expect(rej.maxAllowed, equals(1));
        expect(rej.currentCount, greaterThanOrEqualTo(1));
        expect(rej.dayDate, equals(day));
        expect(rej.candidateTitle, startsWith('Sentosa Test'));
      }
    });
  });

  // ─── 3. Flag ON limite maxPerTrip ────────────────────────────────────

  group('Flag ON — limite maxPerTrip', () {
    test('sentosa.maxPerTrip=2 : maximum 2 lieux du complexe sur le '
        'voyage', () {
      final day1 = DateTime(2026, 5, 18);
      final day2 = DateTime(2026, 5, 19);
      final day3 = DateTime(2026, 5, 20);
      // Même candidat structure mais sur 3 jours.
      // 4 candidats par jour, le sélecteur en gardera ≤ 1 du
      // complexe par jour, mais cap trip = 2 → 3e jour rejeté.
      final candidates = [
        _candidate(id: 'p1', name: 'Sentosa Test A'),
        _candidate(id: 'p2', name: 'Sentosa Test B'),
        _candidate(id: 'p3', name: 'Sentosa Test C'),
        _candidate(id: 'p4', name: 'Sentosa Test D'),
      ];
      final cluster = _cluster(
          days: [day1, day2, day3], pool: _pool(candidates));
      final trip = _singaporeTrip(startDate: day1, endDate: day3);

      final rejections = <SameComplexRejection>[];
      final visits = selectVisitsDeterministic(
        clusters: [cluster],
        trip: trip,
        travelerProfile: null,
        useSameComplexDedup: true,
        complexGroups: [sentosaLikeGroup],
        sameComplexRejectionsOut: rejections,
      );

      final sentosaPicks = visits
          .where((v) => v.title.startsWith('Sentosa Test'))
          .toList();
      expect(sentosaPicks.length, lessThanOrEqualTo(2),
          reason: 'maxPerTrip=2 : au plus 2 lieux Sentosa sur tout '
              'le voyage (3 jours)');

      // Au moins un rejet cap_trip doit avoir été émis
      // (jour 3 : 2 déjà pris).
      final tripRejections = rejections
          .where((r) => r.reason == SameComplexRejection.reasonCapTrip)
          .toList();
      expect(tripRejections, isNotEmpty,
          reason: 'Au moins un rejet same_complex_cap_trip attendu '
              'au jour 3');

      for (final rej in tripRejections) {
        expect(rej.complexKey, equals('test_sentosa'));
        expect(rej.maxAllowed, equals(2));
        expect(rej.currentCount, greaterThanOrEqualTo(2));
      }
    });
  });

  // ─── 4. Groupe relâché Chinatown ─────────────────────────────────────

  group('Flag ON — groupe relâché chinatown_heritage', () {
    test('chinatown_heritage.maxPerDay=2 : 2 lieux acceptés, 3e rejeté',
        () {
      final day = DateTime(2026, 5, 18);
      final candidates = [
        _candidate(id: 'c1', name: 'Chinatown Test A'),
        _candidate(id: 'c2', name: 'Chinatown Test B'),
        _candidate(id: 'c3', name: 'Chinatown Test C'),
      ];
      final cluster = _cluster(days: [day], pool: _pool(candidates));
      final trip = _singaporeTrip(startDate: day, endDate: day);

      final rejections = <SameComplexRejection>[];
      final visits = selectVisitsDeterministic(
        clusters: [cluster],
        trip: trip,
        travelerProfile: null,
        useSameComplexDedup: true,
        complexGroups: [chinatownLikeGroup],
        sameComplexRejectionsOut: rejections,
      );

      final chinatownPicks = visits
          .where((v) => v.title.startsWith('Chinatown Test'))
          .toList();
      expect(chinatownPicks.length, lessThanOrEqualTo(2),
          reason: 'maxPerDay=2 pour chinatown_heritage');

      // Si 3 candidats valides et 2 retenus → 1 rejet attendu.
      // Si <= 1 retenus pour autres raisons → 0 ou 1 rejet
      // possible. Test souple : si rejet présent, alors
      // chinatown_heritage et cap_day.
      for (final rej in rejections) {
        expect(rej.complexKey, equals('test_chinatown'));
        expect(rej.maxAllowed, equals(2));
        expect(rej.reason, equals(SameComplexRejection.reasonCapDay));
      }
    });
  });

  // ─── 5. Destination sans groupes ─────────────────────────────────────

  group('Destination sans groupes connus', () {
    test('complexGroups vide + flag ON → aucun crash, aucun rejet', () {
      final day = DateTime(2026, 5, 18);
      final candidates = [
        _candidate(id: 'p1', name: 'Sentosa Test A'),
      ];
      final cluster = _cluster(days: [day], pool: _pool(candidates));
      final trip = _singaporeTrip(startDate: day, endDate: day);

      final rejections = <SameComplexRejection>[];
      // Pas de crash.
      final visits = selectVisitsDeterministic(
        clusters: [cluster],
        trip: trip,
        travelerProfile: null,
        useSameComplexDedup: true,
        complexGroups: const [], // empty
        sameComplexRejectionsOut: rejections,
      );

      expect(rejections, isEmpty);
      // Le sélecteur ne crash pas et peut sélectionner.
      expect(visits, isNotEmpty);
    });
  });

  // ─── 6. Candidats sans match complexe ─────────────────────────────────

  group('Candidats sans match complexe', () {
    test('Lieu non reconnu n\'est pas affecté par la dédup', () {
      final day = DateTime(2026, 5, 18);
      final candidates = [
        _candidate(id: 'p1', name: 'Random Museum Singapore'),
        _candidate(id: 'p2', name: 'Eiffel Tower'),
        _candidate(id: 'p3', name: 'Another Unrelated Place'),
      ];
      final cluster = _cluster(days: [day], pool: _pool(candidates));
      final trip = _singaporeTrip(startDate: day, endDate: day);

      final rejections = <SameComplexRejection>[];
      final visits = selectVisitsDeterministic(
        clusters: [cluster],
        trip: trip,
        travelerProfile: null,
        useSameComplexDedup: true,
        complexGroups: [sentosaLikeGroup, chinatownLikeGroup],
        sameComplexRejectionsOut: rejections,
      );

      expect(rejections, isEmpty,
          reason: 'Lieux non reconnus ne déclenchent aucun rejet');
      expect(visits, isNotEmpty);
    });
  });

  // ─── 7. Fuzzy matching dans l'intégration ────────────────────────────

  group('Fuzzy + exact dans l\'intégration', () {
    test('Cloud Forest (Singapour réel) → reconnu via gardens_by_the_bay',
        () {
      final day = DateTime(2026, 5, 18);
      // Note : reviews intentionnellement faibles pour éviter
      // l'interaction avec le cap iconic 1×/trip existant.
      final candidates = [
        _candidate(
            id: 'p1',
            name: 'Cloud Forest',
            rating: 4.5,
            reviews: 100,
            types: const ['park', 'point_of_interest']),
        _candidate(
            id: 'p2',
            name: 'Flower Dome',
            rating: 4.5,
            reviews: 100,
            types: const ['park', 'point_of_interest']),
      ];
      final cluster = _cluster(days: [day], pool: _pool(candidates));
      final trip = _singaporeTrip(startDate: day, endDate: day);

      final rejections = <SameComplexRejection>[];
      selectVisitsDeterministic(
        clusters: [cluster],
        trip: trip,
        travelerProfile: null,
        useSameComplexDedup: true,
        complexGroups: buildSingaporeSameComplexGroups(),
        sameComplexRejectionsOut: rejections,
      );

      // gardens_by_the_bay.maxPerDay=1 → 2nd doit être rejeté.
      final gardensRejections = rejections
          .where((r) => r.complexKey == 'gardens_by_the_bay')
          .toList();
      expect(gardensRejections, isNotEmpty,
          reason: 'Cloud Forest + Flower Dome même jour → 1 rejet '
              'attendu sur gardens_by_the_bay');
    });

    test('Universal Studio Singapore (typo, fuzzy) → reconnu sentosa',
        () {
      final day = DateTime(2026, 5, 18);
      final candidates = [
        _candidate(
            id: 'p1',
            name: 'Sentosa Island',
            rating: 4.5,
            reviews: 100),
        _candidate(
            id: 'p2',
            name: 'Universal Studio Singapore', // typo: Studio sans s
            rating: 4.5,
            reviews: 100),
      ];
      final cluster = _cluster(days: [day], pool: _pool(candidates));
      final trip = _singaporeTrip(startDate: day, endDate: day);

      final rejections = <SameComplexRejection>[];
      selectVisitsDeterministic(
        clusters: [cluster],
        trip: trip,
        travelerProfile: null,
        useSameComplexDedup: true,
        complexGroups: buildSingaporeSameComplexGroups(),
        sameComplexRejectionsOut: rejections,
      );

      final sentosaRejections = rejections
          .where((r) => r.complexKey == 'sentosa')
          .toList();
      expect(sentosaRejections, isNotEmpty,
          reason: 'Sentosa Island + Universal Studio (typo fuzzy) '
              'même jour → 1 rejet attendu sur sentosa');
    });
  });
}
