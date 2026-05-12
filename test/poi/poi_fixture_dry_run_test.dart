// POI-0.2 — Tests de validation offline du fixture Singapour.
//
// Aucun accès réseau. Aucun write Supabase. Aucun appel Google.
// Le test charge le fixture JSON depuis le disque et exécute le
// validateur offline. Toute erreur bloque le test.
//
// Commande :
//   flutter test test/poi/poi_fixture_dry_run_test.dart

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:voyage/features/poi/tools/poi_fixture_validator.dart';

void main() {
  group('POI Fixture Dry-Run', () {
    late Map<String, dynamic> fixtureJson;
    late PoiDryRunReport report;

    setUpAll(() {
      final file = File('test/fixtures/poi/sample_pois_singapore.json');
      expect(file.existsSync(), isTrue, reason: 'Fixture file not found');
      final content = file.readAsStringSync();
      fixtureJson = json.decode(content) as Map<String, dynamic>;
      report = PoiFixtureValidator().validate(fixtureJson);
    });

    test('fixture parses successfully', () {
      expect(fixtureJson, isA<Map<String, dynamic>>());
      expect(fixtureJson['sources'], isA<List>());
      expect(fixtureJson['pois'], isA<List>());
    });

    test('dry-run produces zero errors', () {
      // Affichage explicite pour le log de CI / console
      if (report.errors.isNotEmpty) {
        print('❌ Errors (${report.errors.length}):');
        for (final e in report.errors) {
          print('   • $e');
        }
      }
      if (report.warnings.isNotEmpty) {
        print('⚠️ Warnings (${report.warnings.length}):');
        for (final w in report.warnings) {
          print('   • $w');
        }
      }
      print(report.stats);
      expect(
        report.isValid,
        isTrue,
        reason: 'Dry-run found ${report.errors.length} error(s). '
            'See stdout for details.',
      );
    });

    test('fixture contains expected sources', () {
      expect(report.stats.sourceCount, equals(2));
    });

    test('fixture contains expected POIs', () {
      expect(report.stats.poiCount, equals(8));
    });

    test('all categories used are in the allowed taxonomy', () {
      for (final cat in report.stats.categoriesUsed) {
        expect(
          PoiFixtureValidator.allowedCategories,
          contains(cat),
          reason: 'Category "$cat" is not in the allowed taxonomy',
        );
      }
    });

    test('all source types are allowed', () {
      final sources = (fixtureJson['sources'] as List).cast<Map<String, dynamic>>();
      for (final src in sources) {
        final st = src['source_type'] as String;
        expect(
          PoiFixtureValidator.allowedSourceTypes,
          contains(st),
          reason: 'Source type "$st" is not allowed',
        );
      }
    });

    test('destination is singapore only', () {
      expect(report.stats.destinationKeysUsed, equals({'singapore'}));
    });

    test('must-see count matches expectation', () {
      expect(report.stats.mustSeeCount, equals(3));
    });

    test('family-friendly count matches expectation', () {
      expect(report.stats.familyFriendlyCount, equals(8));
    });

    test('complex group keys are tracked', () {
      expect(report.stats.complexGroupKeysUsed, contains('sentosa'));
    });

    test('google_place_id is optional and never required', () {
      final pois = (fixtureJson['pois'] as List).cast<Map<String, dynamic>>();
      for (final poi in pois) {
        final gpid = poi['google_place_id'];
        // Null est OK ; String est OK ; tout autre type est interdit.
        expect(
          gpid == null || gpid is String,
          isTrue,
          reason: 'POI "${poi['name']}" has invalid google_place_id type',
        );
      }
    });

    test('google_place_id is unique when non-null', () {
      final ids = <String>{};
      final pois = (fixtureJson['pois'] as List).cast<Map<String, dynamic>>();
      for (final poi in pois) {
        final gpid = poi['google_place_id'];
        if (gpid is String && gpid.isNotEmpty) {
          expect(
            ids.add(gpid),
            isTrue,
            reason: 'Duplicate google_place_id "$gpid" detected',
          );
        }
      }
    });

    test('normalized names match normalization rule', () {
      final pois = (fixtureJson['pois'] as List).cast<Map<String, dynamic>>();
      for (final poi in pois) {
        final name = poi['name'] as String;
        final norm = poi['normalized_name'] as String;
        expect(
          norm,
          equals(PoiFixtureValidator.normalizeName(name)),
          reason: 'Normalized name mismatch for "$name"',
        );
      }
    });

    test('aliases are normalized correctly', () {
      final pois = (fixtureJson['pois'] as List).cast<Map<String, dynamic>>();
      for (final poi in pois) {
        final aliases = (poi['aliases'] as List).cast<Map<String, dynamic>>();
        for (final alias in aliases) {
          final text = alias['alias'] as String;
          final norm = alias['alias_normalized'] as String;
          expect(
            norm,
            equals(PoiFixtureValidator.normalizeName(text)),
            reason: 'Alias normalized mismatch for "$text"',
          );
        }
      }
    });

    test('no duplicate aliases within the same POI', () {
      final pois = (fixtureJson['pois'] as List).cast<Map<String, dynamic>>();
      for (final poi in pois) {
        final aliases = (poi['aliases'] as List).cast<Map<String, dynamic>>();
        final norms = aliases.map((a) => a['alias_normalized'] as String).toList();
        expect(
          norms.toSet().length,
          equals(norms.length),
          reason: 'Duplicate aliases in POI "${poi['name']}"',
        );
      }
    });

    test('all tag categories are allowed when present', () {
      final pois = (fixtureJson['pois'] as List).cast<Map<String, dynamic>>();
      for (final poi in pois) {
        final tags = (poi['tags'] as List).cast<Map<String, dynamic>>();
        for (final tag in tags) {
          final cat = tag['tag_category'];
          if (cat != null) {
            expect(
              PoiFixtureValidator.allowedTagCategories,
              contains(cat as String),
              reason: 'Invalid tag_category "$cat" in POI "${poi['name']}"',
            );
          }
        }
      }
    });

    test('confidence values are within 0..100 when present', () {
      final pois = (fixtureJson['pois'] as List).cast<Map<String, dynamic>>();
      for (final poi in pois) {
        final tags = (poi['tags'] as List).cast<Map<String, dynamic>>();
        for (final tag in tags) {
          final conf = tag['confidence'];
          if (conf != null) {
            expect(
              conf,
              allOf(greaterThanOrEqualTo(0), lessThanOrEqualTo(100)),
              reason: 'Confidence out of range in POI "${poi['name']}"',
            );
          }
        }
      }
    });

    test('same_complex_group_key is string or null', () {
      final pois = (fixtureJson['pois'] as List).cast<Map<String, dynamic>>();
      for (final poi in pois) {
        final scgk = poi['same_complex_group_key'];
        expect(
          scgk == null || scgk is String,
          isTrue,
          reason: 'same_complex_group_key must be string or null '
              'in POI "${poi['name']}"',
        );
      }
    });

    test('coordinates are within valid ranges', () {
      final pois = (fixtureJson['pois'] as List).cast<Map<String, dynamic>>();
      for (final poi in pois) {
        final lat = poi['lat'];
        final lng = poi['lng'];
        if (lat != null) {
          expect(
            lat,
            allOf(greaterThanOrEqualTo(-90.0), lessThanOrEqualTo(90.0)),
            reason: 'Invalid lat for "${poi['name']}"',
          );
        }
        if (lng != null) {
          expect(
            lng,
            allOf(greaterThanOrEqualTo(-180.0), lessThanOrEqualTo(180.0)),
            reason: 'Invalid lng for "${poi['name']}"',
          );
        }
      }
    });

    test('editorial_score and touristic_importance are in valid ranges', () {
      final pois = (fixtureJson['pois'] as List).cast<Map<String, dynamic>>();
      for (final poi in pois) {
        final es = poi['editorial_score'];
        final ti = poi['touristic_importance'];
        if (es != null) {
          expect(
            es,
            allOf(greaterThanOrEqualTo(0), lessThanOrEqualTo(100)),
            reason: 'editorial_score out of range for "${poi['name']}"',
          );
        }
        if (ti != null) {
          expect(
            ti,
            allOf(greaterThanOrEqualTo(1), lessThanOrEqualTo(5)),
            reason: 'touristic_importance out of range for "${poi['name']}"',
          );
        }
      }
    });

    test('dry-run report is JSON-serializable', () {
      final json = report.toJson();
      expect(json['is_valid'], equals(report.isValid));
      expect(json['error_count'], equals(report.errors.length));
      expect(json['warning_count'], equals(report.warnings.length));
      expect(json['stats'], isA<Map<String, dynamic>>());
    });
  });
}
