// POI-0.7 — Tests de SupabasePoiRepository avec fake client offline.
//
// Valide que l'implémentation Supabase respecte le contrat PoiRepository
// sans aucun appel réseau, sans credentials, sans supabase_flutter.

import 'package:flutter_test/flutter_test.dart';
import 'package:voyage/features/poi/data/poi_supabase_client.dart';
import 'package:voyage/features/poi/data/supabase_poi_repository.dart';
import 'package:voyage/features/poi/domain/poi.dart';
import 'package:voyage/features/poi/domain/poi_alias.dart';
import 'package:voyage/features/poi/domain/poi_repository.dart';
import 'package:voyage/features/poi/domain/poi_tag.dart';

// ═══════════════════════════════════════════════════════════════════
// Fake client offline
// ═══════════════════════════════════════════════════════════════════

/// Implémentation offline de [PoiSupabaseClient] basée sur des tables
/// en mémoire (`Map<String, List<Map<String, dynamic>>>`).
class FakePoiSupabaseClient implements PoiSupabaseClient {
  final Map<String, List<Map<String, dynamic>>> _tables;

  const FakePoiSupabaseClient({required Map<String, List<Map<String, dynamic>>> tables})
      : _tables = tables;

  @override
  PoiSupabaseQuery from(String table) => FakePoiSupabaseQuery(
        List<Map<String, dynamic>>.from(_tables[table] ?? []),
      );
}

/// Query builder PostgREST minimal résolu en mémoire.
class FakePoiSupabaseQuery implements PoiSupabaseQuery {
  final List<Map<String, dynamic>> _source;
  List<String> _columns = ['*'];
  final List<_EqFilter> _eqFilters = [];
  final List<_IlikeFilter> _ilikeFilters = [];
  String? _orCondition;
  _InFilter? _inFilter;
  final List<_Order> _orders = [];
  int? _limit;

  FakePoiSupabaseQuery(this._source);

  @override
  PoiSupabaseQuery select([List<String>? columns]) {
    _columns = columns ?? ['*'];
    return this;
  }

  @override
  PoiSupabaseQuery eq(String column, dynamic value) {
    _eqFilters.add(_EqFilter(column, value));
    return this;
  }

  @override
  PoiSupabaseQuery ilike(String column, String pattern) {
    _ilikeFilters.add(_IlikeFilter(column, pattern));
    return this;
  }

  @override
  PoiSupabaseQuery or(String conditions) {
    _orCondition = conditions;
    return this;
  }

  @override
  PoiSupabaseQuery inFilter(String column, List<dynamic> values) {
    _inFilter = _InFilter(column, values.toSet());
    return this;
  }

  @override
  PoiSupabaseQuery order(String column, {bool ascending = true}) {
    _orders.add(_Order(column, ascending));
    return this;
  }

  @override
  PoiSupabaseQuery limit(int count) {
    _limit = count;
    return this;
  }

  @override
  Future<List<Map<String, dynamic>>> execute() async {
    var rows = List<Map<String, dynamic>>.from(_source);

    // eq
    for (final f in _eqFilters) {
      rows = rows.where((r) => r[f.column] == f.value).toList();
    }

    // ilike
    for (final f in _ilikeFilters) {
      final re = _patternToRegex(f.pattern);
      rows = rows.where((r) {
        final v = r[f.column];
        return v is String && re.hasMatch(v.toLowerCase());
      }).toList();
    }

    // or
    if (_orCondition != null) {
      final parts = _orCondition!.split(',');
      rows = rows.where((r) {
        for (final part in parts) {
          if (_matchesOrPart(r, part.trim())) return true;
        }
        return false;
      }).toList();
    }

    // inFilter
    if (_inFilter != null) {
      rows = rows.where((r) => _inFilter!.values.contains(r[_inFilter!.column])).toList();
    }

    // order (stable multi-column sort)
    if (_orders.isNotEmpty) {
      rows.sort((a, b) {
        for (final o in _orders) {
          final av = a[o.column];
          final bv = b[o.column];
          int cmp;
          if (av == null && bv == null) {
            cmp = 0;
          } else if (av == null) {
            cmp = o.ascending ? 1 : -1;
          } else if (bv == null) {
            cmp = o.ascending ? -1 : 1;
          } else if (av is Comparable && bv is Comparable) {
            cmp = av.compareTo(bv);
          } else {
            cmp = '$av'.compareTo('$bv');
          }
          if (cmp != 0) {
            return o.ascending ? cmp : -cmp;
          }
        }
        return 0;
      });
    }

    // limit
    if (_limit != null && _limit! > 0 && rows.length > _limit!) {
      rows = rows.sublist(0, _limit!);
    }

    // column projection
    if (_columns.length == 1 && _columns.first == '*') {
      return rows;
    }
    return rows.map((r) {
      final projected = <String, dynamic>{};
      for (final col in _columns) {
        if (r.containsKey(col)) projected[col] = r[col];
      }
      return projected;
    }).toList();
  }

  @override
  Future<Map<String, dynamic>?> maybeSingle() async {
    final rows = await execute();
    return rows.isEmpty ? null : rows.first;
  }

  // ─── Helpers internes ───

  static RegExp _patternToRegex(String pattern) {
    final escaped = pattern
        .replaceAllMapped(RegExp(r'[^a-zA-Z0-9%_]'), (m) => '\\${m[0]}');
    final regexPattern = escaped
        .replaceAll('%', '.*')
        .replaceAll('_', '.');
    return RegExp('^$regexPattern\$', caseSensitive: false);
  }

  static bool _matchesOrPart(Map<String, dynamic> row, String part) {
    // Format attendu : column.op.value
    final firstDot = part.indexOf('.');
    final secondDot = part.indexOf('.', firstDot + 1);
    if (firstDot == -1 || secondDot == -1) return false;

    final column = part.substring(0, firstDot);
    final op = part.substring(firstDot + 1, secondDot);
    final value = part.substring(secondDot + 1);

    final rowValue = row[column];
    if (rowValue == null) return false;

    switch (op) {
      case 'eq':
        return '$rowValue' == value;
      case 'ilike':
        if (rowValue is! String) return false;
        final re = _patternToRegex(value);
        return re.hasMatch(rowValue.toLowerCase());
      default:
        return false;
    }
  }
}

class _EqFilter {
  final String column;
  final dynamic value;
  _EqFilter(this.column, this.value);
}

class _IlikeFilter {
  final String column;
  final String pattern;
  _IlikeFilter(this.column, this.pattern);
}

class _InFilter {
  final String column;
  final Set<dynamic> values;
  _InFilter(this.column, this.values);
}

class _Order {
  final String column;
  final bool ascending;
  _Order(this.column, this.ascending);
}

// ═══════════════════════════════════════════════════════════════════
// Fixture helpers
// ═══════════════════════════════════════════════════════════════════

DateTime _ts(String iso) => DateTime.parse(iso);

Poi _poi({
  required String poiId,
  required String name,
  required String normalizedName,
  required PoiCategory category,
  int? editorialScore,
  bool isMustSee = false,
  String destinationKey = 'singapore',
  String sourcePrimaryId = 'src1',
}) {
  return Poi(
    poiId: poiId,
    destinationKey: destinationKey,
    name: name,
    normalizedName: normalizedName,
    category: category,
    sourcePrimaryId: sourcePrimaryId,
    editorialScore: editorialScore,
    isMustSee: isMustSee,
    createdAt: _ts('2024-01-15T10:00:00Z'),
    updatedAt: _ts('2024-01-15T10:00:00Z'),
  );
}

PoiAlias _alias({
  required String poiId,
  required String alias,
  required String aliasNormalized,
}) {
  return PoiAlias(
    aliasId: 'alias-${aliasNormalized.hashCode}',
    poiId: poiId,
    alias: alias,
    aliasNormalized: aliasNormalized,
    createdAt: _ts('2024-01-15T10:00:00Z'),
  );
}

PoiTag _tag({
  required String poiId,
  required String tag,
  String? tagCategory,
}) {
  return PoiTag(
    tagId: 'tag-${tag.hashCode}-$poiId',
    poiId: poiId,
    tag: tag,
    tagCategory: tagCategory,
    createdAt: _ts('2024-01-15T10:00:00Z'),
  );
}

/// Jeu de données Singapour (5 POIs + aliases + tags).
({
  List<Map<String, dynamic>> pois,
  List<Map<String, dynamic>> aliases,
  List<Map<String, dynamic>> tags,
}) _singaporeFixture() {
  final p1 = _poi(
    poiId: 'poi-001',
    name: 'Gardens by the Bay',
    normalizedName: 'gardens by the bay',
    category: PoiCategory.park,
    editorialScore: 98,
    isMustSee: true,
  );
  final p2 = _poi(
    poiId: 'poi-002',
    name: 'Marina Bay Sands',
    normalizedName: 'marina bay sands',
    category: PoiCategory.mustSee,
    editorialScore: 95,
    isMustSee: true,
  );
  final p3 = _poi(
    poiId: 'poi-003',
    name: 'National Museum of Singapore',
    normalizedName: 'national museum of singapore',
    category: PoiCategory.museum,
    editorialScore: 88,
    isMustSee: false,
  );
  final p4 = _poi(
    poiId: 'poi-004',
    name: 'Sentosa',
    normalizedName: 'sentosa',
    category: PoiCategory.nature,
    editorialScore: 90,
    isMustSee: true,
  );
  final p5 = _poi(
    poiId: 'poi-005',
    name: 'Chinatown',
    normalizedName: 'chinatown',
    category: PoiCategory.neighborhood,
    editorialScore: 75,
    isMustSee: false,
  );

  final aliases = <PoiAlias>[
    _alias(poiId: p1.poiId, alias: 'GBTB', aliasNormalized: 'gbtb'),
    _alias(poiId: p1.poiId, alias: 'Bay South Gardens', aliasNormalized: 'bay south gardens'),
    _alias(poiId: p2.poiId, alias: 'MBS', aliasNormalized: 'mbs'),
    _alias(poiId: p4.poiId, alias: 'Sentosa Island', aliasNormalized: 'sentosa island'),
  ];

  final tags = <PoiTag>[
    _tag(poiId: p1.poiId, tag: 'night_photography', tagCategory: 'vibe'),
    _tag(poiId: p1.poiId, tag: 'indoor_conservatory', tagCategory: 'activity_type'),
    _tag(poiId: p1.poiId, tag: 'wheelchair_accessible', tagCategory: 'accessibility'),
    _tag(poiId: p2.poiId, tag: 'rooftop_view', tagCategory: 'vibe'),
    _tag(poiId: p2.poiId, tag: 'shopping', tagCategory: 'activity_type'),
    _tag(poiId: p2.poiId, tag: 'casino', tagCategory: 'activity_type'),
    _tag(poiId: p3.poiId, tag: 'history', tagCategory: 'activity_type'),
    _tag(poiId: p3.poiId, tag: 'air_conditioned', tagCategory: 'comfort'),
    _tag(poiId: p4.poiId, tag: 'beach', tagCategory: 'activity_type'),
    _tag(poiId: p4.poiId, tag: 'family_friendly', tagCategory: 'audience'),
    _tag(poiId: p5.poiId, tag: 'street_food', tagCategory: 'food'),
    _tag(poiId: p5.poiId, tag: 'cultural', tagCategory: 'vibe'),
  ];

  return (
    pois: [p1, p2, p3, p4, p5].map((p) => p.toJson()).toList(),
    aliases: aliases.map((a) => a.toJson()).toList(),
    tags: tags.map((t) => t.toJson()).toList(),
  );
}

PoiRepository _repo({
  List<Map<String, dynamic>>? pois,
  List<Map<String, dynamic>>? aliases,
  List<Map<String, dynamic>>? tags,
}) {
  return SupabasePoiRepository(
    FakePoiSupabaseClient(
      tables: {
        'pois': pois ?? [],
        'poi_aliases': aliases ?? [],
        'poi_tags': tags ?? [],
      },
    ),
  );
}

// ═══════════════════════════════════════════════════════════════════
// Tests
// ═══════════════════════════════════════════════════════════════════

void main() {
  // ═══════════════════════════════════════════════════════════════════
  // 1. listPoisByDestination
  // ═══════════════════════════════════════════════════════════════════

  group('listPoisByDestination', () {
    test('returns all POIs for known destination ordered by score', () async {
      final fixture = _singaporeFixture();
      final repo = _repo(
        pois: fixture.pois,
        aliases: fixture.aliases,
        tags: fixture.tags,
      );

      final results = await repo.listPoisByDestination('singapore');
      expect(results.length, equals(5));
      expect(results[0].name, equals('Gardens by the Bay'));
      expect(results[1].name, equals('Marina Bay Sands'));
      expect(results[2].name, equals('Sentosa'));
      expect(results[3].name, equals('National Museum of Singapore'));
      expect(results[4].name, equals('Chinatown'));
    });

    test('returns empty for unknown destination', () async {
      final fixture = _singaporeFixture();
      final repo = _repo(pois: fixture.pois);

      final results = await repo.listPoisByDestination('tokyo');
      expect(results, isEmpty);
    });
  });

  // ═══════════════════════════════════════════════════════════════════
  // 2. getPoiById
  // ═══════════════════════════════════════════════════════════════════

  group('getPoiById', () {
    test('returns POI when found', () async {
      final fixture = _singaporeFixture();
      final repo = _repo(pois: fixture.pois);

      final result = await repo.getPoiById('poi-001');
      expect(result, isNotNull);
      expect(result!.name, equals('Gardens by the Bay'));
    });

    test('returns null when not found', () async {
      final fixture = _singaporeFixture();
      final repo = _repo(pois: fixture.pois);

      final result = await repo.getPoiById('poi-999');
      expect(result, isNull);
    });
  });

  // ═══════════════════════════════════════════════════════════════════
  // 3. getTopPoisForDestination
  // ═══════════════════════════════════════════════════════════════════

  group('getTopPoisForDestination', () {
    test('returns top N ordered by score desc', () async {
      final fixture = _singaporeFixture();
      final repo = _repo(pois: fixture.pois);

      final results = await repo.getTopPoisForDestination('singapore', 2);
      expect(results.length, equals(2));
      expect(results[0].name, equals('Gardens by the Bay'));
      expect(results[1].name, equals('Marina Bay Sands'));
    });

    test('limit larger than set returns all', () async {
      final fixture = _singaporeFixture();
      final repo = _repo(pois: fixture.pois);

      final results = await repo.getTopPoisForDestination('singapore', 100);
      expect(results.length, equals(5));
    });

    test('unknown destination returns empty', () async {
      final fixture = _singaporeFixture();
      final repo = _repo(pois: fixture.pois);

      final results = await repo.getTopPoisForDestination('unknown', 3);
      expect(results, isEmpty);
    });
  });

  // ═══════════════════════════════════════════════════════════════════
  // 4. getPoisByCategories
  // ═══════════════════════════════════════════════════════════════════

  group('getPoisByCategories', () {
    test('filters by single category', () async {
      final fixture = _singaporeFixture();
      final repo = _repo(pois: fixture.pois);

      final results = await repo.getPoisByCategories(
        'singapore',
        [PoiCategory.museum],
      );
      expect(results.length, equals(1));
      expect(results.first.name, equals('National Museum of Singapore'));
    });

    test('filters by multiple categories', () async {
      final fixture = _singaporeFixture();
      final repo = _repo(pois: fixture.pois);

      final results = await repo.getPoisByCategories(
        'singapore',
        [PoiCategory.park, PoiCategory.museum],
      );
      final names = results.map((p) => p.name).toList();
      expect(names, contains('Gardens by the Bay'));
      expect(names, contains('National Museum of Singapore'));
    });

    test('empty categories returns empty', () async {
      final fixture = _singaporeFixture();
      final repo = _repo(pois: fixture.pois);

      final results = await repo.getPoisByCategories('singapore', []);
      expect(results, isEmpty);
    });
  });

  // ═══════════════════════════════════════════════════════════════════
  // 5. searchPois — query
  // ═══════════════════════════════════════════════════════════════════

  group('searchPois by query', () {
    late PoiRepository repo;

    setUp(() {
      final fixture = _singaporeFixture();
      repo = _repo(
        pois: fixture.pois,
        aliases: fixture.aliases,
        tags: fixture.tags,
      );
    });

    test('empty query returns all POIs', () async {
      final results = await repo.searchPois(destinationKey: 'singapore');
      expect(results.length, equals(5));
    });

    test('query matches name (case insensitive)', () async {
      final results = await repo.searchPois(
        destinationKey: 'singapore',
        query: 'MARINA',
      );
      expect(results.length, equals(1));
      expect(results.first.name, equals('Marina Bay Sands'));
    });

    test('query matches normalized_name', () async {
      final results = await repo.searchPois(
        destinationKey: 'singapore',
        query: 'gardens by the bay',
      );
      expect(results.length, equals(1));
      expect(results.first.poiId, equals('poi-001'));
    });

    test('query matches alias_normalized', () async {
      final results = await repo.searchPois(
        destinationKey: 'singapore',
        query: 'gbtb',
      );
      expect(results.length, equals(1));
      expect(results.first.poiId, equals('poi-001'));
    });

    test('query matches alias display name', () async {
      final results = await repo.searchPois(
        destinationKey: 'singapore',
        query: 'MBS',
      );
      expect(results.length, equals(1));
      expect(results.first.poiId, equals('poi-002'));
    });

    test('query with no match returns empty', () async {
      final results = await repo.searchPois(
        destinationKey: 'singapore',
        query: 'tokyo tower',
      );
      expect(results, isEmpty);
    });

    test('blank query is treated as no query', () async {
      final results = await repo.searchPois(
        destinationKey: 'singapore',
        query: '   ',
      );
      expect(results.length, equals(5));
    });
  });

  // ═══════════════════════════════════════════════════════════════════
  // 4. searchPois — category filter
  // ═══════════════════════════════════════════════════════════════════

  group('searchPois by category', () {
    test('filters by exact category', () async {
      final fixture = _singaporeFixture();
      final repo = _repo(pois: fixture.pois);

      final results = await repo.searchPois(
        destinationKey: 'singapore',
        category: PoiCategory.museum,
      );
      expect(results.length, equals(1));
      expect(results.first.category, equals(PoiCategory.museum));
    });

    test('category with no match returns empty', () async {
      final fixture = _singaporeFixture();
      final repo = _repo(pois: fixture.pois);

      final results = await repo.searchPois(
        destinationKey: 'singapore',
        category: PoiCategory.beach,
      );
      expect(results, isEmpty);
    });
  });

  // ═══════════════════════════════════════════════════════════════════
  // 5. searchPois — tags filter
  // ═══════════════════════════════════════════════════════════════════

  group('searchPois by tags', () {
    test('filters by single tag', () async {
      final fixture = _singaporeFixture();
      final repo = _repo(
        pois: fixture.pois,
        tags: fixture.tags,
      );

      final results = await repo.searchPois(
        destinationKey: 'singapore',
        tags: ['shopping'],
      );
      expect(results.length, equals(1));
      expect(results.first.poiId, equals('poi-002'));
    });

    test('OR logic on multiple tags', () async {
      final fixture = _singaporeFixture();
      final repo = _repo(
        pois: fixture.pois,
        tags: fixture.tags,
      );

      final results = await repo.searchPois(
        destinationKey: 'singapore',
        tags: ['shopping', 'beach'],
      );
      final ids = results.map((p) => p.poiId).toSet();
      expect(ids, contains('poi-002')); // shopping
      expect(ids, contains('poi-004')); // beach
    });

    test('unknown tag returns empty', () async {
      final fixture = _singaporeFixture();
      final repo = _repo(
        pois: fixture.pois,
        tags: fixture.tags,
      );

      final results = await repo.searchPois(
        destinationKey: 'singapore',
        tags: ['surfing'],
      );
      expect(results, isEmpty);
    });

    test('empty tags list is treated as no filter', () async {
      final fixture = _singaporeFixture();
      final repo = _repo(
        pois: fixture.pois,
        tags: fixture.tags,
      );

      final results = await repo.searchPois(
        destinationKey: 'singapore',
        tags: [],
      );
      expect(results.length, equals(5));
    });
  });

  // ═══════════════════════════════════════════════════════════════════
  // 6. searchPois — mustSeeOnly
  // ═══════════════════════════════════════════════════════════════════

  group('searchPois mustSeeOnly', () {
    test('returns only must-see POIs', () async {
      final fixture = _singaporeFixture();
      final repo = _repo(pois: fixture.pois);

      final results = await repo.searchPois(
        destinationKey: 'singapore',
        mustSeeOnly: true,
      );
      expect(results.length, equals(3));
      for (final p in results) {
        expect(p.isMustSee, isTrue);
      }
    });
  });

  // ═══════════════════════════════════════════════════════════════════
  // 7. searchPois — limit
  // ═══════════════════════════════════════════════════════════════════

  group('searchPois limit', () {
    test('limits results to N', () async {
      final fixture = _singaporeFixture();
      final repo = _repo(pois: fixture.pois);

      final results = await repo.searchPois(
        destinationKey: 'singapore',
        limit: 2,
      );
      expect(results.length, equals(2));
    });
  });

  // ═══════════════════════════════════════════════════════════════════
  // 8. searchPois — combined filters
  // ═══════════════════════════════════════════════════════════════════

  group('searchPois combined filters', () {
    test('query + category + mustSeeOnly', () async {
      final fixture = _singaporeFixture();
      final repo = _repo(
        pois: fixture.pois,
        aliases: fixture.aliases,
        tags: fixture.tags,
      );

      final results = await repo.searchPois(
        destinationKey: 'singapore',
        query: 'bay',
        category: PoiCategory.mustSee,
        mustSeeOnly: true,
      );
      expect(results.length, equals(1));
      expect(results.first.name, equals('Marina Bay Sands'));
    });

    test('tags + limit', () async {
      final fixture = _singaporeFixture();
      final repo = _repo(
        pois: fixture.pois,
        tags: fixture.tags,
      );

      final results = await repo.searchPois(
        destinationKey: 'singapore',
        tags: ['shopping'],
        limit: 1,
      );
      expect(results.length, equals(1));
      expect(results.first.poiId, equals('poi-002'));
    });
  });

  // ═══════════════════════════════════════════════════════════════════
  // 9. Edge cases & determinism
  // ═══════════════════════════════════════════════════════════════════

  group('Edge cases & determinism', () {
    test('empty repository returns empty for all operations', () async {
      final repo = _repo();
      expect(await repo.listPoisByDestination('singapore'), isEmpty);
      expect(await repo.getPoiById('x'), isNull);
      expect(
        await repo.searchPois(destinationKey: 'singapore'),
        isEmpty,
      );
    });

    test('multiple calls return identical results', () async {
      final fixture = _singaporeFixture();
      final repo = _repo(pois: fixture.pois);

      final r1 = await repo.listPoisByDestination('singapore');
      final r2 = await repo.listPoisByDestination('singapore');
      expect(r1.map((p) => p.poiId).toList(),
          equals(r2.map((p) => p.poiId).toList()));
    });

    test('repository is async (returns Future)', () async {
      final fixture = _singaporeFixture();
      final repo = _repo(pois: fixture.pois);

      final future = repo.listPoisByDestination('singapore');
      expect(future, isA<Future<List<Poi>>>());
      await future;
    });
  });

  // ═══════════════════════════════════════════════════════════════════
  // 10. FakePoiSupabaseQuery unit tests
  // ═══════════════════════════════════════════════════════════════════

  group('FakePoiSupabaseQuery primitives', () {
    final rows = [
      {'id': '1', 'name': 'Alice', 'score': 100},
      {'id': '2', 'name': 'Bob', 'score': 50},
      {'id': '3', 'name': 'Charlie', 'score': null},
    ];

    test('eq filter', () async {
      final q = FakePoiSupabaseQuery(rows).eq('name', 'Alice');
      final result = await q.execute();
      expect(result.length, equals(1));
      expect(result.first['id'], equals('1'));
    });

    test('ilike filter with wildcard', () async {
      final q = FakePoiSupabaseQuery(rows).ilike('name', '%li%');
      final result = await q.execute();
      expect(result.length, equals(2)); // Alice, Charlie
    });

    test('or condition', () async {
      final q = FakePoiSupabaseQuery(rows)
          .or('name.ilike.%lice%,name.ilike.%ob%');
      final result = await q.execute();
      expect(result.length, equals(2)); // Alice, Bob
    });

    test('inFilter', () async {
      final q = FakePoiSupabaseQuery(rows).inFilter('id', ['1', '3']);
      final result = await q.execute();
      expect(result.length, equals(2));
    });

    test('order ascending', () async {
      final q = FakePoiSupabaseQuery(rows).order('name', ascending: true);
      final result = await q.execute();
      expect(result.first['name'], equals('Alice'));
      expect(result.last['name'], equals('Charlie'));
    });

    test('order descending with nulls last', () async {
      final q = FakePoiSupabaseQuery(rows).order('score', ascending: false);
      final result = await q.execute();
      expect(result[0]['score'], equals(100));
      expect(result[1]['score'], equals(50));
      expect(result[2]['score'], isNull);
    });

    test('limit', () async {
      final q = FakePoiSupabaseQuery(rows).limit(2);
      final result = await q.execute();
      expect(result.length, equals(2));
    });

    test('column projection', () async {
      final q = FakePoiSupabaseQuery(rows).select(['id', 'name']);
      final result = await q.execute();
      expect(result.first.keys.toSet(), equals({'id', 'name'}));
    });

    test('maybeSingle returns first or null', () async {
      final hit = await FakePoiSupabaseQuery(rows).eq('id', '1').maybeSingle();
      expect(hit?['name'], equals('Alice'));

      final miss = await FakePoiSupabaseQuery(rows).eq('id', '99').maybeSingle();
      expect(miss, isNull);
    });
  });
}
