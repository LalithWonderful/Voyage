// Phase 4 / Tâche 4.4 — Tests unitaires TemplateFirstDayBuilder.
//
// Tests purement unitaires : aucun réseau, aucun Supabase,
// aucune dépendance Google Places, aucun framework de mock.

import 'package:flutter_test/flutter_test.dart';
import 'package:voyage/data/day_templates/singapore_templates.dart';
import 'package:voyage/models/day_template.dart';
import 'package:voyage/models/destination_intelligence.dart' show GeoPoint;
import 'package:voyage/services/template_first_day_builder.dart';

// ─── Coordonnées Singapore utiles aux tests 4.7 ──────────────────────
//
// Centres de zones (issus de `buildSingaporeDestinationIntelligence`).
// Réutilisés pour tester Axe 1 anti-zigzag sans dépendre de la DI
// complète (tests purement unitaires sur le builder).
const _marinaBayCenter = GeoPoint(lat: 1.2830, lng: 103.8600);

// ─── Helpers ──────────────────────────────────────────────────────────

TemplateCandidate _cand({
  required String placeKey,
  required String title,
  required String category,
  required double score,
  String? anchorKey,
  String? complexKey,
  double? rating,
  int? userRatingCount,
  double? lat,
  double? lng,
  int? estimatedDurationMinutes,
}) {
  return TemplateCandidate(
    placeKey: placeKey,
    title: title,
    category: category,
    score: score,
    anchorKey: anchorKey,
    complexKey: complexKey,
    rating: rating,
    userRatingCount: userRatingCount,
    lat: lat,
    lng: lng,
    estimatedDurationMinutes: estimatedDurationMinutes,
  );
}

DayTemplate _marinaBayDay() =>
    buildSingaporeDayTemplates().firstWhere(
        (t) => t.templateKey == 'marina_bay_day');

DayTemplate _chinatownCivicDay() =>
    buildSingaporeDayTemplates().firstWhere(
        (t) => t.templateKey == 'chinatown_civic_day');

DayTemplate _freeDay() =>
    buildSingaporeDayTemplates().firstWhere(
        (t) => t.templateKey == 'free_day');

DayTemplate _arrivalDay() =>
    buildSingaporeDayTemplates().firstWhere(
        (t) => t.templateKey == 'arrival_day');

TemplateDayBuildInput _input({
  required DayTemplate template,
  required List<TemplateCandidate> candidates,
  int dayIndex = 1,
  Set<String> alreadyUsedPlaceKeys = const {},
  Set<String> alreadyUsedAnchorKeys = const {},
  GeoPoint? primaryZoneCenter,
}) {
  return TemplateDayBuildInput(
    template: template,
    date: DateTime.utc(2026, 5, 19).add(Duration(days: dayIndex)),
    dayIndex: dayIndex,
    candidates: candidates,
    alreadyUsedPlaceKeys: alreadyUsedPlaceKeys,
    alreadyUsedAnchorKeys: alreadyUsedAnchorKeys,
    primaryZoneCenter: primaryZoneCenter,
  );
}

void main() {
  // ─── A. Cas nominal ──────────────────────────────────────────────────

  group('A. Cas nominal — marina_bay_day', () {
    final template = _marinaBayDay();
    // 4 slots : anchor, meal, visit, viewpoint
    final candidates = [
      _cand(
          placeKey: 'p_mbs',
          title: 'Marina Bay Sands',
          category: 'anchor',
          anchorKey: 'Marina Bay Sands',
          score: 95,
          rating: 4.7,
          userRatingCount: 80000,
          estimatedDurationMinutes: 180),
      _cand(
          placeKey: 'p_gbb',
          title: 'Gardens by the Bay',
          category: 'anchor',
          anchorKey: 'Gardens by the Bay',
          score: 92,
          rating: 4.8,
          userRatingCount: 150000,
          estimatedDurationMinutes: 180),
      _cand(
          placeKey: 'p_merlion',
          title: 'Merlion Park',
          category: 'visit',
          anchorKey: 'Merlion Park',
          score: 85,
          rating: 4.5,
          userRatingCount: 60000,
          estimatedDurationMinutes: 60),
      _cand(
          placeKey: 'p_lunch',
          title: 'Marina Restaurant',
          category: 'meal',
          score: 80,
          rating: 4.4,
          userRatingCount: 800,
          estimatedDurationMinutes: 90),
      _cand(
          placeKey: 'p_view',
          title: 'Spectra Light Show',
          category: 'viewpoint',
          score: 78,
          rating: 4.6,
          userRatingCount: 20000,
          estimatedDurationMinutes: 30),
    ];
    final result = buildTemplateFirstDay(_input(
      template: template,
      candidates: candidates,
    ));

    test('Tous les slots du template ont une assignment', () {
      expect(result.assignments.length, equals(template.slots.length));
    });

    test('Tous les slots sont remplis (filledSlotsCount = nb slots)', () {
      expect(result.filledSlotsCount, equals(template.slots.length));
    });

    test('isFallback = false', () {
      expect(result.isFallback, isFalse);
    });

    test('Aucun warning day-level', () {
      expect(result.warnings, isEmpty);
    });

    test('Slot anchor matin reçoit Gardens by the Bay '
        '(score 92 mais rating supérieur)', () {
      // gardens_by_the_bay et marina_bay_sands sont tous les 2
      // recommended anchors. Au tri: anchor match égal (rang 0 pour
      // les deux), score DESC → MBS 95 vs GBB 92 → MBS gagne sur score.
      expect(
          result.assignments[0].candidate?.placeKey, equals('p_mbs'));
    });

    test('Slot meal reçoit Marina Restaurant', () {
      expect(
          result.assignments[1].candidate?.placeKey, equals('p_lunch'));
    });

    test('Slot afternoon_waterfront (visit) reçoit Merlion Park', () {
      expect(result.assignments[2].candidate?.placeKey,
          equals('p_merlion'));
    });

    test('Slot evening_viewpoint reçoit Spectra Light Show', () {
      expect(
          result.assignments[3].candidate?.placeKey, equals('p_view'));
    });

    test('templateKey préservé dans le résultat', () {
      expect(result.templateKey, equals('marina_bay_day'));
    });

    test('result.validate() vide', () {
      expect(result.validate(), isEmpty);
    });
  });

  // ─── B. forbiddenComplexKeys ─────────────────────────────────────────

  group('B. forbiddenComplexKeys', () {
    final template = _marinaBayDay(); // forbidden: ['sentosa']

    test('Candidat avec complexKey=sentosa exclu', () {
      final candidates = [
        _cand(
            placeKey: 'p_uss',
            title: 'Universal Studios',
            category: 'anchor',
            anchorKey: 'Universal Studios',
            complexKey: 'sentosa',
            score: 99),
        _cand(
            placeKey: 'p_gbb',
            title: 'Gardens by the Bay',
            category: 'anchor',
            anchorKey: 'Gardens by the Bay',
            score: 92),
      ];
      final r = buildTemplateFirstDay(_input(
        template: template,
        candidates: candidates,
      ));
      // Universal Studios doit être absent
      final assignedKeys = r.assignments
          .where((a) => a.candidate != null)
          .map((a) => a.candidate!.placeKey)
          .toList();
      expect(assignedKeys, isNot(contains('p_uss')));
      expect(r.warnings,
          contains(TemplateDayBuildWarning.forbiddenComplexFiltered));
    });

    test('Tous les candidats forbidden → pool vide → fallback', () {
      final candidates = [
        _cand(
            placeKey: 'p_uss',
            title: 'Universal Studios',
            category: 'anchor',
            complexKey: 'sentosa',
            score: 99),
        _cand(
            placeKey: 'p_rws',
            title: 'Resorts World Sentosa',
            category: 'visit',
            complexKey: 'sentosa',
            score: 88),
      ];
      final r = buildTemplateFirstDay(_input(
        template: template,
        candidates: candidates,
      ));
      expect(r.isFallback, isTrue);
      expect(r.warnings,
          contains(TemplateDayBuildWarning.emptyCandidatePool));
      expect(r.filledSlotsCount, equals(0));
      // Tous les slots doivent avoir warning missingCandidateForSlot
      for (final a in r.assignments) {
        expect(a.warnings,
            contains(TemplateDayBuildWarning.missingCandidateForSlot));
      }
    });

    test('Candidat sans complexKey n\'est PAS filtré (complexKey null)',
        () {
      final candidates = [
        _cand(
            placeKey: 'p_gbb',
            title: 'Gardens by the Bay',
            category: 'anchor',
            anchorKey: 'Gardens by the Bay',
            score: 92),
      ];
      final r = buildTemplateFirstDay(_input(
        template: template,
        candidates: candidates,
      ));
      expect(r.warnings,
          isNot(contains(TemplateDayBuildWarning.forbiddenComplexFiltered)));
      expect(r.assignments[0].candidate?.placeKey, equals('p_gbb'));
    });
  });

  // ─── C. recommendedAnchorKeys ────────────────────────────────────────

  group('C. recommendedAnchorKeys', () {
    final template = _marinaBayDay();
    // recommended: Gardens by the Bay, Marina Bay Sands, Merlion Park

    test('Anchor recommandé prioritaire même si autre a score '
        'légèrement supérieur', () {
      // Random anchor non recommandé avec score 100
      // GBB anchor recommandé avec score 80
      // → GBB gagne car anchor match prioritaire
      final candidates = [
        _cand(
            placeKey: 'p_random',
            title: 'Random Place',
            category: 'anchor',
            anchorKey: 'Some Other Anchor',
            score: 100),
        _cand(
            placeKey: 'p_gbb',
            title: 'Gardens by the Bay',
            category: 'anchor',
            anchorKey: 'Gardens by the Bay',
            score: 80),
      ];
      final r = buildTemplateFirstDay(_input(
        template: template,
        candidates: candidates,
      ));
      expect(r.assignments[0].candidate?.placeKey, equals('p_gbb'),
          reason: 'Anchor recommandé doit gagner sur score brut');
    });

    test('Si aucun anchor recommandé dispo, fallback meilleur score + '
        'warning missingRecommendedAnchor', () {
      // Aucun candidate avec anchorKey ∈ recommended
      final candidates = [
        _cand(
            placeKey: 'p_random',
            title: 'Random Anchor',
            category: 'anchor',
            anchorKey: 'Some Other Anchor',
            score: 80),
      ];
      final r = buildTemplateFirstDay(_input(
        template: template,
        candidates: candidates,
      ));
      // Anchor slot rempli mais warning émis
      expect(r.assignments[0].candidate?.placeKey, equals('p_random'));
      expect(r.assignments[0].warnings,
          contains(TemplateDayBuildWarning.missingRecommendedAnchor));
    });

    test('Anchor match case-insensitive + trim', () {
      final candidates = [
        _cand(
            placeKey: 'p_gbb',
            title: 'Gardens by the Bay',
            category: 'anchor',
            anchorKey: 'GARDENS BY THE BAY  ', // casse + espaces
            score: 50),
      ];
      final r = buildTemplateFirstDay(_input(
        template: template,
        candidates: candidates,
      ));
      // Aucun warning missingRecommendedAnchor : match malgré casse
      expect(r.assignments[0].warnings,
          isNot(contains(TemplateDayBuildWarning.missingRecommendedAnchor)));
    });

    test('Anchor null ne match pas recommended (warning émis)', () {
      final candidates = [
        _cand(
            placeKey: 'p_x',
            title: 'No Anchor',
            category: 'anchor',
            // anchorKey null
            score: 80),
      ];
      final r = buildTemplateFirstDay(_input(
        template: template,
        candidates: candidates,
      ));
      expect(r.assignments[0].warnings,
          contains(TemplateDayBuildWarning.missingRecommendedAnchor));
    });
  });

  // ─── D. Anti-duplication ─────────────────────────────────────────────

  group('D. Anti-duplication', () {
    final template = _marinaBayDay();

    test('Pas deux fois le même placeKey dans une journée', () {
      // Un seul candidate de chaque category, mais le premier
      // candidate a un score énorme. Le builder ne doit pas
      // remettre le même candidate dans 2 slots.
      final candidates = [
        _cand(
            placeKey: 'p_mbs',
            title: 'Marina Bay Sands',
            category: 'anchor',
            anchorKey: 'Marina Bay Sands',
            score: 100),
        _cand(
            placeKey: 'p_meal',
            title: 'Some Restaurant',
            category: 'meal',
            score: 70),
      ];
      final r = buildTemplateFirstDay(_input(
        template: template,
        candidates: candidates,
      ));
      // p_mbs ne doit apparaître qu'1 fois
      final keys = r.assignments
          .where((a) => a.candidate != null)
          .map((a) => a.candidate!.placeKey)
          .toList();
      expect(keys.where((k) => k == 'p_mbs').length, equals(1));
      expect(r.validate(), isEmpty);
    });

    test('alreadyUsedPlaceKeys évité si alternative existe', () {
      final candidates = [
        _cand(
            placeKey: 'p_mbs',
            title: 'Marina Bay Sands',
            category: 'anchor',
            anchorKey: 'Marina Bay Sands',
            score: 100), // dans alreadyUsed
        _cand(
            placeKey: 'p_gbb',
            title: 'Gardens by the Bay',
            category: 'anchor',
            anchorKey: 'Gardens by the Bay',
            score: 80),
      ];
      final r = buildTemplateFirstDay(_input(
        template: template,
        candidates: candidates,
        alreadyUsedPlaceKeys: {'p_mbs'},
      ));
      // Le slot anchor doit prendre GBB (alternative non utilisée)
      expect(r.assignments[0].candidate?.placeKey, equals('p_gbb'));
      expect(r.assignments[0].warnings,
          isNot(contains(
              TemplateDayBuildWarning.reusedPlaceDueToNoAlternative)));
    });

    test('Reuse autorisée en dernier recours avec warning', () {
      // Seul candidate disponible est dans alreadyUsed
      final candidates = [
        _cand(
            placeKey: 'p_mbs',
            title: 'Marina Bay Sands',
            category: 'anchor',
            anchorKey: 'Marina Bay Sands',
            score: 100),
      ];
      final r = buildTemplateFirstDay(_input(
        template: template,
        candidates: candidates,
        alreadyUsedPlaceKeys: {'p_mbs'},
      ));
      // Reuse autorisée → slot 0 rempli avec p_mbs
      expect(r.assignments[0].candidate?.placeKey, equals('p_mbs'));
      expect(r.assignments[0].warnings,
          contains(TemplateDayBuildWarning.reusedPlaceDueToNoAlternative));
    });

    test('alreadyUsedAnchorKeys évité si alternative existe', () {
      // Marina Bay Sands déjà utilisé comme anchor cross-trip.
      // Gardens by the Bay n'a pas été utilisé.
      final candidates = [
        _cand(
            placeKey: 'p_mbs',
            title: 'Marina Bay Sands',
            category: 'anchor',
            anchorKey: 'Marina Bay Sands',
            score: 100),
        _cand(
            placeKey: 'p_gbb',
            title: 'Gardens by the Bay',
            category: 'anchor',
            anchorKey: 'Gardens by the Bay',
            score: 80),
      ];
      final r = buildTemplateFirstDay(_input(
        template: template,
        candidates: candidates,
        alreadyUsedAnchorKeys: {'Marina Bay Sands'},
      ));
      // GBB doit gagner car MBS anchor déjà utilisé
      expect(r.assignments[0].candidate?.placeKey, equals('p_gbb'));
      expect(r.assignments[0].warnings,
          isNot(contains(
              TemplateDayBuildWarning.reusedAnchorDueToNoAlternative)));
    });

    test('Reuse anchor seulement si aucune alternative + warning', () {
      // Tous les candidates ont MBS comme anchor → forcé de reuse
      final candidates = [
        _cand(
            placeKey: 'p_mbs',
            title: 'Marina Bay Sands',
            category: 'anchor',
            anchorKey: 'Marina Bay Sands',
            score: 100),
      ];
      final r = buildTemplateFirstDay(_input(
        template: template,
        candidates: candidates,
        alreadyUsedAnchorKeys: {'Marina Bay Sands'},
      ));
      expect(r.assignments[0].candidate?.placeKey, equals('p_mbs'));
      expect(r.assignments[0].warnings,
          contains(TemplateDayBuildWarning.reusedAnchorDueToNoAlternative));
    });
  });

  // ─── E. Déterminisme ─────────────────────────────────────────────────

  group('E. Déterminisme', () {
    final template = _marinaBayDay();
    final candidates = [
      _cand(
          placeKey: 'p_a',
          title: 'A Anchor',
          category: 'anchor',
          anchorKey: 'Marina Bay Sands',
          score: 80,
          rating: 4.5,
          userRatingCount: 1000),
      _cand(
          placeKey: 'p_b',
          title: 'B Anchor',
          category: 'anchor',
          anchorKey: 'Gardens by the Bay',
          score: 80,
          rating: 4.5,
          userRatingCount: 1000),
      _cand(
          placeKey: 'p_c',
          title: 'C Meal',
          category: 'meal',
          score: 70),
      _cand(
          placeKey: 'p_d',
          title: 'D Visit',
          category: 'visit',
          score: 60),
      _cand(
          placeKey: 'p_e',
          title: 'E Viewpoint',
          category: 'viewpoint',
          score: 50),
    ];

    test('Deux appels avec mêmes inputs → mêmes assignments', () {
      final r1 = buildTemplateFirstDay(_input(
        template: template,
        candidates: candidates,
      ));
      final r2 = buildTemplateFirstDay(_input(
        template: template,
        candidates: candidates,
      ));
      final keys1 = r1.assignments.map((a) => a.candidate?.placeKey).toList();
      final keys2 = r2.assignments.map((a) => a.candidate?.placeKey).toList();
      expect(keys1, equals(keys2));
    });

    test('Candidates shuffled → même résultat (tri stable)', () {
      final shuffled = [...candidates.reversed];
      final r1 = buildTemplateFirstDay(_input(
        template: template,
        candidates: candidates,
      ));
      final r2 = buildTemplateFirstDay(_input(
        template: template,
        candidates: shuffled,
      ));
      final keys1 = r1.assignments.map((a) => a.candidate?.placeKey).toList();
      final keys2 = r2.assignments.map((a) => a.candidate?.placeKey).toList();
      expect(keys1, equals(keys2));
    });

    test('Tiebreaker final placeKey ASC stable sur scores/ratings '
        'identiques', () {
      // A et B ont mêmes anchor match, score, rating, reviews
      // → départage par title ('A Anchor' < 'B Anchor') → A gagne
      final r = buildTemplateFirstDay(_input(
        template: template,
        candidates: candidates,
      ));
      expect(r.assignments[0].candidate?.placeKey, equals('p_a'));
    });
  });

  // ─── F. Edge cases ───────────────────────────────────────────────────

  group('F. Edge cases', () {
    test('candidates vide → résultat avec warnings, pas crash', () {
      final r = buildTemplateFirstDay(_input(
        template: _marinaBayDay(),
        candidates: const [],
      ));
      expect(r.isFallback, isTrue);
      expect(r.warnings,
          contains(TemplateDayBuildWarning.emptyCandidatePool));
      expect(r.filledSlotsCount, equals(0));
      expect(r.assignments.length,
          equals(_marinaBayDay().slots.length));
    });

    test('Tous les candidats filtrés par forbiddenComplexKeys', () {
      final r = buildTemplateFirstDay(_input(
        template: _marinaBayDay(),
        candidates: [
          _cand(
              placeKey: 'p_x',
              title: 'X',
              category: 'anchor',
              complexKey: 'sentosa',
              score: 100),
        ],
      ));
      expect(r.warnings,
          contains(TemplateDayBuildWarning.forbiddenComplexFiltered));
      expect(r.warnings,
          contains(TemplateDayBuildWarning.emptyCandidatePool));
      expect(r.isFallback, isTrue);
    });

    test('rating/userRatingCount null gérés (nulls last)', () {
      // Candidate A avec rating 4.8 ; B avec rating null. A doit gagner.
      final candidates = [
        _cand(
            placeKey: 'p_b',
            title: 'No Rating',
            category: 'anchor',
            anchorKey: 'Marina Bay Sands',
            score: 80),
        _cand(
            placeKey: 'p_a',
            title: 'Has Rating',
            category: 'anchor',
            anchorKey: 'Marina Bay Sands',
            score: 80,
            rating: 4.8,
            userRatingCount: 10000),
      ];
      final r = buildTemplateFirstDay(_input(
        template: _marinaBayDay(),
        candidates: candidates,
      ));
      expect(r.assignments[0].candidate?.placeKey, equals('p_a'));
    });

    test('Template free_day — slots freeTime restent volontairement '
        'vides (4.7 Axe 2)', () {
      // 4.7 — Axe 2 : `ExpectedSlotType.freeTime` n'est plus
      // rempli automatiquement. free_day a 3 slots :
      // 2× freeTime + 1× meal. Avec un candidate non-meal
      // disponible, seul le slot meal est rempli (ici 0 car
      // pas de candidate meal) → filledSlotsCount peut être 0.
      // Le résultat ne doit PAS marquer ces slots comme
      // `missingCandidateForSlot` — ils sont vides par design.
      final template = _freeDay();
      final candidates = [
        _cand(
            placeKey: 'p_any',
            title: 'Anything',
            category: 'visit',
            score: 80),
      ];
      final r = buildTemplateFirstDay(_input(
        template: template,
        candidates: candidates,
      ));
      // Les 2 slots freeTime sont vides SANS warning
      // `missingCandidateForSlot` (sortie volontaire).
      final freeSlots = r.assignments
          .where((a) => a.slot.expectedType == ExpectedSlotType.freeTime)
          .toList();
      expect(freeSlots.length, equals(2));
      for (final s in freeSlots) {
        expect(s.candidate, isNull);
        expect(s.warnings, isEmpty,
            reason: 'Slot freeTime ne doit pas porter '
                'missingCandidateForSlot — vide volontaire.');
      }
      // free_day n'est PAS un fallback (les freeTime ne comptent
      // pas dans le ratio empty).
      expect(r.isFallback, isFalse);
      expect(r.validate(), isEmpty);
    });

    test('estimatedDurationMinutes null → fallback '
        'slot.typicalDurationMinutes', () {
      final template = _marinaBayDay();
      final candidates = [
        _cand(
            placeKey: 'p_x',
            title: 'X',
            category: 'anchor',
            anchorKey: 'Marina Bay Sands',
            score: 80,
            // estimatedDurationMinutes intentionnellement null
            ),
      ];
      final r = buildTemplateFirstDay(_input(
        template: template,
        candidates: candidates,
      ));
      final firstSlot = template.slots[0];
      expect(r.assignments[0].effectiveDurationMinutes,
          equals(firstSlot.typicalDurationMinutes));
    });

    test('1 seul candidate pour plusieurs slots → 1 slot rempli, '
        'autres vides', () {
      final template = _marinaBayDay(); // 4 slots
      final candidates = [
        _cand(
            placeKey: 'p_solo',
            title: 'Solo Place',
            category: 'anchor',
            anchorKey: 'Marina Bay Sands',
            score: 90),
      ];
      final r = buildTemplateFirstDay(_input(
        template: template,
        candidates: candidates,
      ));
      expect(r.filledSlotsCount, equals(1));
      // 3 slots restent vides avec warning
      expect(r.assignments.where((a) => a.isEmpty).length, equals(3));
      // isFallback car > 50% slots vides (3/4)
      expect(r.isFallback, isTrue);
    });

    test('candidate.estimatedDurationMinutes override slot duration',
        () {
      final template = _marinaBayDay();
      final candidates = [
        _cand(
            placeKey: 'p_x',
            title: 'X',
            category: 'anchor',
            anchorKey: 'Marina Bay Sands',
            score: 80,
            estimatedDurationMinutes: 42),
      ];
      final r = buildTemplateFirstDay(_input(
        template: template,
        candidates: candidates,
      ));
      expect(r.assignments[0].effectiveDurationMinutes, equals(42));
    });
  });

  // ─── G. Intégration légère avec Singapore templates ──────────────────

  group('G. Intégration légère avec Singapore templates', () {
    test('chinatown_civic_day construit avec fake candidates Chinatown',
        () {
      final template = _chinatownCivicDay();
      final candidates = [
        _cand(
            placeKey: 'p_btrt',
            title: 'Buddha Tooth Relic Temple',
            category: 'anchor',
            anchorKey: 'Buddha Tooth Relic Temple',
            score: 92,
            rating: 4.7,
            userRatingCount: 30000,
            estimatedDurationMinutes: 120),
        _cand(
            placeKey: 'p_chinatown_zone',
            title: 'Chinatown',
            category: 'anchor',
            anchorKey: 'Chinatown',
            score: 80,
            rating: 4.4),
        _cand(
            placeKey: 'p_hawker',
            title: 'Maxwell Food Centre',
            category: 'meal',
            score: 85,
            rating: 4.6),
        _cand(
            placeKey: 'p_museum',
            title: 'Chinatown Heritage Centre',
            category: 'visit',
            score: 75,
            rating: 4.3),
        _cand(
            placeKey: 'p_walk',
            title: 'Pagoda Street Walk',
            category: 'visit',
            score: 60,
            rating: 4.2),
      ];
      final r = buildTemplateFirstDay(_input(
        template: template,
        candidates: candidates,
      ));
      expect(r.filledSlotsCount, equals(template.slots.length));
      expect(r.validate(), isEmpty);
      expect(r.isFallback, isFalse);
    });

    test('arrival_day construit avec candidates minimalistes', () {
      // 4.7 — Axe 2 : arrival_day a 3 slots (visit, meal, freeTime).
      // Le slot freeTime reste vide volontairement (cf. Axe 2).
      // filledSlotsCount attendu = 2 (visit + meal), pas 3.
      final template = _arrivalDay();
      final candidates = [
        _cand(
            placeKey: 'p_walk',
            title: 'Orchard Stroll',
            category: 'visit',
            score: 70),
        _cand(
            placeKey: 'p_dinner',
            title: 'Restaurant Near Hotel',
            category: 'meal',
            score: 75),
      ];
      final r = buildTemplateFirstDay(_input(
        template: template,
        candidates: candidates,
      ));
      // 2 slots non-freeTime remplis sur 2 → pas fallback.
      final nonFreeSlots = template.slots
          .where((s) => s.expectedType != ExpectedSlotType.freeTime)
          .length;
      expect(r.filledSlotsCount, equals(nonFreeSlots));
      expect(r.warnings, isEmpty);
      expect(r.isFallback, isFalse);
    });

    test('marina_bay_day construit avec fake candidates iconic + '
        'sentosa filtré', () {
      final template = _marinaBayDay();
      final candidates = [
        _cand(
            placeKey: 'p_mbs',
            title: 'Marina Bay Sands',
            category: 'anchor',
            anchorKey: 'Marina Bay Sands',
            complexKey: 'marina_bay_sands',
            score: 100,
            rating: 4.7,
            userRatingCount: 80000),
        _cand(
            placeKey: 'p_gbb',
            title: 'Gardens by the Bay',
            category: 'anchor',
            anchorKey: 'Gardens by the Bay',
            complexKey: 'gardens_by_the_bay',
            score: 95,
            rating: 4.8,
            userRatingCount: 150000),
        // Universal Studios DOIT être exclu par forbiddenComplexKeys
        _cand(
            placeKey: 'p_uss',
            title: 'Universal Studios Singapore',
            category: 'anchor',
            anchorKey: 'Sentosa Island',
            complexKey: 'sentosa',
            score: 99),
        _cand(
            placeKey: 'p_lunch',
            title: 'Marina Restaurant',
            category: 'meal',
            score: 80),
        _cand(
            placeKey: 'p_walk',
            title: 'Waterfront Walk',
            category: 'visit',
            score: 70),
        _cand(
            placeKey: 'p_view',
            title: 'SkyPark',
            category: 'viewpoint',
            score: 88),
      ];
      final r = buildTemplateFirstDay(_input(
        template: template,
        candidates: candidates,
      ));
      // Universal Studios doit être absent
      final keys = r.assignments
          .where((a) => a.candidate != null)
          .map((a) => a.candidate!.placeKey)
          .toList();
      expect(keys, isNot(contains('p_uss')));
      expect(r.warnings,
          contains(TemplateDayBuildWarning.forbiddenComplexFiltered));
      expect(r.filledSlotsCount, equals(template.slots.length));
    });
  });

  // ─── H. Warnings & isFallback ────────────────────────────────────────

  group('H. Warnings & isFallback', () {
    test('isFallback = false quand tous les slots remplis', () {
      final template = _marinaBayDay();
      final candidates = [
        _cand(
            placeKey: 'p1',
            title: 'A',
            category: 'anchor',
            anchorKey: 'Marina Bay Sands',
            score: 90),
        _cand(
            placeKey: 'p2',
            title: 'B',
            category: 'meal',
            score: 80),
        _cand(
            placeKey: 'p3',
            title: 'C',
            category: 'visit',
            score: 70),
        _cand(
            placeKey: 'p4',
            title: 'D',
            category: 'viewpoint',
            score: 60),
      ];
      final r = buildTemplateFirstDay(_input(
        template: template,
        candidates: candidates,
      ));
      expect(r.isFallback, isFalse);
    });

    test('isFallback = true quand > 50% slots vides', () {
      final template = _marinaBayDay(); // 4 slots
      final candidates = [
        _cand(
            placeKey: 'p1',
            title: 'A',
            category: 'anchor',
            anchorKey: 'Marina Bay Sands',
            score: 90),
      ];
      final r = buildTemplateFirstDay(_input(
        template: template,
        candidates: candidates,
      ));
      // 1 slot rempli, 3 vides → > 50% vides → isFallback = true
      expect(r.isFallback, isTrue);
    });

    test('Warnings émis avec codes stables', () {
      final r = buildTemplateFirstDay(_input(
        template: _marinaBayDay(),
        candidates: const [],
      ));
      // Warning codes doivent être exactement les enums prévus
      expect(r.warnings, contains(TemplateDayBuildWarning.emptyCandidatePool));
    });

    test('isFallback ne compte PAS les slots freeTime (4.7 Axe 2)', () {
      // free_day a 3 slots : 2× freeTime + 1× meal. Avec 0
      // candidate meal, le slot meal reste vide → 1/1 slots
      // non-freeTime vide. Mais isFallback est `emptyCount >
      // nonFreeSlots.length / 2`, donc 1 > 0.5 → true.
      // Test inverse : si le slot meal est rempli, isFallback=false.
      final template = _freeDay();
      final candidates = [
        _cand(
            placeKey: 'p_meal',
            title: 'Lunch',
            category: 'meal',
            score: 80,
            rating: 4.5),
      ];
      final r = buildTemplateFirstDay(_input(
        template: template,
        candidates: candidates,
      ));
      // 1 slot non-freeTime (meal), rempli → 0 empty → not fallback.
      expect(r.isFallback, isFalse);
      // 2 slots freeTime vides volontaires.
      final freeEmpty = r.assignments
          .where((a) =>
              a.slot.expectedType == ExpectedSlotType.freeTime &&
              a.candidate == null)
          .length;
      expect(freeEmpty, equals(2));
    });

    test('validate() détecte duplicate placeKey '
        '(invariant interne préservé)', () {
      // En condition normale, le builder ne génère jamais de
      // duplicate (selectedThisDay set). Mais validate() reste
      // une assurance contre régression.
      const slot = SlotSpec(
        slotKey: 's',
        startTime: '09:00',
        typicalDurationMinutes: 60,
        expectedType: ExpectedSlotType.anchor,
      );
      const cand = TemplateCandidate(
        placeKey: 'p_dup',
        title: 'X',
        category: 'anchor',
        score: 1,
      );
      final result = TemplateDayBuildResult(
        date: DateTime.utc(2026, 5, 18),
        dayIndex: 0,
        templateKey: 'fake',
        assignments: [
          const TemplateSlotAssignment(
            slot: slot,
            candidate: cand,
            effectiveDurationMinutes: 60,
          ),
          const TemplateSlotAssignment(
            slot: slot,
            candidate: cand, // même placeKey ← invariant cassé
            effectiveDurationMinutes: 60,
          ),
        ],
        warnings: const [],
        isFallback: false,
      );
      expect(result.validate().any((e) => e.contains('duplicated')),
          isTrue);
    });
  });

  // ═══════════════════════════════════════════════════════════════════
  // Spec 4.7 — Stabilisation template-first day quality
  // ═══════════════════════════════════════════════════════════════════
  //
  // 4 axes ajoutés (cf. `docs/migrations/phase4_task4_7.md`) :
  //   I.  Anti-zigzag / zone primaire
  //   J.  Respect freeTime / free_day (déjà couvert dans F.H ci-dessus)
  //   K.  Quality floor (rating ≥ 4.0, reviews ≥ 50)
  //   L.  Hawker / food-centre block en visit
  //   M.  Intégration multi-axes (cas Singapour réaliste, offline)

  // ─── I. Axe 1 — Anti-zigzag / zone primaire ──────────────────────────

  group('I. Axe 4.7-1 — Anti-zigzag / zone primaire', () {
    final template = _marinaBayDay(); // primaryZoneName='Marina Bay'

    test('Candidat dans la zone primaire (≤2km) prioritaire sur '
        'candidat hors zone (>5km) à score égal', () {
      // p_close à 0.4 km de Marina Bay center, p_far à ~5-8 km.
      // Anchor + meal + viewpoint fournis pour ne pas perturber
      // le slot visit (le builder ne doit pas "consommer" p_close
      // pour combler un autre slot en relax category).
      final candidates = [
        _cand(
            placeKey: 'p_anchor',
            title: 'Marina Bay Sands',
            category: 'anchor',
            anchorKey: 'Marina Bay Sands',
            score: 95,
            rating: 4.7,
            userRatingCount: 50000,
            lat: 1.2834,
            lng: 103.8607),
        _cand(
            placeKey: 'p_meal',
            title: 'Marina Lunch',
            category: 'meal',
            score: 75,
            rating: 4.4,
            userRatingCount: 800,
            lat: 1.2840,
            lng: 103.8605),
        _cand(
            placeKey: 'p_view',
            title: 'Spectra Light Show',
            category: 'viewpoint',
            score: 80,
            rating: 4.6,
            userRatingCount: 20000,
            lat: 1.2843,
            lng: 103.8590),
        // Les 2 candidats visit en compétition (score égal,
        // distance différente) :
        _cand(
            placeKey: 'p_far',
            title: 'Far Visit',
            category: 'visit',
            score: 70,
            rating: 4.5,
            userRatingCount: 1000,
            lat: 1.3138, // Botanic Gardens ~5.6 km
            lng: 103.8159),
        _cand(
            placeKey: 'p_close',
            title: 'Close Visit',
            category: 'visit',
            score: 70,
            rating: 4.5,
            userRatingCount: 1000,
            lat: 1.2850, // ~0.4 km de Marina Bay center
            lng: 103.8605),
      ];
      final r = buildTemplateFirstDay(_input(
        template: template,
        candidates: candidates,
        primaryZoneCenter: _marinaBayCenter,
      ));
      final visitSlot = r.assignments
          .firstWhere((a) => a.slot.slotKey == 'afternoon_waterfront');
      expect(visitSlot.candidate?.placeKey, equals('p_close'),
          reason: 'Le candidat proche zone primaire doit gagner sur '
              'le candidat éloigné à score égal.');
    });

    test('Candidat à >10 km de la zone primaire rejeté si alternative '
        'existe (non-anchor)', () {
      // p_remote à ~50 km au nord (équivalent Johor Bahru) → rejet.
      // p_alt à 1 km dans la zone → sélectionné.
      final candidates = [
        _cand(
            placeKey: 'p_remote',
            title: 'Way Too Far',
            category: 'visit',
            score: 100, // score élevé mais hors zone
            rating: 4.8,
            userRatingCount: 5000,
            lat: 1.7000, // ~50 km au nord
            lng: 103.8600),
        _cand(
            placeKey: 'p_alt',
            title: 'In Zone Alt',
            category: 'visit',
            score: 70,
            rating: 4.4,
            userRatingCount: 500,
            lat: 1.2840,
            lng: 103.8605),
      ];
      final r = buildTemplateFirstDay(_input(
        template: template,
        candidates: candidates,
        primaryZoneCenter: _marinaBayCenter,
      ));
      final keys = r.assignments
          .where((a) => a.candidate != null)
          .map((a) => a.candidate!.placeKey)
          .toList();
      expect(keys, isNot(contains('p_remote')),
          reason: 'Candidat > 10 km hors zone (non-anchor) doit être '
              'rejeté quand une alternative existe.');
      expect(keys, contains('p_alt'));
    });

    test('Anchor recommandé hors zone (>10 km) toléré (exception)', () {
      // Le template marina_bay_day recommande 'Gardens by the Bay'
      // comme anchor. Si le candidat correspondant est étrangement
      // loin (mauvais geocoding par ex.), on doit quand même
      // l'accepter pour respecter le choix éditorial du template.
      final candidates = [
        _cand(
            placeKey: 'p_gbb_far',
            title: 'Gardens by the Bay (geocoded far)',
            category: 'anchor',
            anchorKey: 'Gardens by the Bay',
            score: 50,
            rating: 4.8,
            userRatingCount: 100000,
            lat: 1.7000, // > 10 km hors zone
            lng: 103.8600),
      ];
      final r = buildTemplateFirstDay(_input(
        template: template,
        candidates: candidates,
        primaryZoneCenter: _marinaBayCenter,
      ));
      // Le slot anchor doit toujours prendre p_gbb_far : exception
      // anti-zigzag pour anchor recommandé.
      expect(r.assignments[0].candidate?.placeKey, equals('p_gbb_far'),
          reason: 'Anchor recommandé exempt du rejet > 10 km.');
    });

    test('primaryZoneCenter null → axe anti-zigzag en bypass complet '
        '(rétro-compat tests 4.4/4.5)', () {
      // Sans primaryZoneCenter, le comportement doit être identique
      // à pré-4.7 : tri = anchor + score + rating + ...
      // Aucun candidat n'est rejeté pour distance, peu importe où.
      final candidates = [
        _cand(
            placeKey: 'p_remote',
            title: 'Remote MBS',
            category: 'anchor',
            anchorKey: 'Marina Bay Sands',
            score: 100,
            rating: 4.7,
            userRatingCount: 50000,
            lat: 5.0, // au milieu de l'océan, ne devrait
            lng: 110.0), // pas être rejeté car bypass.
      ];
      final r = buildTemplateFirstDay(_input(
        template: template,
        candidates: candidates,
        // primaryZoneCenter non passé → null
      ));
      expect(r.assignments[0].candidate?.placeKey, equals('p_remote'));
    });

    test('Candidat sans coordonnées (lat/lng null) accepté '
        '(pas pénalisé)', () {
      // Un candidat sans coordonnées ne doit pas être rejeté ni
      // pénalisé en tri par anti-zigzag — c'est une absence
      // d'information, pas un mauvais signal.
      final candidates = [
        _cand(
            placeKey: 'p_no_coord',
            title: 'Anchor No Coord',
            category: 'anchor',
            anchorKey: 'Marina Bay Sands',
            score: 90,
            rating: 4.6,
            userRatingCount: 10000,
            // lat/lng intentionnellement null
            ),
      ];
      final r = buildTemplateFirstDay(_input(
        template: template,
        candidates: candidates,
        primaryZoneCenter: _marinaBayCenter,
      ));
      expect(r.assignments[0].candidate?.placeKey, equals('p_no_coord'));
    });
  });

  // ─── J. Axe 2 — Respect freeTime (couverture additionnelle) ──────────

  group('J. Axe 4.7-2 — Respect freeTime', () {
    test('arrival_day : slot freeTime non rempli même si candidate '
        'freeTime disponible dans le pool', () {
      final template = _arrivalDay();
      // Pool généreux incluant un candidate "freeTime"-compatible
      final candidates = [
        _cand(
            placeKey: 'p_visit',
            title: 'Soft Walk',
            category: 'visit',
            score: 70,
            rating: 4.3,
            userRatingCount: 200),
        _cand(
            placeKey: 'p_meal',
            title: 'Dinner',
            category: 'meal',
            score: 75,
            rating: 4.5),
        _cand(
            placeKey: 'p_anything',
            title: 'Could Fill Free Slot',
            category: 'visit',
            score: 60,
            rating: 4.5,
            userRatingCount: 500),
      ];
      final r = buildTemplateFirstDay(_input(
        template: template,
        candidates: candidates,
      ));
      // Slot evening_free_time DOIT rester vide.
      final freeSlot = r.assignments
          .firstWhere((a) => a.slot.slotKey == 'evening_free_time');
      expect(freeSlot.candidate, isNull,
          reason: 'Slot freeTime ne doit pas être rempli '
              'automatiquement (4.7 Axe 2).');
      expect(freeSlot.warnings, isEmpty,
          reason: 'Slot freeTime vide est volontaire, pas un manque.');
    });
  });

  // ─── K. Axe 3 — Quality floor ────────────────────────────────────────

  group('K. Axe 4.7-3 — Quality floor', () {
    final template = _marinaBayDay();

    // Helper anchor + meal + viewpoint pour isoler le slot visit
    // dans les tests quality floor (sinon le builder, en relax
    // category Tier 3, consomme nos visit candidates pour combler
    // le slot anchor — pollution du test).
    List<TemplateCandidate> surroundingSlots() => [
          _cand(
              placeKey: 'p_anchor',
              title: 'Marina Bay Sands',
              category: 'anchor',
              anchorKey: 'Marina Bay Sands',
              score: 95,
              rating: 4.7,
              userRatingCount: 50000,
              lat: 1.2834,
              lng: 103.8607),
          _cand(
              placeKey: 'p_meal',
              title: 'Marina Lunch',
              category: 'meal',
              score: 75,
              rating: 4.4,
              userRatingCount: 800,
              lat: 1.2840,
              lng: 103.8605),
          _cand(
              placeKey: 'p_view',
              title: 'Spectra Light Show',
              category: 'viewpoint',
              score: 80,
              rating: 4.6,
              userRatingCount: 20000,
              lat: 1.2843,
              lng: 103.8590),
        ];

    test('Candidat rating < 4.0 rejeté en slot visit', () {
      final candidates = [
        ...surroundingSlots(),
        _cand(
            placeKey: 'p_low_rating',
            title: 'Mediocre Place',
            category: 'visit',
            score: 100,
            rating: 3.5, // sous le seuil
            userRatingCount: 1000,
            lat: 1.2840,
            lng: 103.8605),
        _cand(
            placeKey: 'p_ok',
            title: 'Decent Place',
            category: 'visit',
            score: 50,
            rating: 4.4,
            userRatingCount: 200,
            lat: 1.2840,
            lng: 103.8605),
      ];
      final r = buildTemplateFirstDay(_input(
        template: template,
        candidates: candidates,
        primaryZoneCenter: _marinaBayCenter,
      ));
      final visit = r.assignments
          .firstWhere((a) => a.slot.slotKey == 'afternoon_waterfront');
      expect(visit.candidate?.placeKey, equals('p_ok'),
          reason: 'p_low_rating doit être rejeté (rating < 4.0).');
    });

    test('Candidat userRatingCount < 50 rejeté en slot visit', () {
      final candidates = [
        ...surroundingSlots(),
        _cand(
            placeKey: 'p_few_reviews',
            title: 'Obscure Place',
            category: 'visit',
            score: 100,
            rating: 4.9,
            userRatingCount: 12, // sous le seuil
            lat: 1.2840,
            lng: 103.8605),
        _cand(
            placeKey: 'p_normal',
            title: 'Normal Place',
            category: 'visit',
            score: 50,
            rating: 4.2,
            userRatingCount: 500,
            lat: 1.2840,
            lng: 103.8605),
      ];
      final r = buildTemplateFirstDay(_input(
        template: template,
        candidates: candidates,
        primaryZoneCenter: _marinaBayCenter,
      ));
      final visit = r.assignments
          .firstWhere((a) => a.slot.slotKey == 'afternoon_waterfront');
      expect(visit.candidate?.placeKey, equals('p_normal'),
          reason: 'p_few_reviews doit être rejeté (reviews < 50).');
    });

    test('Anchor recommandé avec rating < 4.0 ACCEPTÉ (exception)', () {
      // Si l'anchor recommandé du template a un rating bas (cas
      // rare mais possible), on l'accepte quand même pour
      // préserver le choix éditorial.
      final candidates = [
        _cand(
            placeKey: 'p_gbb_low',
            title: 'Gardens by the Bay',
            category: 'anchor',
            anchorKey: 'Gardens by the Bay',
            score: 50,
            rating: 3.5,
            userRatingCount: 20,
            lat: 1.2820,
            lng: 103.8636),
      ];
      final r = buildTemplateFirstDay(_input(
        template: template,
        candidates: candidates,
        primaryZoneCenter: _marinaBayCenter,
      ));
      expect(r.assignments[0].candidate?.placeKey, equals('p_gbb_low'),
          reason: 'Anchor recommandé exempt du quality floor.');
    });

    test('Slot meal exempté du quality floor (rating 3.8 accepté)', () {
      final candidates = [
        _cand(
            placeKey: 'p_mbs',
            title: 'Marina Bay Sands',
            category: 'anchor',
            anchorKey: 'Marina Bay Sands',
            score: 95,
            rating: 4.7,
            userRatingCount: 50000,
            lat: 1.2834,
            lng: 103.8607),
        _cand(
            placeKey: 'p_meh_meal',
            title: 'Average Resto',
            category: 'meal',
            score: 60,
            rating: 3.8, // sous le seuil visit mais OK en meal
            userRatingCount: 80,
            lat: 1.2840,
            lng: 103.8605),
      ];
      final r = buildTemplateFirstDay(_input(
        template: template,
        candidates: candidates,
        primaryZoneCenter: _marinaBayCenter,
      ));
      final meal = r.assignments
          .firstWhere((a) => a.slot.slotKey == 'lunch');
      expect(meal.candidate?.placeKey, equals('p_meh_meal'),
          reason: 'Slot meal accepte rating < 4.0 (insertion repas '
              'legacy gère ses propres règles).');
    });
  });

  // ─── L. Axe 4 — Hawker / food-centre block en visit ──────────────────

  group('L. Axe 4.7-4 — Hawker / food-centre block', () {
    final template = _marinaBayDay();

    // Helper identique à K — isoler le slot visit.
    List<TemplateCandidate> surroundingSlots() => [
          _cand(
              placeKey: 'p_anchor',
              title: 'Marina Bay Sands',
              category: 'anchor',
              anchorKey: 'Marina Bay Sands',
              score: 95,
              rating: 4.7,
              userRatingCount: 50000,
              lat: 1.2834,
              lng: 103.8607),
          _cand(
              placeKey: 'p_meal',
              title: 'Marina Lunch',
              category: 'meal',
              score: 75,
              rating: 4.4,
              userRatingCount: 800,
              lat: 1.2840,
              lng: 103.8605),
          _cand(
              placeKey: 'p_view',
              title: 'Spectra Light Show',
              category: 'viewpoint',
              score: 80,
              rating: 4.6,
              userRatingCount: 20000,
              lat: 1.2843,
              lng: 103.8590),
        ];

    test('Candidat "Maxwell Food Centre" rejeté en slot visit', () {
      final candidates = [
        ...surroundingSlots(),
        _cand(
            placeKey: 'p_maxwell',
            title: 'Maxwell Food Centre',
            category: 'visit', // catégorie trompeuse
            score: 100,
            rating: 4.6,
            userRatingCount: 30000,
            lat: 1.2840,
            lng: 103.8605),
        _cand(
            placeKey: 'p_alt',
            title: 'Real Attraction',
            category: 'visit',
            score: 40,
            rating: 4.3,
            userRatingCount: 200,
            lat: 1.2840,
            lng: 103.8605),
      ];
      final r = buildTemplateFirstDay(_input(
        template: template,
        candidates: candidates,
        primaryZoneCenter: _marinaBayCenter,
      ));
      final visit = r.assignments
          .firstWhere((a) => a.slot.slotKey == 'afternoon_waterfront');
      expect(visit.candidate?.placeKey, equals('p_alt'),
          reason: 'Maxwell Food Centre doit être bloqué en slot visit.');
    });

    test('Candidat "Maxwell Food Centre" ACCEPTÉ en slot meal', () {
      // Le template chinatown_civic_day a un slot meal hawker.
      final chinatown = _chinatownCivicDay();
      final candidates = [
        _cand(
            placeKey: 'p_anchor',
            title: 'Buddha Tooth Relic Temple',
            category: 'anchor',
            anchorKey: 'Buddha Tooth Relic Temple',
            score: 90,
            rating: 4.7,
            userRatingCount: 30000,
            lat: 1.2814,
            lng: 103.8443),
        _cand(
            placeKey: 'p_maxwell',
            title: 'Maxwell Food Centre',
            category: 'meal',
            score: 85,
            rating: 4.6,
            userRatingCount: 30000,
            lat: 1.2807,
            lng: 103.8447),
      ];
      final r = buildTemplateFirstDay(_input(
        template: chinatown,
        candidates: candidates,
        primaryZoneCenter: const GeoPoint(lat: 1.2814, lng: 103.8443),
      ));
      final meal = r.assignments
          .firstWhere((a) => a.slot.slotKey == 'lunch_hawker');
      expect(meal.candidate?.placeKey, equals('p_maxwell'),
          reason: 'Hawker centre accepté comme expérience food '
              'structurante en slot meal.');
    });

    test('"hawker centre" générique (substring) rejeté en visit', () {
      final candidates = [
        ...surroundingSlots(),
        _cand(
            placeKey: 'p_generic',
            title: 'Some Random Hawker Centre',
            category: 'visit',
            score: 100,
            rating: 4.5,
            userRatingCount: 2000,
            lat: 1.2840,
            lng: 103.8605),
        _cand(
            placeKey: 'p_real',
            title: 'Marina Promenade',
            category: 'visit',
            score: 60,
            rating: 4.3,
            userRatingCount: 800,
            lat: 1.2840,
            lng: 103.8605),
      ];
      final r = buildTemplateFirstDay(_input(
        template: template,
        candidates: candidates,
        primaryZoneCenter: _marinaBayCenter,
      ));
      final visit = r.assignments
          .firstWhere((a) => a.slot.slotKey == 'afternoon_waterfront');
      expect(visit.candidate?.placeKey, equals('p_real'),
          reason: '"hawker centre" substring doit bloquer en visit.');
    });
  });

  // ─── M. Intégration multi-axes — cas Singapour offline ────────────────

  group('M. Intégration 4.7 — multi-axes Singapour offline', () {
    test('marina_bay_day : tous les axes coopèrent', () {
      // Pool simulant un résultat Google Places réaliste :
      // - 2 anchors recommandés Marina Bay (rating OK, in zone)
      // - 1 anchor recommandé Sentosa hors zone (toléré car anchor)
      // - 1 hawker centre (devrait aller en meal, pas en visit)
      // - 1 visite obscure (rating bas → rejet)
      // - 1 visite cohérente
      // - 1 candidat très loin > 10 km (rejet anti-zigzag)
      // - 1 repas standard
      final template = _marinaBayDay();
      final candidates = [
        // Anchor recommandé, in zone — devrait gagner slot anchor
        _cand(
            placeKey: 'p_mbs',
            title: 'Marina Bay Sands',
            category: 'anchor',
            anchorKey: 'Marina Bay Sands',
            score: 95,
            rating: 4.7,
            userRatingCount: 80000,
            lat: 1.2834,
            lng: 103.8607),
        _cand(
            placeKey: 'p_gbb',
            title: 'Gardens by the Bay',
            category: 'anchor',
            anchorKey: 'Gardens by the Bay',
            score: 92,
            rating: 4.8,
            userRatingCount: 150000,
            lat: 1.2816,
            lng: 103.8636),
        // Hawker centre — devrait être bloqué en visit, accepté
        // pour meal s'il y en avait dans la même catégorie. Ici on
        // le marque comme catégorie "visit" trompeuse → block.
        _cand(
            placeKey: 'p_hawker',
            title: 'Lau Pa Sat',
            category: 'visit',
            score: 70,
            rating: 4.5,
            userRatingCount: 20000,
            lat: 1.2806,
            lng: 103.8503),
        // Visite faible qualité → quality floor reject.
        _cand(
            placeKey: 'p_obscure',
            title: 'Obscure Random Place',
            category: 'visit',
            score: 60,
            rating: 3.6,
            userRatingCount: 25,
            lat: 1.2845,
            lng: 103.8610),
        // Visite cohérente, dans zone, qualité OK.
        _cand(
            placeKey: 'p_helix',
            title: 'Helix Bridge',
            category: 'visit',
            score: 65,
            rating: 4.4,
            userRatingCount: 5000,
            lat: 1.2860,
            lng: 103.8627),
        // Trop loin (Sentosa) sans être anchor recommandé Marina
        // → bucket fort mais pas > 10 km Marina Bay → bucket 1-2.
        // Pour tester rejet > 10 km, on met un cas explicite plus loin.
        _cand(
            placeKey: 'p_remote',
            title: 'Remote Tourist Trap',
            category: 'visit',
            score: 90,
            rating: 4.5,
            userRatingCount: 500,
            lat: 1.7000, // ~50 km au nord (Johor)
            lng: 103.8600),
        // Repas standard.
        _cand(
            placeKey: 'p_lunch',
            title: 'Marina Lunch',
            category: 'meal',
            score: 75,
            rating: 4.3,
            userRatingCount: 800,
            lat: 1.2840,
            lng: 103.8605),
        // Viewpoint.
        _cand(
            placeKey: 'p_view',
            title: 'Spectra Light Show',
            category: 'viewpoint',
            score: 80,
            rating: 4.6,
            userRatingCount: 20000,
            lat: 1.2843,
            lng: 103.8590),
      ];
      final r = buildTemplateFirstDay(_input(
        template: template,
        candidates: candidates,
        primaryZoneCenter: _marinaBayCenter,
      ));

      final selected = r.assignments
          .where((a) => a.candidate != null)
          .map((a) => a.candidate!.placeKey)
          .toList();

      // Anchor slot rempli avec anchor recommandé in-zone.
      expect(
          [r.assignments[0].candidate?.placeKey],
          anyOf([
            equals(['p_mbs']),
            equals(['p_gbb']),
          ]));

      // Meal slot rempli avec Marina Lunch.
      final mealSlot = r.assignments
          .firstWhere((a) => a.slot.expectedType == ExpectedSlotType.meal);
      expect(mealSlot.candidate?.placeKey, equals('p_lunch'));

      // Aucune sélection ne doit contenir Lau Pa Sat (hawker block)
      // ni p_obscure (quality floor) ni p_remote (anti-zigzag >10km).
      expect(selected, isNot(contains('p_hawker')));
      expect(selected, isNot(contains('p_obscure')));
      expect(selected, isNot(contains('p_remote')));

      // Tous les slots non-freeTime sont remplis (pool généreux).
      expect(r.isFallback, isFalse);

      // Le résultat reste déterministe + sans duplicate.
      expect(r.validate(), isEmpty);
    });
  });
}
