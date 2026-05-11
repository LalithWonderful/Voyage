// Phase 0 / Tâche 0.2 — Tests unitaires du module métriques qualité.
//
// 3 scénarios fictifs, AUCUNE dépendance réseau / Google Places. Toutes
// les `ActivitySuggestion` sont construites en mémoire avec coords
// déterministes. Reproductible exécution à exécution.

import 'package:flutter_test/flutter_test.dart';
import 'package:voyage/features/planning/models/activity_suggestion_model.dart';
import 'package:voyage/quality/planning_metrics.dart';

// ─── Helpers de construction ────────────────────────────────────────────

ActivitySuggestion _act({
  required String day,
  required String slot,
  required String title,
  required String tag,
  double? lat,
  double? lng,
}) {
  return ActivitySuggestion(
    dayDate: DateTime.parse(day),
    startTime: slot,
    title: title,
    tag: tag,
    latitude: lat,
    longitude: lng,
  );
}

void main() {
  group('PlanningMetrics — 1. Bon planning (proche, varié, sans répétition)',
      () {
    // 3 jours, 9 visites compactes (toutes <2 km entre slots), 5 tags
    // différents, 0 répétition. Singapour Marina Bay area pour
    // coords plausibles.
    final goodPlanning = <ActivitySuggestion>[
      _act(day: '2026-05-18', slot: '09:30', title: 'Marina Bay Sands',
          tag: 'Spots populaires', lat: 1.2834, lng: 103.8607),
      _act(day: '2026-05-18', slot: '11:00', title: 'Gardens by the Bay',
          tag: 'Nature', lat: 1.2816, lng: 103.8636),
      _act(day: '2026-05-18', slot: '14:30', title: 'ArtScience Museum',
          tag: 'Culture', lat: 1.2862, lng: 103.8597),
      // Day 2 — Chinatown
      _act(day: '2026-05-19', slot: '09:30', title: 'Buddha Tooth Relic Temple',
          tag: 'Culture', lat: 1.2814, lng: 103.8443),
      _act(day: '2026-05-19', slot: '11:00', title: 'Sri Mariamman Temple',
          tag: 'Culture', lat: 1.2830, lng: 103.8462),
      _act(day: '2026-05-19', slot: '14:30', title: 'Chinatown Heritage Centre',
          tag: 'Shopping', lat: 1.2826, lng: 103.8438),
      // Day 3 — Botanic
      _act(day: '2026-05-20', slot: '09:30', title: 'Singapore Botanic Gardens',
          tag: 'Nature', lat: 1.3138, lng: 103.8159),
      _act(day: '2026-05-20', slot: '11:00', title: 'National Orchid Garden',
          tag: 'Nature', lat: 1.3122, lng: 103.8160),
      _act(day: '2026-05-20', slot: '14:30', title: 'Dempsey Hill',
          tag: 'Gastronomie', lat: 1.3050, lng: 103.8090),
    ];

    test('overallScore ≥ 80 (planning compact, varié, propre)', () {
      final report = computePlanningMetrics(goodPlanning,
          expectedTripDays: 3);
      expect(report.overallScore, isNotNull);
      expect(report.overallScore!, greaterThanOrEqualTo(80.0),
          reason: 'Bon planning doit avoir score global ≥ 80, '
              'obtenu ${report.overallScore!.toStringAsFixed(1)}');
    });

    test('transitionScore = 100 (toutes les hops < 2 km)', () {
      final report = computePlanningMetrics(goodPlanning);
      expect(report.transitionScore, isNotNull);
      expect(report.transitionScore!, equals(100.0),
          reason: 'Tous les hops < 2 km → score parfait sur transition');
    });

    test('repetitionScore = 100 (0 répétition)', () {
      final report = computePlanningMetrics(goodPlanning);
      expect(report.repetitionScore, equals(100.0));
      expect(report.repeatedTitlesNormalized, isEmpty);
    });

    test('diversityScore > 60 (5 tags pour 9 visites, distribution '
        '3/3/1/1/1 → entropie normalisée ~67%)', () {
      final report = computePlanningMetrics(goodPlanning);
      expect(report.diversityScore, isNotNull);
      expect(report.diversityScore!, greaterThan(60.0));
    });

    test('coverageScore = 100 (3/3 jours remplis)', () {
      final report = computePlanningMetrics(goodPlanning,
          expectedTripDays: 3);
      expect(report.coverageScore, equals(100.0));
    });

    test('Aucun warning par jour', () {
      final report = computePlanningMetrics(goodPlanning,
          expectedTripDays: 3);
      for (final d in report.byDay) {
        expect(d.warnings, isEmpty,
            reason: 'Jour ${d.date} a des warnings : ${d.warnings}');
      }
    });

    test('Per-day distances en mètres correctes', () {
      final report = computePlanningMetrics(goodPlanning);
      final day1 = report.byDay.firstWhere(
          (d) => d.date == DateTime.utc(2026, 5, 18));
      expect(day1.totalSlots, equals(3));
      expect(day1.visitsCount, equals(3));
      expect(day1.mealsCount, equals(0));
      expect(day1.avgInterSlotMeters, isNotNull);
      expect(day1.avgInterSlotMeters!, greaterThan(0));
      expect(day1.avgInterSlotMeters!, lessThan(2000),
          reason: 'Marina Bay area : hops < 2 km');
    });
  });

  group(
      'PlanningMetrics — 2. Planning moyen (transitions longues, '
      'variété moyenne, couverture partielle)',
      () {
    // 4 jours attendus, 3 jours remplis (75% coverage). Variété moyenne
    // (2 tags). Quelques transitions 6-8 km.
    final mediumPlanning = <ActivitySuggestion>[
      // Day 1 — compact (Singapour Marina)
      _act(day: '2026-05-18', slot: '09:30', title: 'Marina Bay Sands',
          tag: 'Spots populaires', lat: 1.2834, lng: 103.8607),
      _act(day: '2026-05-18', slot: '11:00', title: 'Gardens by the Bay',
          tag: 'Spots populaires', lat: 1.2816, lng: 103.8636),
      // Day 2 — 2 hops dont 1 longue (Marina Bay → Sentosa, ~5.5 km)
      _act(day: '2026-05-19', slot: '09:30', title: 'Singapore Flyer',
          tag: 'Spots populaires', lat: 1.2893, lng: 103.8631),
      _act(day: '2026-05-19', slot: '11:00', title: 'Sentosa',
          tag: 'Spots populaires', lat: 1.2494, lng: 103.8303),
      // Day 3 — vide (jour libre involontaire)
      // Day 4 — 1 visite seule (low_activity_count)
      _act(day: '2026-05-21', slot: '14:30', title: 'Orchard Road',
          tag: 'Shopping', lat: 1.3050, lng: 103.8322),
    ];

    test('overallScore intermédiaire (entre 35 et 80)', () {
      final report = computePlanningMetrics(mediumPlanning,
          expectedTripDays: 4);
      expect(report.overallScore, isNotNull);
      expect(report.overallScore!, inInclusiveRange(35.0, 80.0),
          reason: 'Planning moyen : score global '
              '${report.overallScore!.toStringAsFixed(1)}');
    });

    test('coverageScore = 75 (3 jours remplis / 4 attendus)', () {
      final report = computePlanningMetrics(mediumPlanning,
          expectedTripDays: 4);
      expect(report.coverageScore, equals(75.0));
      expect(report.totalDaysWithActivity, equals(3));
      expect(report.totalExpectedDays, equals(4));
    });

    test('Jour avec long hop a warning long_transition', () {
      final report = computePlanningMetrics(mediumPlanning,
          expectedTripDays: 4);
      final day2 = report.byDay.firstWhere(
          (d) => d.date == DateTime.utc(2026, 5, 19));
      expect(day2.warnings, contains('long_transition'),
          reason: 'Marina → Sentosa = ~5.5 km > 5 km seuil');
    });

    test('Jour avec 1 seule activité a low_activity_count', () {
      final report = computePlanningMetrics(mediumPlanning,
          expectedTripDays: 4);
      final day4 = report.byDay.firstWhere(
          (d) => d.date == DateTime.utc(2026, 5, 21));
      expect(day4.warnings, contains('low_activity_count'));
    });

    test('transitionScore < 100 (à cause du hop 5.5 km)', () {
      final report = computePlanningMetrics(mediumPlanning,
          expectedTripDays: 4);
      expect(report.transitionScore, isNotNull);
      expect(report.transitionScore!, lessThan(100.0));
      expect(report.transitionScore!, greaterThan(50.0));
    });

    test('diversityScore < 90 (variété limitée 2 tags principaux)', () {
      final report = computePlanningMetrics(mediumPlanning,
          expectedTripDays: 4);
      expect(report.diversityScore, isNotNull);
      expect(report.diversityScore!, lessThan(90.0));
    });
  });

  group(
      'PlanningMetrics — 3. Mauvais planning (répétitions, transitions '
      'très longues, faible variété, faible couverture)',
      () {
    // 7 jours attendus, 2 jours remplis (29% coverage). 1 seul tag.
    // 1 lieu picked 3× (cross-cluster repeat type Buddha Tooth).
    // Transitions très longues (12+ km).
    final badPlanning = <ActivitySuggestion>[
      // Day 1 — 3 visites, 1 répétée, 1 hop 12 km
      _act(day: '2026-05-18', slot: '09:30', title: 'Marina Bay Sands',
          tag: 'Spots populaires', lat: 1.2834, lng: 103.8607),
      _act(day: '2026-05-18', slot: '11:00', title: 'Botanic Gardens far away',
          tag: 'Spots populaires', lat: 1.3700, lng: 103.7800),
      _act(day: '2026-05-18', slot: '14:30', title: 'Marina Bay Sands',
          tag: 'Spots populaires', lat: 1.2834, lng: 103.8607),
      // Day 2 — 1 répétition supplémentaire
      _act(day: '2026-05-20', slot: '09:30', title: 'Marina Bay Sands',
          tag: 'Spots populaires', lat: 1.2834, lng: 103.8607),
      // Days 19, 21, 22, 23, 24, 25 vides
    ];

    test('overallScore faible (< 50)', () {
      final report = computePlanningMetrics(badPlanning,
          expectedTripDays: 8);
      expect(report.overallScore, isNotNull);
      expect(report.overallScore!, lessThan(50.0),
          reason: 'Mauvais planning : score global '
              '${report.overallScore!.toStringAsFixed(1)}');
    });

    test('repetitionScore très bas (lieu répété 3×)', () {
      final report = computePlanningMetrics(badPlanning,
          expectedTripDays: 8);
      expect(report.repetitionScore, isNotNull);
      expect(report.repetitionScore!, lessThan(60.0),
          reason: '2 répétitions / 4 visites → 50%');
      expect(report.repeatedTitlesNormalized, contains('marina bay sands'));
    });

    test('transitionScore bas (hop 12+ km)', () {
      final report = computePlanningMetrics(badPlanning,
          expectedTripDays: 8);
      expect(report.transitionScore, isNotNull);
      expect(report.transitionScore!, lessThan(50.0));
    });

    test('coverageScore très bas (2 jours sur 8)', () {
      final report = computePlanningMetrics(badPlanning,
          expectedTripDays: 8);
      expect(report.coverageScore, isNotNull);
      expect(report.coverageScore!, equals(25.0),
          reason: '2 jours remplis / 8 attendus = 25%');
    });

    test('diversityScore = 100 ou bas selon distribution tags', () {
      // 1 seul tag → diversité minimale (entropie nulle).
      final report = computePlanningMetrics(badPlanning,
          expectedTripDays: 8);
      expect(report.diversityScore, isNotNull);
      expect(report.diversityScore!, equals(0.0),
          reason: 'Toutes les visites ont le même tag → entropie 0');
    });

    test('repeated_place dans warnings des jours concernés', () {
      final report = computePlanningMetrics(badPlanning,
          expectedTripDays: 8);
      final day1 = report.byDay.firstWhere(
          (d) => d.date == DateTime.utc(2026, 5, 18));
      expect(day1.warnings, contains('repeated_place'));
      expect(day1.warnings, contains('long_transition'));
    });
  });

  group('PlanningMetrics — edge cases', () {
    test('Liste vide → tous les scores null sauf coverage si '
        'expectedTripDays fourni', () {
      final report = computePlanningMetrics(const [], expectedTripDays: 5);
      expect(report.overallScore, isNotNull);
      expect(report.coverageScore, equals(0.0));
      expect(report.transitionScore, isNull);
      expect(report.diversityScore, isNull);
      expect(report.repetitionScore, isNull);
      expect(report.coherenceScore, isNull);
      expect(report.totalSlots, equals(0));
    });

    test('Slot sans coords → missing_coordinates warning, transition '
        'calculée sur les autres hops', () {
      final mixedCoords = <ActivitySuggestion>[
        _act(day: '2026-05-18', slot: '09:30', title: 'A',
            tag: 'Culture', lat: 1.28, lng: 103.86),
        _act(day: '2026-05-18', slot: '11:00', title: 'B (no coords)',
            tag: 'Culture'),
        _act(day: '2026-05-18', slot: '14:30', title: 'C',
            tag: 'Culture', lat: 1.29, lng: 103.86),
      ];
      final report = computePlanningMetrics(mixedCoords);
      final day = report.byDay.single;
      expect(day.warnings, contains('missing_coordinates'));
      expect(day.totalSlots, equals(3));
    });

    test('Slots 12:30 et 19:30 comptés comme repas, pas comme visites',
        () {
      final withMeals = <ActivitySuggestion>[
        _act(day: '2026-05-18', slot: '09:30', title: 'Visite',
            tag: 'Culture', lat: 1.28, lng: 103.86),
        _act(day: '2026-05-18', slot: '12:30', title: 'Déjeuner',
            tag: 'Gastronomie', lat: 1.28, lng: 103.86),
        _act(day: '2026-05-18', slot: '19:30', title: 'Dîner',
            tag: 'Gastronomie', lat: 1.28, lng: 103.86),
      ];
      final report = computePlanningMetrics(withMeals);
      expect(report.totalVisits, equals(1));
      expect(report.totalMeals, equals(2));
      final day = report.byDay.single;
      expect(day.visitsCount, equals(1));
      expect(day.mealsCount, equals(2));
    });

    test('expectedTripDays null → déduit du min/max dayDate', () {
      final report = computePlanningMetrics([
        _act(day: '2026-05-18', slot: '09:30', title: 'A',
            tag: 'Culture', lat: 1.28, lng: 103.86),
        _act(day: '2026-05-22', slot: '09:30', title: 'B',
            tag: 'Culture', lat: 1.29, lng: 103.87),
      ]);
      // Span 18 → 22 mai = 5 jours, 2 jours remplis → coverage = 40%
      expect(report.totalExpectedDays, equals(5));
      expect(report.coverageScore, equals(40.0));
    });

    test('repetitionScore : repas répétés ne pénalisent PAS '
        '(seuls les visites comptent)', () {
      final repeatedMeals = <ActivitySuggestion>[
        _act(day: '2026-05-18', slot: '09:30', title: 'Visite unique',
            tag: 'Culture', lat: 1.28, lng: 103.86),
        _act(day: '2026-05-18', slot: '12:30', title: 'Même resto',
            tag: 'Gastronomie', lat: 1.28, lng: 103.86),
        _act(day: '2026-05-19', slot: '12:30', title: 'Même resto',
            tag: 'Gastronomie', lat: 1.28, lng: 103.86),
      ];
      final report = computePlanningMetrics(repeatedMeals,
          expectedTripDays: 2);
      expect(report.repetitionScore, equals(100.0),
          reason: 'Repas répétés OK (cap insertDeterministicMeals), '
              'seulement visites pénalisent repetitionScore');
    });
  });
}
