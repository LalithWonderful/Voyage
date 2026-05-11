// Phase 4 / Tâche 4.3 — Tests unitaires DayThemeAssigner.
//
// Tests purement unitaires : aucun réseau, aucun Supabase,
// aucune dépendance Google Places, aucun framework de mock.

import 'package:flutter_test/flutter_test.dart';
import 'package:voyage/data/day_templates/singapore_templates.dart';
import 'package:voyage/data/destinations/singapore.dart';
import 'package:voyage/models/day_template.dart';
import 'package:voyage/services/day_theme_assigner.dart';

// ─── Helpers ──────────────────────────────────────────────────────────

TripSkeleton _trip({
  required DateTime startDate,
  required DateTime endDate,
  String destinationKey = 'singapore',
  List<String> interests = const [],
  String? travelerType,
}) {
  return TripSkeleton(
    destinationKey: destinationKey,
    startDate: startDate,
    endDate: endDate,
    interests: interests,
    travelerType: travelerType,
  );
}

/// Construit un template minimal valide pour tests "templates
/// manquants" et autres cas exceptionnels.
DayTemplate _minimalTemplate({
  required String key,
  String destinationKey = 'singapore',
  String zoneName = 'Marina Bay',
  DayIntensity intensity = DayIntensity.medium,
  List<String> recommendedAnchorKeys = const [],
}) {
  return DayTemplate(
    templateKey: key,
    destinationKey: destinationKey,
    theme: 'Theme $key',
    primaryZoneName: zoneName,
    intensity: intensity,
    recommendedAnchorKeys: recommendedAnchorKeys,
    forbiddenComplexKeys: const [],
    mealStrategy: MealStrategy.mixed,
    slots: const [
      SlotSpec(
        slotKey: 'morning',
        startTime: '10:00',
        typicalDurationMinutes: 90,
        expectedType: ExpectedSlotType.visit,
      ),
      SlotSpec(
        slotKey: 'lunch',
        startTime: '12:30',
        typicalDurationMinutes: 60,
        expectedType: ExpectedSlotType.meal,
      ),
      SlotSpec(
        slotKey: 'afternoon',
        startTime: '14:30',
        typicalDurationMinutes: 90,
        expectedType: ExpectedSlotType.visit,
      ),
    ],
  );
}

int _countTemplateKey(
        List<DayTemplateAssignment> assigns, String key) =>
    assigns.where((a) => a.template.templateKey == key).length;

bool _hasConsecutiveIntense(List<DayTemplateAssignment> assigns) {
  for (var i = 1; i < assigns.length; i++) {
    if (assigns[i].template.intensity == DayIntensity.intense &&
        assigns[i - 1].template.intensity == DayIntensity.intense) {
      return true;
    }
  }
  return false;
}

void main() {
  // ─── 1. Voyage 8 jours Singapour (cas de référence) ──────────────────

  group('Voyage 8 jours Singapour', () {
    final di = buildSingaporeDestinationIntelligence();
    final templates = buildSingaporeDayTemplates();
    final trip = _trip(
      startDate: DateTime.utc(2026, 5, 18),
      endDate: DateTime.utc(2026, 5, 25),
    );
    final assignments = assignThemesToDays(trip, di, templates);

    test('8 assignments', () {
      expect(assignments.length, equals(8));
    });

    test('Jour 0 = arrival_day', () {
      expect(assignments.first.template.templateKey, equals('arrival_day'));
      expect(assignments.first.reason, equals(DayAssignmentReason.arrival));
    });

    test('Jour 7 = departure_day', () {
      expect(assignments.last.template.templateKey,
          equals('departure_day'));
      expect(
          assignments.last.reason, equals(DayAssignmentReason.departure));
    });

    test('Contient free_day', () {
      expect(_countTemplateKey(assignments, 'free_day'),
          greaterThanOrEqualTo(1));
    });

    test('Contient marina_bay_day', () {
      expect(_countTemplateKey(assignments, 'marina_bay_day'),
          greaterThanOrEqualTo(1));
    });

    test('Contient sentosa_day', () {
      expect(_countTemplateKey(assignments, 'sentosa_day'),
          greaterThanOrEqualTo(1));
    });

    test('Aucun template dupliqué', () {
      final keys = assignments.map((a) => a.template.templateKey).toList();
      expect(keys.toSet().length, equals(keys.length));
    });

    test('Pas deux jours intense consécutifs', () {
      expect(_hasConsecutiveIntense(assignments), isFalse);
    });

    test('Chaque assignment template valide vs DI', () {
      for (final a in assignments) {
        final errors = a.template.validateAgainstDestination(di);
        expect(errors, isEmpty,
            reason: 'Day ${a.dayIndex} (${a.template.templateKey}) '
                'invalide : $errors');
      }
    });

    test('Dates calendaires correctes (séquence consécutive)', () {
      for (var i = 0; i < assignments.length; i++) {
        expect(assignments[i].date,
            equals(trip.startDate.add(Duration(days: i))));
        expect(assignments[i].dayIndex, equals(i));
      }
    });

    test('sentosa_day n\'est ni le 1er ni le dernier jour', () {
      final sentosa = assignments
          .firstWhere((a) => a.template.templateKey == 'sentosa_day');
      expect(sentosa.dayIndex, greaterThan(0));
      expect(sentosa.dayIndex, lessThan(assignments.length - 1));
    });
  });

  // ─── 2. Voyage 3 jours Singapour ─────────────────────────────────────

  group('Voyage 3 jours Singapour', () {
    final di = buildSingaporeDestinationIntelligence();
    final templates = buildSingaporeDayTemplates();
    final trip = _trip(
      startDate: DateTime.utc(2026, 5, 18),
      endDate: DateTime.utc(2026, 5, 20),
    );
    final assignments = assignThemesToDays(trip, di, templates);

    test('3 assignments', () {
      expect(assignments.length, equals(3));
    });

    test('Jour 0 = arrival_day', () {
      expect(assignments.first.template.templateKey, equals('arrival_day'));
    });

    test('Jour 2 = departure_day', () {
      expect(assignments.last.template.templateKey,
          equals('departure_day'));
    });

    test('Jour 1 = template iconique (anchors non vides)', () {
      final middle = assignments[1];
      expect(middle.template.recommendedAnchorKeys, isNotEmpty,
          reason: 'Jour du milieu doit être iconique');
      // Pour voyage court, on attend marina_bay_day (top de queue
      // iconique) ou un autre iconique non-intense.
      expect(middle.template.intensity, isNot(DayIntensity.intense),
          reason: 'Jour du milieu ne doit pas être intense (pas '
              'après arrival ni avant departure)');
    });
  });

  // ─── 3. Voyage 1 jour ────────────────────────────────────────────────

  group('Voyage 1 jour Singapour', () {
    final di = buildSingaporeDestinationIntelligence();
    final templates = buildSingaporeDayTemplates();
    final trip = _trip(
      startDate: DateTime.utc(2026, 5, 18),
      endDate: DateTime.utc(2026, 5, 18),
    );
    final assignments = assignThemesToDays(trip, di, templates);

    test('1 assignment', () {
      expect(assignments.length, equals(1));
    });

    test('Pas de crash, retourne arrival_day', () {
      expect(assignments.first.template.templateKey, equals('arrival_day'));
      expect(assignments.first.dayIndex, equals(0));
    });

    test('Sans arrival_day → fallback light', () {
      final templatesNoArrival = templates
          .where((t) => t.templateKey != 'arrival_day')
          .toList();
      final assigns = assignThemesToDays(trip, di, templatesNoArrival);
      expect(assigns.length, equals(1));
      expect(assigns.first.template.intensity, equals(DayIntensity.light),
          reason: 'Fallback doit choisir un template light');
    });
  });

  // ─── 4. Voyage 2 jours ───────────────────────────────────────────────

  group('Voyage 2 jours Singapour', () {
    final di = buildSingaporeDestinationIntelligence();
    final templates = buildSingaporeDayTemplates();
    final trip = _trip(
      startDate: DateTime.utc(2026, 5, 18),
      endDate: DateTime.utc(2026, 5, 19),
    );
    final assignments = assignThemesToDays(trip, di, templates);

    test('2 assignments', () {
      expect(assignments.length, equals(2));
    });

    test('Arrival puis departure', () {
      expect(assignments[0].template.templateKey, equals('arrival_day'));
      expect(assignments[1].template.templateKey, equals('departure_day'));
    });
  });

  // ─── 5. Voyage 12 jours (répétitions autorisées) ─────────────────────

  group('Voyage 12 jours Singapour (long, > 10)', () {
    final di = buildSingaporeDestinationIntelligence();
    final templates = buildSingaporeDayTemplates();
    final trip = _trip(
      startDate: DateTime.utc(2026, 5, 18),
      endDate: DateTime.utc(2026, 5, 29),
    );
    final assignments = assignThemesToDays(trip, di, templates);

    test('12 assignments', () {
      expect(assignments.length, equals(12));
    });

    test('Au moins 2 free_day (rythme repos long séjour)', () {
      expect(_countTemplateKey(assignments, 'free_day'),
          greaterThanOrEqualTo(2));
    });

    test('Pas deux intense consécutifs', () {
      expect(_hasConsecutiveIntense(assignments), isFalse);
    });

    test('Jour 0 arrival, jour 11 departure', () {
      expect(assignments.first.template.templateKey, equals('arrival_day'));
      expect(assignments.last.template.templateKey,
          equals('departure_day'));
    });

    test('Répétitions autorisées (≥ 1 templateKey apparaît ≥ 2×)', () {
      // Sauf arrival/departure qui restent uniques, on attend que
      // certains iconic se répètent (cycle).
      final middleKeys = assignments
          .where((a) =>
              a.template.templateKey != 'arrival_day' &&
              a.template.templateKey != 'departure_day')
          .map((a) => a.template.templateKey)
          .toList();
      final uniqueMiddle = middleKeys.toSet();
      expect(middleKeys.length, greaterThan(uniqueMiddle.length),
          reason: '> 10 jours doit autoriser des répétitions');
    });
  });

  // ─── 6. Templates manquants ──────────────────────────────────────────

  group('Templates manquants — fallback déterministe', () {
    final di = buildSingaporeDestinationIntelligence();
    final trip = _trip(
      startDate: DateTime.utc(2026, 5, 18),
      endDate: DateTime.utc(2026, 5, 22),
    );

    test('Sans arrival_day → fallback light pour jour 0', () {
      final templates = [
        _minimalTemplate(
            key: 'marina_bay_lite',
            zoneName: 'Marina Bay',
            intensity: DayIntensity.light),
        _minimalTemplate(
            key: 'sentosa_intense',
            zoneName: 'Sentosa',
            intensity: DayIntensity.intense),
        _minimalTemplate(
            key: 'departure_day',
            zoneName: 'Orchard',
            intensity: DayIntensity.light),
      ];
      final assigns = assignThemesToDays(trip, di, templates);
      expect(assigns.length, equals(5));
      // Jour 0 doit être light (pas sentosa_intense).
      expect(assigns.first.template.intensity, equals(DayIntensity.light));
    });

    test('Sans departure_day → fallback light pour dernier jour', () {
      final templates = [
        _minimalTemplate(
            key: 'arrival_day',
            zoneName: 'Marina Bay',
            intensity: DayIntensity.light),
        _minimalTemplate(
            key: 'marina_bay_alt',
            zoneName: 'Marina Bay',
            intensity: DayIntensity.medium),
        _minimalTemplate(
            key: 'sentosa_alt',
            zoneName: 'Sentosa',
            intensity: DayIntensity.intense),
        _minimalTemplate(
            key: 'orchard_lite',
            zoneName: 'Orchard',
            intensity: DayIntensity.light),
      ];
      final assigns = assignThemesToDays(trip, di, templates);
      expect(assigns.length, equals(5));
      expect(assigns.last.template.intensity, equals(DayIntensity.light));
    });

    test('Sans free_day → pas d\'insertion repos automatique, '
        'pas de crash', () {
      final templates = [
        _minimalTemplate(
            key: 'arrival_day',
            zoneName: 'Marina Bay',
            intensity: DayIntensity.light),
        _minimalTemplate(
            key: 'marina_bay_alt',
            zoneName: 'Marina Bay',
            intensity: DayIntensity.medium,
            recommendedAnchorKeys: const ['Marina Bay Sands']),
        _minimalTemplate(
            key: 'chinatown_alt',
            zoneName: 'Chinatown',
            intensity: DayIntensity.medium),
        _minimalTemplate(
            key: 'departure_day',
            zoneName: 'Orchard',
            intensity: DayIntensity.light),
      ];
      final assigns = assignThemesToDays(trip, di, templates);
      expect(assigns.length, equals(5));
      // Chaque jour reçoit un template.
      for (final a in assigns) {
        expect(a.template, isNotNull);
      }
    });
  });

  // ─── 7. Liste templates vide ─────────────────────────────────────────

  group('Liste templates vide', () {
    final di = buildSingaporeDestinationIntelligence();
    final trip = _trip(
      startDate: DateTime.utc(2026, 5, 18),
      endDate: DateTime.utc(2026, 5, 20),
    );

    test('throw ArgumentError sur liste vide', () {
      expect(() => assignThemesToDays(trip, di, const []),
          throwsA(isA<ArgumentError>()));
    });

    test('throw ArgumentError sur destinationKey non matché', () {
      // Tous les templates ciblent une autre destination → vide après filtrage.
      final templates = [
        _minimalTemplate(key: 'arrival_day', destinationKey: 'paris'),
      ];
      expect(() => assignThemesToDays(trip, di, templates),
          throwsA(isA<ArgumentError>()));
    });
  });

  // ─── 8. Dates invalides ──────────────────────────────────────────────

  group('Dates invalides', () {
    final di = buildSingaporeDestinationIntelligence();
    final templates = buildSingaporeDayTemplates();

    test('endDate < startDate → ArgumentError', () {
      final trip = _trip(
        startDate: DateTime.utc(2026, 5, 25),
        endDate: DateTime.utc(2026, 5, 18),
      );
      expect(() => assignThemesToDays(trip, di, templates),
          throwsA(isA<ArgumentError>()));
    });

    test('endDate == startDate → OK (1 jour)', () {
      final trip = _trip(
        startDate: DateTime.utc(2026, 5, 18),
        endDate: DateTime.utc(2026, 5, 18),
      );
      final assigns = assignThemesToDays(trip, di, templates);
      expect(assigns.length, equals(1));
    });
  });

  // ─── 9. Déterminisme ─────────────────────────────────────────────────

  group('Déterminisme', () {
    final di = buildSingaporeDestinationIntelligence();
    final templates = buildSingaporeDayTemplates();
    final trip = _trip(
      startDate: DateTime.utc(2026, 5, 18),
      endDate: DateTime.utc(2026, 5, 25),
    );

    test('Deux appels avec mêmes inputs → même séquence de '
        'templateKey', () {
      final a = assignThemesToDays(trip, di, templates);
      final b = assignThemesToDays(trip, di, templates);
      expect(a.map((x) => x.template.templateKey).toList(),
          equals(b.map((x) => x.template.templateKey).toList()));
    });

    test('Deux appels avec mêmes inputs → même séquence de raisons',
        () {
      final a = assignThemesToDays(trip, di, templates);
      final b = assignThemesToDays(trip, di, templates);
      expect(a.map((x) => x.reason).toList(),
          equals(b.map((x) => x.reason).toList()));
    });

    test('Ordre des templates dans l\'input ne change pas la séquence',
        () {
      final shuffled = [...templates.reversed];
      final a = assignThemesToDays(trip, di, templates);
      final b = assignThemesToDays(trip, di, shuffled);
      expect(a.map((x) => x.template.templateKey).toList(),
          equals(b.map((x) => x.template.templateKey).toList()),
          reason: 'Le tri interne doit rendre l\'algo indépendant de '
              'l\'ordre des inputs');
    });
  });

  // ─── 10. Reasons cohérentes ──────────────────────────────────────────

  group('Reasons', () {
    final di = buildSingaporeDestinationIntelligence();
    final templates = buildSingaporeDayTemplates();
    final trip = _trip(
      startDate: DateTime.utc(2026, 5, 18),
      endDate: DateTime.utc(2026, 5, 25),
    );
    final assignments = assignThemesToDays(trip, di, templates);

    test('arrival_day → reason arrival', () {
      final a = assignments
          .firstWhere((x) => x.template.templateKey == 'arrival_day');
      expect(a.reason, equals(DayAssignmentReason.arrival));
    });

    test('departure_day → reason departure', () {
      final a = assignments
          .firstWhere((x) => x.template.templateKey == 'departure_day');
      expect(a.reason, equals(DayAssignmentReason.departure));
    });

    test('free_day → reason restBalance', () {
      final freeDays = assignments
          .where((x) => x.template.templateKey == 'free_day')
          .toList();
      for (final a in freeDays) {
        expect(a.reason, equals(DayAssignmentReason.restBalance));
      }
    });

    test('Templates iconiques (anchors non vides) → reason '
        'iconicPriority', () {
      final iconics = assignments.where((x) =>
          x.template.templateKey != 'arrival_day' &&
          x.template.templateKey != 'departure_day' &&
          x.template.templateKey != 'free_day');
      for (final a in iconics) {
        expect(a.reason, equals(DayAssignmentReason.iconicPriority),
            reason: '${a.template.templateKey} (anchors '
                '${a.template.recommendedAnchorKeys.length})');
      }
    });
  });
}
