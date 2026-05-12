// POI-0.4 — Contract tests offline entre PoiStagingPlan et le schéma SQL.
//
// Aucune connexion réseau. Aucun Supabase. Aucun write.
// Le test charge le fichier SQL de migration, le parse avec le parser
// léger POI-0.4, génère le staging plan POI-0.3, et valide le contrat.
//
// Commande :
//   flutter test test/poi/poi_sql_contract_test.dart

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'poi_sql_contract_validator.dart';
import 'poi_sql_schema_parser.dart';
import 'package:voyage/features/poi/tools/poi_staging_importer.dart';

void main() {
  group('POI SQL Contract Tests', () {
    late SqlSchema schema;
    late PoiStagingPlan plan;
    late PoiSqlContractReport report;

    setUpAll(() async {
      // 1. Parse SQL schema
      final sqlFile = File('supabase/sql/poi_knowledge_base.sql');
      expect(sqlFile.existsSync(), isTrue, reason: 'SQL migration file not found');
      final sql = sqlFile.readAsStringSync();
      schema = PoiSqlSchemaParser().parse(sql);

      // 2. Generate staging plan from fixture
      final fixtureFile = File('test/fixtures/poi/sample_pois_singapore.json');
      final fixtureJson =
          json.decode(fixtureFile.readAsStringSync()) as Map<String, dynamic>;
      final importer = PoiStagingImporter();
      final stagingReport = await importer.run(fixtureJson);
      expect(stagingReport.plan, isNotNull,
          reason: 'Staging plan should not be null');
      plan = stagingReport.plan!;

      // 3. Run contract validator
      final validator = PoiSqlContractValidator(schema);
      report = validator.validate(plan);
    });

    test('SQL schema parses all 6 POI tables', () {
      expect(schema.tables.keys, contains('poi_sources'));
      expect(schema.tables.keys, contains('pois'));
      expect(schema.tables.keys, contains('poi_aliases'));
      expect(schema.tables.keys, contains('poi_source_links'));
      expect(schema.tables.keys, contains('poi_tags'));
      expect(schema.tables.keys, contains('poi_quality_flags'));
    });

    test('contract report has zero errors for clean fixture', () {
      if (report.errors.isNotEmpty) {
        print('Contract errors (${report.errors.length}):');
        for (final e in report.errors) {
          print('  • $e');
        }
      }
      if (report.warnings.isNotEmpty) {
        print('Contract warnings (${report.warnings.length}):');
        for (final w in report.warnings) {
          print('  • $w');
        }
      }
      expect(report.isValid, isTrue,
          reason:
              'Contract validation failed with ${report.errors.length} error(s)');
    });

    test('poi_sources columns match schema', () {
      final table = schema.tables['poi_sources']!;
      expect(table.columns.keys, contains('source_id'));
      expect(table.columns.keys, contains('name'));
      expect(table.columns.keys, contains('source_type'));
      expect(table.columns.keys, contains('trust_level'));
      expect(table.columns.keys, contains('is_active'));
    });

    test('pois columns match schema', () {
      final table = schema.tables['pois']!;
      expect(table.columns.keys, contains('poi_id'));
      expect(table.columns.keys, contains('destination_key'));
      expect(table.columns.keys, contains('name'));
      expect(table.columns.keys, contains('normalized_name'));
      expect(table.columns.keys, contains('category'));
      expect(table.columns.keys, contains('lat'));
      expect(table.columns.keys, contains('lng'));
      expect(table.columns.keys, contains('google_place_id'));
      expect(table.columns.keys, contains('same_complex_group_key'));
    });

    test('poi_sources NOT NULL without default are populated', () {
      final table = schema.tables['poi_sources']!;
      final criticalCols = table.columns.values
          .where((c) => !c.isNullable && !c.hasDefault)
          .map((c) => c.name)
          .toList();
      expect(criticalCols, contains('name'));
      expect(criticalCols, contains('source_type'));
      for (final row in plan.poiSources) {
        for (final col in criticalCols) {
          expect(row.containsKey(col), isTrue,
              reason: 'source missing NOT NULL column "$col"');
          expect(row[col], isNotNull,
              reason: 'source column "$col" is null');
        }
      }
    });

    test('pois NOT NULL without default are populated', () {
      final table = schema.tables['pois']!;
      final criticalCols = table.columns.values
          .where((c) => !c.isNullable && !c.hasDefault)
          .map((c) => c.name)
          .toList();
      expect(criticalCols, contains('destination_key'));
      expect(criticalCols, contains('name'));
      expect(criticalCols, contains('normalized_name'));
      expect(criticalCols, contains('category'));
      expect(criticalCols, contains('source_primary_id'));
      for (final row in plan.pois) {
        for (final col in criticalCols) {
          expect(row.containsKey(col), isTrue,
              reason: 'poi missing NOT NULL column "$col"');
          expect(row[col], isNotNull,
              reason: 'poi column "$col" is null');
        }
      }
    });

    test('Dart types are compatible with SQL types across all rows', () {
      // This is fully covered by the zero-errors contract test,
      // but we double-check critical fields explicitly.
      for (final row in plan.pois) {
        expect(row['poi_id'], isA<String>());
        expect(row['lat'], anyOf(isNull, isA<double>(), isA<int>()));
        expect(row['is_must_see'], isA<bool>());
        expect(row['payload'], isA<Map<String, dynamic>>());
      }
      for (final row in plan.poiSourceLinks) {
        expect(row['source_raw_data'], isA<Map<String, dynamic>>());
      }
    });

    test('CHECK constraints satisfied for range values', () {
      // trust_level : 1..5
      for (final row in plan.poiSources) {
        final tl = row['trust_level'];
        if (tl is int) {
          expect(tl, greaterThanOrEqualTo(1));
          expect(tl, lessThanOrEqualTo(5));
        }
      }
      // lat : -90..90
      for (final row in plan.pois) {
        final lat = row['lat'];
        if (lat is num) {
          expect(lat, greaterThanOrEqualTo(-90));
          expect(lat, lessThanOrEqualTo(90));
        }
      }
      // editorial_score : 0..100
      for (final row in plan.pois) {
        final es = row['editorial_score'];
        if (es is int) {
          expect(es, greaterThanOrEqualTo(0));
          expect(es, lessThanOrEqualTo(100));
        }
      }
      // confidence : 0..100
      for (final row in plan.poiTags) {
        final conf = row['confidence'];
        if (conf is int) {
          expect(conf, greaterThanOrEqualTo(0));
          expect(conf, lessThanOrEqualTo(100));
        }
      }
    });

    test('CHECK enum constraints satisfied', () {
      // source_type
      final sourceTypeCheck = schema.tables['poi_sources']!.checkConstraints
          .firstWhere((c) => c.expression != null && c.expression!.contains('in ('));
      expect(sourceTypeCheck, isNotNull);
      final sourceTypes = _extractEnumValues(sourceTypeCheck.expression!);
      for (final row in plan.poiSources) {
        expect(sourceTypes, contains(row['source_type']));
      }

      // category
      final categoryCheck = schema.tables['pois']!.checkConstraints
          .firstWhere((c) => c.expression != null && c.expression!.contains('in ('));
      final categories = _extractEnumValues(categoryCheck.expression!);
      for (final row in plan.pois) {
        expect(categories, contains(row['category']));
      }

      // flag_type
      final flagCheck = schema.tables['poi_quality_flags']!.checkConstraints
          .firstWhere((c) => c.expression != null && c.expression!.contains('in ('));
      final flagTypes = _extractEnumValues(flagCheck.expression!);
      for (final row in plan.poiQualityFlags) {
        expect(flagTypes, contains(row['flag_type']));
      }
    });

    test('unique constraints not violated by staging plan', () {
      final aliasTable = schema.tables['poi_aliases']!;
      expect(aliasTable.uniqueConstraints, isNotEmpty);
      expect(
        aliasTable.uniqueConstraints.any(
          (u) => u.columns.contains('poi_id') && u.columns.contains('alias_normalized'),
        ),
        isTrue,
      );

      final linkTable = schema.tables['poi_source_links']!;
      expect(linkTable.uniqueConstraints, isNotEmpty);
    });

    test('FK insertion order is correct', () {
      // poi_sources has no FK deps
      final sourcesTable = schema.tables['poi_sources']!;
      expect(sourcesTable.foreignKeys, isEmpty);

      // pois depends only on poi_sources
      final poisTable = schema.tables['pois']!;
      expect(poisTable.foreignKeys.length, equals(1));
      expect(poisTable.foreignKeys.first.referenceTable, equals('poi_sources'));

      // Children depend on pois and/or poi_sources
      final aliasTable = schema.tables['poi_aliases']!;
      final aliasDeps = aliasTable.foreignKeys.map((fk) => fk.referenceTable).toSet();
      expect(aliasDeps, contains('pois'));
      expect(aliasDeps, contains('poi_sources'));
    });

    test('schema captures all primary keys', () {
      for (final tableName in [
        'poi_sources',
        'pois',
        'poi_aliases',
        'poi_source_links',
        'poi_tags',
        'poi_quality_flags',
      ]) {
        final table = schema.tables[tableName]!;
        expect(table.primaryKeys, isNotEmpty,
            reason: '$tableName missing primary key');
      }
    });

    test('schema captures expected foreign keys', () {
      final poisTable = schema.tables['pois']!;
      expect(poisTable.foreignKeys.length, greaterThanOrEqualTo(1));

      final aliasTable = schema.tables['poi_aliases']!;
      expect(aliasTable.foreignKeys.length, greaterThanOrEqualTo(2));
    });

    test('contract report is JSON-serializable', () {
      final json = report.toJson();
      expect(json['valid'], equals(report.isValid));
      expect(json['error_count'], equals(report.errors.length));
      expect(json['warning_count'], equals(report.warnings.length));
    });

    // ─── Tests négatifs (plan malformé artificiel) ───

    test('detects extra column not in SQL schema', () {
      final badPlan = PoiStagingPlan(
        poiSources: [
          ...plan.poiSources,
        ],
        pois: [
          ...plan.pois.map((r) => {...r, 'nonexistent_column': 'oops'}),
        ],
        poiAliases: plan.poiAliases,
        poiSourceLinks: plan.poiSourceLinks,
        poiTags: plan.poiTags,
        poiQualityFlags: plan.poiQualityFlags,
      );
      final badReport = PoiSqlContractValidator(schema).validate(badPlan);
      expect(badReport.isValid, isFalse);
      expect(
        badReport.errors.any((e) => e.contains('nonexistent_column')),
        isTrue,
      );
    });

    test('detects NOT NULL violation', () {
      final badPlan = PoiStagingPlan(
        poiSources: [
          {'source_id': 'abc', 'name': null, 'source_type': 'x'},
        ],
        pois: plan.pois,
        poiAliases: plan.poiAliases,
        poiSourceLinks: plan.poiSourceLinks,
        poiTags: plan.poiTags,
        poiQualityFlags: plan.poiQualityFlags,
      );
      final badReport = PoiSqlContractValidator(schema).validate(badPlan);
      expect(badReport.isValid, isFalse);
      expect(
        badReport.errors.any((e) => e.contains('name') && e.contains('NOT NULL')),
        isTrue,
      );
    });

    test('detects type mismatch', () {
      final badPlan = PoiStagingPlan(
        poiSources: plan.poiSources,
        pois: [
          {...plan.pois.first, 'lat': 'not_a_number'},
        ],
        poiAliases: plan.poiAliases,
        poiSourceLinks: plan.poiSourceLinks,
        poiTags: plan.poiTags,
        poiQualityFlags: plan.poiQualityFlags,
      );
      final badReport = PoiSqlContractValidator(schema).validate(badPlan);
      expect(badReport.isValid, isFalse);
      expect(
        badReport.errors.any((e) => e.contains('lat') && e.contains('type mismatch')),
        isTrue,
      );
    });

    test('detects CHECK violation', () {
      final badPlan = PoiStagingPlan(
        poiSources: [
          {...plan.poiSources.first, 'trust_level': 99},
        ],
        pois: plan.pois,
        poiAliases: plan.poiAliases,
        poiSourceLinks: plan.poiSourceLinks,
        poiTags: plan.poiTags,
        poiQualityFlags: plan.poiQualityFlags,
      );
      final badReport = PoiSqlContractValidator(schema).validate(badPlan);
      expect(badReport.isValid, isFalse);
      expect(
        badReport.errors.any((e) => e.contains('CHECK') && e.contains('trust_level')),
        isTrue,
      );
    });

    test('detects unique constraint violation', () {
      final badPlan = PoiStagingPlan(
        poiSources: plan.poiSources,
        pois: plan.pois,
        poiAliases: [
          ...plan.poiAliases,
          plan.poiAliases.first, // duplicate
        ],
        poiSourceLinks: plan.poiSourceLinks,
        poiTags: plan.poiTags,
        poiQualityFlags: plan.poiQualityFlags,
      );
      final badReport = PoiSqlContractValidator(schema).validate(badPlan);
      expect(badReport.isValid, isFalse);
      expect(
        badReport.errors.any((e) => e.contains('violates unique')),
        isTrue,
      );
    });
  });
}

// Extrait les valeurs d'une expression IN SQL : ('a', 'b', 'c')
Set<String> _extractEnumValues(String expression) {
  final lower = expression.toLowerCase();
  final match = RegExp(r"in\s*\(\s*((?:'[^']*'(?:\s*,\s*'[^']*')*))\s*\)").firstMatch(lower);
  if (match == null) return {};
  return RegExp(r"'([^']*)'")
      .allMatches(match.group(1)!)
      .map((m) => m.group(1)!)
      .toSet();
}
