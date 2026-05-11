// Phase 4 / Tâche 4.2 — Tests des données Singapour DayTemplates.
//
// Tests purement unitaires : aucun réseau, aucun Supabase, aucune
// dépendance Google Places, aucun framework de mock.

import 'package:flutter_test/flutter_test.dart';
import 'package:voyage/data/complexes/singapore_complexes.dart';
import 'package:voyage/data/day_templates/singapore_templates.dart';
import 'package:voyage/data/destinations/singapore.dart';
import 'package:voyage/models/day_template.dart';

DayTemplate _byKey(List<DayTemplate> templates, String key) =>
    templates.firstWhere((t) => t.templateKey == key,
        orElse: () => throw StateError('Template "$key" not found'));

void main() {
  // ─── 1. Liste globale ────────────────────────────────────────────────

  group('buildSingaporeDayTemplates — liste globale', () {
    final templates = buildSingaporeDayTemplates();

    test('Exactement 8 templates', () {
      expect(templates.length, equals(8));
    });

    test('Tous ont destinationKey == "singapore"', () {
      for (final t in templates) {
        expect(t.destinationKey, equals('singapore'),
            reason: '${t.templateKey} doit cibler Singapour');
      }
    });

    test('Tous passent validate() sans erreur', () {
      for (final t in templates) {
        final errors = t.validate();
        expect(errors, isEmpty,
            reason:
                'Template "${t.templateKey}" doit être valide. '
                'Erreurs : $errors');
      }
    });

    test('Tous passent validateAgainstDestination(buildSingaporeDI)', () {
      final di = buildSingaporeDestinationIntelligence();
      for (final t in templates) {
        final errors = t.validateAgainstDestination(di);
        expect(errors, isEmpty,
            reason:
                'Template "${t.templateKey}" doit passer la validation '
                'croisée DI. Erreurs : $errors');
      }
    });
  });

  // ─── 2. Présence des 8 templateKey ───────────────────────────────────

  group('Présence des 8 templateKey attendus', () {
    final templates = buildSingaporeDayTemplates();
    final keys = templates.map((t) => t.templateKey).toSet();

    const expectedKeys = {
      'arrival_day',
      'marina_bay_day',
      'chinatown_civic_day',
      'sentosa_day',
      'orchard_botanic_day',
      'little_india_kampong_day',
      'free_day',
      'departure_day',
    };

    test('Les 8 templateKey obligatoires sont présents', () {
      expect(keys.containsAll(expectedKeys), isTrue,
          reason: 'Manquants : ${expectedKeys.difference(keys)}');
    });

    test('Aucun templateKey dupliqué', () {
      final list = templates.map((t) => t.templateKey).toList();
      expect(list.length, equals(keys.length),
          reason: 'templateKey dupliqué détecté');
    });
  });

  // ─── 3. Références zones (DI Singapour) ──────────────────────────────

  group('Références zones — toutes existent dans DI', () {
    final templates = buildSingaporeDayTemplates();
    final di = buildSingaporeDestinationIntelligence();
    final zoneNames = di.zones.map((z) => z.name).toSet();

    test('Chaque primaryZoneName existe dans DI Singapour', () {
      for (final t in templates) {
        expect(zoneNames, contains(t.primaryZoneName),
            reason: '${t.templateKey} → primaryZoneName '
                '"${t.primaryZoneName}" introuvable dans DI');
      }
    });
  });

  // ─── 4. Références anchors (DI Singapour) ────────────────────────────

  group('Références anchors — toutes existent dans DI ou liste vide',
      () {
    final templates = buildSingaporeDayTemplates();
    final di = buildSingaporeDestinationIntelligence();
    final anchorNames = di.anchors.map((a) => a.name).toSet();

    test('Chaque recommendedAnchorKey existe dans DI Singapour', () {
      for (final t in templates) {
        for (final a in t.recommendedAnchorKeys) {
          expect(anchorNames, contains(a),
              reason: '${t.templateKey} → anchor "$a" introuvable '
                  'dans DI');
        }
      }
    });

    test('Templates avec recommendedAnchorKeys vide acceptés '
        '(contrat bf54187)', () {
      final freeDay = _byKey(templates, 'free_day');
      expect(freeDay.recommendedAnchorKeys, isEmpty);
      expect(freeDay.validate(), isEmpty);
      expect(freeDay.validateAgainstDestination(di), isEmpty);
    });
  });

  // ─── 5. Références complexes (Singapour complexes) ───────────────────

  group('Références complexes — toutes existent dans Singapour '
      'complexes ou liste vide', () {
    final templates = buildSingaporeDayTemplates();
    final complexKeys = buildSingaporeSameComplexGroups()
        .map((g) => g.complexKey)
        .toSet();

    test('Chaque forbiddenComplexKey existe dans Singapour complexes',
        () {
      for (final t in templates) {
        for (final c in t.forbiddenComplexKeys) {
          expect(complexKeys, contains(c),
              reason: '${t.templateKey} → forbiddenComplexKey "$c" '
                  'introuvable dans Singapour complexes');
        }
      }
    });

    test('Templates avec forbiddenComplexKeys vide acceptés '
        '(contrat bf54187)', () {
      // arrival_day et free_day ont forbiddenComplexKeys vide
      final arrival = _byKey(templates, 'arrival_day');
      expect(arrival.forbiddenComplexKeys, isEmpty);
      expect(arrival.validate(), isEmpty);

      final free = _byKey(templates, 'free_day');
      expect(free.forbiddenComplexKeys, isEmpty);
      expect(free.validate(), isEmpty);
    });
  });

  // ─── 6. Slots ────────────────────────────────────────────────────────

  group('Slots — invariants', () {
    final templates = buildSingaporeDayTemplates();

    test('Chaque template a entre 3 et 5 slots', () {
      for (final t in templates) {
        expect(t.slots.length, inInclusiveRange(3, 5),
            reason: '${t.templateKey} → ${t.slots.length} slots '
                '(doit être 3..5)');
      }
    });

    test('Chaque slot a une heure valide (cf. SlotSpec.validate)', () {
      for (final t in templates) {
        for (final s in t.slots) {
          expect(s.validate(), isEmpty,
              reason: '${t.templateKey}/${s.slotKey} invalide');
        }
      }
    });

    test('Chaque template a des slotKey uniques', () {
      for (final t in templates) {
        final keys = t.slots.map((s) => s.slotKey).toSet();
        expect(keys.length, equals(t.slots.length),
            reason: '${t.templateKey} → slotKey dupliqué');
      }
    });

    test('Au moins un template contient ExpectedSlotType.anchor', () {
      final hasAnchor = templates.any(
          (t) => t.slots.any((s) => s.expectedType == ExpectedSlotType.anchor));
      expect(hasAnchor, isTrue);
    });

    test('Au moins un template contient ExpectedSlotType.meal', () {
      final hasMeal = templates.any(
          (t) => t.slots.any((s) => s.expectedType == ExpectedSlotType.meal));
      expect(hasMeal, isTrue);
    });

    test('Au moins un template contient ExpectedSlotType.freeTime', () {
      final hasFree = templates.any(
          (t) =>
              t.slots.any((s) => s.expectedType == ExpectedSlotType.freeTime));
      expect(hasFree, isTrue);
    });
  });

  // ─── 7. Intensité ─────────────────────────────────────────────────────

  group('Intensité par template', () {
    final templates = buildSingaporeDayTemplates();

    test('sentosa_day est intense', () {
      expect(_byKey(templates, 'sentosa_day').intensity,
          equals(DayIntensity.intense));
    });

    test('marina_bay_day, chinatown_civic_day, orchard_botanic_day, '
        'little_india_kampong_day sont medium', () {
      for (final key in const [
        'marina_bay_day',
        'chinatown_civic_day',
        'orchard_botanic_day',
        'little_india_kampong_day',
      ]) {
        expect(_byKey(templates, key).intensity,
            equals(DayIntensity.medium),
            reason: '$key doit être medium');
      }
    });

    test('arrival_day, free_day, departure_day sont light', () {
      for (final key in const [
        'arrival_day',
        'free_day',
        'departure_day',
      ]) {
        expect(_byKey(templates, key).intensity,
            equals(DayIntensity.light),
            reason: '$key doit être light');
      }
    });
  });

  // ─── 8. JSON round-trip ──────────────────────────────────────────────

  group('Round-trip JSON par template', () {
    final templates = buildSingaporeDayTemplates();
    final di = buildSingaporeDestinationIntelligence();

    test('toJson() puis fromJson() préserve chaque template', () {
      for (final original in templates) {
        final json = original.toJson();
        final decoded = DayTemplate.fromJson(json);

        expect(decoded.templateKey, equals(original.templateKey));
        expect(decoded.destinationKey, equals(original.destinationKey));
        expect(decoded.theme, equals(original.theme));
        expect(decoded.primaryZoneName, equals(original.primaryZoneName));
        expect(decoded.intensity, equals(original.intensity));
        expect(decoded.recommendedAnchorKeys,
            equals(original.recommendedAnchorKeys));
        expect(decoded.forbiddenComplexKeys,
            equals(original.forbiddenComplexKeys));
        expect(decoded.mealStrategy, equals(original.mealStrategy));
        expect(decoded.slots.length, equals(original.slots.length));
        expect(decoded.flexibility, equals(original.flexibility));
        expect(decoded.validate(), isEmpty);
        expect(decoded.validateAgainstDestination(di), isEmpty);
      }
    });
  });

  // ─── 9. No duplicate templateKey ─────────────────────────────────────

  group('No duplicate templateKey', () {
    final templates = buildSingaporeDayTemplates();

    test('Aucun doublon de templateKey', () {
      final keys = templates.map((t) => t.templateKey).toList();
      final unique = keys.toSet();
      expect(unique.length, equals(keys.length));
    });

    test('Aucun doublon de templateKey après normalisation lowercase',
        () {
      final keys = templates
          .map((t) => t.templateKey.toLowerCase().trim())
          .toList();
      final unique = keys.toSet();
      expect(unique.length, equals(keys.length));
    });
  });

  // ─── 10. Contrat listes vides (bf54187) ──────────────────────────────

  group('Contrat listes vides (bf54187)', () {
    final templates = buildSingaporeDayTemplates();
    final di = buildSingaporeDestinationIntelligence();
    final freeDay = _byKey(templates, 'free_day');

    test('free_day a recommendedAnchorKeys vide', () {
      expect(freeDay.recommendedAnchorKeys, isEmpty);
    });

    test('free_day a forbiddenComplexKeys vide', () {
      expect(freeDay.forbiddenComplexKeys, isEmpty);
    });

    test('free_day reste valide validate() + croisé DI', () {
      expect(freeDay.validate(), isEmpty);
      expect(freeDay.validateAgainstDestination(di), isEmpty);
    });

    test('free_day round-trip JSON préserve les listes vides', () {
      final decoded = DayTemplate.fromJson(freeDay.toJson());
      expect(decoded.recommendedAnchorKeys, isEmpty);
      expect(decoded.forbiddenComplexKeys, isEmpty);
      expect(decoded.validate(), isEmpty);
    });
  });
}
