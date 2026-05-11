// Phase 2 / Tâche 2.3 — Tests unitaires ComplexMatcher.
//
// Tests purement unitaires : aucun réseau, aucun Supabase, aucune
// dépendance Google Places, aucun framework de mock. Couvrent :
//   - les 3 stratégies (placeId, exact normalisé, fuzzy > 0.85)
//   - le tie-break priority desc puis complexKey asc
//   - les bornes / null safety
//   - la fonction normalizedStringSimilarity isolée
//   - matchComplexDetailed avec sa stratégie reportée

import 'package:flutter_test/flutter_test.dart';
import 'package:voyage/data/complexes/singapore_complexes.dart';
import 'package:voyage/models/same_complex_group.dart';
import 'package:voyage/services/complex_matcher.dart';

// ─── Helpers ──────────────────────────────────────────────────────────

SameComplexGroup _group(
  String key, {
  String dest = 'fixture_dest',
  List<String>? aliases,
  List<String>? placeIds,
  int maxPerDay = 1,
  int maxPerTrip = 2,
  int priority = 3,
}) =>
    SameComplexGroup(
      complexKey: key,
      destinationKey: dest,
      aliases: aliases ?? <String>['Alias for $key'],
      placeIds: placeIds ?? const <String>[],
      maxPerDay: maxPerDay,
      maxPerTrip: maxPerTrip,
      priority: priority,
    );

void main() {
  // ─── 1. Match exact alias Singapour ──────────────────────────────────

  group('Match exact alias — Singapour', () {
    final groups = buildSingaporeSameComplexGroups();

    test('Buddha Tooth Relic Temple → chinatown_heritage', () {
      expect(matchComplex(name: 'Buddha Tooth Relic Temple', groups: groups),
          equals('chinatown_heritage'));
    });

    test('Universal Studios Singapore → sentosa', () {
      expect(matchComplex(name: 'Universal Studios Singapore', groups: groups),
          equals('sentosa'));
    });

    test('sentosa island (lowercase) → sentosa', () {
      expect(matchComplex(name: 'sentosa island', groups: groups),
          equals('sentosa'));
    });

    test('SENTOSA ISLAND (UPPERCASE) → sentosa', () {
      expect(matchComplex(name: 'SENTOSA ISLAND', groups: groups),
          equals('sentosa'));
    });

    test('Cloud Forest → gardens_by_the_bay', () {
      expect(matchComplex(name: 'Cloud Forest', groups: groups),
          equals('gardens_by_the_bay'));
    });

    test('ArtScience Museum → marina_bay_sands', () {
      expect(matchComplex(name: 'ArtScience Museum', groups: groups),
          equals('marina_bay_sands'));
    });

    test('S.E.A. Aquarium (ponctuation) → sentosa', () {
      expect(matchComplex(name: 'S.E.A. Aquarium', groups: groups),
          equals('sentosa'));
    });

    test('Lieu random → null', () {
      expect(matchComplex(name: 'Eiffel Tower', groups: groups), isNull);
      expect(matchComplex(name: 'Random Museum', groups: groups), isNull);
    });

    test('Stratégie reportée = exactName pour match alias normalisé', () {
      final r = matchComplexDetailed(
          name: 'SENTOSA ISLAND', groups: groups);
      expect(r, isNotNull);
      expect(r!.strategy, equals(ComplexMatchStrategy.exactName));
      expect(r.similarity, equals(1.0));
      expect(r.matchedAlias, equals('sentosa island'));
      expect(r.complexKey, equals('sentosa'));
    });
  });

  // ─── 2. Match placeId ────────────────────────────────────────────────

  group('Match placeId — groupes fictifs', () {
    final groups = <SameComplexGroup>[
      _group('alpha',
          aliases: const ['Alpha Tower'],
          placeIds: const ['ChIJ_alpha_001', 'ChIJ_alpha_002'],
          priority: 3),
      _group('beta',
          aliases: const ['Beta Center'],
          placeIds: const ['ChIJ_beta_001'],
          priority: 5),
    ];

    test('placeId exact → bon complexKey', () {
      expect(matchComplex(placeId: 'ChIJ_alpha_001', groups: groups),
          equals('alpha'));
      expect(matchComplex(placeId: 'ChIJ_beta_001', groups: groups),
          equals('beta'));
    });

    test('placeId avec espaces avant/après matche', () {
      expect(matchComplex(placeId: '  ChIJ_alpha_002  ', groups: groups),
          equals('alpha'));
      expect(matchComplex(placeId: '\tChIJ_beta_001\n', groups: groups),
          equals('beta'));
    });

    test('placeId inconnu → null', () {
      expect(matchComplex(placeId: 'ChIJ_unknown', groups: groups), isNull);
    });

    test('placeId case-sensitive (Google convention)', () {
      expect(matchComplex(placeId: 'chij_alpha_001', groups: groups),
          isNull);
    });

    test('placeId partagé entre 2 groupes → priorité la plus haute gagne',
        () {
      final shared = <SameComplexGroup>[
        _group('cheap',
            aliases: const ['Cheap Place'],
            placeIds: const ['ChIJ_shared'],
            priority: 2),
        _group('iconic',
            aliases: const ['Iconic Place'],
            placeIds: const ['ChIJ_shared'],
            priority: 5),
        _group('middle',
            aliases: const ['Middle Place'],
            placeIds: const ['ChIJ_shared'],
            priority: 3),
      ];
      expect(matchComplex(placeId: 'ChIJ_shared', groups: shared),
          equals('iconic'));
    });

    test('Stratégie reportée = placeId quand match via placeId', () {
      final r = matchComplexDetailed(
          placeId: 'ChIJ_beta_001', groups: groups);
      expect(r, isNotNull);
      expect(r!.strategy, equals(ComplexMatchStrategy.placeId));
      expect(r.similarity, equals(1.0));
      expect(r.matchedAlias, equals(''));
      expect(r.complexKey, equals('beta'));
      expect(r.priority, equals(5));
    });

    test('placeId vide après trim → ignoré, fall-through au name', () {
      final mixed = <SameComplexGroup>[
        _group('alpha', aliases: const ['Alpha Tower'], priority: 3),
      ];
      // placeId vide + name qui matche → on tombe sur le name
      expect(
          matchComplex(placeId: '   ', name: 'Alpha Tower', groups: mixed),
          equals('alpha'));
    });

    test('placeId fourni mais sans match + name non fourni → null', () {
      expect(matchComplex(placeId: 'ChIJ_unknown', groups: groups), isNull);
    });

    test('placeId sans match + name avec match → fall-through OK', () {
      expect(
          matchComplex(
              placeId: 'ChIJ_unknown', name: 'Alpha Tower', groups: groups),
          equals('alpha'));
    });
  });

  // ─── 3. Fuzzy matching ───────────────────────────────────────────────

  group('Fuzzy matching > 0.85', () {
    final groups = buildSingaporeSameComplexGroups();

    test('Universal Studio Singapore (missing s) → sentosa', () {
      expect(
          matchComplex(name: 'Universal Studio Singapore', groups: groups),
          equals('sentosa'));
    });

    test('Garden by the Bay (missing s) → gardens_by_the_bay', () {
      expect(matchComplex(name: 'Garden by the Bay', groups: groups),
          equals('gardens_by_the_bay'));
    });

    test('Resort World Sentosa (missing s) → sentosa', () {
      expect(matchComplex(name: 'Resort World Sentosa', groups: groups),
          equals('sentosa'));
    });

    test('Skyline Luge Sentosa (casse différente) → sentosa via exact',
        () {
      // Note : après normalisation, "Skyline" et "SkyLine" deviennent
      // tous deux "skyline" → exact match, pas fuzzy.
      final r =
          matchComplexDetailed(name: 'Skyline Luge Sentosa', groups: groups);
      expect(r, isNotNull);
      expect(r!.complexKey, equals('sentosa'));
      expect(r.strategy, equals(ComplexMatchStrategy.exactName));
    });

    test('Random Museum → null (similarité trop basse)', () {
      expect(matchComplex(name: 'Random Museum', groups: groups), isNull);
    });

    test('Bay → null (substring permissif rejeté)', () {
      expect(matchComplex(name: 'Bay', groups: groups), isNull);
    });

    test('Stratégie reportée = fuzzyAlias quand match approximatif', () {
      final r =
          matchComplexDetailed(name: 'Garden by the Bay', groups: groups);
      expect(r, isNotNull);
      expect(r!.strategy, equals(ComplexMatchStrategy.fuzzyAlias));
      expect(r.similarity, greaterThan(0.85));
      expect(r.similarity, lessThan(1.0));
      expect(r.matchedAlias, equals('gardens by the bay'));
      expect(r.complexKey, equals('gardens_by_the_bay'));
    });

    test('Seuil strict > 0.85 (pas >= 0.85)', () {
      // Construction artisanale : un alias court où la perte d'une
      // lettre donne pile 0.85 → doit être rejeté.
      // "aaaaa" (5) vs "aaaab" (5) : distance 1 → sim = 1 - 1/5 = 0.8 < 0.85
      // "aaaaaa" (6) vs "aaaaab" (6) : distance 1 → sim = 1 - 1/6 ≈ 0.833 < 0.85
      // "aaaaaaa" (7) vs "aaaaaab" (7) : distance 1 → sim = 1 - 1/7 ≈ 0.857 > 0.85
      final near = <SameComplexGroup>[
        _group('exactly85',
            aliases: const ['aaaaaa'], placeIds: const [], priority: 3),
      ];
      // similarité = 0.833 → < 0.85 → null
      expect(matchComplex(name: 'aaaaab', groups: near), isNull);

      final near2 = <SameComplexGroup>[
        _group('above85',
            aliases: const ['aaaaaaa'], placeIds: const [], priority: 3),
      ];
      // similarité ≈ 0.857 → > 0.85 → match
      expect(matchComplex(name: 'aaaaaab', groups: near2),
          equals('above85'));
    });
  });

  // ─── 4. Priorité et stabilité ────────────────────────────────────────

  group('Tie-break — priorité puis complexKey', () {
    test('exact match : 2 groupes contiennent le même alias → '
        'priority desc gagne', () {
      final groups = <SameComplexGroup>[
        _group('low', aliases: const ['Shared Place'], priority: 2),
        _group('high', aliases: const ['Shared Place'], priority: 5),
        _group('mid', aliases: const ['Shared Place'], priority: 3),
      ];
      expect(matchComplex(name: 'Shared Place', groups: groups),
          equals('high'));
    });

    test('exact match : priorités égales → complexKey asc (stable)', () {
      final groups = <SameComplexGroup>[
        _group('zeta', aliases: const ['Shared Place'], priority: 3),
        _group('alpha', aliases: const ['Shared Place'], priority: 3),
        _group('mike', aliases: const ['Shared Place'], priority: 3),
      ];
      expect(matchComplex(name: 'Shared Place', groups: groups),
          equals('alpha'));
    });

    test('fuzzy match : meilleure similarité gagne quel que soit priority',
        () {
      final groups = <SameComplexGroup>[
        // Plus haute priority mais similarité plus faible
        _group('high_far',
            aliases: const ['Far From Match'],
            priority: 5),
        // Priority basse mais similarité presque parfaite
        _group('low_close',
            aliases: const ['Universal Studio Singapore'],
            priority: 1),
      ];
      // "Universal Studios Singapore" matche le 2e via fuzzy (sim ≈ 0.96)
      expect(
          matchComplex(name: 'Universal Studios Singapore', groups: groups),
          equals('low_close'));
    });

    test('fuzzy match : similarités identiques → priority gagne, puis '
        'complexKey', () {
      // Deux groupes avec exactement le même alias texte → toute
      // similarité fuzzy sera identique (en réalité on tombe sur
      // exactName, qui applique le même tie-break).
      final groups = <SameComplexGroup>[
        _group('zeta',
            aliases: const ['Tied Alias Name'], priority: 3),
        _group('alpha',
            aliases: const ['Tied Alias Name'], priority: 4),
        _group('mike',
            aliases: const ['Tied Alias Name'], priority: 3),
      ];
      // alpha a priority 4 → gagne
      expect(matchComplex(name: 'Tied Alias Name', groups: groups),
          equals('alpha'));
    });
  });

  // ─── 5. Entrées null / vides ─────────────────────────────────────────

  group('Entrées null / vides', () {
    final groups = buildSingaporeSameComplexGroups();

    test('name et placeId tous deux null → null', () {
      expect(matchComplex(groups: groups), isNull);
    });

    test('name vide (string vide) → null si pas de placeId', () {
      expect(matchComplex(name: '', groups: groups), isNull);
    });

    test('name whitespace uniquement → null', () {
      expect(matchComplex(name: '   ', groups: groups), isNull);
      expect(matchComplex(name: '\t\n', groups: groups), isNull);
    });

    test('name uniquement ponctuation → null (normalisation vide)', () {
      expect(matchComplex(name: '!!! ??? ---', groups: groups), isNull);
    });

    test('groups vide → null', () {
      expect(matchComplex(name: 'Cloud Forest', groups: const []), isNull);
      expect(matchComplex(placeId: 'ChIJ_xxx', groups: const []), isNull);
    });

    test('placeId vide + name matchant → fall-through OK', () {
      expect(
          matchComplex(placeId: '', name: 'Cloud Forest', groups: groups),
          equals('gardens_by_the_bay'));
    });
  });

  // ─── 6. normalizedStringSimilarity ───────────────────────────────────

  group('normalizedStringSimilarity', () {
    test('même string → 1.0', () {
      expect(normalizedStringSimilarity('hello', 'hello'), equals(1.0));
      expect(normalizedStringSimilarity('cloud forest', 'cloud forest'),
          equals(1.0));
    });

    test('strings très proches (diff 1 char) → > 0.85', () {
      // 27 chars, distance 1
      expect(
          normalizedStringSimilarity(
              'universal studios singapore', 'universal studio singapore'),
          greaterThan(0.85));
      // 18 chars, distance 1
      expect(
          normalizedStringSimilarity(
              'gardens by the bay', 'garden by the bay'),
          greaterThan(0.85));
    });

    test('strings différentes → < 0.85', () {
      expect(normalizedStringSimilarity('cloud forest', 'random museum'),
          lessThan(0.85));
      expect(normalizedStringSimilarity('bay', 'marina bay sands'),
          lessThan(0.85));
    });

    test('vide vs vide → 1.0 (convention documentée)', () {
      expect(normalizedStringSimilarity('', ''), equals(1.0));
    });

    test('vide vs non-vide → 0.0', () {
      expect(normalizedStringSimilarity('', 'hello'), equals(0.0));
      expect(normalizedStringSimilarity('hello', ''), equals(0.0));
    });

    test('symétrie : similarity(a, b) == similarity(b, a)', () {
      expect(
          normalizedStringSimilarity('hello world', 'helo wrld'),
          equals(
              normalizedStringSimilarity('helo wrld', 'hello world')));
    });

    test('plage [0, 1] strictement respectée', () {
      for (final pair in const [
        ['abc', 'abc'],
        ['abc', 'xyz'],
        ['hello world', 'hello world!'],
        ['', 'x'],
        ['', ''],
      ]) {
        final s = normalizedStringSimilarity(pair[0], pair[1]);
        expect(s, inInclusiveRange(0.0, 1.0),
            reason: 'sim("${pair[0]}", "${pair[1]}") = $s');
      }
    });
  });

  // ─── 7. Ordre des stratégies (placeId beats exact beats fuzzy) ───────

  group('Ordre des stratégies', () {
    test('placeId match préempte tout match name (même fuzzy excellent)',
        () {
      // Le placeId pointe sur "alpha", mais le name pointe exactement
      // sur "beta". Doit retourner "alpha" car placeId vient d'abord.
      final groups = <SameComplexGroup>[
        _group('alpha',
            aliases: const ['Quite Different Alias Here'],
            placeIds: const ['ChIJ_alpha'],
            priority: 1),
        _group('beta',
            aliases: const ['Marina Bay Sands'],
            placeIds: const [],
            priority: 5),
      ];
      final r = matchComplexDetailed(
        placeId: 'ChIJ_alpha',
        name: 'Marina Bay Sands',
        groups: groups,
      );
      expect(r, isNotNull);
      expect(r!.complexKey, equals('alpha'));
      expect(r.strategy, equals(ComplexMatchStrategy.placeId));
    });

    test('exact match préempte fuzzy match (même si fuzzy autre groupe)',
        () {
      final groups = <SameComplexGroup>[
        // alias normalisé "marina bay sand" — fuzzy match pour
        // "Marina Bay Sands"
        _group('fuzzy_only',
            aliases: const ['Marina Bay Sand'], priority: 5),
        // alias exact normalisé
        _group('exact_match',
            aliases: const ['Marina Bay Sands'], priority: 1),
      ];
      final r = matchComplexDetailed(
          name: 'Marina Bay Sands', groups: groups);
      expect(r, isNotNull);
      // Doit gagner par exact, peu importe que fuzzy_only ait priority 5
      expect(r!.complexKey, equals('exact_match'));
      expect(r.strategy, equals(ComplexMatchStrategy.exactName));
    });
  });
}
