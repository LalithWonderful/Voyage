/// Phase 4 / Tâche 4.8 — Validation A/B offline du template-first
/// stabilisé (post-4.7).
///
/// **Tests purement unitaires + intégration légère.** Aucun appel
/// réseau, aucune dépendance Google Places, aucun framework de mock.
/// Tous les inputs sont des `TemplateCandidate` ou `NearbyCandidate`
/// construits inline, coordonnées copiées depuis sources locales
/// validées (`lib/data/destinations/singapore.dart`).
///
/// ## 8 scénarios couverts (cf. spec 4.8)
///
/// 1. Marina Bay — zone primaire respectée (Sentosa rejeté).
/// 2. Sentosa — zone primaire respectée (Marina Bay rejeté).
/// 3. `free_day` reste léger (slots freeTime non remplis).
/// 4. Hawker centres bloqués en visit / anchor / viewpoint.
/// 5. Quality floor (rating < 4.0 / reviews < 50).
/// 6. Transition longue rejetée (> 10 km).
/// 7. Déterminisme global (shuffled inputs → output stable).
/// 8. Regression guard pré/post-4.7 (chiffres A/B 4.6 référencés).
///
/// ## Conformité 4.8
///
/// - Aucune commande live API ne sera lancée par ces tests.
/// - Aucune modification de `lib/` (test-only).
/// - `useDayTemplates` reste OFF par défaut (non touché ici).
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:voyage/data/day_templates/singapore_templates.dart';
import 'package:voyage/models/day_template.dart';
import 'package:voyage/services/template_first_day_builder.dart';

import '../../../fixtures/planning/singapore_template_first_fixtures.dart';

// ─── Helpers locaux ──────────────────────────────────────────────────

DayTemplate _marinaBay() => buildSingaporeDayTemplates()
    .firstWhere((t) => t.templateKey == 'marina_bay_day');

DayTemplate _sentosa() => buildSingaporeDayTemplates()
    .firstWhere((t) => t.templateKey == 'sentosa_day');

DayTemplate _freeDay() => buildSingaporeDayTemplates()
    .firstWhere((t) => t.templateKey == 'free_day');

DayTemplate _chinatown() => buildSingaporeDayTemplates()
    .firstWhere((t) => t.templateKey == 'chinatown_civic_day');

TemplateDayBuildInput buildInput({
  required DayTemplate template,
  required List<TemplateCandidate> candidates,
  required Object? primaryZoneCenter,
  int dayIndex = 1,
}) {
  return TemplateDayBuildInput(
    template: template,
    date: DateTime.utc(2026, 5, 19).add(Duration(days: dayIndex)),
    dayIndex: dayIndex,
    candidates: candidates,
    primaryZoneCenter: primaryZoneCenter as dynamic,
  );
}

List<String> _selectedKeys(TemplateDayBuildResult r) => r.assignments
    .where((a) => a.candidate != null)
    .map((a) => a.candidate!.placeKey)
    .toList();

void main() {
  // ─── 1. Marina Bay — zone primaire respectée ───────────────────────

  group('A/B offline 1 — Marina Bay zone respectée', () {
    test('Sentosa très scoré rejeté face à Marina Bay dans '
        'template marina_bay_day', () {
      final candidates = [
        ...marinaBayPool(),
        ...sentosaPool(), // Universal Studios score 99 (> MBS 95)
      ];
      final r = buildTemplateFirstDay(buildInput(
        template: _marinaBay(),
        candidates: candidates,
        primaryZoneCenter: kMarinaBayCenter,
      ));

      final keys = _selectedKeys(r);
      // Universal Studios, Sentosa Island et Singapore Oceanarium
      // sont dans `complexKey: sentosa`, et `marina_bay_day.forbiddenComplexKeys`
      // contient `sentosa` → exclus dès le filtrage day-level.
      expect(keys, isNot(contains('p_uss')),
          reason: 'Universal Studios doit être exclu par '
              'forbiddenComplexKeys=sentosa.');
      expect(keys, isNot(contains('p_sentosa')));
      expect(keys, isNot(contains('p_oceanarium')));

      // Anchor slot rempli avec un anchor recommandé Marina Bay.
      final anchorSlot = r.assignments
          .firstWhere((a) => a.slot.slotKey == 'morning_anchor');
      expect(['p_mbs', 'p_gbb'], contains(anchorSlot.candidate?.placeKey),
          reason: 'Anchor recommandé Marina Bay attendu.');

      // Rapport offline : aucun lieu out-of-zone (>10 km de Marina
      // Bay center).
      final report = reportFor(r, zoneCenter: kMarinaBayCenter);
      expect(report.outOfZoneCount, equals(0));
      // Transitions longues (>5 km) tolérées en zone Marina Bay
      // mais devraient rester rares (≤ 1 attendue compte tenu du
      // pool resserré).
      expect(report.transitionsAboveKm(5.0), lessThanOrEqualTo(1));
    });

    test('Marina Bay : pool partiel uniquement → slot anchor '
        'tombe sur l\'alternative la plus proche en zone', () {
      // Pool sans MBS : on vérifie que GBB (autre anchor
      // recommandé) prend le slot.
      final candidates = [
        ...marinaBayPool().where((c) => c.placeKey != 'p_mbs'),
      ];
      final r = buildTemplateFirstDay(buildInput(
        template: _marinaBay(),
        candidates: candidates,
        primaryZoneCenter: kMarinaBayCenter,
      ));
      final anchorSlot = r.assignments
          .firstWhere((a) => a.slot.slotKey == 'morning_anchor');
      expect(anchorSlot.candidate?.placeKey, equals('p_gbb'));
    });
  });

  // ─── 2. Sentosa — zone primaire respectée ───────────────────────────

  group('A/B offline 2 — Sentosa zone respectée', () {
    test('Marina Bay très scoré rejeté/dépriorisé dans template '
        'sentosa_day', () {
      // sentosa_day a forbiddenComplexKeys: gardens_by_the_bay,
      // marina_bay_sands, orchard_shopping. Donc p_mbs / p_gbb /
      // p_supertree (gardens_by_the_bay) / p_artscience
      // (marina_bay_sands) sont exclus dès le filtrage.
      final candidates = [
        ...sentosaPool(),
        ...marinaBayPool(), // tentative de squeeze Marina Bay
      ];
      final r = buildTemplateFirstDay(buildInput(
        template: _sentosa(),
        candidates: candidates,
        primaryZoneCenter: kSentosaCenter,
      ));

      final keys = _selectedKeys(r);
      // MBS, GBB, Supertree, ArtScience exclus par
      // forbiddenComplexKeys.
      expect(keys, isNot(contains('p_mbs')));
      expect(keys, isNot(contains('p_gbb')));
      expect(keys, isNot(contains('p_supertree')));
      expect(keys, isNot(contains('p_artscience')));

      // Sentosa Island est anchor recommandé du template.
      final anchorSlot = r.assignments.firstWhere(
          (a) => a.slot.slotKey == 'morning_sentosa_anchor');
      expect(anchorSlot.candidate?.placeKey, equals('p_sentosa'));

      // Out-of-zone Sentosa : Merlion Park (1.2868, 103.8545) est
      // à ~4.7 km de Sentosa center → bucket 1, pas hors zone.
      final report = reportFor(r, zoneCenter: kSentosaCenter);
      expect(report.outOfZoneCount, equals(0),
          reason: 'Aucun lieu sélectionné ne doit être > 10 km de '
              'Sentosa center.');
    });
  });

  // ─── 3. free_day reste léger ───────────────────────────────────────

  group('A/B offline 3 — free_day reste léger', () {
    test('free_day : slots freeTime restent vides même avec pool '
        'généreux', () {
      // Pool très généreux. Avant 4.7, le builder aurait rempli
      // les slots freeTime avec les meilleurs candidats.
      final candidates = [
        ...marinaBayPool(),
        ...orchardBotanicPool(),
      ];
      final r = buildTemplateFirstDay(buildInput(
        template: _freeDay(),
        candidates: candidates,
        primaryZoneCenter: kMarinaBayCenter,
      ));

      // free_day a 3 slots : freeTime, meal, freeTime.
      final freeTimeSlots = r.assignments
          .where((a) => a.slot.expectedType == ExpectedSlotType.freeTime)
          .toList();
      expect(freeTimeSlots.length, equals(2));
      for (final s in freeTimeSlots) {
        expect(s.candidate, isNull,
            reason: 'Slot freeTime doit rester volontairement vide.');
        expect(s.warnings, isEmpty,
            reason: 'Slot freeTime vide n\'est PAS un manque.');
      }

      // Slot meal n'a pas de candidate meal dans le pool, restera
      // vide → mais ce n'est pas du sur-remplissage. isFallback
      // dépend du nombre de slots non-freeTime vides.
      final filledNonFree = r.assignments
          .where((a) =>
              a.slot.expectedType != ExpectedSlotType.freeTime &&
              a.candidate != null)
          .length;
      // Au plus 1 slot non-freeTime rempli (le meal slot, seulement
      // si un candidat meal était présent — ici non).
      expect(filledNonFree, lessThanOrEqualTo(1));
    });

    test('free_day avec un meal dispo : exactement 1 slot rempli', () {
      // On ajoute un seul candidate meal explicit.
      final candidates = [
        ...hawkerPool().take(1), // Lau Pa Sat catégorie meal
      ];
      final r = buildTemplateFirstDay(buildInput(
        template: _freeDay(),
        candidates: candidates,
        primaryZoneCenter: kMarinaBayCenter,
      ));
      expect(r.filledSlotsCount, equals(1));
      expect(r.isFallback, isFalse);
    });
  });

  // ─── 4. Hawker centres bloqués comme visites ───────────────────────

  group('A/B offline 4 — Hawker block en non-meal', () {
    test('Hawker mis en categorie visit (cas trompeur A/B 4.6) → '
        'bloqué sur visit/anchor/viewpoint', () {
      // Construire un pool avec UNIQUEMENT des hawker mal-étiquetés
      // + un anchor légitime + une vraie visite + un viewpoint.
      // On vérifie qu'aucun hawker ne sort.
      final candidates = [
        ...hawkerMislabeledAsVisit(),
        ...marinaBayPool(), // 5 vrais POIs Marina Bay (anchor+visit+viewpoint)
      ];
      final r = buildTemplateFirstDay(buildInput(
        template: _marinaBay(),
        candidates: candidates,
        primaryZoneCenter: kMarinaBayCenter,
      ));

      final report = reportFor(r, zoneCenter: kMarinaBayCenter);
      expect(report.hawkerInNonMealSlotsCount, equals(0),
          reason: 'Aucun hawker / food centre ne doit sortir en '
              'slot non-meal (Axe 4 — V8.28b1 réintroduit).');

      // Détail : Lau Pa Sat / Maxwell / Hong Lim ne doivent
      // jamais apparaître dans les slots non-meal.
      final keys = _selectedKeys(r);
      expect(keys, isNot(contains('p_lau_pa_sat_visit')));
      expect(keys, isNot(contains('p_maxwell_visit')));
      expect(keys, isNot(contains('p_hong_lim_visit')));
    });

    test('Hawker en categorie meal : accepté sur slot meal '
        '(chinatown_civic_day → lunch_hawker)', () {
      // chinatown_civic_day a un slot meal `lunch_hawker`.
      final candidates = [
        ...chinatownPool(),
        ...hawkerPool().take(2), // Lau Pa Sat + Maxwell catégorie meal
      ];
      final r = buildTemplateFirstDay(buildInput(
        template: _chinatown(),
        candidates: candidates,
        primaryZoneCenter: kChinatownCenter,
      ));
      final meal = r.assignments
          .firstWhere((a) => a.slot.slotKey == 'lunch_hawker');
      expect(['p_lau_pa_sat', 'p_maxwell'],
          contains(meal.candidate?.placeKey),
          reason: 'Hawker accepté comme expérience meal.');
    });
  });

  // ─── 5. Quality floor ──────────────────────────────────────────────

  group('A/B offline 5 — Quality floor', () {
    test('Cafés obscurs / lieux faibles rejetés en visit (Axe 3 — '
        'V8.28f réintroduit)', () {
      // Pool : 1 anchor MBS + 1 meal + 1 viewpoint + 1 vrai visit
      // de qualité (Merlion) + tous les weak. Les weak ne doivent
      // pas sortir.
      final candidates = [
        marinaBayPool().firstWhere((c) => c.placeKey == 'p_mbs'),
        marinaBayPool().firstWhere((c) => c.placeKey == 'p_merlion'),
        marinaBayPool().firstWhere((c) => c.placeKey == 'p_artscience'),
        hawkerPool().firstWhere((c) => c.placeKey == 'p_lau_pa_sat'),
        ...weakPool(),
      ];
      final r = buildTemplateFirstDay(buildInput(
        template: _marinaBay(),
        candidates: candidates,
        primaryZoneCenter: kMarinaBayCenter,
      ));

      final keys = _selectedKeys(r);
      expect(keys, isNot(contains('p_columbus_coffee')),
          reason: 'reviews < 50 → rejet quality floor.');
      expect(keys, isNot(contains('p_sod_cafe')),
          reason: 'rating < 4.0 → rejet quality floor.');
      expect(keys, isNot(contains('p_obscure_attraction')),
          reason: 'rating < 4.0 ET reviews < 50 → rejet.');
    });

    test('Anchor recommandé avec rating bas : exception → accepté', () {
      // Anchor recommandé MBS, rating fictif bas mais comme
      // anchorKey ∈ recommandés → exempté.
      final candidates = [
        tc(
          placeKey: 'p_mbs_low',
          title: 'Marina Bay Sands',
          category: 'anchor',
          anchorKey: 'Marina Bay Sands',
          complexKey: 'marina_bay_sands',
          score: 40,
          rating: 3.4,
          userRatingCount: 20,
          lat: 1.2834,
          lng: 103.8607,
        ),
      ];
      final r = buildTemplateFirstDay(buildInput(
        template: _marinaBay(),
        candidates: candidates,
        primaryZoneCenter: kMarinaBayCenter,
      ));
      expect(r.assignments[0].candidate?.placeKey, equals('p_mbs_low'),
          reason: 'Anchor recommandé exempt du quality floor.');
    });
  });

  // ─── 6. Transition longue rejetée ──────────────────────────────────

  group('A/B offline 6 — Transition longue rejetée', () {
    test('Candidat > 50 km (Johor) rejeté quand alternative existe', () {
      final candidates = [
        ...marinaBayPool(),
        veryFarCandidate(
          placeKey: 'p_johor',
          title: 'Johor Tourist Trap',
          category: 'visit',
          score: 200, // score énorme mais hors zone
        ),
      ];
      final r = buildTemplateFirstDay(buildInput(
        template: _marinaBay(),
        candidates: candidates,
        primaryZoneCenter: kMarinaBayCenter,
      ));

      final keys = _selectedKeys(r);
      expect(keys, isNot(contains('p_johor')),
          reason: 'Candidat > 10 km de zone non-anchor doit être '
              'rejeté.');

      final report = reportFor(r, zoneCenter: kMarinaBayCenter);
      // Aucune transition intra-jour > 10 km (le candidat à 50 km
      // est exclu, le reste est en zone Marina Bay).
      expect(report.transitionsAboveKm(10.0), equals(0));
    });
  });

  // ─── 7. Déterminisme global ────────────────────────────────────────

  group('A/B offline 7 — Déterminisme', () {
    test('Pool shuffled → mêmes assignments (tri stable)', () {
      final base = [
        ...marinaBayPool(),
        ...hawkerPool().take(2),
        ...weakPool(),
      ];
      final shuffled = base.reversed.toList();

      final r1 = buildTemplateFirstDay(buildInput(
        template: _marinaBay(),
        candidates: base,
        primaryZoneCenter: kMarinaBayCenter,
      ));
      final r2 = buildTemplateFirstDay(buildInput(
        template: _marinaBay(),
        candidates: shuffled,
        primaryZoneCenter: kMarinaBayCenter,
      ));

      expect(_selectedKeys(r1), equals(_selectedKeys(r2)));
      expect(
        r1.assignments.map((a) => a.slot.slotKey).toList(),
        equals(r2.assignments.map((a) => a.slot.slotKey).toList()),
      );
    });

    test('Deux runs successifs identiques → mêmes warnings', () {
      final pool = [...marinaBayPool(), ...sentosaPool()];
      final r1 = buildTemplateFirstDay(buildInput(
        template: _marinaBay(),
        candidates: pool,
        primaryZoneCenter: kMarinaBayCenter,
      ));
      final r2 = buildTemplateFirstDay(buildInput(
        template: _marinaBay(),
        candidates: pool,
        primaryZoneCenter: kMarinaBayCenter,
      ));
      expect(r1.warnings, equals(r2.warnings));
      for (var i = 0; i < r1.assignments.length; i++) {
        expect(r1.assignments[i].warnings,
            equals(r2.assignments[i].warnings));
      }
    });
  });

  // ─── 8. Regression guard pré/post-4.7 ──────────────────────────────

  group('A/B offline 8 — Regression guard (référence chiffres 4.6)',
      () {
    // Référence : `docs/migrations/phase4_ab_test.md`.
    // En A/B 4.6, le template-first ON produisait :
    // - 12 long transitions (>5km) sur 8 jours ;
    // - 2 hawker centres en visit slot ;
    // - 5 cafés obscurs en visit slot ;
    // - free_day rempli avec 3 visites ;
    // - Universal Studios sur arrival_day.
    //
    // Ces tests vérifient que sur un pool intentionnellement
    // « pollué » (équivalent du run live problématique), aucun
    // de ces comportements ne se reproduit avec le builder 4.7.

    test('Cas 4.6 simulé : pool Marina Bay + Sentosa + hawker '
        '+ cafés obscurs → 0 régression observée', () {
      final candidates = [
        ...marinaBayPool(),
        ...sentosaPool(),
        ...hawkerMislabeledAsVisit(),
        ...weakPool(),
      ];
      final r = buildTemplateFirstDay(buildInput(
        template: _marinaBay(),
        candidates: candidates,
        primaryZoneCenter: kMarinaBayCenter,
      ));

      final report = reportFor(r, zoneCenter: kMarinaBayCenter);

      // Régression 1 : avg inter-slot × 4.1, long transitions ×12 →
      // garde-fou : 0 transition > 10 km, ≤ 1 transition > 5 km
      // sur ce template marina_bay_day (4 slots).
      expect(report.transitionsAboveKm(10.0), equals(0));
      expect(report.transitionsAboveKm(5.0), lessThanOrEqualTo(1));

      // Régression 2 : coherence -30 (zone primaire non respectée)
      // → garde-fou : aucun lieu out-of-zone Marina Bay.
      expect(report.outOfZoneCount, equals(0));

      // Régression 3 : 2 hawker en visit slot → garde-fou : 0.
      expect(report.hawkerInNonMealSlotsCount, equals(0));

      // Régression 4 : 5 cafés obscurs en visit → garde-fou :
      // aucun des candidats weak n'est sélectionné.
      final keys = _selectedKeys(r);
      expect(keys, isNot(contains('p_columbus_coffee')));
      expect(keys, isNot(contains('p_sod_cafe')));
      expect(keys, isNot(contains('p_obscure_attraction')));

      // Régression 5 : Universal Studios sur arrival_day / Marina
      // Bay → garde-fou : sentosa exclu par
      // forbiddenComplexKeys=sentosa.
      expect(keys, isNot(contains('p_uss')));
      expect(keys, isNot(contains('p_sentosa')));
      expect(keys, isNot(contains('p_oceanarium')));
    });

    test('Cas 4.6 simulé : free_day pollué par pool généreux → '
        '0 régression sur-remplissage', () {
      // Régression 6 : free_day rempli (3 visites) en A/B 4.6.
      // Post-4.7 : freeTime non rempli, isFallback=false si meal
      // dispo.
      final candidates = [
        ...marinaBayPool(),
        ...orchardBotanicPool(),
        ...sentosaPool(), // tenter de remplir avec n'importe quoi
        ...weakPool(),
      ];
      final r = buildTemplateFirstDay(buildInput(
        template: _freeDay(),
        candidates: candidates,
        primaryZoneCenter: kMarinaBayCenter,
      ));
      // free_day a 2 slots freeTime + 1 meal. Avec pool sans
      // category=meal, le slot meal reste vide (1 slot non-free,
      // 1 empty → > 50 % → isFallback=true). Quel que soit
      // isFallback, les slots freeTime DOIVENT rester vides.
      final freeAssignments = r.assignments
          .where((a) => a.slot.expectedType == ExpectedSlotType.freeTime)
          .toList();
      for (final s in freeAssignments) {
        expect(s.candidate, isNull,
            reason: 'free_day post-4.7 : slot freeTime jamais '
                'rempli automatiquement.');
      }
      // Au plus 1 slot rempli (le meal slot si meal dispo, ici
      // non) → loin des 3 visites observées en 4.6 ON.
      expect(r.filledSlotsCount, lessThanOrEqualTo(1));
    });
  });
}
