// POI-0.6 — Tests de contrat du repository POI (FakePoiRepository).
//
// Valide que l'implémentation fake respecte le contrat PoiRepository
// sans aucun appel réseau, sans Supabase, sans Riverpod.

import 'package:flutter_test/flutter_test.dart';
import 'package:voyage/features/poi/data/fake_poi_repository.dart';
import 'package:voyage/features/poi/domain/poi.dart';
import 'package:voyage/features/poi/domain/poi_alias.dart';
import 'package:voyage/features/poi/domain/poi_repository.dart';
import 'package:voyage/features/poi/domain/poi_tag.dart';

// ─── Helper builders ──────────────────────────────────────────────────

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

/// Jeu de données Singapour minimal (5 POIs + aliases + tags).
({
  List<Poi> pois,
  List<PoiAlias> aliases,
  List<PoiTag> tags,
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

  return (pois: [p1, p2, p3, p4, p5], aliases: aliases, tags: tags);
}

PoiRepository _repo({
  List<Poi>? pois,
  List<PoiAlias>? aliases,
  List<PoiTag>? tags,
}) {
  return FakePoiRepository(
    pois: pois ?? const [],
    aliases: aliases ?? const [],
    tags: tags ?? const [],
  );
}

// ──────────────────────────────────────────────────────────────────────

void main() {
  // ═══════════════════════════════════════════════════════════════════
  // 1. listPoisByDestination
  // ═══════════════════════════════════════════════════════════════════

  group('listPoisByDestination', () {
    test('returns all POIs for known destination', () async {
      final fixture = _singaporeFixture();
      final repo = _repo(
        pois: fixture.pois,
        aliases: fixture.aliases,
        tags: fixture.tags,
      );

      final results = await repo.listPoisByDestination('singapore');
      expect(results.length, equals(5));
    });

    test('returns empty list for unknown destination', () async {
      final fixture = _singaporeFixture();
      final repo = _repo(pois: fixture.pois);

      final results = await repo.listPoisByDestination('tokyo');
      expect(results, isEmpty);
    });

    test('order is deterministic (score desc, then name asc)', () async {
      final fixture = _singaporeFixture();
      final repo = _repo(pois: fixture.pois);

      final results = await repo.listPoisByDestination('singapore');
      expect(results[0].name, equals('Gardens by the Bay')); // 98
      expect(results[1].name, equals('Marina Bay Sands')); // 95
      expect(results[2].name, equals('Sentosa')); // 90
      expect(results[3].name, equals('National Museum of Singapore')); // 88
      expect(results[4].name, equals('Chinatown')); // 75
    });

    test('POIs without score are sorted last', () async {
      final pNoScore = _poi(
        poiId: 'poi-no',
        name: 'Zoo',
        normalizedName: 'zoo',
        category: PoiCategory.family,
      );
      final pScore = _poi(
        poiId: 'poi-yes',
        name: 'Art Museum',
        normalizedName: 'art museum',
        category: PoiCategory.museum,
        editorialScore: 10,
      );
      final repo = _repo(pois: [pNoScore, pScore]);

      final results = await repo.listPoisByDestination('singapore');
      expect(results[0].name, equals('Art Museum'));
      expect(results[1].name, equals('Zoo'));
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
    test('returns top N POIs ordered by score desc', () async {
      final fixture = _singaporeFixture();
      final repo = _repo(pois: fixture.pois);

      final results = await repo.getTopPoisForDestination('singapore', 2);
      expect(results.length, equals(2));
      expect(results[0].name, equals('Gardens by the Bay'));
      expect(results[1].name, equals('Marina Bay Sands'));
    });

    test('limit larger than result set returns all', () async {
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

    test('filters by multiple categories (OR)', () async {
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

    test('empty categories list returns empty', () async {
      final fixture = _singaporeFixture();
      final repo = _repo(pois: fixture.pois);

      final results = await repo.getPoisByCategories('singapore', []);
      expect(results, isEmpty);
    });

    test('unknown destination returns empty', () async {
      final fixture = _singaporeFixture();
      final repo = _repo(pois: fixture.pois);

      final results = await repo.getPoisByCategories(
        'unknown',
        [PoiCategory.park],
      );
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

    test('empty query returns all POIs for destination', () async {
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

    test('query matches alias', () async {
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

    test('query on unknown destination returns empty', () async {
      final results = await repo.searchPois(
        destinationKey: 'paris',
        query: 'gardens',
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
        tags: ['surfing', 'skiing'],
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

    test('false returns all POIs', () async {
      final fixture = _singaporeFixture();
      final repo = _repo(pois: fixture.pois);

      final results = await repo.searchPois(
        destinationKey: 'singapore',
        mustSeeOnly: false,
      );
      expect(results.length, equals(5));
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

    test('limit larger than result set returns all', () async {
      final fixture = _singaporeFixture();
      final repo = _repo(pois: fixture.pois);

      final results = await repo.searchPois(
        destinationKey: 'singapore',
        limit: 100,
      );
      expect(results.length, equals(5));
    });

    test('limit zero returns all', () async {
      final fixture = _singaporeFixture();
      final repo = _repo(pois: fixture.pois);

      final results = await repo.searchPois(
        destinationKey: 'singapore',
        limit: 0,
      );
      expect(results.length, equals(5));
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

      // 'shopping' ne match que Marina Bay Sands (1 POI)
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
}
