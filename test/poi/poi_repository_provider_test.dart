import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:voyage/features/poi/data/fake_poi_repository.dart';
import 'package:voyage/features/poi/domain/poi.dart';
import 'package:voyage/features/poi/domain/poi_repository.dart';
import 'package:voyage/features/poi/providers/poi_repository_provider.dart';

void main() {
  group('poiRepositoryProvider', () {
    test('returns a PoiRepository backed by offline fixtures', () {
      final container = ProviderContainer();
      addTearDown(container.dispose);

      final repository = container.read(poiRepositoryProvider);
      expect(repository, isA<PoiRepository>());
      expect(repository, isA<LazyFixturePoiRepository>());
    });

    test('returns Paris POIs through the repository', () async {
      final container = ProviderContainer();
      addTearDown(container.dispose);

      final repository = container.read(poiRepositoryProvider);
      final pois = await repository.listPoisByDestination('paris');

      expect(pois, hasLength(10));
      expect(pois.first.payload['poi_slug'], equals('paris_eiffel_tower'));
    });

    test('returns Lisbon POIs through the repository', () async {
      final container = ProviderContainer();
      addTearDown(container.dispose);

      final repository = container.read(poiRepositoryProvider);
      final pois = await repository.listPoisByDestination('lisbon');

      expect(pois, hasLength(10));
      expect(pois.first.payload['poi_slug'], equals('lisbon_belem_tower'));
    });

    test('can be overridden with a fake repository', () async {
      final fakePoi = Poi(
        poiId: 'fake-poi',
        destinationKey: 'test-city',
        name: 'Fixture Override',
        normalizedName: 'fixture override',
        category: PoiCategory.museum,
        sourcePrimaryId: 'fake-source',
        createdAt: DateTime.utc(2026, 5, 13),
        updatedAt: DateTime.utc(2026, 5, 13),
      );
      final fakeRepository = FakePoiRepository(pois: [fakePoi]);
      final container = ProviderContainer(
        overrides: [poiRepositoryProvider.overrideWithValue(fakeRepository)],
      );
      addTearDown(container.dispose);

      final repository = container.read(poiRepositoryProvider);
      final pois = await repository.listPoisByDestination('test-city');

      expect(repository, same(fakeRepository));
      expect(pois, equals([fakePoi]));
    });
  });
}
