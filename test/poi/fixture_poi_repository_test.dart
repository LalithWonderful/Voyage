import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:voyage/features/poi/data/fixture_poi_repository.dart';
import 'package:voyage/features/poi/domain/poi.dart';

void main() {
  group('FixturePoiRepository', () {
    late FixturePoiRepository repository;

    setUpAll(() {
      repository = FixturePoiRepository.fromDecodedFixtures([
        _readFixture('assets/poi_fixtures/paris_mvp_pois.json'),
        _readFixture('assets/poi_fixtures/lisbon_mvp_pois.json'),
      ]);
    });

    test('Paris returns 10 POIs', () async {
      final pois = await repository.getPoisForDestination('paris');
      expect(pois, hasLength(10));
      expect(pois.every((poi) => poi.destinationKey == 'paris'), isTrue);
    });

    test('Lisbon returns 10 POIs', () async {
      final pois = await repository.getPoisForDestination('lisbon');
      expect(pois, hasLength(10));
      expect(pois.every((poi) => poi.destinationKey == 'lisbon'), isTrue);
    });

    test('unknown destination returns an empty list', () async {
      expect(await repository.getPoisForDestination('tokyo'), isEmpty);
      expect(await repository.searchPois(destinationKey: 'tokyo'), isEmpty);
    });

    test('must-see filtering works', () async {
      final mustSee = await repository.getMustSeePois('lisbon');

      expect(mustSee, isNotEmpty);
      expect(mustSee.every((poi) => poi.isMustSee), isTrue);
      expect(
        mustSee.map((poi) => poi.payload['poi_slug']),
        containsAll([
          'lisbon_belem_tower',
          'lisbon_jeronimos_monastery',
          'lisbon_sao_jorge_castle',
        ]),
      );
    });

    test('category filtering works', () async {
      final museums = await repository.getPoisByCategory(
        'paris',
        PoiCategory.museum,
      );

      expect(museums, hasLength(2));
      expect(
        museums.every((poi) => poi.category == PoiCategory.museum),
        isTrue,
      );
      expect(
        museums.map((poi) => poi.payload['poi_slug']),
        equals(['paris_louvre_museum', 'paris_musee_d_orsay']),
      );
    });

    test('ordering is deterministic', () async {
      final first = await repository.getPoisForDestination('paris');
      final second = await repository.getPoisForDestination('paris');

      expect(
        first.map((poi) => poi.payload['poi_slug']),
        equals(second.map((poi) => poi.payload['poi_slug'])),
      );
      expect(first.first.payload['poi_slug'], equals('paris_eiffel_tower'));
      expect(first[1].payload['poi_slug'], equals('paris_louvre_museum'));
      expect(
        first[2].payload['poi_slug'],
        equals('paris_notre_dame_cathedral'),
      );
    });

    test('search by localized and common names works', () async {
      final localName = await repository.searchPois(
        destinationKey: 'lisbon',
        query: 'torre de belém',
      );
      expect(
        localName.single.payload['poi_slug'],
        equals('lisbon_belem_tower'),
      );

      final commonName = await repository.searchPois(
        destinationKey: 'paris',
        query: 'Luxembourg Gardens',
      );
      expect(
        commonName.single.payload['poi_slug'],
        equals('paris_luxembourg_gardens'),
      );
    });

    test('search supports existing repository filters', () async {
      final results = await repository.searchPois(
        destinationKey: 'paris',
        tags: ['indoor'],
        category: PoiCategory.museum,
        limit: 1,
      );

      expect(results, hasLength(1));
      expect(results.single.payload['poi_slug'], equals('paris_louvre_museum'));
    });

    test('does not require or expose Google Places IDs', () async {
      final pois = [
        ...await repository.getPoisForDestination('paris'),
        ...await repository.getPoisForDestination('lisbon'),
      ];

      expect(pois, hasLength(20));
      expect(pois.every((poi) => poi.googlePlaceId == null), isTrue);
      expect(
        pois.every((poi) => !poi.payload.containsKey('google_place_id')),
        isTrue,
      );
    });
  });
}

Map<String, dynamic> _readFixture(String path) {
  return json.decode(File(path).readAsStringSync()) as Map<String, dynamic>;
}
