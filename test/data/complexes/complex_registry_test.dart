// Phase 2 / Tâche 2.4 — Tests unitaires complex_registry.
//
// Tests purement unitaires : aucun réseau, aucun Supabase.

import 'package:flutter_test/flutter_test.dart';
import 'package:voyage/data/complexes/complex_registry.dart';

void main() {
  group('loadLocalComplexGroupsForDestination', () {
    test('Singapore standard resolves to 6 groups', () {
      final groups = loadLocalComplexGroupsForDestination('Singapore');
      expect(groups, isNotEmpty);
      expect(groups.length, equals(6));
    });

    test('Singapore avec country suffix résout aussi', () {
      final groups = loadLocalComplexGroupsForDestination(
          'Singapore, Singapore');
      expect(groups.length, equals(6));
    });

    test('Aliases Singapour (singapour / singapura / sg) acceptés', () {
      expect(
          loadLocalComplexGroupsForDestination('Singapour').length,
          equals(6));
      expect(
          loadLocalComplexGroupsForDestination('singapura').length,
          equals(6));
      expect(
          loadLocalComplexGroupsForDestination('SG').length, equals(6));
    });

    test('Casse mixte robuste', () {
      expect(loadLocalComplexGroupsForDestination('SINGAPORE').length,
          equals(6));
      expect(loadLocalComplexGroupsForDestination('  Singapore  ').length,
          equals(6));
    });

    test('Destination inconnue → []', () {
      expect(loadLocalComplexGroupsForDestination('Bangkok'), isEmpty);
      expect(loadLocalComplexGroupsForDestination('Paris'), isEmpty);
      expect(loadLocalComplexGroupsForDestination('Tokyo, Japan'),
          isEmpty);
    });

    test('Null / vide / whitespace → []', () {
      expect(loadLocalComplexGroupsForDestination(null), isEmpty);
      expect(loadLocalComplexGroupsForDestination(''), isEmpty);
      expect(loadLocalComplexGroupsForDestination('   '), isEmpty);
      expect(loadLocalComplexGroupsForDestination(','), isEmpty);
    });

    test('Tous les groupes Singapore retournés sont valides', () {
      final groups = loadLocalComplexGroupsForDestination('Singapore');
      for (final g in groups) {
        expect(g.validate(), isEmpty,
            reason: 'Groupe ${g.complexKey} doit passer validate()');
      }
    });
  });
}
