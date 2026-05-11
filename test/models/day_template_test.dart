// Phase 4 / Tâche 4.1 — Tests unitaires DayTemplate.
//
// Tests purement unitaires : aucun réseau, aucun Supabase, aucune
// dépendance Google Places, aucun framework de mock.

import 'package:flutter_test/flutter_test.dart';
import 'package:voyage/models/day_template.dart';
import 'package:voyage/models/destination_intelligence.dart';

// ─── Helper builders ──────────────────────────────────────────────────

DayTemplate _validTemplate({
  String templateKey = 'marina_bay_day',
  String destinationKey = 'singapore',
  String theme = 'Marina Bay & waterfront icons',
  String primaryZoneName = 'Marina Bay',
  DayIntensity intensity = DayIntensity.medium,
  List<String>? recommendedAnchorKeys,
  List<String>? forbiddenComplexKeys,
  MealStrategy mealStrategy = MealStrategy.mixed,
  List<SlotSpec>? slots,
  int flexibility = 70,
}) {
  return DayTemplate(
    templateKey: templateKey,
    destinationKey: destinationKey,
    theme: theme,
    primaryZoneName: primaryZoneName,
    intensity: intensity,
    recommendedAnchorKeys: recommendedAnchorKeys ??
        const ['Gardens by the Bay', 'Marina Bay Sands'],
    forbiddenComplexKeys: forbiddenComplexKeys ?? const ['sentosa'],
    mealStrategy: mealStrategy,
    slots: slots ??
        const [
          SlotSpec(
            slotKey: 'morning_anchor',
            startTime: '09:30',
            typicalDurationMinutes: 180,
            expectedType: ExpectedSlotType.anchor,
          ),
          SlotSpec(
            slotKey: 'lunch',
            startTime: '12:30',
            typicalDurationMinutes: 60,
            expectedType: ExpectedSlotType.meal,
          ),
          SlotSpec(
            slotKey: 'afternoon_visit',
            startTime: '14:30',
            typicalDurationMinutes: 120,
            expectedType: ExpectedSlotType.visit,
          ),
        ],
    flexibility: flexibility,
  );
}

DestinationIntelligence _singaporeDiFixture() {
  return DestinationIntelligence(
    destinationKey: 'singapore',
    canonicalCenter: const GeoPoint(lat: 1.3521, lng: 103.8198),
    countryCode: 'SG',
    allowedCountryCodes: const ['SG'],
    blockedCountryCodes: const ['MY', 'ID'],
    blockedNeighborRegions: const [],
    borderSensitivity: BorderSensitivity.high,
    tripMode: TripMode.megaCity,
    zones: [
      const TouristZone(
        name: 'Marina Bay',
        center: GeoPoint(lat: 1.283, lng: 103.860),
        radiusKm: 2,
        theme: 'waterfront',
      ),
      const TouristZone(
        name: 'Sentosa',
        center: GeoPoint(lat: 1.249, lng: 103.830),
        radiusKm: 3,
        theme: 'island_resort',
      ),
    ],
    anchors: [
      const DestinationAnchor(
        name: 'Gardens by the Bay',
        placeQueries: ['Gardens by the Bay'],
        importance: 5,
        recommendedDuration: Duration(minutes: 180),
      ),
      const DestinationAnchor(
        name: 'Marina Bay Sands',
        placeQueries: ['Marina Bay Sands'],
        importance: 5,
        recommendedDuration: Duration(minutes: 120),
      ),
    ],
    transportRules: const TransportRules(
      maxTransitionKm: 5,
      dominantMode: 'public_transport',
      hasMetro: true,
      hasMetroAnchorLogic: true,
    ),
  );
}

void main() {
  // ─── 1. Modèle valide ────────────────────────────────────────────────

  group('Modèle valide', () {
    test('Template complet passe validate() sans erreur', () {
      final t = _validTemplate();
      expect(t.validate(), isEmpty);
      expect(t.isValid, isTrue);
    });

    test('Defaults exposés (flexibility=50, ranges)', () {
      expect(DayTemplate.defaultFlexibility, equals(50));
      expect(DayTemplate.minFlexibility, equals(0));
      expect(DayTemplate.maxFlexibility, equals(100));
    });

    test('Default flexibility via constructor', () {
      final t = DayTemplate(
        templateKey: 'k',
        destinationKey: 'd',
        theme: 't',
        primaryZoneName: 'z',
        intensity: DayIntensity.light,
        recommendedAnchorKeys: const [],
        forbiddenComplexKeys: const [],
        mealStrategy: MealStrategy.mixed,
        slots: const [
          SlotSpec(
            slotKey: 's',
            startTime: '09:00',
            typicalDurationMinutes: 60,
            expectedType: ExpectedSlotType.anchor,
          ),
        ],
      );
      expect(t.flexibility, equals(50));
    });
  });

  // ─── 2. Round-trip JSON ──────────────────────────────────────────────

  group('Round-trip JSON', () {
    test('toJson() puis fromJson() conserve toutes les valeurs', () {
      final original = _validTemplate();
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
    });

    test('JSON utilise snake_case (clés)', () {
      final json = _validTemplate().toJson();
      expect(json.keys, containsAll(<String>[
        'template_key',
        'destination_key',
        'theme',
        'primary_zone_name',
        'intensity',
        'recommended_anchor_keys',
        'forbidden_complex_keys',
        'meal_strategy',
        'slots',
        'flexibility',
      ]));
      final slot = (json['slots'] as List).first as Map;
      expect(slot.keys, containsAll(<String>[
        'slot_key',
        'start_time',
        'typical_duration_minutes',
        'expected_type',
      ]));
    });

    test('SlotSpec round-trip JSON conserve les valeurs', () {
      const original = SlotSpec(
        slotKey: 'evening_show',
        startTime: '19:45',
        typicalDurationMinutes: 90,
        expectedType: ExpectedSlotType.show,
      );
      final decoded = SlotSpec.fromJson(original.toJson());
      expect(decoded.slotKey, equals('evening_show'));
      expect(decoded.startTime, equals('19:45'));
      expect(decoded.typicalDurationMinutes, equals(90));
      expect(decoded.expectedType, equals(ExpectedSlotType.show));
    });

    test('fromJson() applique default flexibility si absent', () {
      final json = _validTemplate().toJson();
      json.remove('flexibility');
      final decoded = DayTemplate.fromJson(json);
      expect(decoded.flexibility, equals(DayTemplate.defaultFlexibility));
    });

    test('fromJson() applique listes vides si clés absentes', () {
      final json = _validTemplate().toJson();
      json.remove('recommended_anchor_keys');
      json.remove('forbidden_complex_keys');
      final decoded = DayTemplate.fromJson(json);
      expect(decoded.recommendedAnchorKeys, isEmpty);
      expect(decoded.forbiddenComplexKeys, isEmpty);
    });
  });

  // ─── 3. Enums (parsing strict-by-default) ────────────────────────────

  group('Enums parsing', () {
    test('DayIntensity : light / medium / intense', () {
      expect(DayIntensity.fromJsonString('light'),
          equals(DayIntensity.light));
      expect(DayIntensity.fromJsonString('medium'),
          equals(DayIntensity.medium));
      expect(DayIntensity.fromJsonString('intense'),
          equals(DayIntensity.intense));
    });

    test('DayIntensity round-trip', () {
      for (final v in DayIntensity.values) {
        expect(DayIntensity.fromJsonString(v.toJsonString()), equals(v));
      }
    });

    test('DayIntensity inconnu → FormatException', () {
      expect(() => DayIntensity.fromJsonString('extreme'),
          throwsA(isA<FormatException>()));
    });

    test('MealStrategy : zoneRestaurants / hawkerCenters / fineDining '
        '/ mixed', () {
      expect(MealStrategy.fromJsonString('zoneRestaurants'),
          equals(MealStrategy.zoneRestaurants));
      expect(MealStrategy.fromJsonString('hawkerCenters'),
          equals(MealStrategy.hawkerCenters));
      expect(MealStrategy.fromJsonString('fineDining'),
          equals(MealStrategy.fineDining));
      expect(MealStrategy.fromJsonString('mixed'),
          equals(MealStrategy.mixed));
    });

    test('MealStrategy inconnu → FormatException', () {
      expect(() => MealStrategy.fromJsonString('streetfood'),
          throwsA(isA<FormatException>()));
    });

    test('ExpectedSlotType : tous les types présents', () {
      const expected = [
        'anchor',
        'visit',
        'meal',
        'rest',
        'transfer',
        'shopping',
        'viewpoint',
        'show',
        'freeTime',
      ];
      for (final name in expected) {
        final v = ExpectedSlotType.fromJsonString(name);
        expect(v.name, equals(name));
      }
    });

    test('ExpectedSlotType round-trip', () {
      for (final v in ExpectedSlotType.values) {
        expect(ExpectedSlotType.fromJsonString(v.toJsonString()),
            equals(v));
      }
    });

    test('ExpectedSlotType inconnu → FormatException', () {
      expect(() => ExpectedSlotType.fromJsonString('parade'),
          throwsA(isA<FormatException>()));
    });

    test('JSON DayTemplate avec intensity inconnue → FormatException',
        () {
      final json = _validTemplate().toJson();
      json['intensity'] = 'extreme';
      expect(() => DayTemplate.fromJson(json),
          throwsA(isA<FormatException>()));
    });
  });

  // ─── 4. Validation champs obligatoires ───────────────────────────────

  group('Champs obligatoires', () {
    test('templateKey vide rejeté', () {
      final t = _validTemplate(templateKey: '');
      expect(t.validate(), contains('template_key must be non-empty'));
    });

    test('templateKey avec whitespace rejeté', () {
      final t = _validTemplate(templateKey: 'marina bay');
      expect(t.validate().any((e) => e.contains('whitespace')), isTrue);
    });

    test('destinationKey vide rejeté', () {
      final t = _validTemplate(destinationKey: '');
      expect(t.validate(), contains('destination_key must be non-empty'));
    });

    test('theme vide rejeté', () {
      final t = _validTemplate(theme: '   ');
      expect(t.validate(), contains('theme must be non-empty'));
    });

    test('primaryZoneName vide rejeté', () {
      final t = _validTemplate(primaryZoneName: '');
      expect(t.validate(),
          contains('primary_zone_name must be non-empty'));
    });

    test('slots vide rejeté', () {
      final t = _validTemplate(slots: const []);
      expect(t.validate(), contains('slots must have at least one entry'));
    });
  });

  // ─── 5. Validation flexibility ───────────────────────────────────────

  group('Validation flexibility', () {
    test('flexibility -1 rejeté', () {
      final t = _validTemplate(flexibility: -1);
      expect(
        t.validate().any((e) => e.startsWith('flexibility must be in '
            '[0, 100]')),
        isTrue,
      );
    });

    test('flexibility 101 rejeté', () {
      final t = _validTemplate(flexibility: 101);
      expect(
        t.validate().any((e) => e.startsWith('flexibility must be in '
            '[0, 100]')),
        isTrue,
      );
    });

    test('flexibility 0 accepté', () {
      final t = _validTemplate(flexibility: 0);
      expect(t.validate(), isEmpty);
    });

    test('flexibility 100 accepté', () {
      final t = _validTemplate(flexibility: 100);
      expect(t.validate(), isEmpty);
    });
  });

  // ─── 6. Validation SlotSpec ──────────────────────────────────────────

  group('Validation SlotSpec', () {
    SlotSpec slotWith({
      String slotKey = 'k',
      String startTime = '09:00',
      int typicalDurationMinutes = 60,
      ExpectedSlotType expectedType = ExpectedSlotType.anchor,
    }) =>
        SlotSpec(
          slotKey: slotKey,
          startTime: startTime,
          typicalDurationMinutes: typicalDurationMinutes,
          expectedType: expectedType,
        );

    test('slotKey vide rejeté', () {
      expect(
        slotWith(slotKey: '').validate(),
        contains('SlotSpec.slot_key must be non-empty'),
      );
    });

    test('slotKey avec whitespace rejeté', () {
      expect(
        slotWith(slotKey: 'morning anchor')
            .validate()
            .any((e) => e.contains('whitespace')),
        isTrue,
      );
    });

    test('startTime invalide rejeté — vide', () {
      expect(
        slotWith(startTime: '')
            .validate()
            .any((e) => e.contains('start_time must be HH:mm')),
        isTrue,
      );
    });

    test('startTime 09:00 accepté', () {
      expect(slotWith(startTime: '09:00').validate(), isEmpty);
    });

    test('startTime 13:30 accepté', () {
      expect(slotWith(startTime: '13:30').validate(), isEmpty);
    });

    test('startTime 19:45 accepté', () {
      expect(slotWith(startTime: '19:45').validate(), isEmpty);
    });

    test('startTime 00:00 accepté (minuit)', () {
      expect(slotWith(startTime: '00:00').validate(), isEmpty);
    });

    test('startTime 23:59 accepté (dernière minute)', () {
      expect(slotWith(startTime: '23:59').validate(), isEmpty);
    });

    test('startTime 9:00 rejeté (manque leading zero)', () {
      expect(
        slotWith(startTime: '9:00')
            .validate()
            .any((e) => e.contains('start_time')),
        isTrue,
      );
    });

    test('startTime 25:00 rejeté (heure invalide)', () {
      expect(
        slotWith(startTime: '25:00')
            .validate()
            .any((e) => e.contains('start_time')),
        isTrue,
      );
    });

    test('startTime 12:99 rejeté (minute invalide)', () {
      expect(
        slotWith(startTime: '12:99')
            .validate()
            .any((e) => e.contains('start_time')),
        isTrue,
      );
    });

    test('typicalDurationMinutes 0 rejeté', () {
      expect(
        slotWith(typicalDurationMinutes: 0)
            .validate()
            .any((e) => e.contains('typical_duration_minutes must be > 0')),
        isTrue,
      );
    });

    test('typicalDurationMinutes négatif rejeté', () {
      expect(
        slotWith(typicalDurationMinutes: -10)
            .validate()
            .any((e) => e.contains('typical_duration_minutes must be > 0')),
        isTrue,
      );
    });

    test('typicalDurationMinutes 720 accepté (limite max)', () {
      expect(slotWith(typicalDurationMinutes: 720).validate(), isEmpty);
    });

    test('typicalDurationMinutes 721 rejeté (> 720)', () {
      expect(
        slotWith(typicalDurationMinutes: 721)
            .validate()
            .any((e) => e.contains('typical_duration_minutes must be <= 720')),
        isTrue,
      );
    });
  });

  // ─── 7. Doublons ─────────────────────────────────────────────────────

  group('Doublons', () {
    test('Duplicate recommendedAnchorKeys (casse différente) rejeté', () {
      final t = _validTemplate(
        recommendedAnchorKeys: const [
          'Gardens by the Bay',
          'gardens by the bay', // doublon après normalisation
        ],
      );
      expect(
        t.validate().any((e) => e.contains('recommended_anchor_keys') &&
            e.contains('duplicates')),
        isTrue,
      );
    });

    test('Empty entry dans recommendedAnchorKeys rejeté', () {
      final t = _validTemplate(
        recommendedAnchorKeys: const ['Gardens', '   ', 'Marina'],
      );
      expect(
        t.validate().any((e) => e.startsWith(
            'recommended_anchor_keys[1] must be non-empty')),
        isTrue,
      );
    });

    test('Duplicate forbiddenComplexKeys rejeté', () {
      final t = _validTemplate(
        forbiddenComplexKeys: const ['sentosa', 'SENTOSA'],
      );
      expect(
        t.validate().any((e) => e.contains('forbidden_complex_keys') &&
            e.contains('duplicates')),
        isTrue,
      );
    });

    test('Empty entry dans forbiddenComplexKeys rejeté', () {
      final t = _validTemplate(
        forbiddenComplexKeys: const ['sentosa', ''],
      );
      expect(
        t.validate().any((e) => e.startsWith(
            'forbidden_complex_keys[1] must be non-empty')),
        isTrue,
      );
    });

    test('Duplicate slotKey rejeté', () {
      final t = _validTemplate(
        slots: const [
          SlotSpec(
            slotKey: 'morning_anchor',
            startTime: '09:00',
            typicalDurationMinutes: 90,
            expectedType: ExpectedSlotType.anchor,
          ),
          SlotSpec(
            slotKey: 'morning_anchor', // doublon
            startTime: '11:00',
            typicalDurationMinutes: 60,
            expectedType: ExpectedSlotType.visit,
          ),
        ],
      );
      expect(
        t.validate().any((e) => e.contains('slot_key duplicates')),
        isTrue,
      );
    });
  });

  // ─── 8. Validation croisée avec DestinationIntelligence ──────────────

  group('validateAgainstDestination', () {
    final di = _singaporeDiFixture();

    test('Template Marina Bay + anchors connus → 0 erreur croisée', () {
      final t = _validTemplate();
      expect(t.validateAgainstDestination(di), isEmpty);
    });

    test('destinationKey différente rejetée', () {
      final t = _validTemplate(destinationKey: 'bangkok');
      expect(
        t.validateAgainstDestination(di).any((e) => e.contains(
            'destination_key "bangkok" does not match DI '
            'destinationKey "singapore"')),
        isTrue,
      );
    });

    test('primaryZoneName inconnu rejeté', () {
      final t = _validTemplate(primaryZoneName: 'Unknown Zone');
      expect(
        t.validateAgainstDestination(di).any((e) =>
            e.contains('primary_zone_name "Unknown Zone" is not a known '
                'zone')),
        isTrue,
      );
    });

    test('primaryZoneName matche insensible à la casse', () {
      final t = _validTemplate(primaryZoneName: 'marina bay');
      expect(t.validateAgainstDestination(di), isEmpty);
    });

    test('recommendedAnchorKey inconnu rejeté', () {
      final t = _validTemplate(
        recommendedAnchorKeys: const [
          'Gardens by the Bay',
          'Eiffel Tower',
        ],
      );
      expect(
        t.validateAgainstDestination(di).any((e) =>
            e.contains('recommended_anchor_keys[1] "Eiffel Tower" is not '
                'a known anchor')),
        isTrue,
      );
    });

    test('recommendedAnchorKey matche insensible à la casse / trim', () {
      final t = _validTemplate(
        recommendedAnchorKeys: const [
          '  gardens by the bay  ',
          'MARINA BAY SANDS',
        ],
      );
      expect(t.validateAgainstDestination(di), isEmpty);
    });

    test('forbiddenComplexKeys NON vérifié contre DI (hors scope)', () {
      // Template avec complex key fictif → toujours valide côté DI.
      final t = _validTemplate(
        forbiddenComplexKeys: const ['totally_unknown_complex_key'],
      );
      expect(t.validateAgainstDestination(di), isEmpty,
          reason: 'forbidden_complex_keys non vérifié en 4.1');
    });

    test('Sentosa zone connue → primaryZoneName Sentosa accepté', () {
      final t = _validTemplate(
        templateKey: 'sentosa_day',
        primaryZoneName: 'Sentosa',
        recommendedAnchorKeys: const [],
        forbiddenComplexKeys: const [],
      );
      expect(t.validateAgainstDestination(di), isEmpty);
    });
  });

  // ─── 9. Agrégation d'erreurs ─────────────────────────────────────────

  group('Agrégation d\'erreurs', () {
    test('Template massivement invalide → ≥ 5 erreurs en une fois', () {
      final t = DayTemplate(
        templateKey: '',
        destinationKey: '',
        theme: '',
        primaryZoneName: '',
        intensity: DayIntensity.medium,
        recommendedAnchorKeys: const [],
        forbiddenComplexKeys: const [],
        mealStrategy: MealStrategy.mixed,
        slots: const [], // erreur slots vide
        flexibility: 999, // erreur
      );
      final errors = t.validate();
      expect(errors.length, greaterThanOrEqualTo(5));
    });
  });
}
