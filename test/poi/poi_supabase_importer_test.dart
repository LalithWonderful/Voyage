// POI-1.3 — Tests offline de PoiSupabaseImporter.
//
// Aucun appel réseau. Les writes sont testés via un fake executor
// en mémoire pour valider l'idempotence et l'orchestration.
//
// Commande :
//   flutter test test/poi/poi_supabase_importer_test.dart

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:voyage/features/poi/tools/poi_staging_importer.dart';
import 'package:voyage/features/poi/tools/poi_supabase_importer.dart';

void main() {
  group('PoiSupabaseImporter', () {
    late Map<String, dynamic> fixtureJson;
    late PoiSupabaseImporter importer;

    setUpAll(() {
      final file = File('test/fixtures/poi/sample_pois_singapore.json');
      expect(file.existsSync(), isTrue);
      fixtureJson =
          json.decode(file.readAsStringSync()) as Map<String, dynamic>;
    });

    setUp(() {
      importer = PoiSupabaseImporter();
    });

    test('dry-run by default returns validated report without write', () async {
      final report = await importer.import(fixtureJson);
      expect(report.dryRun, isTrue);
      expect(report.validationPassed, isTrue);
      expect(report.canProceed, isTrue);
      expect(report.writeExecuted, isFalse);
      expect(report.plan, isNotNull);
    });

    test('explicit dryRun=true never writes', () async {
      final report = await importer.import(
        fixtureJson,
        dryRun: true,
      );
      expect(report.dryRun, isTrue);
      expect(report.writeExecuted, isFalse);
    });

    test('write blocked without ALLOW_POI_SUPABASE_WRITE opt-in', () async {
      final report = await importer.import(
        fixtureJson,
        dryRun: false,
      );
      expect(report.dryRun, isFalse);
      expect(report.canProceed, isFalse);
      expect(report.writeExecuted, isFalse);
      expect(
        report.blockingErrors.any((e) => e.contains('ALLOW_POI_SUPABASE_WRITE')),
        isTrue,
      );
    });

    test('write blocked when validation fails even with opt-in', () async {
      final badImporter = PoiSupabaseImporter(allowWriteOverride: true);
      final badFixture = <String, dynamic>{
        'sources': [],
        'pois': [
          {'poi_id': 'invalid-uuid', 'name': 'Bad'},
        ],
      };
      final report = await badImporter.import(badFixture, dryRun: false);
      expect(report.validationPassed, isFalse);
      expect(report.canProceed, isFalse);
      expect(report.writeExecuted, isFalse);
    });

    test('write succeeds with opt-in and valid executor', () async {
      var writeCalled = false;
      PoiStagingPlan? capturedPlan;
      Future<void> fakeExecutor(PoiStagingPlan plan) async {
        writeCalled = true;
        capturedPlan = plan;
      }

      final importerWithExecutor = PoiSupabaseImporter(
        allowWriteOverride: true,
        writeExecutor: fakeExecutor,
      );

      final report = await importerWithExecutor.import(
        fixtureJson,
        dryRun: false,
      );
      expect(report.dryRun, isFalse);
      expect(report.validationPassed, isTrue);
      expect(report.canProceed, isTrue);
      expect(report.writeExecuted, isTrue);
      expect(writeCalled, isTrue);
      expect(capturedPlan, isNotNull);
      expect(capturedPlan!.pois.length, equals(8));
    });

    test('report is JSON-serializable', () async {
      final report = await importer.import(fixtureJson);
      final json = report.toJson();
      expect(json['dry_run'], isTrue);
      expect(json['validation_passed'], isTrue);
      expect(json['can_proceed'], isTrue);
      expect(json['insert_counts'], isA<Map<String, dynamic>>());
      expect(json['blocking_errors'], isA<List>());
      expect(json['warnings'], isA<List>());
    });

    test('idempotence: same fixture imported twice does not duplicate', () async {
      final fake = _FakeInMemoryExecutor();
      final idempotentImporter = PoiSupabaseImporter(
        allowWriteOverride: true,
        writeExecutor: fake,
      );

      // Premier import
      final report1 = await idempotentImporter.import(
        fixtureJson,
        dryRun: false,
      );
      expect(report1.canProceed, isTrue);
      expect(report1.writeExecuted, isTrue);

      final counts1 = {
        'poi_sources': fake.count('poi_sources'),
        'pois': fake.count('pois'),
        'poi_aliases': fake.count('poi_aliases'),
        'poi_source_links': fake.count('poi_source_links'),
        'poi_tags': fake.count('poi_tags'),
        'poi_quality_flags': fake.count('poi_quality_flags'),
      };

      // Deuxième import avec le même fixture
      final report2 = await idempotentImporter.import(
        fixtureJson,
        dryRun: false,
      );
      expect(report2.canProceed, isTrue);
      expect(report2.writeExecuted, isTrue);

      final counts2 = {
        'poi_sources': fake.count('poi_sources'),
        'pois': fake.count('pois'),
        'poi_aliases': fake.count('poi_aliases'),
        'poi_source_links': fake.count('poi_source_links'),
        'poi_tags': fake.count('poi_tags'),
        'poi_quality_flags': fake.count('poi_quality_flags'),
      };

      expect(counts2, equals(counts1));
    });

    test('upsert updates existing rows on re-import', () async {
      final fake = _FakeInMemoryExecutor();
      final idempotentImporter = PoiSupabaseImporter(
        allowWriteOverride: true,
        writeExecutor: fake,
      );

      // Premier import
      await idempotentImporter.import(fixtureJson, dryRun: false);
      final firstScore = fake.get('pois', 'poi_id',
          'c3d4e5f6-a7b8-9012-cdef-123456789012')!['editorial_score'];

      // Modifier le fixture (même poi_id, score différent)
      final modifiedFixture = _deepCopy(fixtureJson);
      final pois = (modifiedFixture['pois'] as List).cast<Map<String, dynamic>>();
      final poi = pois.firstWhere(
        (p) => p['poi_id'] == 'c3d4e5f6-a7b8-9012-cdef-123456789012',
      );
      poi['editorial_score'] = 42;

      // Re-importer
      await idempotentImporter.import(modifiedFixture, dryRun: false);
      final updatedScore = fake.get('pois', 'poi_id',
          'c3d4e5f6-a7b8-9012-cdef-123456789012')!['editorial_score'];

      expect(updatedScore, equals(42));
      // Nombre de POIs inchangé
      expect(fake.count('pois'), equals(8));
    });
  });
}

// ═══════════════════════════════════════════════════════════════════
// Fake executor en mémoire simulant l'upsert idempotent
// ═══════════════════════════════════════════════════════════════════

class _FakeInMemoryExecutor {
  final Map<String, List<Map<String, dynamic>>> _tables = {};

  Future<void> call(PoiStagingPlan plan) async {
    _upsert('poi_sources', plan.poiSources, ['source_id']);
    _upsert('pois', plan.pois, ['poi_id']);
    _upsert('poi_aliases', plan.poiAliases, ['poi_id', 'alias_normalized']);
    _upsert(
      'poi_source_links',
      plan.poiSourceLinks,
      ['poi_id', 'source_id', 'source_poi_identifier'],
    );
    _upsert('poi_tags', plan.poiTags, ['poi_id', 'tag']);
    _upsert(
      'poi_quality_flags',
      plan.poiQualityFlags,
      ['poi_id', 'flag_type', 'flag_reason'],
    );
  }

  void _upsert(
    String table,
    List<Map<String, dynamic>> rows,
    List<String> keys,
  ) {
    final existing = _tables.putIfAbsent(table, () => []);
    for (final row in rows) {
      final idx = existing.indexWhere(
        (r) => keys.every((k) => r[k] == row[k]),
      );
      if (idx >= 0) {
        existing[idx] = {...existing[idx], ...row};
      } else {
        existing.add(Map<String, dynamic>.from(row));
      }
    }
  }

  int count(String table) => _tables[table]?.length ?? 0;

  Map<String, dynamic>? get(String table, String keyColumn, dynamic keyValue) {
    final rows = _tables[table];
    if (rows == null) return null;
    try {
      return rows.firstWhere((r) => r[keyColumn] == keyValue);
    } on StateError {
      return null;
    }
  }
}

Map<String, dynamic> _deepCopy(Map<String, dynamic> original) {
  return json.decode(json.encode(original)) as Map<String, dynamic>;
}
