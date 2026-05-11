// Phase 2 / Tâche 2.2 — Tests des données Singapour SameComplexGroup.
//
// Tests purement unitaires : aucun réseau, aucun Supabase, aucune
// dépendance Google Places, aucun framework de mock. Vérifient :
//   - le builder retourne une liste non vide cohérente avec la spec
//   - chaque groupe passe `validate()` sans erreur
//   - les 6 complex_keys attendus sont présents
//   - les aliases minimaux par groupe sont présents
//   - `matchesAlias` fonctionne correctement avec case/accents/ponct
//   - aucun complexKey dupliqué
//   - aucun alias normalisé dupliqué intra-groupe ni inter-groupes
//   - round-trip JSON par groupe préservé

import 'package:flutter_test/flutter_test.dart';
import 'package:voyage/data/complexes/singapore_complexes.dart';
import 'package:voyage/models/same_complex_group.dart';

// ─── Helpers ──────────────────────────────────────────────────────────

SameComplexGroup _byKey(List<SameComplexGroup> groups, String key) =>
    groups.firstWhere((g) => g.complexKey == key,
        orElse: () => throw StateError('Complex "$key" not found'));

Set<String> _normalizedAliases(SameComplexGroup g) =>
    g.aliases.map(normalizeComplexText).toSet();

void main() {
  group('buildSingaporeSameComplexGroups — validation globale', () {
    final groups = buildSingaporeSameComplexGroups();

    test('liste non vide', () {
      expect(groups, isNotEmpty);
    });

    test('chaque groupe passe validate() sans erreur', () {
      for (final g in groups) {
        final errors = g.validate();
        expect(errors, isEmpty,
            reason:
                'Groupe "${g.complexKey}" doit être valide. Erreurs : '
                '$errors');
        expect(g.isValid, isTrue);
      }
    });

    test('chaque groupe a destinationKey == "singapore"', () {
      for (final g in groups) {
        expect(g.destinationKey, equals('singapore'),
            reason: 'Groupe "${g.complexKey}" doit cibler Singapour');
      }
    });

    test('caps cohérents (maxPerDay >= 1, maxPerTrip >= maxPerDay, '
        'priority ∈ [1,5])', () {
      for (final g in groups) {
        expect(g.maxPerDay, greaterThanOrEqualTo(1),
            reason: g.complexKey);
        expect(g.maxPerTrip, greaterThanOrEqualTo(g.maxPerDay),
            reason: g.complexKey);
        expect(g.priority, inInclusiveRange(1, 5),
            reason: g.complexKey);
      }
    });

    test('aliases non vide pour chaque groupe', () {
      for (final g in groups) {
        expect(g.aliases, isNotEmpty, reason: g.complexKey);
      }
    });

    test('placeIds vides en Tâche 2.2 (matching alias only)', () {
      for (final g in groups) {
        expect(g.placeIds, isEmpty,
            reason: 'Groupe "${g.complexKey}" — placeIds doivent rester '
                'vides en Tâche 2.2 (cf. spec)');
      }
    });
  });

  // ─── Présence des 6 complex_keys attendus ────────────────────────────

  group('Présence des 6 complex_keys attendus', () {
    final groups = buildSingaporeSameComplexGroups();
    final keys = groups.map((g) => g.complexKey).toSet();

    const expectedKeys = {
      'sentosa',
      'gardens_by_the_bay',
      'marina_bay_sands',
      'chinatown_heritage',
      'clarke_quay_riverside',
      'orchard_shopping',
    };

    test('au minimum les 6 complex_keys obligatoires', () {
      expect(keys.containsAll(expectedKeys), isTrue,
          reason: 'Manquants : ${expectedKeys.difference(keys)}');
    });

    test('aucun complexKey dupliqué', () {
      final list = groups.map((g) => g.complexKey).toList();
      expect(list.length, equals(keys.length),
          reason:
              'complexKey dupliqué détecté : ${list.length} vs ${keys.length}');
    });
  });

  // ─── Aliases minimaux par groupe ─────────────────────────────────────

  group('Aliases obligatoires par groupe', () {
    final groups = buildSingaporeSameComplexGroups();

    test('sentosa contient Universal Studios / Resorts World / Wings of '
        'Time', () {
      final g = _byKey(groups, 'sentosa');
      expect(g.matchesAlias('Universal Studios Singapore'), isTrue);
      expect(g.matchesAlias('Resorts World Sentosa'), isTrue);
      expect(g.matchesAlias('Wings of Time'), isTrue);
    });

    test('gardens_by_the_bay contient Cloud Forest / Flower Dome / '
        'Supertree Grove', () {
      final g = _byKey(groups, 'gardens_by_the_bay');
      expect(g.matchesAlias('Cloud Forest'), isTrue);
      expect(g.matchesAlias('Flower Dome'), isTrue);
      expect(g.matchesAlias('Supertree Grove'), isTrue);
    });

    test('marina_bay_sands contient ArtScience Museum / SkyPark / '
        'The Shoppes at Marina Bay Sands', () {
      final g = _byKey(groups, 'marina_bay_sands');
      expect(g.matchesAlias('ArtScience Museum'), isTrue);
      expect(g.matchesAlias('SkyPark Observation Deck'), isTrue);
      expect(g.matchesAlias('The Shoppes at Marina Bay Sands'), isTrue);
    });

    test('chinatown_heritage contient Buddha Tooth Relic Temple / '
        'Sri Mariamman / Pagoda Street', () {
      final g = _byKey(groups, 'chinatown_heritage');
      expect(g.matchesAlias('Buddha Tooth Relic Temple'), isTrue);
      expect(g.matchesAlias('Sri Mariamman Temple'), isTrue);
      expect(g.matchesAlias('Pagoda Street'), isTrue);
    });

    test('clarke_quay_riverside contient Boat Quay / Robertson Quay', () {
      final g = _byKey(groups, 'clarke_quay_riverside');
      expect(g.matchesAlias('Boat Quay'), isTrue);
      expect(g.matchesAlias('Robertson Quay'), isTrue);
    });

    test('orchard_shopping contient ION Orchard / Takashimaya / Paragon',
        () {
      final g = _byKey(groups, 'orchard_shopping');
      expect(g.matchesAlias('ION Orchard'), isTrue);
      expect(g.matchesAlias('Takashimaya'), isTrue);
      expect(g.matchesAlias('Paragon'), isTrue);
    });
  });

  // ─── Caps recommandés par groupe ─────────────────────────────────────

  group('Caps recommandés par groupe', () {
    final groups = buildSingaporeSameComplexGroups();

    test('sentosa : 1/2 priority 5', () {
      final g = _byKey(groups, 'sentosa');
      expect(g.maxPerDay, equals(1));
      expect(g.maxPerTrip, equals(2));
      expect(g.priority, equals(5));
    });

    test('gardens_by_the_bay : 1/2 priority 5', () {
      final g = _byKey(groups, 'gardens_by_the_bay');
      expect(g.maxPerDay, equals(1));
      expect(g.maxPerTrip, equals(2));
      expect(g.priority, equals(5));
    });

    test('marina_bay_sands : 1/2 priority 5', () {
      final g = _byKey(groups, 'marina_bay_sands');
      expect(g.maxPerDay, equals(1));
      expect(g.maxPerTrip, equals(2));
      expect(g.priority, equals(5));
    });

    test('chinatown_heritage : 2/3 priority 4 (assouplissement quartier '
        'patrimonial)', () {
      final g = _byKey(groups, 'chinatown_heritage');
      expect(g.maxPerDay, equals(2));
      expect(g.maxPerTrip, equals(3));
      expect(g.priority, equals(4));
    });

    test('clarke_quay_riverside : 1/2 priority 3', () {
      final g = _byKey(groups, 'clarke_quay_riverside');
      expect(g.maxPerDay, equals(1));
      expect(g.maxPerTrip, equals(2));
      expect(g.priority, equals(3));
    });

    test('orchard_shopping : 1/2 priority 3', () {
      final g = _byKey(groups, 'orchard_shopping');
      expect(g.maxPerDay, equals(1));
      expect(g.maxPerTrip, equals(2));
      expect(g.priority, equals(3));
    });
  });

  // ─── Matching alias robuste (casse / ponctuation) ─────────────────────

  group('matchesAlias — robustesse casse / ponctuation', () {
    final groups = buildSingaporeSameComplexGroups();

    test('SENTOSA ISLAND (uppercase) matche sentosa', () {
      final g = _byKey(groups, 'sentosa');
      expect(g.matchesAlias('SENTOSA ISLAND'), isTrue);
    });

    test('sentosa island (lowercase) matche sentosa', () {
      final g = _byKey(groups, 'sentosa');
      expect(g.matchesAlias('sentosa island'), isTrue);
    });

    test('cloud forest (lowercase) matche gardens_by_the_bay', () {
      final g = _byKey(groups, 'gardens_by_the_bay');
      expect(g.matchesAlias('cloud forest'), isTrue);
    });

    test('ARTSCIENCE MUSEUM matche marina_bay_sands', () {
      final g = _byKey(groups, 'marina_bay_sands');
      expect(g.matchesAlias('ARTSCIENCE MUSEUM'), isTrue);
    });

    test('ponctuation différente — "Sentosa-Island" matche', () {
      final g = _byKey(groups, 'sentosa');
      expect(g.matchesAlias('Sentosa-Island'), isTrue);
    });

    test('whitespace multiple — "  S.E.A.   Aquarium  " matche', () {
      final g = _byKey(groups, 'sentosa');
      expect(g.matchesAlias('  S.E.A.   Aquarium  '), isTrue);
    });

    test('alias inconnu ne matche aucun groupe', () {
      for (final g in groups) {
        expect(g.matchesAlias('Eiffel Tower'), isFalse,
            reason: 'Eiffel Tower ne doit pas matcher ${g.complexKey}');
      }
    });

    test('alias d\'un autre groupe ne matche pas', () {
      final sentosa = _byKey(groups, 'sentosa');
      expect(sentosa.matchesAlias('Cloud Forest'), isFalse);
      expect(sentosa.matchesAlias('Marina Bay Sands'), isFalse);

      final gbtb = _byKey(groups, 'gardens_by_the_bay');
      expect(gbtb.matchesAlias('Universal Studios Singapore'), isFalse);
      expect(gbtb.matchesAlias('Paragon'), isFalse);
    });
  });

  // ─── Pas de doublons d'aliases ────────────────────────────────────────

  group('Pas de doublons d\'aliases', () {
    final groups = buildSingaporeSameComplexGroups();

    test('aucun alias normalisé dupliqué intra-groupe '
        '(vérifié aussi par validate())', () {
      for (final g in groups) {
        final normalized = g.aliases.map(normalizeComplexText).toList();
        final set = normalized.toSet();
        expect(set.length, equals(normalized.length),
            reason:
                'Groupe "${g.complexKey}" — alias normalisé dupliqué : '
                '$normalized');
      }
    });

    test('aucun alias normalisé partagé entre groupes', () {
      final seen = <String, String>{};
      for (final g in groups) {
        for (final alias in _normalizedAliases(g)) {
          final prevGroup = seen[alias];
          expect(prevGroup, isNull,
              reason: 'Alias "$alias" partagé entre "${g.complexKey}" '
                  'et "$prevGroup"');
          seen[alias] = g.complexKey;
        }
      }
    });
  });

  // ─── Round-trip JSON par groupe ──────────────────────────────────────

  group('Round-trip JSON par groupe', () {
    final groups = buildSingaporeSameComplexGroups();

    test('toJson() puis fromJson() préserve chaque groupe', () {
      for (final original in groups) {
        final json = original.toJson();
        final decoded = SameComplexGroup.fromJson(json);

        expect(decoded.complexKey, equals(original.complexKey));
        expect(decoded.destinationKey, equals(original.destinationKey));
        expect(decoded.aliases, equals(original.aliases),
            reason: 'aliases mismatch sur ${original.complexKey}');
        expect(decoded.placeIds, equals(original.placeIds));
        expect(decoded.maxPerDay, equals(original.maxPerDay));
        expect(decoded.maxPerTrip, equals(original.maxPerTrip));
        expect(decoded.priority, equals(original.priority));
        expect(decoded.validate(), isEmpty,
            reason: 'Round-trip ${original.complexKey} doit rester valide');
      }
    });
  });
}
