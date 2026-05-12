// POI-0.3 — Tests de l'importer staging dry-run.
//
// Aucun accès réseau. Aucun write Supabase en l'absence de flag explicite.
// Le test charge le fixture, exécute l'importer en mode dry-run,
// et vérifie le plan d'insertion généré.
//
// Commande :
//   flutter test test/poi/poi_staging_import_test.dart

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:voyage/features/poi/tools/poi_staging_importer.dart';

void main() {
  group('POI Staging Import Dry-Run', () {
    late Map<String, dynamic> fixtureJson;
    late PoiStagingImporter importer;

    setUpAll(() {
      final file = File('test/fixtures/poi/sample_pois_singapore.json');
      expect(file.existsSync(), isTrue);
      fixtureJson =
          json.decode(file.readAsStringSync()) as Map<String, dynamic>;
      importer = PoiStagingImporter();
    });

    test('dry-run default produces report with zero blocking errors', () async {
      final report = await importer.run(fixtureJson);
      expect(report.dryRun, isTrue);
      expect(report.validationPassed, isTrue);
      expect(report.blockingErrors, isEmpty);
      expect(report.canProceed, isTrue);
      expect(report.plan, isNotNull);
      expect(report.writeExecuted, isFalse);
    });

    test('report counts match fixture structure', () async {
      final report = await importer.run(fixtureJson);
      final counts = report.plan!.counts;
      expect(counts['poi_sources'], equals(2));
      expect(counts['pois'], equals(8));
      expect(counts['poi_aliases'], equals(16));
      expect(counts['poi_source_links'], equals(8));
      expect(counts['poi_tags'], equals(24));
      expect(counts['poi_quality_flags'], equals(0));
    });

    test('dry-run never calls writeExecutor even if provided', () async {
      var writeCalled = false;
      Future<void> executor(PoiStagingPlan plan) async {
        writeCalled = true;
      }

      final report = await importer.run(
        fixtureJson,
        dryRun: true,
        writeExecutor: executor,
      );
      expect(report.writeExecuted, isFalse);
      expect(writeCalled, isFalse);
    });

    test('write mode without executor produces blocking error', () async {
      final report = await importer.run(fixtureJson, dryRun: false);
      expect(report.dryRun, isFalse);
      expect(report.writeExecuted, isFalse);
      expect(report.canProceed, isFalse);
      expect(report.blockingErrors, isNotEmpty);
      expect(
        report.blockingErrors.any((e) => e.contains('writeExecutor')),
        isTrue,
        reason: 'Expected error about missing writeExecutor',
      );
    });

    test('write mode with executor succeeds when data is clean', () async {
      var writeCalled = false;
      PoiStagingPlan? capturedPlan;
      Future<void> executor(PoiStagingPlan plan) async {
        writeCalled = true;
        capturedPlan = plan;
      }

      final report = await importer.run(
        fixtureJson,
        dryRun: false,
        writeExecutor: executor,
      );
      expect(report.dryRun, isFalse);
      expect(report.validationPassed, isTrue);
      expect(report.blockingErrors, isEmpty);
      expect(report.canProceed, isTrue);
      expect(report.writeExecuted, isTrue);
      expect(writeCalled, isTrue);
      expect(capturedPlan, isNotNull);
      expect(capturedPlan!.pois.length, equals(8));
    });

    test('write mode blocked if validation fails', () async {
      var writeCalled = false;
      Future<void> executor(PoiStagingPlan plan) async {
        writeCalled = true;
      }

      final badFixture = <String, dynamic>{
        'sources': [],
        'pois': [
          {'poi_id': 'invalid-uuid', 'name': 'Bad'},
        ],
      };
      final report = await importer.run(
        badFixture,
        dryRun: false,
        writeExecutor: executor,
      );
      expect(report.validationPassed, isFalse);
      expect(report.canProceed, isFalse);
      expect(report.writeExecuted, isFalse);
      expect(writeCalled, isFalse);
    });

    test('report is JSON-serializable', () async {
      final report = await importer.run(fixtureJson);
      final json = report.toJson();
      expect(json['dry_run'], isTrue);
      expect(json['validation_passed'], isTrue);
      expect(json['can_proceed'], isTrue);
      expect(json['insert_counts'], isA<Map<String, dynamic>>());
      expect(json['blocking_errors'], isA<List>());
      expect(json['warnings'], isA<List>());
    });

    test('all POI rows contain required SQL fields', () async {
      final report = await importer.run(fixtureJson);
      final pois = report.plan!.pois;
      for (final poi in pois) {
        expect(poi['poi_id'], isNotNull);
        expect(poi['destination_key'], isNotNull);
        expect(poi['name'], isNotNull);
        expect(poi['normalized_name'], isNotNull);
        expect(poi['category'], isNotNull);
        expect(poi['source_primary_id'], isNotNull);
      }
    });

    test('aliases reference existing POIs', () async {
      final report = await importer.run(fixtureJson);
      final poiIds = report.plan!.pois
          .map((p) => p['poi_id'] as String)
          .toSet();
      for (final alias in report.plan!.poiAliases) {
        expect(
          poiIds,
          contains(alias['poi_id']),
          reason: 'Alias references unknown poi_id',
        );
      }
    });

    test('tags reference existing POIs', () async {
      final report = await importer.run(fixtureJson);
      final poiIds = report.plan!.pois
          .map((p) => p['poi_id'] as String)
          .toSet();
      for (final tag in report.plan!.poiTags) {
        expect(
          poiIds,
          contains(tag['poi_id']),
          reason: 'Tag references unknown poi_id',
        );
      }
    });

    test('source links reference existing sources and POIs', () async {
      final report = await importer.run(fixtureJson);
      final sourceIds = report.plan!.poiSources
          .map((s) => s['source_id'] as String)
          .toSet();
      final poiIds = report.plan!.pois
          .map((p) => p['poi_id'] as String)
          .toSet();
      for (final link in report.plan!.poiSourceLinks) {
        expect(sourceIds, contains(link['source_id']));
        expect(poiIds, contains(link['poi_id']));
      }
    });

    test('google_place_id optional and preserved as-is', () async {
      final report = await importer.run(fixtureJson);
      final pois = report.plan!.pois;
      final withGpid = pois.where((p) => p['google_place_id'] != null).length;
      expect(withGpid, equals(0));
      // Tous les POIs doivent quand même être présents
      expect(pois.length, equals(8));
    });

    test('same_complex_group_key preserved when present', () async {
      final report = await importer.run(fixtureJson);
      final withComplex = report.plan!.pois
          .where((p) => p['same_complex_group_key'] != null)
          .toList();
      expect(withComplex.length, equals(2));
      expect(
        withComplex.every((p) => p['same_complex_group_key'] == 'sentosa'),
        isTrue,
      );
    });

    test('plan has no duplicate names per destination', () async {
      final report = await importer.run(fixtureJson);
      final names = <String>{};
      for (final poi in report.plan!.pois) {
        final key = '${poi['destination_key']}|${poi['normalized_name']}';
        expect(
          names.add(key),
          isTrue,
          reason: 'Duplicate name key "$key" in staging plan',
        );
      }
    });

    test('plan has no duplicate poi_id', () async {
      final report = await importer.run(fixtureJson);
      final ids = report.plan!.pois.map((p) => p['poi_id'] as String).toList();
      expect(ids.toSet().length, equals(ids.length));
    });

    test('plan has no duplicate source_id', () async {
      final report = await importer.run(fixtureJson);
      final ids = report.plan!.poiSources
          .map((s) => s['source_id'] as String)
          .toList();
      expect(ids.toSet().length, equals(ids.length));
    });

    test('quality flags empty for clean fixture', () async {
      final report = await importer.run(fixtureJson);
      expect(report.plan!.poiQualityFlags, isEmpty);
    });

    test('fixture has coordinates for all POIs', () async {
      final report = await importer.run(fixtureJson);
      final warnings = report.warnings;
      final missingCoordWarnings = warnings.where(
        (w) => w.contains('no coordinates'),
      );
      expect(missingCoordWarnings, isEmpty);
    });

    test(
      'multiple POIs from same source with empty source_poi_identifier '
      'do not collide',
      () async {
        const sourceId = 'a1b2c3d4-e5f6-7890-abcd-ef1234567890';
        final minimalFixture = <String, dynamic>{
          'sources': [
            {
              'source_id': sourceId,
              'name': 'Test Source',
              'source_type': 'editorial',
              'trust_level': 5,
              'is_active': true,
            },
          ],
          'pois': [
            {
              'poi_id': '11111111-1111-1111-1111-111111111111',
              'destination_key': 'testville',
              'name': 'POI One',
              'normalized_name': 'poi one',
              'category': 'museum',
              'lat': 1.0,
              'lng': 2.0,
              'address': '1 Test St',
              'country_code': 'TV',
              'source_primary_id': sourceId,
              'editorial_score': 80,
              'touristic_importance': 3,
              'is_must_see': false,
              'aliases': [
                {
                  'alias': 'POI One',
                  'alias_normalized': 'poi one',
                  'is_canonical': true,
                },
              ],
              'tags': [
                {
                  'tag': 'indoor',
                  'tag_category': 'activity_type',
                  'confidence': 90,
                },
              ],
            },
            {
              'poi_id': '22222222-2222-2222-2222-222222222222',
              'destination_key': 'testville',
              'name': 'POI Two',
              'normalized_name': 'poi two',
              'category': 'park',
              'lat': 3.0,
              'lng': 4.0,
              'address': '2 Test St',
              'country_code': 'TV',
              'source_primary_id': sourceId,
              'editorial_score': 75,
              'touristic_importance': 3,
              'is_must_see': false,
              'aliases': [
                {
                  'alias': 'POI Two',
                  'alias_normalized': 'poi two',
                  'is_canonical': true,
                },
              ],
              'tags': [
                {
                  'tag': 'outdoor',
                  'tag_category': 'activity_type',
                  'confidence': 85,
                },
              ],
            },
            {
              'poi_id': '33333333-3333-3333-3333-333333333333',
              'destination_key': 'testville',
              'name': 'POI Three',
              'normalized_name': 'poi three',
              'category': 'monument',
              'lat': 5.0,
              'lng': 6.0,
              'address': '3 Test St',
              'country_code': 'TV',
              'source_primary_id': sourceId,
              'editorial_score': 70,
              'touristic_importance': 3,
              'is_must_see': false,
              'aliases': [
                {
                  'alias': 'POI Three',
                  'alias_normalized': 'poi three',
                  'is_canonical': true,
                },
              ],
              'tags': [
                {
                  'tag': 'historic',
                  'tag_category': 'vibe',
                  'confidence': 95,
                },
              ],
            },
          ],
        };

        final report = await importer.run(minimalFixture);
        expect(report.validationPassed, isTrue);
        expect(report.blockingErrors, isEmpty);
        expect(report.canProceed, isTrue);
        expect(report.plan, isNotNull);
        expect(report.plan!.poiSourceLinks.length, equals(3));
        for (final link in report.plan!.poiSourceLinks) {
          expect(link['source_id'], equals(sourceId));
          expect(link['source_poi_identifier'], equals(''));
        }
      },
    );

    test(
      'poi_source_links plan excludes generated column and normalizes '
      'source_poi_identifier for new onConflict target',
      () async {
        const sourceId = 'a1b2c3d4-e5f6-7890-abcd-ef1234567890';
        final minimalFixture = <String, dynamic>{
          'sources': [
            {
              'source_id': sourceId,
              'name': 'Test Source',
              'source_type': 'editorial',
              'trust_level': 5,
              'is_active': true,
            },
          ],
          'pois': [
            {
              'poi_id': '11111111-1111-1111-1111-111111111111',
              'destination_key': 'testville',
              'name': 'POI One',
              'normalized_name': 'poi one',
              'category': 'museum',
              'lat': 1.0,
              'lng': 2.0,
              'address': '1 Test St',
              'country_code': 'TV',
              'source_primary_id': sourceId,
              'editorial_score': 80,
              'touristic_importance': 3,
              'is_must_see': false,
              'aliases': [
                {
                  'alias': 'POI One',
                  'alias_normalized': 'poi one',
                  'is_canonical': true,
                },
              ],
              'tags': [],
            },
          ],
        };

        final report = await importer.run(minimalFixture);
        expect(report.plan, isNotNull);
        expect(report.plan!.poiSourceLinks.length, equals(1));

        final link = report.plan!.poiSourceLinks.first;
        // source_poi_identifier must be normalized to '' so the DB-generated
        // source_poi_identifier_key (coalesce(..., '')) matches for upsert.
        expect(link['source_poi_identifier'], equals(''));
        // The generated column must NOT be in the insert payload.
        expect(link.containsKey('source_poi_identifier_key'), isFalse);
      },
    );
  });
}
