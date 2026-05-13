import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  group('MVP POI fixtures', () {
    test('Paris and Lisbon fixtures satisfy the offline contract', () {
      final fixtures = {
        'paris': File('assets/poi_fixtures/paris_mvp_pois.json'),
        'lisbon': File('assets/poi_fixtures/lisbon_mvp_pois.json'),
      };

      final allIds = <String>{};
      final allSlugs = <String>{};

      for (final entry in fixtures.entries) {
        final destinationKey = entry.key;
        final file = entry.value;

        expect(
          file.existsSync(),
          isTrue,
          reason: 'Missing fixture: ${file.path}',
        );

        final fixture =
            json.decode(file.readAsStringSync()) as Map<String, dynamic>;
        expect(fixture['schema_version'], equals('poi_mvp_fixture_v1'));
        expect(fixture['destination_key'], equals(destinationKey));
        expect(fixture['sources'], isA<List>());
        expect(fixture['categories'], isA<List>());
        expect(fixture['pois'], isA<List>());

        final batch = fixture['import_batch'] as Map<String, dynamic>;
        expect(batch['batch_type'], equals('fixture'));
        expect(batch['destination_key'], equals(destinationKey));
        expect(batch['dry_run'], isTrue);

        final pois = (fixture['pois'] as List).cast<Map<String, dynamic>>();
        expect(pois, isNotEmpty);

        for (final poi in pois) {
          _expectRequiredString(poi, 'poi_id');
          _expectRequiredString(poi, 'poi_slug');
          _expectRequiredString(poi, 'destination_key');
          _expectRequiredString(poi, 'name');
          _expectRequiredString(poi, 'canonical_name');
          _expectRequiredString(poi, 'normalized_name');
          _expectRequiredString(poi, 'category');
          _expectRequiredString(poi, 'primary_category_key');
          _expectRequiredString(poi, 'country_code');
          _expectRequiredString(poi, 'locality');

          expect(poi['destination_key'], equals(destinationKey));
          expect(poi['is_must_see'], isA<bool>());
          expect(poi['is_hidden_gem'], isA<bool>());
          expect(poi['typical_duration_minutes'], isA<int>());
          expect(poi['typical_duration_minutes'] as int, greaterThan(0));

          expect(
            allIds.add(poi['poi_id'] as String),
            isTrue,
            reason: 'Duplicate poi_id ${poi['poi_id']}',
          );
          expect(
            allSlugs.add(poi['poi_slug'] as String),
            isTrue,
            reason: 'Duplicate poi_slug ${poi['poi_slug']}',
          );

          if (poi.containsKey('lat')) {
            expect(
              poi['lat'],
              isA<num>(),
              reason: 'lat must be numeric for ${poi['name']}',
            );
            expect(
              poi['lat'] as num,
              allOf(greaterThanOrEqualTo(-90), lessThanOrEqualTo(90)),
            );
          }
          if (poi.containsKey('lng')) {
            expect(
              poi['lng'],
              isA<num>(),
              reason: 'lng must be numeric for ${poi['name']}',
            );
            expect(
              poi['lng'] as num,
              allOf(greaterThanOrEqualTo(-180), lessThanOrEqualTo(180)),
            );
          }
          expect(
            poi.containsKey('lat'),
            equals(poi.containsKey('lng')),
            reason: 'lat/lng must be provided together for ${poi['name']}',
          );

          final localizedNames = (poi['localized_names'] as List)
              .cast<Map<String, dynamic>>();
          expect(
            localizedNames,
            isNotEmpty,
            reason: 'Missing localized names for ${poi['name']}',
          );
          for (final localizedName in localizedNames) {
            _expectRequiredString(localizedName, 'locale');
            _expectRequiredString(localizedName, 'name');
            _expectRequiredString(localizedName, 'normalized_name');
            _expectRequiredString(localizedName, 'name_type');
            expect(localizedName['is_primary'], isA<bool>());
          }

          final destinationLinks = (poi['destination_links'] as List)
              .cast<Map<String, dynamic>>();
          expect(
            destinationLinks,
            isNotEmpty,
            reason: 'Missing destination link for ${poi['name']}',
          );
          for (final link in destinationLinks) {
            expect(link['destination_key'], equals(destinationKey));
            expect(link['destination_scope'], equals('city'));
            expect(
              link['relevance_score'],
              allOf(greaterThanOrEqualTo(0), lessThanOrEqualTo(100)),
            );
          }

          final externalRefs = (poi['external_refs'] as List)
              .cast<Map<String, dynamic>>();
          expect(
            externalRefs,
            isNotEmpty,
            reason: 'Missing manual slug ref for ${poi['name']}',
          );
          for (final ref in externalRefs) {
            expect(ref['ref_type'], equals('manual_slug'));
            _expectRequiredString(ref, 'ref_value');
          }

          final quality = poi['quality_scores'] as Map<String, dynamic>;
          expect(
            quality['touristic_importance'],
            allOf(greaterThanOrEqualTo(1), lessThanOrEqualTo(5)),
          );
          for (final key in [
            'editorial_score',
            'source_confidence',
            'category_priority',
            'duplicate_confidence',
            'freshness_score',
            'overall_score',
          ]) {
            expect(
              quality[key],
              allOf(greaterThanOrEqualTo(0), lessThanOrEqualTo(100)),
              reason: '$key out of range for ${poi['name']}',
            );
          }

          expect(poi['tags'], isA<List>());
          expect((poi['tags'] as List).cast<String>(), isNotEmpty);
        }

        _expectNoDeferredOrLiveFields(fixture);
      }
    });
  });
}

void _expectRequiredString(Map<String, dynamic> map, String key) {
  expect(map.containsKey(key), isTrue, reason: 'Missing required field "$key"');
  expect(map[key], isA<String>(), reason: 'Field "$key" must be a string');
  expect(
    (map[key] as String).trim(),
    isNotEmpty,
    reason: 'Field "$key" must not be blank',
  );
}

void _expectNoDeferredOrLiveFields(Object? value) {
  const forbiddenKeys = {
    'address',
    'formatted_address',
    'google_place_id',
    'opening_hours',
    'openingHours',
    'poi_opening_hours',
    'media',
    'poi_media',
    'photo',
    'photos',
    'photo_url',
    'photo_urls',
    'image',
    'image_url',
    'thumbnail_url',
    'rating',
    'ratings',
    'review_count',
    'reviews',
    'user_ratings_total',
  };

  if (value is Map) {
    for (final entry in value.entries) {
      final key = entry.key.toString();
      expect(
        forbiddenKeys.contains(key),
        isFalse,
        reason: 'Forbidden field present: $key',
      );
      _expectNoDeferredOrLiveFields(entry.value);
    }
  } else if (value is List) {
    for (final item in value) {
      _expectNoDeferredOrLiveFields(item);
    }
  } else if (value is String) {
    expect(
      value.startsWith('ChIJ'),
      isFalse,
      reason: 'Google Places-like ID found: $value',
    );
  }
}
