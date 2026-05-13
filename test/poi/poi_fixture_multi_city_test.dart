// POI-2.2 — Tests de validation offline des fixtures multi-villes.
//
// Aucun accès réseau. Aucun write Supabase. Aucun appel Google.

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:voyage/features/poi/tools/poi_fixture_validator.dart';

void main() {
  group('POI Multi-City Fixture Dry-Run', () {
    for (final city in ['paris', 'rome', 'barcelona']) {
      group(city, () {
        late Map<String, dynamic> fixtureJson;
        late PoiDryRunReport report;

        setUpAll(() {
          final file = File('test/fixtures/poi/pilot_pois_$city.json');
          expect(file.existsSync(), isTrue, reason: 'Fixture file for $city not found');
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
          if (report.errors.isNotEmpty) {
            print('❌ Errors for $city (${report.errors.length}):');
            for (final e in report.errors) {
              print('   • $e');
            }
          }
          if (report.warnings.isNotEmpty) {
            print('⚠️ Warnings for $city (${report.warnings.length}):');
            for (final w in report.warnings) {
              print('   • $w');
            }
          }
          print(report.stats);
          expect(
            report.isValid,
            isTrue,
            reason: 'Dry-run for $city found ${report.errors.length} error(s). '
                'See stdout for details.',
          );
        });

        test('fixture contains exactly 1 source', () {
          expect(report.stats.sourceCount, equals(1));
        });

        test('fixture contains expected POI count', () {
          expect(report.stats.poiCount, equals(25));
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

        test('destination is $city only', () {
          expect(report.stats.destinationKeysUsed, equals({city}));
        });

        test('fixture has at least 3 must-see POIs', () {
          expect(report.stats.mustSeeCount, greaterThanOrEqualTo(3));
        });

        test('fixture has at least 5 family-friendly POIs', () {
          expect(report.stats.familyFriendlyCount, greaterThanOrEqualTo(5));
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
      });
    }
  });
}
