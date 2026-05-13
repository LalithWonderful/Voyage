/// POI-1.1 — Tests offline du mapping OSM → Fixture Lunao.
// ignore_for_file: avoid_print
///
/// Aucun appel réseau. Tous les tests utilisent des réponses Overpass
/// mockées en mémoire. L'extraction live est testée séparément et
/// skipped par défaut (opt-in via `ALLOW_LIVE_OVERPASS=true`).
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:voyage/config/live_api_guards.dart';
import 'package:voyage/features/poi/tools/osm_overpass_extractor.dart';

import 'package:voyage/features/poi/tools/poi_fixture_validator.dart';

// ═══════════════════════════════════════════════════════════
//  Helpers de construction de mock Overpass
// ═══════════════════════════════════════════════════════════

Map<String, dynamic> _mockOverpassResponse(
  List<Map<String, dynamic>> elements,
) {
  return {'version': 0.6, 'generator': 'test-mock', 'elements': elements};
}

Map<String, dynamic> _node({
  required int id,
  required double lat,
  required double lon,
  required Map<String, dynamic> tags,
}) {
  return {'type': 'node', 'id': id, 'lat': lat, 'lon': lon, 'tags': tags};
}

Map<String, dynamic> _way({
  required int id,
  required double centerLat,
  required double centerLon,
  required Map<String, dynamic> tags,
}) {
  return {
    'type': 'way',
    'id': id,
    'center': {'lat': centerLat, 'lon': centerLon},
    'tags': tags,
  };
}

const _sourceId = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa';

OsmExtractionResult _extract(List<Map<String, dynamic>> elements) {
  final extractor = OsmOverpassExtractor();
  return extractor.extractFromResponse(
    _mockOverpassResponse(elements),
    destinationKey: 'singapore',
    countryCode: 'SG',
    sourcePrimaryId: _sourceId,
  );
}

// ═══════════════════════════════════════════════════════════
//  Tests
// ═══════════════════════════════════════════════════════════

void main() {
  group('OsmOverpassExtractor — mapping tags → catégories', () {
    test('tourism=museum → museum', () {
      final r = _extract([
        _node(
          id: 1,
          lat: 1.0,
          lon: 103.0,
          tags: {'name': 'National Museum', 'tourism': 'museum'},
        ),
      ]);
      expect(r.poiCount, 1);
      final poi = r.fixtureJson['pois'][0];
      expect(poi['category'], 'museum');
      expect(poi['subcategory'], 'museum');
    });

    test('tourism=theme_park → family', () {
      final r = _extract([
        _node(
          id: 2,
          lat: 1.1,
          lon: 103.1,
          tags: {'name': 'Universal Studios', 'tourism': 'theme_park'},
        ),
      ]);
      expect(r.poiCount, 1);
      expect(r.fixtureJson['pois'][0]['category'], 'family');
    });

    test('tourism=zoo → family', () {
      final r = _extract([
        _node(
          id: 3,
          lat: 1.2,
          lon: 103.2,
          tags: {'name': 'City Zoo', 'tourism': 'zoo'},
        ),
      ]);
      expect(r.fixtureJson['pois'][0]['category'], 'family');
    });

    test('tourism=viewpoint → viewpoint', () {
      final r = _extract([
        _node(
          id: 4,
          lat: 1.3,
          lon: 103.3,
          tags: {'name': 'Sky Deck', 'tourism': 'viewpoint'},
        ),
      ]);
      expect(r.fixtureJson['pois'][0]['category'], 'viewpoint');
    });

    test('historic=monument → monument', () {
      final r = _extract([
        _node(
          id: 5,
          lat: 1.4,
          lon: 103.4,
          tags: {'name': 'War Memorial', 'historic': 'monument'},
        ),
      ]);
      expect(r.fixtureJson['pois'][0]['category'], 'monument');
    });

    test('historic=castle → monument', () {
      final r = _extract([
        _node(
          id: 6,
          lat: 1.5,
          lon: 103.5,
          tags: {'name': 'Old Castle', 'historic': 'castle'},
        ),
      ]);
      expect(r.fixtureJson['pois'][0]['category'], 'monument');
    });

    test('historic=ruins → monument (fallback)', () {
      final r = _extract([
        _node(
          id: 7,
          lat: 1.6,
          lon: 103.6,
          tags: {'name': 'Ancient Ruins', 'historic': 'ruins'},
        ),
      ]);
      expect(r.fixtureJson['pois'][0]['category'], 'monument');
    });

    test('leisure=park → park', () {
      final r = _extract([
        _node(
          id: 8,
          lat: 1.7,
          lon: 103.7,
          tags: {'name': 'Botanic Gardens', 'leisure': 'park'},
        ),
      ]);
      expect(r.fixtureJson['pois'][0]['category'], 'park');
    });

    test('leisure=nature_reserve → nature', () {
      final r = _extract([
        _node(
          id: 9,
          lat: 1.8,
          lon: 103.8,
          tags: {'name': 'Mandai Reserve', 'leisure': 'nature_reserve'},
        ),
      ]);
      expect(r.fixtureJson['pois'][0]['category'], 'nature');
    });

    test('natural=beach → beach', () {
      final r = _extract([
        _node(
          id: 10,
          lat: 1.9,
          lon: 103.9,
          tags: {'name': 'Sentosa Beach', 'natural': 'beach'},
        ),
      ]);
      expect(r.fixtureJson['pois'][0]['category'], 'beach');
    });

    test('amenity=marketplace → market', () {
      final r = _extract([
        _node(
          id: 11,
          lat: 1.10,
          lon: 103.10,
          tags: {'name': 'Chinatown Market', 'amenity': 'marketplace'},
        ),
      ]);
      expect(r.fixtureJson['pois'][0]['category'], 'market');
    });

    test('tourism=attraction → must_see', () {
      final r = _extract([
        _node(
          id: 12,
          lat: 1.11,
          lon: 103.11,
          tags: {'name': 'Merlion Statue', 'tourism': 'attraction'},
        ),
      ]);
      expect(r.fixtureJson['pois'][0]['category'], 'must_see');
    });

    test('museum prime sur attraction', () {
      final r = _extract([
        _node(
          id: 13,
          lat: 1.12,
          lon: 103.12,
          tags: {
            'name': 'Art Museum',
            'tourism': 'museum',
            'historic': 'building',
          },
        ),
      ]);
      expect(r.fixtureJson['pois'][0]['category'], 'museum');
    });
  });

  group('OsmOverpassExtractor — structuration fixture', () {
    test('fixture contient source OSM et champs requis', () {
      final r = _extract([
        _node(
          id: 100,
          lat: 1.28,
          lon: 103.86,
          tags: {'name': 'Gardens by the Bay', 'tourism': 'attraction'},
        ),
      ]);

      // Source
      final sources = r.fixtureJson['sources'] as List;
      expect(sources.length, 1);
      final src = sources[0];
      expect(src['source_type'], 'openstreetmap');
      expect(src['trust_level'], 3);
      expect(src['is_active'], true);

      // POI fields
      final poi = r.fixtureJson['pois'][0] as Map<String, dynamic>;
      expect(poi['poi_id'], isA<String>());
      expect(poi['destination_key'], 'singapore');
      expect(poi['country_code'], 'SG');
      expect(poi['name'], 'Gardens by the Bay');
      expect(poi['normalized_name'], 'gardens by the bay');
      expect(poi['lat'], 1.28);
      expect(poi['lng'], 103.86);
      expect(poi['source_primary_id'], _sourceId);
      expect(poi['aliases'], isA<List>());
      expect(poi['tags'], isA<List>());
    });

    test('aliases incluent canonical + alt_name', () {
      final r = _extract([
        _node(
          id: 101,
          lat: 1.0,
          lon: 103.0,
          tags: {
            'name': 'Marina Bay Sands',
            'alt_name': 'MBS',
            'tourism': 'attraction',
          },
        ),
      ]);

      final aliases = r.fixtureJson['pois'][0]['aliases'] as List;
      expect(aliases.length, 2);
      expect(aliases[0]['is_canonical'], true);
      expect(aliases[0]['alias'], 'Marina Bay Sands');
      expect(aliases[1]['is_canonical'], false);
      expect(aliases[1]['alias'], 'MBS');
    });

    test('way avec center extrait correctement', () {
      final r = _extract([
        _way(
          id: 200,
          centerLat: 1.50,
          centerLon: 104.00,
          tags: {'name': 'Big Park', 'leisure': 'park'},
        ),
      ]);

      final poi = r.fixtureJson['pois'][0];
      expect(poi['lat'], 1.50);
      expect(poi['lng'], 104.00);
    });

    test('éléments sans nom sont ignorés', () {
      final r = _extract([
        _node(
          id: 300,
          lat: 1.0,
          lon: 103.0,
          tags: {'tourism': 'attraction'}, // pas de name
        ),
      ]);
      expect(r.poiCount, 0);
      expect(r.skippedCount, 1);
    });

    test('éléments sans catégorie mappée sont ignorés', () {
      final r = _extract([
        _node(
          id: 301,
          lat: 1.0,
          lon: 103.0,
          tags: {'name': 'Random Building', 'building': 'yes'},
        ),
      ]);
      expect(r.poiCount, 0);
      expect(r.skippedCount, 1);
    });

    test('dédoublonnage par ID OSM', () {
      final r = _extract([
        _node(
          id: 400,
          lat: 1.0,
          lon: 103.0,
          tags: {'name': 'Dup', 'tourism': 'attraction'},
        ),
        _node(
          id: 400,
          lat: 1.0,
          lon: 103.0,
          tags: {'name': 'Dup', 'tourism': 'attraction'},
        ),
      ]);
      expect(r.poiCount, 1);
    });
  });

  group('OsmOverpassExtractor — heuristiques', () {
    test('editorial_score augmente avec wikipedia/wikidata', () {
      final noWiki = _extract([
        _node(
          id: 500,
          lat: 1.0,
          lon: 103.0,
          tags: {'name': 'Plain', 'tourism': 'attraction'},
        ),
      ]);
      final withWiki = _extract([
        _node(
          id: 501,
          lat: 1.0,
          lon: 103.0,
          tags: {
            'name': 'Famous',
            'tourism': 'attraction',
            'wikipedia': 'en:Famous',
            'wikidata': 'Q12345',
            'website': 'https://example.com',
          },
        ),
      ]);

      final scoreNo = noWiki.fixtureJson['pois'][0]['editorial_score'] as int;
      final scoreYes =
          withWiki.fixtureJson['pois'][0]['editorial_score'] as int;
      expect(scoreYes, greaterThan(scoreNo));
      expect(scoreYes, lessThanOrEqualTo(100));
    });

    test('fee=no → is_free=true et price_level=1', () {
      final r = _extract([
        _node(
          id: 600,
          lat: 1.0,
          lon: 103.0,
          tags: {'name': 'Free Park', 'leisure': 'park', 'fee': 'no'},
        ),
      ]);
      final poi = r.fixtureJson['pois'][0];
      expect(poi['is_free'], true);
      expect(poi['price_level'], 1);
    });

    test('fee=yes → price_level estimé', () {
      final r = _extract([
        _node(
          id: 601,
          lat: 1.0,
          lon: 103.0,
          tags: {'name': 'Paid Museum', 'tourism': 'museum', 'fee': 'yes'},
        ),
      ]);
      expect(r.fixtureJson['pois'][0]['price_level'], 2);
    });

    test('family_friendly et rain_friendly selon catégorie', () {
      final museum = _extract([
        _node(
          id: 700,
          lat: 1.0,
          lon: 103.0,
          tags: {'name': 'Museum', 'tourism': 'museum'},
        ),
      ]);
      final poi = museum.fixtureJson['pois'][0];
      expect(poi['is_family_friendly'], true);
      expect(poi['is_rain_friendly'], true);

      final viewpoint = _extract([
        _node(
          id: 701,
          lat: 1.0,
          lon: 103.0,
          tags: {'name': 'Lookout', 'tourism': 'viewpoint'},
        ),
      ]);
      final vp = viewpoint.fixtureJson['pois'][0];
      expect(vp['is_family_friendly'], true);
      expect(vp['is_rain_friendly'], false);
    });

    test('touristic_importance selon catégorie', () {
      final mustSee = _extract([
        _node(
          id: 800,
          lat: 1.0,
          lon: 103.0,
          tags: {'name': 'Icon', 'tourism': 'attraction'},
        ),
      ]);
      final park = _extract([
        _node(
          id: 801,
          lat: 1.0,
          lon: 103.0,
          tags: {'name': 'Park', 'leisure': 'park'},
        ),
      ]);
      expect(mustSee.fixtureJson['pois'][0]['touristic_importance'], 5);
      expect(park.fixtureJson['pois'][0]['touristic_importance'], 3);
    });
  });

  group('OsmOverpassExtractor — validation PoiFixtureValidator', () {
    test('fixture généré passe la validation sans erreur', () {
      final r = _extract([
        _node(
          id: 900,
          lat: 1.28,
          lon: 103.86,
          tags: {
            'name': 'Gardens by the Bay',
            'tourism': 'attraction',
            'wikipedia': 'en:GBTB',
            'fee': 'no',
          },
        ),
        _node(
          id: 901,
          lat: 1.29,
          lon: 103.87,
          tags: {'name': 'National Museum', 'tourism': 'museum', 'fee': 'yes'},
        ),
        _way(
          id: 902,
          centerLat: 1.30,
          centerLon: 103.88,
          tags: {'name': 'Big Park', 'leisure': 'park'},
        ),
      ]);

      final report = PoiFixtureValidator().validate(r.fixtureJson);

      if (report.errors.isNotEmpty) {
        print('Validation errors:');
        for (final e in report.errors) {
          print('  • $e');
        }
      }
      if (report.warnings.isNotEmpty) {
        print('Validation warnings:');
        for (final w in report.warnings) {
          print('  • $w');
        }
      }

      expect(report.isValid, isTrue);
      expect(report.stats.poiCount, 3);
      expect(report.stats.sourceCount, 1);
    });
  });

  group('OsmOverpassExtractor — requête Overpass QL', () {
    test('buildOverpassQuery contient les tags touristiques', () {
      final extractor = OsmOverpassExtractor();
      final ql = extractor.buildOverpassQuery(BoundingBox.singapore);

      expect(ql, contains('tourism"="museum"'));
      expect(ql, contains('tourism"="attraction"'));
      expect(ql, contains('historic"]'));
      expect(ql, contains('leisure"="park"'));
      expect(ql, contains('tourism"="viewpoint"'));
      expect(ql, contains('amenity"="marketplace"'));
      expect(ql, contains('tourism"="theme_park"'));
      expect(ql, contains('tourism"="zoo"'));
      expect(ql, contains('natural"="beach"'));
      expect(ql, contains('out center body'));
    });
  });

  group('OsmOverpassExtractor — live API guard', () {
    test('fetchOverpass bloque par défaut avant tout appel HTTP', () async {
      final extractor = OsmOverpassExtractor(guards: LiveApiGuards.defaults());
      final client = _FailingHttpClient();

      await expectLater(
        extractor.fetchOverpass(BoundingBox.singapore, client: client),
        throwsA(
          isA<LiveApiBlockedException>()
              .having((e) => e.family, 'family', LiveApiFamily.overpass)
              .having(
                (e) => e.operation,
                'operation',
                'OsmOverpassExtractor.fetchOverpass',
              )
              .having((e) => e.message, 'message', contains('Overpass'))
              .having(
                (e) => e.message,
                'message',
                contains('--dart-define=ALLOW_LIVE_OVERPASS=true'),
              ),
        ),
      );
      expect(client.sentRequests, isZero);
    });
  });

  // ═══════════════════════════════════════════════════════════
  //  Test live — skipped par défaut
  // ═══════════════════════════════════════════════════════════

  group('Overpass LIVE — skipped par défaut', () {
    test(
      'fetchOverpass pour Singapore retourne des éléments',
      () async {
        final extractor = OsmOverpassExtractor();
        final overpassJson = await extractor.fetchOverpass(
          BoundingBox.singapore,
        );
        expect(overpassJson['elements'], isA<List>());
        expect((overpassJson['elements'] as List).isNotEmpty, isTrue);

        final result = extractor.extractFromResponse(
          overpassJson,
          destinationKey: 'singapore',
          countryCode: 'SG',
          sourcePrimaryId: _sourceId,
        );
        expect(result.poiCount, greaterThan(0));

        // Validation
        final report = PoiFixtureValidator().validate(result.fixtureJson);
        expect(report.isValid, isTrue);
      },
      skip: const bool.fromEnvironment('ALLOW_LIVE_OVERPASS')
          ? false
          : 'Live Overpass test — set ALLOW_LIVE_OVERPASS=true to run',
    );
  });
}

class _FailingHttpClient extends http.BaseClient {
  int sentRequests = 0;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    sentRequests++;
    throw StateError(
      'HTTP client should not be reached while Overpass is blocked',
    );
  }
}
