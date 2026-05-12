/// POI-1.2 — Tests offline du reviewer de fixture POI.
///
/// Aucun accès réseau. Tous les tests utilisent des fixtures en mémoire.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:voyage/features/poi/tools/poi_fixture_reviewer.dart';

import 'package:voyage/features/poi/tools/poi_fixture_validator.dart';

// ═══════════════════════════════════════════════════════════
//  Helpers de construction de fixtures
// ═══════════════════════════════════════════════════════════

Map<String, dynamic> _fixture(List<Map<String, dynamic>> pois) {
  return {
    '_comment': 'test fixture',
    'sources': [
      {
        'source_id': 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa',
        'name': 'Test Source',
        'source_type': 'openstreetmap',
        'trust_level': 3,
        'is_active': true,
      },
    ],
    'pois': pois,
  };
}

Map<String, dynamic> _poi({
  required String poiId,
  required String name,
  required String category,
  String? subcategory,
  double? lat,
  double? lng,
  int? editorialScore,
  bool isMustSee = false,
  List<Map<String, dynamic>>? tags,
  List<Map<String, dynamic>>? aliases,
}) {
  return {
    'poi_id': poiId,
    'destination_key': 'singapore',
    'name': name,
    'normalized_name': name.toLowerCase(),
    'category': category,
    'subcategory': subcategory,
    'lat': lat,
    'lng': lng,
    'country_code': 'SG',
    'source_primary_id': 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa',
    'editorial_score': editorialScore ?? 60,
    'touristic_importance': 3,
    'is_must_see': isMustSee,
    'is_family_friendly': false,
    'is_rain_friendly': false,
    'is_free': false,
    'typical_duration_minutes': 60,
    'price_level': 2,
    'google_place_id': null,
    'same_complex_group_key': null,
    'aliases': aliases ??
        [
          {
            'alias': name,
            'alias_normalized': name.toLowerCase(),
            'is_canonical': true,
          },
        ],
    'tags': tags ??
        [
          {'tag': 'test', 'tag_category': 'vibe', 'confidence': 80},
        ],
  };
}

// ═══════════════════════════════════════════════════════════
//  Tests
// ═══════════════════════════════════════════════════════════

void main() {
  group('PoiFixtureReviewer — application overrides', () {
    test('override simple modifie le POI', () {
      final raw = _fixture([
        _poi(poiId: 'p1', name: 'Old Name', category: 'park', lat: 1.0, lng: 103.0),
      ]);

      final reviewer = PoiFixtureReviewer(
        rawFixture: raw,
        overrides: {
          'p1': const PoiOverride(name: 'New Name', editorialScore: 95),
        },
      );

      final reviewed = reviewer.buildReviewedFixture();
      final pois = reviewed['pois'] as List;
      expect(pois.length, 1);
      expect(pois[0]['name'], 'New Name');
      expect(pois[0]['normalized_name'], 'new name');
      expect(pois[0]['editorial_score'], 95);
      // Champs non overridés préservés
      expect(pois[0]['category'], 'park');
    });

    test('override category change la catégorie', () {
      final raw = _fixture([
        _poi(poiId: 'p1', name: 'Museum', category: 'must_see', lat: 1.0, lng: 103.0),
      ]);

      final reviewer = PoiFixtureReviewer(
        rawFixture: raw,
        overrides: {
          'p1': const PoiOverride(category: 'museum'),
        },
      );

      final reviewed = reviewer.buildReviewedFixture();
      expect(reviewed['pois'][0]['category'], 'museum');
    });

    test('override removed supprime le POI', () {
      final raw = _fixture([
        _poi(poiId: 'p1', name: 'Keep', category: 'park', lat: 1.0, lng: 103.0),
        _poi(poiId: 'p2', name: 'Remove', category: 'park', lat: 1.1, lng: 103.1),
      ]);

      final reviewer = PoiFixtureReviewer(
        rawFixture: raw,
        overrides: {
          'p2': const PoiOverride(removed: true),
        },
      );

      final reviewed = reviewer.buildReviewedFixture();
      final pois = reviewed['pois'] as List;
      expect(pois.length, 1);
      expect(pois[0]['poi_id'], 'p1');
    });

    test('override name met à jour alias canonical', () {
      final raw = _fixture([
        _poi(
          poiId: 'p1',
          name: 'Old',
          category: 'park',
          lat: 1.0,
          lng: 103.0,
          aliases: [
            {'alias': 'Old', 'alias_normalized': 'old', 'is_canonical': true},
            {'alias': 'Alt', 'alias_normalized': 'alt', 'is_canonical': false},
          ],
        ),
      ]);

      final reviewer = PoiFixtureReviewer(
        rawFixture: raw,
        overrides: {
          'p1': const PoiOverride(name: 'New'),
        },
      );

      final reviewed = reviewer.buildReviewedFixture();
      final aliases = reviewed['pois'][0]['aliases'] as List;
      expect(aliases[0]['alias'], 'New');
      expect(aliases[0]['alias_normalized'], 'new');
      expect(aliases[0]['is_canonical'], true);
      expect(aliases[1]['alias'], 'Alt'); // non-canonical préservé
    });

    test('override aliases remplace tous les aliases', () {
      final raw = _fixture([
        _poi(
          poiId: 'p1',
          name: 'Name',
          category: 'park',
          lat: 1.0,
          lng: 103.0,
          aliases: [
            {'alias': 'Name', 'alias_normalized': 'name', 'is_canonical': true},
          ],
        ),
      ]);

      final reviewer = PoiFixtureReviewer(
        rawFixture: raw,
        overrides: {
          'p1': const PoiOverride(
            aliases: [
              {
                'alias': 'Custom',
                'alias_normalized': 'custom',
                'is_canonical': true,
              },
            ],
          ),
        },
      );

      final reviewed = reviewer.buildReviewedFixture();
      final aliases = reviewed['pois'][0]['aliases'] as List;
      expect(aliases.length, 1);
      expect(aliases[0]['alias'], 'Custom');
    });

    test('override tags remplace les tags', () {
      final raw = _fixture([
        _poi(poiId: 'p1', name: 'Name', category: 'park', lat: 1.0, lng: 103.0),
      ]);

      final reviewer = PoiFixtureReviewer(
        rawFixture: raw,
        overrides: {
          'p1': const PoiOverride(
            tags: [
              {'tag': 'new_tag', 'tag_category': 'vibe', 'confidence': 99},
            ],
          ),
        },
      );

      final reviewed = reviewer.buildReviewedFixture();
      final tags = reviewed['pois'][0]['tags'] as List;
      expect(tags.length, 1);
      expect(tags[0]['tag'], 'new_tag');
    });

    test('pas d\'override = fixture identique au raw', () {
      final raw = _fixture([
        _poi(poiId: 'p1', name: 'Name', category: 'park', lat: 1.0, lng: 103.0),
      ]);

      final reviewer = PoiFixtureReviewer(rawFixture: raw);
      final reviewed = reviewer.buildReviewedFixture();

      expect(reviewed['pois'][0]['name'], 'Name');
      expect(reviewed['pois'][0]['category'], 'park');
    });

    test('fixture reviewed passe la validation PoiFixtureValidator', () {
      final raw = _fixture([
        _poi(poiId: 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaa1', name: 'Gardens', category: 'park', lat: 1.28, lng: 103.86),
        _poi(poiId: 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaa2', name: 'Museum', category: 'museum', lat: 1.29, lng: 103.87),
      ]);

      final reviewer = PoiFixtureReviewer(rawFixture: raw);
      final reviewed = reviewer.buildReviewedFixture();

      final report = PoiFixtureValidator().validate(reviewed);
      expect(report.isValid, isTrue, reason: report.errors.join('\n'));
    });
  });

  group('PoiFixtureReviewer — rapport qualité', () {
    test('détecte score faible', () {
      final raw = _fixture([
        _poi(poiId: 'p1', name: 'Low', category: 'park', lat: 1.0, lng: 103.0, editorialScore: 30),
        _poi(poiId: 'p2', name: 'High', category: 'park', lat: 1.1, lng: 103.1, editorialScore: 90),
      ]);

      final report = PoiFixtureReviewer(rawFixture: raw).generateQualityReport();
      final lowScoreIssues = report.issues.where(
        (i) => i.message.contains('Score éditorial faible'),
      );
      expect(lowScoreIssues.length, 1);
      expect(lowScoreIssues.first.poiId, 'p1');
    });

    test('détecte catégorie fallback must_see', () {
      final raw = _fixture([
        _poi(
          poiId: 'p1',
          name: 'Generic Attraction',
          category: 'must_see',
          subcategory: 'attraction',
          lat: 1.0,
          lng: 103.0,
        ),
        _poi(
          poiId: 'p2',
          name: 'Real Museum',
          category: 'museum',
          subcategory: 'museum',
          lat: 1.1,
          lng: 103.1,
        ),
      ]);

      final report = PoiFixtureReviewer(rawFixture: raw).generateQualityReport();
      final fallbackIssues = report.issues.where(
        (i) => i.message.contains('fallback'),
      );
      expect(fallbackIssues.length, 1);
      expect(fallbackIssues.first.poiId, 'p1');
    });

    test('détecte noms suspects', () {
      final raw = _fixture([
        _poi(poiId: 'p1', name: 'Building', category: 'park', lat: 1.0, lng: 103.0),
        _poi(poiId: 'p2', name: 'Hotel', category: 'park', lat: 1.1, lng: 103.1),
        _poi(poiId: 'p3', name: 'Gardens', category: 'park', lat: 1.2, lng: 103.2),
      ]);

      final report = PoiFixtureReviewer(rawFixture: raw).generateQualityReport();
      final suspiciousIssues = report.issues.where(
        (i) => i.message.contains('suspect'),
      );
      expect(suspiciousIssues.length, 2);
    });

    test('détecte doublons par nom', () {
      final raw = _fixture([
        _poi(poiId: 'p1', name: 'Same Name', category: 'park', lat: 1.0, lng: 103.0),
        _poi(poiId: 'p2', name: 'Same Name', category: 'park', lat: 1.5, lng: 104.0),
      ]);

      final report = PoiFixtureReviewer(rawFixture: raw).generateQualityReport();
      final dupIssues = report.issues.where(
        (i) => i.message.contains('Doublon probable par nom'),
      );
      expect(dupIssues.length, 2); // un pour chaque POI
    });

    test('détecte doublons par coordonnées proches', () {
      final raw = _fixture([
        _poi(poiId: 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaa1', name: 'A', category: 'park', lat: 1.2800, lng: 103.8500),
        _poi(poiId: 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaa2', name: 'B', category: 'park', lat: 1.2801, lng: 103.8501),
      ]);

      final report = PoiFixtureReviewer(rawFixture: raw).generateQualityReport();
      final dupLocIssues = report.issues.where(
        (i) => i.message.contains('Doublon probable par proximité'),
      );
      // Un doublon par proximité génère 2 issues (un pour chaque POI)
      expect(dupLocIssues.length, 2);
    });

    test('détecte tags pauvres', () {
      final raw = _fixture([
        _poi(
          poiId: 'p1',
          name: 'Poor',
          category: 'park',
          lat: 1.0,
          lng: 103.0,
          tags: [],
        ),
        _poi(
          poiId: 'p2',
          name: 'Rich',
          category: 'park',
          lat: 1.1,
          lng: 103.1,
          tags: [
            {'tag': 'a', 'tag_category': 'vibe', 'confidence': 80},
            {'tag': 'b', 'tag_category': 'vibe', 'confidence': 80},
            {'tag': 'c', 'tag_category': 'vibe', 'confidence': 80},
          ],
        ),
      ]);

      final report = PoiFixtureReviewer(rawFixture: raw).generateQualityReport();
      final poorTagIssues = report.issues.where(
        (i) => i.message.contains('Peu de tags'),
      );
      expect(poorTagIssues.length, 1);
      expect(poorTagIssues.first.poiId, 'p1');
    });

    test('rapport exclut les POI supprimés', () {
      final raw = _fixture([
        _poi(poiId: 'p1', name: 'Keep', category: 'park', lat: 1.0, lng: 103.0),
        _poi(poiId: 'p2', name: 'Remove', category: 'park', lat: 1.1, lng: 103.1),
      ]);

      final reviewer = PoiFixtureReviewer(
        rawFixture: raw,
        overrides: {'p2': const PoiOverride(removed: true)},
      );

      final report = reviewer.generateQualityReport();
      expect(report.totalPois, 2);
      expect(report.reviewedPois, 1);
      expect(report.removedPois, 1);
      expect(report.issues.any((i) => i.poiId == 'p2'), isFalse);
    });

    test('rapport compte correctement les sévérités', () {
      final raw = _fixture([
        // Doublon par nom → erreur
        _poi(poiId: 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaa1', name: 'Building', category: 'must_see', subcategory: 'attraction', lat: 1.0, lng: 103.0, editorialScore: 30),
        _poi(poiId: 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaa2', name: 'Building', category: 'park', lat: 1.5, lng: 104.0, editorialScore: 30),
      ]);

      final report = PoiFixtureReviewer(rawFixture: raw).generateQualityReport();
      expect(report.errors.length, greaterThanOrEqualTo(2)); // 2 doublons par nom
      expect(report.warnings.length, greaterThanOrEqualTo(4)); // score faible + fallback + suspect × 2
      expect(report.infos.length, greaterThanOrEqualTo(2)); // peu de tags × 2
    });
  });

  group('PoiFixtureReviewer — loadOverrides', () {
    test('charge un fichier overrides JSON', () {
      final overridesJson = {
        'overrides': {
          'p1': {
            'name': 'Corrigé',
            'editorial_score': 95,
            'removed': false,
          },
          'p2': {
            'removed': true,
          },
        },
      };

      final overrides = PoiFixtureReviewer.loadOverrides(overridesJson);
      expect(overrides.length, 2);
      expect(overrides['p1']?.name, 'Corrigé');
      expect(overrides['p1']?.editorialScore, 95);
      expect(overrides['p2']?.removed, true);
    });

    test('JSON vide retourne map vide', () {
      final overrides = PoiFixtureReviewer.loadOverrides({});
      expect(overrides, isEmpty);
    });
  });

  group('PoiQualityReport — format de sortie', () {
    test('toJson produit un objet sérialisable', () {
      final raw = _fixture([
        _poi(poiId: 'p1', name: 'A', category: 'park', lat: 1.0, lng: 103.0),
      ]);

      final report = PoiFixtureReviewer(rawFixture: raw).generateQualityReport();
      final json = report.toJson();

      expect(json['total_pois'], 1);
      expect(json['reviewed_pois'], 1);
      expect(json.containsKey('errors'), true);
      expect(json.containsKey('warnings'), true);
      expect(json.containsKey('infos'), true);
    });

    test('toMarkdown contient les sections', () {
      final raw = _fixture([
        _poi(poiId: 'p1', name: 'Building', category: 'park', lat: 1.0, lng: 103.0),
      ]);

      final report = PoiFixtureReviewer(rawFixture: raw).generateQualityReport();
      final md = report.toMarkdown();

      expect(md.contains('# Rapport qualité POI'), true);
      expect(md.contains('POI bruts'), true);
      expect(md.contains('Avertissements'), true);
    });
  });

  group('PoiFixtureReviewer — raw non modifié', () {
    test('le fixture brut reste inchangé après buildReviewedFixture', () {
      final raw = _fixture([
        _poi(poiId: 'p1', name: 'Name', category: 'park', lat: 1.0, lng: 103.0),
      ]);

      final reviewer = PoiFixtureReviewer(
        rawFixture: raw,
        overrides: {
          'p1': const PoiOverride(name: 'Changed'),
        },
      );

      reviewer.buildReviewedFixture();

      // Le raw ne doit pas avoir été modifié
      expect(raw['pois'][0]['name'], 'Name');
    });
  });
}
