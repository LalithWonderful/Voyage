// POI-1.4 — Tests offline de PoiSupabaseImportChecker.
//
// Aucun appel réseau. Le reader est entièrement fake en mémoire.

import 'package:flutter_test/flutter_test.dart';
import 'package:voyage/features/poi/tools/poi_supabase_import_checker.dart';

void main() {
  group('PoiSupabaseImportChecker', () {
    late FakePoiImportCheckReader reader;
    late PoiSupabaseImportChecker checker;

    setUp(() {
      reader = FakePoiImportCheckReader();
      checker = PoiSupabaseImportChecker(reader);
    });

    test('healthy destination reports zero anomalies', () async {
      _seedHealthyLisbon(reader);
      final report = await checker.checkDestination('lisbon');
      expect(report.isHealthy, isTrue);
      expect(report.anomalies, isEmpty);
      expect(report.poiCount, equals(3));
      expect(report.aliasCount, equals(6)); // 2 per POI
      expect(report.linkCount, equals(3));
      expect(report.tagCount, equals(6)); // 2 per POI
      expect(report.flagCount, equals(0));
    });

    test('detects duplicate aliases', () async {
      _seedHealthyLisbon(reader);
      reader.add('poi_aliases', {
        'poi_id': 'p1',
        'alias': 'Duplicate Alias',
        'alias_normalized': 'belém tower',
        'is_canonical': false,
      });
      final report = await checker.checkDestination('lisbon');
      expect(report.isHealthy, isFalse);
      expect(
        report.anomalies.any((a) => a.contains('Duplicate alias')),
        isTrue,
      );
    });

    test('detects duplicate tags', () async {
      _seedHealthyLisbon(reader);
      reader.add('poi_tags', {
        'poi_id': 'p1',
        'tag': 'historic',
        'tag_category': 'vibe',
        'confidence': 80,
      });
      final report = await checker.checkDestination('lisbon');
      expect(report.isHealthy, isFalse);
      expect(
        report.anomalies.any((a) => a.contains('Duplicate tag')),
        isTrue,
      );
    });

    test('detects duplicate quality flags', () async {
      _seedHealthyLisbon(reader);
      reader.add('poi_quality_flags', {
        'poi_id': 'p1',
        'flag_type': 'needs_review',
        'flag_reason': 'price uncertain',
      });
      reader.add('poi_quality_flags', {
        'poi_id': 'p1',
        'flag_type': 'needs_review',
        'flag_reason': 'price uncertain',
      });
      final report = await checker.checkDestination('lisbon');
      expect(report.isHealthy, isFalse);
      expect(
        report.anomalies.any((a) => a.contains('Duplicate quality flag')),
        isTrue,
      );
    });

    test('detects duplicate source links', () async {
      _seedHealthyLisbon(reader);
      reader.add('poi_source_links', {
        'poi_id': 'p1',
        'source_id': 's1',
        'source_poi_identifier': '',
      });
      final report = await checker.checkDestination('lisbon');
      expect(report.isHealthy, isFalse);
      expect(
        report.anomalies.any((a) => a.contains('Duplicate source link')),
        isTrue,
      );
    });

    test('detects POI without canonical alias', () async {
      _seedHealthyLisbon(reader);
      // Remove canonical alias for p1
      final aliases = reader.table('poi_aliases');
      aliases.removeWhere(
        (a) => a['poi_id'] == 'p1' && a['is_canonical'] == true,
      );
      final report = await checker.checkDestination('lisbon');
      expect(report.isHealthy, isFalse);
      expect(
        report.anomalies.any((a) => a.contains('no canonical alias')),
        isTrue,
      );
    });

    test('empty destination is healthy with zero counts', () async {
      final report = await checker.checkDestination('nowhere');
      expect(report.isHealthy, isTrue);
      expect(report.poiCount, equals(0));
      expect(report.aliasCount, equals(0));
      expect(report.linkCount, equals(0));
      expect(report.tagCount, equals(0));
      expect(report.flagCount, equals(0));
    });

    test('report is JSON-serializable', () async {
      _seedHealthyLisbon(reader);
      final report = await checker.checkDestination('lisbon');
      final json = report.toJson();
      expect(json['destination_key'], equals('lisbon'));
      expect(json['is_healthy'], isTrue);
      expect(json['poi_count'], equals(3));
      expect(json['anomalies'], isA<List>());
    });
  });
}

// ═══════════════════════════════════════════════════════════════════
// Helpers
// ═══════════════════════════════════════════════════════════════════

void _seedHealthyLisbon(FakePoiImportCheckReader reader) {
  // Source
  reader.add('poi_sources', {
    'source_id': 's1',
    'name': 'Lunao Pilot Lisbon',
    'source_type': 'editorial',
  });

  // POIs
  reader.add('pois', {
    'poi_id': 'p1',
    'destination_key': 'lisbon',
    'name': 'Belém Tower',
    'normalized_name': 'belém tower',
  });
  reader.add('pois', {
    'poi_id': 'p2',
    'destination_key': 'lisbon',
    'name': 'Jerónimos Monastery',
    'normalized_name': 'jerónimos monastery',
  });
  reader.add('pois', {
    'poi_id': 'p3',
    'destination_key': 'lisbon',
    'name': 'Alfama',
    'normalized_name': 'alfama',
  });

  // Aliases (2 per POI, one canonical)
  reader.add('poi_aliases', {
    'poi_id': 'p1',
    'alias': 'Belém Tower',
    'alias_normalized': 'belém tower',
    'is_canonical': true,
  });
  reader.add('poi_aliases', {
    'poi_id': 'p1',
    'alias': 'Torre de Belém',
    'alias_normalized': 'torre de belém',
    'is_canonical': false,
  });
  reader.add('poi_aliases', {
    'poi_id': 'p2',
    'alias': 'Jerónimos Monastery',
    'alias_normalized': 'jerónimos monastery',
    'is_canonical': true,
  });
  reader.add('poi_aliases', {
    'poi_id': 'p2',
    'alias': 'Mosteiro dos Jerónimos',
    'alias_normalized': 'mosteiro dos jerónimos',
    'is_canonical': false,
  });
  reader.add('poi_aliases', {
    'poi_id': 'p3',
    'alias': 'Alfama',
    'alias_normalized': 'alfama',
    'is_canonical': true,
  });
  reader.add('poi_aliases', {
    'poi_id': 'p3',
    'alias': 'Bairro de Alfama',
    'alias_normalized': 'bairro de alfama',
    'is_canonical': false,
  });

  // Source links (1 per POI)
  reader.add('poi_source_links', {
    'poi_id': 'p1',
    'source_id': 's1',
    'source_poi_identifier': '',
  });
  reader.add('poi_source_links', {
    'poi_id': 'p2',
    'source_id': 's1',
    'source_poi_identifier': '',
  });
  reader.add('poi_source_links', {
    'poi_id': 'p3',
    'source_id': 's1',
    'source_poi_identifier': '',
  });

  // Tags (2 per POI)
  reader.add('poi_tags', {
    'poi_id': 'p1',
    'tag': 'historic',
    'tag_category': 'vibe',
    'confidence': 95,
  });
  reader.add('poi_tags', {
    'poi_id': 'p1',
    'tag': 'riverside',
    'tag_category': 'vibe',
    'confidence': 80,
  });
  reader.add('poi_tags', {
    'poi_id': 'p2',
    'tag': 'historic',
    'tag_category': 'vibe',
    'confidence': 90,
  });
  reader.add('poi_tags', {
    'poi_id': 'p2',
    'tag': 'architecture',
    'tag_category': 'vibe',
    'confidence': 85,
  });
  reader.add('poi_tags', {
    'poi_id': 'p3',
    'tag': 'fado',
    'tag_category': 'vibe',
    'confidence': 85,
  });
  reader.add('poi_tags', {
    'poi_id': 'p3',
    'tag': 'walking',
    'tag_category': 'activity_type',
    'confidence': 90,
  });
}

/// Lightweight in-memory implementation of [PoiImportCheckReader].
class FakePoiImportCheckReader implements PoiImportCheckReader {
  final Map<String, List<Map<String, dynamic>>> _tables = {};

  List<Map<String, dynamic>> table(String name) =>
      _tables.putIfAbsent(name, () => []);

  void add(String tableName, Map<String, dynamic> row) {
    table(tableName).add(Map<String, dynamic>.from(row));
  }

  @override
  Future<int> count(String table, {Map<String, dynamic>? eqFilters}) async {
    var rows = List<Map<String, dynamic>>.from(_tables[table] ?? []);
    eqFilters?.forEach((k, v) {
      rows = rows.where((r) => r[k] == v).toList();
    });
    return rows.length;
  }

  @override
  Future<List<Map<String, dynamic>>> select(
    String table, {
    List<String> columns = const ['*'],
    Map<String, dynamic>? eqFilters,
  }) async {
    var rows = List<Map<String, dynamic>>.from(_tables[table] ?? []);
    eqFilters?.forEach((k, v) {
      rows = rows.where((r) => r[k] == v).toList();
    });
    if (columns.length == 1 && columns.first == '*') {
      return rows;
    }
    return rows.map((r) {
      final projected = <String, dynamic>{};
      for (final col in columns) {
        if (r.containsKey(col)) projected[col] = r[col];
      }
      return projected;
    }).toList();
  }
}
