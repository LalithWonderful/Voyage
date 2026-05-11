// Phase 0 / Tâche 0.3 — Tests unitaires des feature flags.
//
// Tous purement unitaires : pas de réseau, pas de Supabase, pas de
// dépendance externe. Chaque test crée son `FeatureFlags` localement
// (pas de singleton mutable à reset).

import 'package:flutter_test/flutter_test.dart';
import 'package:voyage/config/feature_flags.dart';

void main() {
  group('FeatureFlags — valeurs par défaut', () {
    test('Constructeur const sans arguments → tous false', () {
      const flags = FeatureFlags();
      expect(flags.useDestinationIntelligence, isFalse);
      expect(flags.useSameComplexDedup, isFalse);
      expect(flags.useDestinationScope, isFalse);
      expect(flags.useDayTemplates, isFalse);
    });

    test('FeatureFlags.defaults() → tous false (identique const ctor)',
        () {
      final flags = FeatureFlags.defaults();
      expect(flags.useDestinationIntelligence, isFalse);
      expect(flags.useSameComplexDedup, isFalse);
      expect(flags.useDestinationScope, isFalse);
      expect(flags.useDayTemplates, isFalse);
      // Vérifie équivalence avec const ctor.
      expect(flags, equals(const FeatureFlags()));
    });

    test('FeatureFlags.fromEnvironmentMap({}) → tous false', () {
      final flags = FeatureFlags.fromEnvironmentMap(const {});
      expect(flags.useDestinationIntelligence, isFalse);
      expect(flags.useSameComplexDedup, isFalse);
      expect(flags.useDestinationScope, isFalse);
      expect(flags.useDayTemplates, isFalse);
    });
  });

  group('FeatureFlags — parsing bool depuis env (ENV keys)', () {
    test('Valeurs truthy reconnues : true, TRUE, 1, yes, YES', () {
      final variants = ['true', 'TRUE', 'True', '1', 'yes', 'YES', 'Yes'];
      for (final v in variants) {
        final flags = FeatureFlags.fromEnvironmentMap({
          'USE_DAY_TEMPLATES': v,
        });
        expect(flags.useDayTemplates, isTrue,
            reason: '"$v" doit être parsé comme true');
      }
    });

    test('Valeurs falsy reconnues : false, FALSE, 0, no, NO', () {
      final variants = ['false', 'FALSE', 'False', '0', 'no', 'NO', 'No'];
      for (final v in variants) {
        final flags = FeatureFlags.fromEnvironmentMap({
          'USE_DAY_TEMPLATES': v,
        });
        expect(flags.useDayTemplates, isFalse,
            reason: '"$v" doit être parsé comme false');
      }
    });

    test('Valeur inconnue → défaut false', () {
      final variants = ['maybe', 'oui', 'sometimes', '42', 'truthy'];
      for (final v in variants) {
        final flags = FeatureFlags.fromEnvironmentMap({
          'USE_DAY_TEMPLATES': v,
        });
        expect(flags.useDayTemplates, isFalse,
            reason: '"$v" inconnu → défaut false');
      }
    });

    test('String vide → défaut false (cas String.fromEnvironment absent)',
        () {
      // `const String.fromEnvironment(key)` renvoie '' si non défini.
      // Notre parser doit traiter ça comme "absent" → défaut.
      final flags = FeatureFlags.fromEnvironmentMap(const {
        'USE_DAY_TEMPLATES': '',
      });
      expect(flags.useDayTemplates, isFalse);
    });

    test('Trim whitespace : "  true  " → true', () {
      final flags = FeatureFlags.fromEnvironmentMap(const {
        'USE_DAY_TEMPLATES': '  true  ',
      });
      expect(flags.useDayTemplates, isTrue);
    });

    test('Mix de 4 flags activés indépendamment', () {
      final flags = FeatureFlags.fromEnvironmentMap(const {
        'USE_DESTINATION_INTELLIGENCE': 'true',
        'USE_SAME_COMPLEX_DEDUP': 'false',
        'USE_DESTINATION_SCOPE': '1',
        'USE_DAY_TEMPLATES': 'yes',
      });
      expect(flags.useDestinationIntelligence, isTrue);
      expect(flags.useSameComplexDedup, isFalse);
      expect(flags.useDestinationScope, isTrue);
      expect(flags.useDayTemplates, isTrue);
    });
  });

  group('FeatureFlags — applyOverrides (Supabase preparation)', () {
    test('Clé connue → flag mis à jour (false → true)', () {
      final base = const FeatureFlags();
      final updated = base.applyOverrides({
        'useDayTemplates': true,
      });
      expect(updated.useDayTemplates, isTrue);
      // Autres flags inchangés.
      expect(updated.useDestinationIntelligence, isFalse);
      expect(updated.useSameComplexDedup, isFalse);
      expect(updated.useDestinationScope, isFalse);
    });

    test('Clé connue → flag mis à jour (true → false)', () {
      const base = FeatureFlags(useDayTemplates: true);
      final updated = base.applyOverrides({'useDayTemplates': false});
      expect(updated.useDayTemplates, isFalse);
    });

    test('Clé inconnue → ignorée silencieusement', () {
      const base = FeatureFlags(useDayTemplates: true);
      final updated = base.applyOverrides({
        'unknownFlag': true,
        'useDayTemplates': true, // existant + valeur valide
      });
      expect(updated.useDayTemplates, isTrue);
      // Vérifie que `unknownFlag` n'a pas planté.
      expect(updated.toMap().containsKey('unknownFlag'), isFalse);
    });

    test('Clé absente → conserve la valeur précédente', () {
      const base = FeatureFlags(useDayTemplates: true);
      final updated = base.applyOverrides({
        'useDestinationScope': true,
        // useDayTemplates absent
      });
      expect(updated.useDayTemplates, isTrue,
          reason: 'Absent de overrides → préserve true existant');
      expect(updated.useDestinationScope, isTrue);
    });

    test('Valeur invalide (Map, List, etc.) → préserve valeur', () {
      const base = FeatureFlags(useDayTemplates: true);
      final updated = base.applyOverrides({
        'useDayTemplates': {'not': 'a bool'}, // map, invalide
      });
      expect(updated.useDayTemplates, isTrue,
          reason: 'Valeur invalide → préserve true existant');
    });

    test('Valeur null → préserve valeur', () {
      const base = FeatureFlags(useDayTemplates: true);
      final updated = base.applyOverrides({'useDayTemplates': null});
      expect(updated.useDayTemplates, isTrue);
    });

    test('Coercition bool : String "true" → true', () {
      final updated = const FeatureFlags()
          .applyOverrides({'useDayTemplates': 'true'});
      expect(updated.useDayTemplates, isTrue);
    });

    test('Coercition bool : int 1 → true, int 0 → false', () {
      final a = const FeatureFlags()
          .applyOverrides({'useDayTemplates': 1});
      final b = const FeatureFlags(useDayTemplates: true)
          .applyOverrides({'useDayTemplates': 0});
      expect(a.useDayTemplates, isTrue);
      expect(b.useDayTemplates, isFalse);
    });

    test('Override map vide → instance équivalente', () {
      const base = FeatureFlags(useDayTemplates: true, useDestinationScope: true);
      final updated = base.applyOverrides(const {});
      expect(updated, equals(base));
    });

    test('Override mixte 4 flags', () {
      const base = FeatureFlags();
      final updated = base.applyOverrides({
        'useDestinationIntelligence': true,
        'useSameComplexDedup': 'yes',
        'useDestinationScope': 1,
        'useDayTemplates': false,
      });
      expect(updated.useDestinationIntelligence, isTrue);
      expect(updated.useSameComplexDedup, isTrue);
      expect(updated.useDestinationScope, isTrue);
      expect(updated.useDayTemplates, isFalse);
    });
  });

  group('FeatureFlags — toMap', () {
    test('toMap retourne exactement les 4 flags attendus (keys camelCase)',
        () {
      const flags = FeatureFlags();
      final map = flags.toMap();
      expect(map, hasLength(4));
      expect(map.keys.toSet(), equals({
        'useDestinationIntelligence',
        'useSameComplexDedup',
        'useDestinationScope',
        'useDayTemplates',
      }));
    });

    test('toMap reflète les valeurs courantes', () {
      const flags = FeatureFlags(
        useDestinationIntelligence: true,
        useDayTemplates: true,
      );
      final map = flags.toMap();
      expect(map['useDestinationIntelligence'], isTrue);
      expect(map['useSameComplexDedup'], isFalse);
      expect(map['useDestinationScope'], isFalse);
      expect(map['useDayTemplates'], isTrue);
    });

    test('toMap defaults → tout false', () {
      final map = FeatureFlags.defaults().toMap();
      expect(map.values.every((v) => v == false), isTrue);
    });
  });

  group('FeatureFlags — immutabilité', () {
    test('applyOverrides retourne une NOUVELLE instance', () {
      const base = FeatureFlags();
      final updated = base.applyOverrides({'useDayTemplates': true});
      expect(identical(base, updated), isFalse,
          reason: 'applyOverrides doit créer une nouvelle instance');
    });

    test('L\'instance source n\'est pas modifiée', () {
      const base = FeatureFlags();
      base.applyOverrides({'useDayTemplates': true});
      expect(base.useDayTemplates, isFalse,
          reason: 'Source intacte après applyOverrides');
    });

    test('Multiple applyOverrides chaînés indépendants', () {
      const base = FeatureFlags();
      final a = base.applyOverrides({'useDayTemplates': true});
      final b = base.applyOverrides({'useSameComplexDedup': true});
      // a et b sont indépendants.
      expect(a.useDayTemplates, isTrue);
      expect(a.useSameComplexDedup, isFalse);
      expect(b.useDayTemplates, isFalse);
      expect(b.useSameComplexDedup, isTrue);
      // base reste tout false.
      expect(base, equals(const FeatureFlags()));
    });
  });

  group('FeatureFlags — equality + toString', () {
    test('== et hashCode cohérents pour valeurs identiques', () {
      const a = FeatureFlags(useDayTemplates: true);
      const b = FeatureFlags(useDayTemplates: true);
      expect(a, equals(b));
      expect(a.hashCode, equals(b.hashCode));
    });

    test('== différencie sur 1 flag', () {
      const a = FeatureFlags(useDayTemplates: true);
      const b = FeatureFlags(useDayTemplates: false);
      expect(a, isNot(equals(b)));
    });

    test('toString lisible (Map debug)', () {
      const flags = FeatureFlags(useDayTemplates: true);
      final s = flags.toString();
      expect(s, contains('useDayTemplates'));
      expect(s, contains('true'));
    });
  });
}
