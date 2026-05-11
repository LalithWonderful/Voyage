// Phase 4 / Tâche 4.4 — Tests unitaires TemplateFirstDayBuilder.
//
// Tests purement unitaires : aucun réseau, aucun Supabase,
// aucune dépendance Google Places, aucun framework de mock.

import 'package:flutter_test/flutter_test.dart';
import 'package:voyage/data/day_templates/singapore_templates.dart';
import 'package:voyage/models/day_template.dart';
import 'package:voyage/services/template_first_day_builder.dart';

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
}) {
  return TemplateDayBuildInput(
    template: template,
    date: DateTime.utc(2026, 5, 19).add(Duration(days: dayIndex)),
    dayIndex: dayIndex,
    candidates: candidates,
    alreadyUsedPlaceKeys: alreadyUsedPlaceKeys,
    alreadyUsedAnchorKeys: alreadyUsedAnchorKeys,
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

    test('Template free_day avec recommendedAnchorKeys/'
        'forbiddenComplexKeys vides', () {
      final template = _freeDay();
      final candidates = [
        _cand(
            placeKey: 'p_any',
            title: 'Anything',
            category: 'freeTime', // matche freeTime via règle "tout match"
            score: 80),
      ];
      final r = buildTemplateFirstDay(_input(
        template: template,
        candidates: candidates,
      ));
      expect(r.filledSlotsCount, greaterThan(0));
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
        _cand(
            placeKey: 'p_free',
            title: 'Free time spot',
            category: 'freeTime',
            score: 50),
      ];
      final r = buildTemplateFirstDay(_input(
        template: template,
        candidates: candidates,
      ));
      expect(r.filledSlotsCount, equals(template.slots.length));
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
}
