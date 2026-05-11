// Phase 4 / Tâche 4.5 — Tests unitaires day_template_registry.
//
// Tests purement unitaires : aucun réseau, aucun Supabase.

import 'package:flutter_test/flutter_test.dart';
import 'package:voyage/data/day_templates/day_template_registry.dart';

void main() {
  group('loadLocalDayTemplatesForDestination', () {
    test('Singapore standard → 8 templates', () {
      final t = loadLocalDayTemplatesForDestination('Singapore');
      expect(t.length, equals(8));
    });

    test('Singapore avec country suffix → 8 templates', () {
      final t = loadLocalDayTemplatesForDestination(
          'Singapore, Singapore');
      expect(t.length, equals(8));
    });

    test('Aliases acceptés : singapour / singapura / sg', () {
      expect(loadLocalDayTemplatesForDestination('Singapour').length,
          equals(8));
      expect(loadLocalDayTemplatesForDestination('singapura').length,
          equals(8));
      expect(loadLocalDayTemplatesForDestination('SG').length, equals(8));
    });

    test('Casse mixte robuste', () {
      expect(loadLocalDayTemplatesForDestination('SINGAPORE').length,
          equals(8));
      expect(
          loadLocalDayTemplatesForDestination('  Singapore  ').length,
          equals(8));
    });

    test('Destination inconnue → []', () {
      expect(loadLocalDayTemplatesForDestination('Bangkok'), isEmpty);
      expect(loadLocalDayTemplatesForDestination('Paris'), isEmpty);
      expect(loadLocalDayTemplatesForDestination('Tokyo, Japan'),
          isEmpty);
    });

    test('Null / vide / whitespace → []', () {
      expect(loadLocalDayTemplatesForDestination(null), isEmpty);
      expect(loadLocalDayTemplatesForDestination(''), isEmpty);
      expect(loadLocalDayTemplatesForDestination('   '), isEmpty);
      expect(loadLocalDayTemplatesForDestination(','), isEmpty);
    });

    test('Tous les templates Singapour retournés sont valides', () {
      final t = loadLocalDayTemplatesForDestination('Singapore');
      for (final tpl in t) {
        expect(tpl.validate(), isEmpty,
            reason: '${tpl.templateKey} doit passer validate()');
      }
    });
  });
}
