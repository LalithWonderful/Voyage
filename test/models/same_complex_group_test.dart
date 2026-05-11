// Phase 2 / Tâche 2.1 — Tests unitaires SameComplexGroup.
//
// Tests purement unitaires : aucun réseau, aucun Supabase, aucune
// dépendance Google Places. Tous les groupes sont construits en
// mémoire.

import 'package:flutter_test/flutter_test.dart';
import 'package:voyage/models/same_complex_group.dart';

// ─── Helper builder ────────────────────────────────────────────────────

SameComplexGroup _validFixture({
  String complexKey = 'sentosa',
  String destinationKey = 'singapore',
  List<String>? aliases,
  List<String>? placeIds,
  int maxPerDay = 1,
  int maxPerTrip = 2,
  int priority = 5,
}) {
  return SameComplexGroup(
    complexKey: complexKey,
    destinationKey: destinationKey,
    aliases: aliases ??
        const [
          'Sentosa Island',
          'Universal Studios Singapore',
          'Resorts World Sentosa',
        ],
    placeIds: placeIds ?? const [],
    maxPerDay: maxPerDay,
    maxPerTrip: maxPerTrip,
    priority: priority,
  );
}

void main() {
  // ─── 1. Modèle valide ────────────────────────────────────────────────

  group('Modèle valide', () {
    test('Sentosa fixture passe validate() sans erreur', () {
      final g = _validFixture();
      expect(g.validate(), isEmpty);
      expect(g.isValid, isTrue);
    });

    test('Place_ids vide est accepté', () {
      final g = _validFixture(placeIds: const []);
      expect(g.validate(), isEmpty);
    });

    test('Place_ids présents acceptés (non vides, sans doublons)', () {
      final g = _validFixture(placeIds: const ['ChIJxxxx', 'ChIJyyyy']);
      expect(g.validate(), isEmpty);
    });
  });

  // ─── 2. Round-trip JSON ──────────────────────────────────────────────

  group('Round-trip JSON', () {
    test('toJson() puis fromJson() conserve toutes les valeurs', () {
      final original = _validFixture(
        placeIds: const ['ChIJ_sentosa_id', 'ChIJ_universal_id'],
        priority: 5,
      );
      final json = original.toJson();
      final decoded = SameComplexGroup.fromJson(json);

      expect(decoded.complexKey, equals(original.complexKey));
      expect(decoded.destinationKey, equals(original.destinationKey));
      expect(decoded.aliases, equals(original.aliases));
      expect(decoded.placeIds, equals(original.placeIds));
      expect(decoded.maxPerDay, equals(original.maxPerDay));
      expect(decoded.maxPerTrip, equals(original.maxPerTrip));
      expect(decoded.priority, equals(original.priority));
      expect(decoded.validate(), isEmpty);
    });

    test('JSON utilise snake_case (clés)', () {
      final json = _validFixture().toJson();
      expect(json.keys, containsAll(<String>[
        'complex_key',
        'destination_key',
        'aliases',
        'place_ids',
        'max_per_day',
        'max_per_trip',
        'priority',
      ]));
    });

    test('fromJson() lève FormatException sur clé manquante', () {
      expect(() => SameComplexGroup.fromJson(<String, dynamic>{
            'destination_key': 'singapore',
            'aliases': ['x'],
          }),
          throwsA(isA<FormatException>()));
    });

    test('fromJson() lève FormatException sur aliases non liste', () {
      expect(
          () => SameComplexGroup.fromJson(<String, dynamic>{
                'complex_key': 'sentosa',
                'destination_key': 'singapore',
                'aliases': 'Sentosa Island',
              }),
          throwsA(isA<FormatException>()));
    });

    test('fromJson() applique les defaults sur place_ids/maxs/priority '
        'manquants', () {
      final decoded = SameComplexGroup.fromJson(<String, dynamic>{
        'complex_key': 'gardens_by_the_bay',
        'destination_key': 'singapore',
        'aliases': ['Gardens by the Bay'],
      });
      expect(decoded.placeIds, isEmpty);
      expect(decoded.maxPerDay, equals(SameComplexGroup.defaultMaxPerDay));
      expect(decoded.maxPerTrip, equals(SameComplexGroup.defaultMaxPerTrip));
      expect(decoded.priority, equals(SameComplexGroup.defaultPriority));
      expect(decoded.validate(), isEmpty);
    });
  });

  // ─── 3. Defaults ─────────────────────────────────────────────────────

  group('Defaults', () {
    test('maxPerDay default = 1', () {
      final g = SameComplexGroup(
        complexKey: 'sentosa',
        destinationKey: 'singapore',
        aliases: const ['Sentosa Island'],
      );
      expect(g.maxPerDay, equals(1));
    });

    test('maxPerTrip default = 2', () {
      final g = SameComplexGroup(
        complexKey: 'sentosa',
        destinationKey: 'singapore',
        aliases: const ['Sentosa Island'],
      );
      expect(g.maxPerTrip, equals(2));
    });

    test('priority default = 3', () {
      final g = SameComplexGroup(
        complexKey: 'sentosa',
        destinationKey: 'singapore',
        aliases: const ['Sentosa Island'],
      );
      expect(g.priority, equals(3));
    });

    test('Defaults exposés comme constantes statiques', () {
      expect(SameComplexGroup.defaultMaxPerDay, equals(1));
      expect(SameComplexGroup.defaultMaxPerTrip, equals(2));
      expect(SameComplexGroup.defaultPriority, equals(3));
      expect(SameComplexGroup.minPriority, equals(1));
      expect(SameComplexGroup.maxPriority, equals(5));
    });
  });

  // ─── 4. Validation ───────────────────────────────────────────────────

  group('Validation', () {
    test('complexKey vide rejeté', () {
      final g = _validFixture(complexKey: '');
      expect(g.validate(), contains('complex_key must be non-empty'));
    });

    test('complexKey avec whitespace rejeté', () {
      final g = _validFixture(complexKey: 'sentosa island');
      expect(
        g.validate().any((e) => e.contains('whitespace')),
        isTrue,
      );
    });

    test('complexKey avec espace trailing rejeté', () {
      final g = _validFixture(complexKey: 'sentosa ');
      expect(
        g.validate().any((e) => e.contains('whitespace')),
        isTrue,
      );
    });

    test('destinationKey vide rejeté', () {
      final g = _validFixture(destinationKey: '');
      expect(g.validate(), contains('destination_key must be non-empty'));
    });

    test('aliases vide rejeté', () {
      final g = _validFixture(aliases: const []);
      expect(
          g.validate(), contains('aliases must have at least one entry'));
    });

    test('alias individuel vide rejeté', () {
      final g = _validFixture(
          aliases: const ['Sentosa Island', '   ', 'Universal Studios']);
      expect(
        g.validate().any((e) => e.startsWith('aliases[1] must be non-empty')),
        isTrue,
      );
    });

    test('placeId vide rejeté', () {
      final g = _validFixture(placeIds: const ['ChIJxxxx', '  ', 'ChIJyyyy']);
      expect(
        g.validate().any((e) => e.startsWith('place_ids[1] must be non-empty')),
        isTrue,
      );
    });

    test('maxPerDay = 0 rejeté', () {
      final g = _validFixture(maxPerDay: 0);
      expect(
        g.validate().any((e) => e.startsWith('max_per_day must be >= 1')),
        isTrue,
      );
    });

    test('maxPerDay négatif rejeté', () {
      final g = _validFixture(maxPerDay: -1);
      expect(
        g.validate().any((e) => e.startsWith('max_per_day must be >= 1')),
        isTrue,
      );
    });

    test('maxPerTrip = 0 rejeté', () {
      final g = _validFixture(maxPerTrip: 0);
      expect(
        g.validate().any((e) => e.startsWith('max_per_trip must be >= 1')),
        isTrue,
      );
    });

    test('maxPerTrip < maxPerDay rejeté', () {
      final g = _validFixture(maxPerDay: 3, maxPerTrip: 2);
      expect(
        g.validate().any((e) => e.contains('max_per_trip (2) must be >= '
            'max_per_day (3)')),
        isTrue,
      );
    });

    test('priority 0 rejeté', () {
      final g = _validFixture(priority: 0);
      expect(
        g.validate().any((e) => e.startsWith('priority must be in [1, 5]')),
        isTrue,
      );
    });

    test('priority 6 rejeté', () {
      final g = _validFixture(priority: 6);
      expect(
        g.validate().any((e) => e.startsWith('priority must be in [1, 5]')),
        isTrue,
      );
    });

    test('priority négative rejetée', () {
      final g = _validFixture(priority: -3);
      expect(
        g.validate().any((e) => e.startsWith('priority must be in [1, 5]')),
        isTrue,
      );
    });

    test('alias doublon après normalisation rejeté', () {
      final g = _validFixture(aliases: const [
        'Sentosa Island',
        'SENTOSA ISLAND',
        'Universal Studios',
      ]);
      expect(
        g.validate().any((e) => e.contains('duplicates a previous alias')),
        isTrue,
      );
    });

    test('alias doublon via ponctuation différente rejeté', () {
      final g = _validFixture(aliases: const [
        'Sentosa-Island',
        'Sentosa Island!',
      ]);
      expect(
        g.validate().any((e) => e.contains('duplicates a previous alias')),
        isTrue,
      );
    });

    test('placeId doublon rejeté', () {
      final g = _validFixture(
          placeIds: const ['ChIJxxxx', 'ChIJyyyy', 'ChIJxxxx']);
      expect(
        g.validate()
            .any((e) => e.contains('duplicates a previous place_id')),
        isTrue,
      );
    });

    test('placeId doublon via whitespace rejeté', () {
      final g = _validFixture(
          placeIds: const ['ChIJxxxx', '  ChIJxxxx  ']);
      expect(
        g.validate()
            .any((e) => e.contains('duplicates a previous place_id')),
        isTrue,
      );
    });

    test('validate() agrège plusieurs erreurs en une seule liste', () {
      final g = SameComplexGroup(
        complexKey: '',
        destinationKey: '',
        aliases: const [],
        placeIds: const [''],
        maxPerDay: 0,
        maxPerTrip: 0,
        priority: 99,
      );
      final errors = g.validate();
      expect(errors.length, greaterThanOrEqualTo(5));
    });
  });

  // ─── 5. Normalisation ────────────────────────────────────────────────

  group('normalizeComplexText', () {
    test('lowercase', () {
      expect(normalizeComplexText('SENTOSA ISLAND'),
          equals('sentosa island'));
    });

    test('trim leading/trailing', () {
      expect(normalizeComplexText('  Sentosa Island  '),
          equals('sentosa island'));
    });

    test('collapse espaces multiples', () {
      expect(normalizeComplexText('Sentosa   Island'),
          equals('sentosa island'));
    });

    test('apostrophe et accents — "Musée d\'Orsay"', () {
      expect(normalizeComplexText("Musée d'Orsay"),
          equals('musee d orsay'));
    });

    test('ponctuation et tirets — "Gardens-by-the Bay!"', () {
      expect(normalizeComplexText('Gardens-by-the Bay!'),
          equals('gardens by the bay'));
    });

    test('accents français/européens courants', () {
      expect(normalizeComplexText('Café Niçois'), equals('cafe nicois'));
      expect(normalizeComplexText('À côté du château'),
          equals('a cote du chateau'));
      expect(normalizeComplexText('São Paulo'), equals('sao paulo'));
      expect(normalizeComplexText('Köln'), equals('koln'));
      expect(normalizeComplexText('München'), equals('munchen'));
    });

    test('digrammes ae/oe/ss', () {
      expect(normalizeComplexText('Æther'), equals('aether'));
      expect(normalizeComplexText('Œuvre'), equals('oeuvre'));
      expect(normalizeComplexText('Straße'), equals('strasse'));
    });

    test('chiffres conservés', () {
      expect(normalizeComplexText('Pier 39'), equals('pier 39'));
      expect(normalizeComplexText('Studio 54!'), equals('studio 54'));
    });

    test('chaîne vide → vide', () {
      expect(normalizeComplexText(''), equals(''));
    });

    test('uniquement ponctuation → vide', () {
      expect(normalizeComplexText('!!! --- ???'), equals(''));
    });

    test('idempotence', () {
      const inputs = [
        'SENTOSA ISLAND',
        "Musée d'Orsay",
        'Gardens-by-the Bay!',
        'Café Niçois',
      ];
      for (final input in inputs) {
        final once = normalizeComplexText(input);
        final twice = normalizeComplexText(once);
        expect(twice, equals(once), reason: 'normalize("$input") must be '
            'idempotent');
      }
    });
  });

  // ─── 6. matchesAlias ─────────────────────────────────────────────────

  group('matchesAlias', () {
    final g = _validFixture();

    test('match case-insensitive', () {
      expect(g.matchesAlias('SENTOSA ISLAND'), isTrue);
      expect(g.matchesAlias('sentosa island'), isTrue);
      expect(g.matchesAlias('Sentosa Island'), isTrue);
    });

    test('match avec whitespace/punctuation différents', () {
      expect(g.matchesAlias('  Sentosa   Island  '), isTrue);
      expect(g.matchesAlias('Sentosa-Island'), isTrue);
    });

    test('alias hors liste ne matche pas', () {
      expect(g.matchesAlias('Gardens by the Bay'), isFalse);
      expect(g.matchesAlias('Marina Bay Sands'), isFalse);
    });

    test('chaîne vide ne matche jamais', () {
      expect(g.matchesAlias(''), isFalse);
      expect(g.matchesAlias('   '), isFalse);
    });

    test('substring strict ne matche pas (pas de fuzzy en 2.1)', () {
      expect(g.matchesAlias('Sentosa'), isFalse);
      expect(g.matchesAlias('Universal Studios'), isFalse);
    });

    test('alias avec accent côté candidat', () {
      final gAccent = _validFixture(aliases: const ["Musée d'Orsay"]);
      expect(gAccent.matchesAlias("Musee d'Orsay"), isTrue);
      expect(gAccent.matchesAlias('MUSEE D ORSAY'), isTrue);
    });
  });

  // ─── 7. containsPlaceId ──────────────────────────────────────────────

  group('containsPlaceId', () {
    final g = _validFixture(
        placeIds: const ['ChIJxxxx', 'ChIJyyyy', 'ChIJzzzz']);

    test('match exact', () {
      expect(g.containsPlaceId('ChIJxxxx'), isTrue);
      expect(g.containsPlaceId('ChIJyyyy'), isTrue);
      expect(g.containsPlaceId('ChIJzzzz'), isTrue);
    });

    test('match avec whitespace avant/après', () {
      expect(g.containsPlaceId('  ChIJxxxx  '), isTrue);
      expect(g.containsPlaceId('\tChIJyyyy\n'), isTrue);
    });

    test('case-sensitive (placeId Google sont case-sensitive)', () {
      expect(g.containsPlaceId('chijxxxx'), isFalse);
      expect(g.containsPlaceId('CHIJXXXX'), isFalse);
    });

    test('placeId inconnu ne matche pas', () {
      expect(g.containsPlaceId('ChIJ_unknown'), isFalse);
    });

    test('chaîne vide ne matche jamais', () {
      expect(g.containsPlaceId(''), isFalse);
      expect(g.containsPlaceId('   '), isFalse);
    });

    test('groupe sans placeIds → toujours false', () {
      final empty = _validFixture(placeIds: const []);
      expect(empty.containsPlaceId('ChIJxxxx'), isFalse);
    });
  });
}
