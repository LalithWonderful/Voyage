// POI-0.9 — Tests des providers Riverpod POI.
//
// Tests offline uniquement : aucun appel réseau, aucun Supabase live,
// aucun credential. Tous les repositories sont injectés via override.

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:voyage/features/poi/data/fake_poi_repository.dart';
import 'package:voyage/features/poi/domain/poi.dart';
import 'package:voyage/features/poi/domain/poi_alias.dart';
import 'package:voyage/features/poi/domain/poi_repository.dart';
import 'package:voyage/features/poi/domain/poi_tag.dart';
import 'package:voyage/features/poi/providers/poi_providers.dart';
import 'package:voyage/features/poi/providers/poi_repository_provider.dart';

DateTime _ts(String iso) => DateTime.parse(iso);

Poi _poi({
  required String poiId,
  required String name,
  required String normalizedName,
  required PoiCategory category,
  int? editorialScore,
  bool isMustSee = false,
  String destinationKey = 'singapore',
}) {
  return Poi(
    poiId: poiId,
    destinationKey: destinationKey,
    name: name,
    normalizedName: normalizedName,
    category: category,
    sourcePrimaryId: 'src1',
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

PoiTag _tag({required String poiId, required String tag}) {
  return PoiTag(
    tagId: 'tag-${tag.hashCode}-$poiId',
    poiId: poiId,
    tag: tag,
    createdAt: _ts('2024-01-15T10:00:00Z'),
  );
}

/// Fixture Singapour minimal.
PoiRepository _singaporeRepo() {
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
    name: 'National Museum',
    normalizedName: 'national museum',
    category: PoiCategory.museum,
    editorialScore: 88,
    isMustSee: false,
  );

  return FakePoiRepository(
    pois: [p1, p2, p3],
    aliases: [
      _alias(poiId: p1.poiId, alias: 'GBTB', aliasNormalized: 'gbtb'),
      _alias(poiId: p2.poiId, alias: 'MBS', aliasNormalized: 'mbs'),
    ],
    tags: [
      _tag(poiId: p1.poiId, tag: 'night_photography'),
      _tag(poiId: p2.poiId, tag: 'shopping'),
    ],
  );
}

ProviderContainer _container(PoiRepository repo) {
  return ProviderContainer(
    overrides: [poiRepositoryProvider.overrideWithValue(repo)],
  );
}

void main() {
  // ═══════════════════════════════════════════════════════════════════
  // 1. poiRepositoryProvider (default)
  // ═══════════════════════════════════════════════════════════════════

  group('poiRepositoryProvider default', () {
    test('returns an offline repository by default', () {
      final container = ProviderContainer();
      addTearDown(container.dispose);

      final repo = container.read(poiRepositoryProvider);
      expect(repo, isA<PoiRepository>());
    });

    test('default repo reads local MVP fixtures', () async {
      final container = ProviderContainer();
      addTearDown(container.dispose);

      final repo = container.read(poiRepositoryProvider);
      expect(await repo.listPoisByDestination('paris'), hasLength(10));
      expect(await repo.listPoisByDestination('lisbon'), hasLength(10));
      expect(await repo.listPoisByDestination('singapore'), isEmpty);
      expect(await repo.getPoiById('any'), isNull);
      expect(await repo.searchPois(destinationKey: 'singapore'), isEmpty);
    });
  });

  // ═══════════════════════════════════════════════════════════════════
  // 2. poisByDestinationProvider
  // ═══════════════════════════════════════════════════════════════════

  group('poisByDestinationProvider', () {
    test('returns POIs for destination', () async {
      final container = _container(_singaporeRepo());
      addTearDown(container.dispose);

      final future = container.read(
        poisByDestinationProvider('singapore').future,
      );
      final pois = await future;
      expect(pois.length, equals(3));
    });

    test('returns empty for unknown destination', () async {
      final container = _container(_singaporeRepo());
      addTearDown(container.dispose);

      final pois = await container.read(
        poisByDestinationProvider('tokyo').future,
      );
      expect(pois, isEmpty);
    });

    test('caches result for same key', () async {
      final repo = _singaporeRepo();
      final container = _container(repo);
      addTearDown(container.dispose);

      final pois1 = await container.read(
        poisByDestinationProvider('singapore').future,
      );
      final pois2 = await container.read(
        poisByDestinationProvider('singapore').future,
      );
      expect(identical(pois1, pois2), isTrue);
    });
  });

  // ═══════════════════════════════════════════════════════════════════
  // 3. poiByIdProvider
  // ═══════════════════════════════════════════════════════════════════

  group('poiByIdProvider', () {
    test('returns POI when found', () async {
      final container = _container(_singaporeRepo());
      addTearDown(container.dispose);

      final poi = await container.read(poiByIdProvider('poi-001').future);
      expect(poi, isNotNull);
      expect(poi!.name, equals('Gardens by the Bay'));
    });

    test('returns null when not found', () async {
      final container = _container(_singaporeRepo());
      addTearDown(container.dispose);

      final poi = await container.read(poiByIdProvider('poi-999').future);
      expect(poi, isNull);
    });
  });

  // ═══════════════════════════════════════════════════════════════════
  // 4. poiSearchProvider
  // ═══════════════════════════════════════════════════════════════════

  group('poiSearchProvider', () {
    test('search with empty params returns all', () async {
      final container = _container(_singaporeRepo());
      addTearDown(container.dispose);

      final pois = await container.read(
        const PoiSearchParams(destinationKey: 'singapore').future,
      );
      expect(pois.length, equals(3));
    });

    test('search with query filters by name', () async {
      final container = _container(_singaporeRepo());
      addTearDown(container.dispose);

      final pois = await container.read(
        const PoiSearchParams(
          destinationKey: 'singapore',
          query: 'marina',
        ).future,
      );
      expect(pois.length, equals(1));
      expect(pois.first.name, equals('Marina Bay Sands'));
    });

    test('search with category filters', () async {
      final container = _container(_singaporeRepo());
      addTearDown(container.dispose);

      final pois = await container.read(
        const PoiSearchParams(
          destinationKey: 'singapore',
          category: PoiCategory.museum,
        ).future,
      );
      expect(pois.length, equals(1));
      expect(pois.first.category, equals(PoiCategory.museum));
    });

    test('search with mustSeeOnly filters', () async {
      final container = _container(_singaporeRepo());
      addTearDown(container.dispose);

      final pois = await container.read(
        const PoiSearchParams(
          destinationKey: 'singapore',
          mustSeeOnly: true,
        ).future,
      );
      expect(pois.length, equals(2));
      for (final p in pois) {
        expect(p.isMustSee, isTrue);
      }
    });

    test('search with limit caps results', () async {
      final container = _container(_singaporeRepo());
      addTearDown(container.dispose);

      final pois = await container.read(
        const PoiSearchParams(destinationKey: 'singapore', limit: 1).future,
      );
      expect(pois.length, equals(1));
    });

    test('search caches identical params', () async {
      final repo = _singaporeRepo();
      final container = _container(repo);
      addTearDown(container.dispose);

      const params = PoiSearchParams(destinationKey: 'singapore');
      final pois1 = await container.read(params.future);
      final pois2 = await container.read(params.future);
      expect(identical(pois1, pois2), isTrue);
    });

    test('search with different params does not share cache', () async {
      final container = _container(_singaporeRepo());
      addTearDown(container.dispose);

      const params1 = PoiSearchParams(destinationKey: 'singapore');
      const params2 = PoiSearchParams(destinationKey: 'tokyo');

      final pois1 = await container.read(params1.future);
      final pois2 = await container.read(params2.future);

      expect(pois1.length, equals(3));
      expect(pois2, isEmpty);
    });
  });

  // ═══════════════════════════════════════════════════════════════════
  // 5. PoiSearchParams equality
  // ═══════════════════════════════════════════════════════════════════

  group('PoiSearchParams equality', () {
    test('equal params have same hashCode', () {
      const a = PoiSearchParams(destinationKey: 'sg', query: 'bay');
      const b = PoiSearchParams(destinationKey: 'sg', query: 'bay');
      expect(a, equals(b));
      expect(a.hashCode, equals(b.hashCode));
    });

    test('different params are not equal', () {
      const a = PoiSearchParams(destinationKey: 'sg');
      const b = PoiSearchParams(destinationKey: 'tokyo');
      expect(a, isNot(equals(b)));
    });

    test('tags list order matters for equality', () {
      const a = PoiSearchParams(destinationKey: 'sg', tags: ['a', 'b']);
      const b = PoiSearchParams(destinationKey: 'sg', tags: ['b', 'a']);
      expect(a, isNot(equals(b)));
    });

    test('null tags equals empty list in params? No — null != []', () {
      const a = PoiSearchParams(destinationKey: 'sg', tags: null);
      const b = PoiSearchParams(destinationKey: 'sg', tags: []);
      expect(a, isNot(equals(b)));
    });
  });
}

// Helper pour lire un FutureProvider avec .future plus lisiblement.
extension on PoiSearchParams {
  ProviderListenable<Future<List<Poi>>> get future =>
      poiSearchProvider(this).future;
}
