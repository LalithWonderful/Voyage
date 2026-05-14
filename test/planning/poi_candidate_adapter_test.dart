import 'package:flutter_test/flutter_test.dart';
import 'package:voyage/features/poi/data/fake_poi_repository.dart';
import 'package:voyage/features/poi/domain/poi.dart';
import 'package:voyage/features/planning/data/destination_key_mapper.dart';
import 'package:voyage/features/planning/services/poi_candidate_adapter.dart';

void main() {
  group('DestinationKeyMapper', () {
    test('maps lisbon/lisbonne/lisboa to "lisbon"', () {
      expect(DestinationKeyMapper.map('lisbon'), 'lisbon');
      expect(DestinationKeyMapper.map('Lisbon'), 'lisbon');
      expect(DestinationKeyMapper.map('LISBON'), 'lisbon');
      expect(DestinationKeyMapper.map('  lisbon  '), 'lisbon');
      expect(DestinationKeyMapper.map('lisbonne'), 'lisbon');
      expect(DestinationKeyMapper.map('Lisbonne'), 'lisbon');
      expect(DestinationKeyMapper.map('lisboa'), 'lisbon');
      expect(DestinationKeyMapper.map('Lisboa'), 'lisbon');
    });

    test('maps paris/rome/barcelona aliases to their keys', () {
      expect(DestinationKeyMapper.map('paris'), 'paris');
      expect(DestinationKeyMapper.map('Paris'), 'paris');
      expect(DestinationKeyMapper.map('paris france'), 'paris');
      expect(DestinationKeyMapper.map('rome'), 'rome');
      expect(DestinationKeyMapper.map('Rome'), 'rome');
      expect(DestinationKeyMapper.map('roma'), 'rome');
      expect(DestinationKeyMapper.map('rome italy'), 'rome');
      expect(DestinationKeyMapper.map('barcelona'), 'barcelona');
      expect(DestinationKeyMapper.map('Barcelona'), 'barcelona');
      expect(DestinationKeyMapper.map('barcelone'), 'barcelona');
      expect(DestinationKeyMapper.map('barca'), 'barcelona');
    });

    test('returns null for unknown destinations', () {
      expect(DestinationKeyMapper.map('tokyo'), isNull);
      expect(DestinationKeyMapper.map(''), isNull);
    });

    test('maps london/londres/london uk to "london"', () {
      expect(DestinationKeyMapper.map('london'), 'london');
      expect(DestinationKeyMapper.map('Londres'), 'london');
      expect(DestinationKeyMapper.map('london uk'), 'london');
      expect(DestinationKeyMapper.map('londres royaume uni'), 'london');
    });

    test('maps amsterdam/amsterdam netherlands to "amsterdam"', () {
      expect(DestinationKeyMapper.map('amsterdam'), 'amsterdam');
      expect(DestinationKeyMapper.map('Amsterdam'), 'amsterdam');
      expect(DestinationKeyMapper.map('amsterdam netherlands'), 'amsterdam');
      expect(DestinationKeyMapper.map('amsterdam pays bas'), 'amsterdam');
    });

    test('maps marrakech/marrakesh/marrakech maroc to "marrakech"', () {
      expect(DestinationKeyMapper.map('marrakech'), 'marrakech');
      expect(DestinationKeyMapper.map('Marrakech'), 'marrakech');
      expect(DestinationKeyMapper.map('marrakesh'), 'marrakech');
      expect(DestinationKeyMapper.map('marrakech maroc'), 'marrakech');
      expect(DestinationKeyMapper.map('marrakesh morocco'), 'marrakech');
    });
  });

  group('PoiCandidateAdapter', () {
    final now = DateTime(2026, 5, 1);

    Poi makePoi({
      required String poiId,
      required String name,
      required String destinationKey,
      PoiCategory category = PoiCategory.museum,
      double? lat,
      double? lng,
      int? editorialScore,
      int? priceLevel,
      String? googlePlaceId,
      String? subcategory,
    }) {
      return Poi(
        poiId: poiId,
        destinationKey: destinationKey,
        name: name,
        normalizedName: name.toLowerCase(),
        category: category,
        sourcePrimaryId: 'source-$poiId',
        lat: lat,
        lng: lng,
        editorialScore: editorialScore,
        priceLevel: priceLevel,
        googlePlaceId: googlePlaceId,
        subcategory: subcategory,
        createdAt: now,
        updatedAt: now,
      );
    }

    test('adaptForDestination converts POIs with valid coordinates', () async {
      final repo = FakePoiRepository(pois: [
        makePoi(
          poiId: 'p1',
          name: 'Test Museum',
          destinationKey: 'lisbon',
          lat: 38.7,
          lng: -9.1,
          category: PoiCategory.museum,
        ),
      ]);
      final adapter = PoiCandidateAdapter(repo);
      final result = await adapter.adaptForDestination('lisbon');

      expect(result.length, 1);
      expect(result.first.placeId, 'poi:p1');
      expect(result.first.name, 'Test Museum');
      expect(result.first.latitude, 38.7);
      expect(result.first.longitude, -9.1);
      expect(result.first.types, ['museum']);
    });

    test('adaptForDestination skips POIs without coordinates', () async {
      final repo = FakePoiRepository(pois: [
        makePoi(poiId: 'p1', name: 'Has Coords', destinationKey: 'lisbon', lat: 1.0, lng: 2.0),
        makePoi(poiId: 'p2', name: 'No Coords', destinationKey: 'lisbon'),
      ]);
      final adapter = PoiCandidateAdapter(repo);
      final result = await adapter.adaptForDestination('lisbon');

      expect(result.length, 1);
      expect(result.first.name, 'Has Coords');
    });

    test('adaptForDestination skips POIs with NaN coordinates', () async {
      final repo = FakePoiRepository(pois: [
        makePoi(poiId: 'p1', name: 'Valid', destinationKey: 'lisbon', lat: 1.0, lng: 2.0),
        makePoi(poiId: 'p2', name: 'NaN', destinationKey: 'lisbon', lat: double.nan, lng: 2.0),
        makePoi(poiId: 'p3', name: 'NaN both', destinationKey: 'lisbon', lat: double.nan, lng: double.nan),
      ]);
      final adapter = PoiCandidateAdapter(repo);
      final result = await adapter.adaptForDestination('lisbon');

      expect(result.length, 1);
      expect(result.first.name, 'Valid');
    });

    test('adaptForDestination uses googlePlaceId when present', () async {
      final repo = FakePoiRepository(pois: [
        makePoi(
          poiId: 'p1',
          name: 'Place',
          destinationKey: 'lisbon',
          lat: 1.0,
          lng: 2.0,
          googlePlaceId: 'ChIJ123',
        ),
      ]);
      final adapter = PoiCandidateAdapter(repo);
      final result = await adapter.adaptForDestination('lisbon');

      expect(result.first.placeId, 'ChIJ123');
    });

    test('adaptForDestination uses synthetic id when no googlePlaceId', () async {
      final repo = FakePoiRepository(pois: [
        makePoi(poiId: 'p1', name: 'Place', destinationKey: 'lisbon', lat: 1.0, lng: 2.0),
      ]);
      final adapter = PoiCandidateAdapter(repo);
      final result = await adapter.adaptForDestination('lisbon');

      expect(result.first.placeId, 'poi:p1');
    });

    test('adaptForDestination deduplicates by placeId', () async {
      final repo = FakePoiRepository(pois: [
        makePoi(poiId: 'p1', name: 'First', destinationKey: 'lisbon', lat: 1.0, lng: 2.0, googlePlaceId: 'ChIJ123', editorialScore: 90),
        makePoi(poiId: 'p2', name: 'Duplicate', destinationKey: 'lisbon', lat: 3.0, lng: 4.0, googlePlaceId: 'ChIJ123', editorialScore: 80),
      ]);
      final adapter = PoiCandidateAdapter(repo);
      final result = await adapter.adaptForDestination('lisbon');

      expect(result.length, 1);
      // Le premier par ordre de tri (score desc) est conservé
      expect(result.first.name, 'First');
    });

    test('adaptForDestination maps editorialScore to rating', () async {
      final repo = FakePoiRepository(pois: [
        makePoi(poiId: 'p1', name: 'Score80', destinationKey: 'lisbon', lat: 1.0, lng: 2.0, editorialScore: 80),
        makePoi(poiId: 'p2', name: 'NoScore', destinationKey: 'lisbon', lat: 3.0, lng: 4.0),
      ]);
      final adapter = PoiCandidateAdapter(repo);
      final result = await adapter.adaptForDestination('lisbon');

      expect(result.length, 2);
      final score80 = result.firstWhere((c) => c.name == 'Score80');
      final noScore = result.firstWhere((c) => c.name == 'NoScore');
      expect(score80.rating, 4.0);
      expect(noScore.rating, isNull);
    });

    test('adaptForDestination includes category and subcategory in types', () async {
      final repo = FakePoiRepository(pois: [
        makePoi(
          poiId: 'p1',
          name: 'Sub',
          destinationKey: 'lisbon',
          lat: 1.0,
          lng: 2.0,
          category: PoiCategory.park,
          subcategory: 'botanic_garden',
        ),
      ]);
      final adapter = PoiCandidateAdapter(repo);
      final result = await adapter.adaptForDestination('lisbon');

      expect(result.first.types, ['park', 'botanic_garden']);
    });

    test('adaptForDestination returns empty for unknown destination', () async {
      final repo = FakePoiRepository(pois: [
        makePoi(poiId: 'p1', name: 'Lisbon', destinationKey: 'lisbon', lat: 1.0, lng: 2.0),
      ]);
      final adapter = PoiCandidateAdapter(repo);
      final result = await adapter.adaptForDestination('tokyo');

      expect(result, isEmpty);
    });

    test('adaptForDestination preserves priceLevel', () async {
      final repo = FakePoiRepository(pois: [
        makePoi(poiId: 'p1', name: 'Free', destinationKey: 'lisbon', lat: 1.0, lng: 2.0, priceLevel: 0),
        makePoi(poiId: 'p2', name: 'Expensive', destinationKey: 'lisbon', lat: 3.0, lng: 4.0, priceLevel: 3),
      ]);
      final adapter = PoiCandidateAdapter(repo);
      final result = await adapter.adaptForDestination('lisbon');

      expect(result.firstWhere((c) => c.name == 'Free').priceLevel, 0);
      expect(result.firstWhere((c) => c.name == 'Expensive').priceLevel, 3);
    });
  });
}
