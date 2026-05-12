// POI-0.5 — Tests unitaires des modèles domaine POI.
//
// Tests purement unitaires : aucun réseau, aucun Supabase, aucun
// provider Riverpod. Tous les modèles sont construits en mémoire.

import 'package:flutter_test/flutter_test.dart';
import 'package:voyage/features/poi/domain/poi.dart';
import 'package:voyage/features/poi/domain/poi_alias.dart';
import 'package:voyage/features/poi/domain/poi_quality_flag.dart';
import 'package:voyage/features/poi/domain/poi_source.dart';
import 'package:voyage/features/poi/domain/poi_source_link.dart';
import 'package:voyage/features/poi/domain/poi_tag.dart';

// ─── Helper builders ──────────────────────────────────────────────────

DateTime _ts(String iso) => DateTime.parse(iso);

PoiSource _validSource({
  String sourceId = 'a1b2c3d4-e5f6-7890-abcd-ef1234567890',
  String name = 'Singapore Tourism Board',
  PoiSourceType sourceType = PoiSourceType.officialBoard,
  int trustLevel = 5,
  bool isActive = true,
  String? baseUrl,
  String? licenseName,
  String? licenseUrl,
  String? notes,
}) {
  return PoiSource(
    sourceId: sourceId,
    name: name,
    sourceType: sourceType,
    trustLevel: trustLevel,
    isActive: isActive,
    baseUrl: baseUrl,
    licenseName: licenseName,
    licenseUrl: licenseUrl,
    notes: notes,
    createdAt: _ts('2024-01-15T10:00:00Z'),
    updatedAt: _ts('2024-01-15T10:00:00Z'),
  );
}

Poi _validPoi({
  String poiId = 'c3d4e5f6-a7b8-9012-cdef-123456789012',
  String destinationKey = 'singapore',
  String name = 'Gardens by the Bay',
  String normalizedName = 'gardens by the bay',
  PoiCategory category = PoiCategory.park,
  String sourcePrimaryId = 'a1b2c3d4-e5f6-7890-abcd-ef1234567890',
  double? lat = 1.2816,
  double? lng = 103.8636,
  int? editorialScore = 98,
  int? touristicImportance = 5,
  bool isMustSee = true,
  int? typicalDurationMinutes = 180,
  int? priceLevel = 2,
  Map<String, dynamic>? payload,
  String? subcategory,
  String? address,
  String? countryCode,
  bool? isFamilyFriendly,
  bool? isRainFriendly,
  bool? isFree,
  String? openingNotes,
  String? googlePlaceId,
}) {
  return Poi(
    poiId: poiId,
    destinationKey: destinationKey,
    name: name,
    normalizedName: normalizedName,
    category: category,
    sourcePrimaryId: sourcePrimaryId,
    lat: lat,
    lng: lng,
    editorialScore: editorialScore,
    touristicImportance: touristicImportance,
    isMustSee: isMustSee,
    typicalDurationMinutes: typicalDurationMinutes,
    priceLevel: priceLevel,
    payload: payload ?? const <String, dynamic>{},
    subcategory: subcategory,
    address: address,
    countryCode: countryCode,
    isFamilyFriendly: isFamilyFriendly,
    isRainFriendly: isRainFriendly,
    isFree: isFree,
    openingNotes: openingNotes,
    googlePlaceId: googlePlaceId,
    createdAt: _ts('2024-01-15T10:00:00Z'),
    updatedAt: _ts('2024-01-15T10:00:00Z'),
  );
}

PoiAlias _validAlias({
  String aliasId = 'f1a2b3c4-d5e6-7890-abcd-ef1234567890',
  String poiId = 'c3d4e5f6-a7b8-9012-cdef-123456789012',
  String alias = 'GBTB',
  String aliasNormalized = 'gbtb',
  bool isCanonical = false,
  String? sourceId,
}) {
  return PoiAlias(
    aliasId: aliasId,
    poiId: poiId,
    alias: alias,
    aliasNormalized: aliasNormalized,
    isCanonical: isCanonical,
    sourceId: sourceId,
    createdAt: _ts('2024-01-15T10:00:00Z'),
  );
}

PoiSourceLink _validLink({
  String linkId = 'g2b3c4d5-e6f7-8901-abcd-ef1234567890',
  String poiId = 'c3d4e5f6-a7b8-9012-cdef-123456789012',
  String sourceId = 'a1b2c3d4-e5f6-7890-abcd-ef1234567890',
  String? sourcePoiIdentifier,
  String? sourceUrl,
  Map<String, dynamic>? sourceRawData,
  DateTime? verifiedAt,
}) {
  return PoiSourceLink(
    linkId: linkId,
    poiId: poiId,
    sourceId: sourceId,
    sourcePoiIdentifier: sourcePoiIdentifier,
    sourceUrl: sourceUrl,
    sourceRawData: sourceRawData ?? const <String, dynamic>{},
    verifiedAt: verifiedAt,
    createdAt: _ts('2024-01-15T10:00:00Z'),
  );
}

PoiTag _validTag({
  String tagId = 'h3c4d5e6-f7a8-9012-abcd-ef1234567890',
  String poiId = 'c3d4e5f6-a7b8-9012-cdef-123456789012',
  String tag = 'night_photography',
  String? tagCategory = 'vibe',
  int? confidence = 95,
  String? sourceId,
}) {
  return PoiTag(
    tagId: tagId,
    poiId: poiId,
    tag: tag,
    tagCategory: tagCategory,
    confidence: confidence,
    sourceId: sourceId,
    createdAt: _ts('2024-01-15T10:00:00Z'),
  );
}

PoiQualityFlag _validFlag({
  String flagId = 'i4d5e6f7-a8b9-0123-abcd-ef1234567890',
  String poiId = 'c3d4e5f6-a7b8-9012-cdef-123456789012',
  PoiFlagType flagType = PoiFlagType.needsReview,
  String? flagReason = 'Coordinates seem off',
  String? reportedBy = 'system',
  DateTime? resolvedAt,
  String? resolutionNotes,
}) {
  return PoiQualityFlag(
    flagId: flagId,
    poiId: poiId,
    flagType: flagType,
    flagReason: flagReason,
    reportedBy: reportedBy,
    resolvedAt: resolvedAt,
    resolutionNotes: resolutionNotes,
    createdAt: _ts('2024-01-15T10:00:00Z'),
  );
}

// ──────────────────────────────────────────────────────────────────────

void main() {
  // ═══════════════════════════════════════════════════════════════════
  // 1. PoiSource
  // ═══════════════════════════════════════════════════════════════════

  group('PoiSource', () {
    group('construction & defaults', () {
      test('valid source passes validation', () {
        final s = _validSource();
        expect(s.validate(), isEmpty);
        expect(s.isValid, isTrue);
      });

      test('defaults are correct', () {
        final s = PoiSource(
          sourceId: 'x',
          name: 'Test',
          sourceType: PoiSourceType.editorial,
          createdAt: DateTime.now(),
          updatedAt: DateTime.now(),
        );
        expect(s.trustLevel, equals(PoiSource.defaultTrustLevel));
        expect(s.isActive, isTrue);
        expect(s.baseUrl, isNull);
        expect(s.licenseName, isNull);
      });

      test('trust_level out of range fails validation', () {
        final s = _validSource(trustLevel: 99);
        expect(s.validate(), isNotEmpty);
        expect(s.isValid, isFalse);
      });

      test('empty name fails validation', () {
        final s = _validSource(name: '');
        expect(s.validate(), isNotEmpty);
      });
    });

    group('round-trip JSON', () {
      test('toJson then fromJson preserves values', () {
        final original = _validSource(
          baseUrl: 'https://example.com',
          licenseName: 'CC0',
        );
        final json = original.toJson();
        final decoded = PoiSource.fromJson(json);

        expect(decoded.sourceId, equals(original.sourceId));
        expect(decoded.name, equals(original.name));
        expect(decoded.sourceType, equals(original.sourceType));
        expect(decoded.trustLevel, equals(original.trustLevel));
        expect(decoded.isActive, equals(original.isActive));
        expect(decoded.baseUrl, equals(original.baseUrl));
        expect(decoded.licenseName, equals(original.licenseName));
        expect(decoded.createdAt, equals(original.createdAt));
      });

      test('equality and hashCode match after round-trip', () {
        final original = _validSource();
        final json = original.toJson();
        final decoded = PoiSource.fromJson(json);
        expect(decoded, equals(original));
        expect(decoded.hashCode, equals(original.hashCode));
      });
    });

    group('fromJson defaults', () {
      test('missing trust_level defaults to 3', () {
        final json = {
          'source_id': 'x',
          'name': 'Test',
          'source_type': 'editorial',
          'created_at': '2024-01-01T00:00:00Z',
          'updated_at': '2024-01-01T00:00:00Z',
        };
        final s = PoiSource.fromJson(json);
        expect(s.trustLevel, equals(3));
      });

      test('missing is_active defaults to true', () {
        final json = {
          'source_id': 'x',
          'name': 'Test',
          'source_type': 'editorial',
          'created_at': '2024-01-01T00:00:00Z',
          'updated_at': '2024-01-01T00:00:00Z',
        };
        final s = PoiSource.fromJson(json);
        expect(s.isActive, isTrue);
      });

      test('missing created_at defaults to now-ish', () {
        final before = DateTime.now();
        final json = {
          'source_id': 'x',
          'name': 'Test',
          'source_type': 'editorial',
          'updated_at': '2024-01-01T00:00:00Z',
        };
        final s = PoiSource.fromJson(json);
        final after = DateTime.now();
        expect(s.createdAt.isAfter(before) || s.createdAt == before, isTrue);
        expect(s.createdAt.isBefore(after) || s.createdAt == after, isTrue);
      });
    });

    group('enum serialization', () {
      test('all PoiSourceType values round-trip', () {
        for (final t in PoiSourceType.values) {
          final s = PoiSource(
            sourceId: 'x',
            name: 'Test',
            sourceType: t,
            createdAt: DateTime.now(),
            updatedAt: DateTime.now(),
          );
          final json = s.toJson();
          expect(json['source_type'], equals(t.toJsonString()));
          final decoded = PoiSource.fromJson(json);
          expect(decoded.sourceType, equals(t));
        }
      });

      test('unknown source_type throws FormatException', () {
        final json = {
          'source_id': 'x',
          'name': 'Test',
          'source_type': 'bogus_type',
          'created_at': '2024-01-01T00:00:00Z',
          'updated_at': '2024-01-01T00:00:00Z',
        };
        expect(() => PoiSource.fromJson(json), throwsFormatException);
      });
    });

    group('DateTime parsing', () {
      test('accepts DateTime object directly', () {
        final dt = DateTime.utc(2024, 6, 1, 12, 0);
        final json = {
          'source_id': 'x',
          'name': 'Test',
          'source_type': 'editorial',
          'created_at': dt,
          'updated_at': dt,
        };
        final s = PoiSource.fromJson(json);
        expect(s.createdAt, equals(dt));
        expect(s.updatedAt, equals(dt));
      });

      test('accepts ISO 8601 string', () {
        final json = {
          'source_id': 'x',
          'name': 'Test',
          'source_type': 'editorial',
          'created_at': '2024-06-01T12:00:00.000Z',
          'updated_at': '2024-06-01T12:00:00.000Z',
        };
        final s = PoiSource.fromJson(json);
        expect(s.createdAt, equals(DateTime.utc(2024, 6, 1, 12, 0)));
      });
    });

    group('nullable fields', () {
      test('nullable fields can be null in toJson', () {
        final s = _validSource();
        final json = s.toJson();
        expect(json['license_url'], isNull);
        expect(json['notes'], isNull);
      });
    });
  });

  // ═══════════════════════════════════════════════════════════════════
  // 2. Poi
  // ═══════════════════════════════════════════════════════════════════

  group('Poi', () {
    group('construction & defaults', () {
      test('valid POI passes validation', () {
        final p = _validPoi();
        expect(p.validate(), isEmpty);
        expect(p.isValid, isTrue);
      });

      test('defaults are correct', () {
        final p = Poi(
          poiId: 'x',
          destinationKey: 'sg',
          name: 'Test',
          normalizedName: 'test',
          category: PoiCategory.museum,
          sourcePrimaryId: 's1',
          createdAt: DateTime.now(),
          updatedAt: DateTime.now(),
        );
        expect(p.isMustSee, isFalse);
        expect(p.payload, equals(<String, dynamic>{}));
        expect(p.lat, isNull);
        expect(p.editorialScore, isNull);
      });

      test('lat out of range fails validation', () {
        final p = _validPoi(lat: 999);
        expect(p.validate(), isNotEmpty);
      });

      test('lng out of range fails validation', () {
        final p = _validPoi(lng: -999);
        expect(p.validate(), isNotEmpty);
      });

      test('editorial_score out of range fails validation', () {
        final p = _validPoi(editorialScore: 101);
        expect(p.validate(), isNotEmpty);
      });

      test('touristic_importance out of range fails validation', () {
        final p = _validPoi(touristicImportance: 0);
        expect(p.validate(), isNotEmpty);
      });

      test('price_level out of range fails validation', () {
        final p = _validPoi(priceLevel: 5);
        expect(p.validate(), isNotEmpty);
      });

      test('typical_duration_minutes <= 0 fails validation', () {
        final p = _validPoi(typicalDurationMinutes: 0);
        expect(p.validate(), isNotEmpty);
      });

      test('empty normalized_name fails validation', () {
        final p = _validPoi(normalizedName: '');
        expect(p.validate(), isNotEmpty);
      });
    });

    group('round-trip JSON', () {
      test('toJson then fromJson preserves values', () {
        final original = _validPoi(
          subcategory: 'botanic_garden',
          address: '18 Marina Gardens Drive',
          countryCode: 'SG',
          isFamilyFriendly: true,
          isRainFriendly: true,
          isFree: false,
          openingNotes: 'Open daily',
          googlePlaceId: 'ChIJ...',
          payload: {'foo': 'bar'},
        );
        final json = original.toJson();
        final decoded = Poi.fromJson(json);

        expect(decoded.poiId, equals(original.poiId));
        expect(decoded.name, equals(original.name));
        expect(decoded.category, equals(original.category));
        expect(decoded.lat, equals(original.lat));
        expect(decoded.lng, equals(original.lng));
        expect(decoded.editorialScore, equals(original.editorialScore));
        expect(decoded.isMustSee, equals(original.isMustSee));
        expect(decoded.isFamilyFriendly, equals(original.isFamilyFriendly));
        expect(decoded.payload, equals(original.payload));
        expect(decoded.createdAt, equals(original.createdAt));
      });

      test('equality and hashCode match after round-trip', () {
        final original = _validPoi();
        final json = original.toJson();
        final decoded = Poi.fromJson(json);
        expect(decoded, equals(original));
        expect(decoded.hashCode, equals(original.hashCode));
      });
    });

    group('fromJson edge cases', () {
      test('lat and lng as int are accepted', () {
        final json = {
          'poi_id': 'x',
          'destination_key': 'sg',
          'name': 'Test',
          'normalized_name': 'test',
          'category': 'museum',
          'source_primary_id': 's1',
          'lat': 1,
          'lng': 103,
          'created_at': '2024-01-01T00:00:00Z',
          'updated_at': '2024-01-01T00:00:00Z',
        };
        final p = Poi.fromJson(json);
        expect(p.lat, equals(1.0));
        expect(p.lng, equals(103.0));
      });

      test('payload defaults to empty map when missing', () {
        final json = {
          'poi_id': 'x',
          'destination_key': 'sg',
          'name': 'Test',
          'normalized_name': 'test',
          'category': 'museum',
          'source_primary_id': 's1',
          'created_at': '2024-01-01T00:00:00Z',
          'updated_at': '2024-01-01T00:00:00Z',
        };
        final p = Poi.fromJson(json);
        expect(p.payload, equals(<String, dynamic>{}));
      });

      test('is_must_see defaults to false when missing', () {
        final json = {
          'poi_id': 'x',
          'destination_key': 'sg',
          'name': 'Test',
          'normalized_name': 'test',
          'category': 'museum',
          'source_primary_id': 's1',
          'created_at': '2024-01-01T00:00:00Z',
          'updated_at': '2024-01-01T00:00:00Z',
        };
        final p = Poi.fromJson(json);
        expect(p.isMustSee, isFalse);
      });
    });

    group('enum serialization', () {
      test('all PoiCategory values round-trip', () {
        for (final c in PoiCategory.values) {
          final p = Poi(
            poiId: 'x',
            destinationKey: 'sg',
            name: 'Test',
            normalizedName: 'test',
            category: c,
            sourcePrimaryId: 's1',
            createdAt: DateTime.now(),
            updatedAt: DateTime.now(),
          );
          final json = p.toJson();
          expect(json['category'], equals(c.toJsonString()));
          final decoded = Poi.fromJson(json);
          expect(decoded.category, equals(c));
        }
      });

      test('unknown category throws FormatException', () {
        final json = {
          'poi_id': 'x',
          'destination_key': 'sg',
          'name': 'Test',
          'normalized_name': 'test',
          'category': 'bogus_category',
          'source_primary_id': 's1',
          'created_at': '2024-01-01T00:00:00Z',
          'updated_at': '2024-01-01T00:00:00Z',
        };
        expect(() => Poi.fromJson(json), throwsFormatException);
      });
    });
  });

  // ═══════════════════════════════════════════════════════════════════
  // 3. PoiAlias
  // ═══════════════════════════════════════════════════════════════════

  group('PoiAlias', () {
    group('construction & defaults', () {
      test('valid alias passes validation', () {
        final a = _validAlias();
        expect(a.validate(), isEmpty);
        expect(a.isValid, isTrue);
      });

      test('is_canonical defaults to false', () {
        final a = PoiAlias(
          aliasId: 'x',
          poiId: 'p1',
          alias: 'Alias',
          aliasNormalized: 'alias',
          createdAt: DateTime.now(),
        );
        expect(a.isCanonical, isFalse);
      });

      test('empty alias fails validation', () {
        final a = _validAlias(alias: '');
        expect(a.validate(), isNotEmpty);
      });
    });

    group('round-trip JSON', () {
      test('toJson then fromJson preserves values', () {
        final original = _validAlias(isCanonical: true, sourceId: 's1');
        final json = original.toJson();
        final decoded = PoiAlias.fromJson(json);
        expect(decoded, equals(original));
        expect(decoded.hashCode, equals(original.hashCode));
      });
    });

    group('fromJson defaults', () {
      test('missing is_canonical defaults to false', () {
        final json = {
          'alias_id': 'x',
          'poi_id': 'p1',
          'alias': 'Alias',
          'alias_normalized': 'alias',
          'created_at': '2024-01-01T00:00:00Z',
        };
        final a = PoiAlias.fromJson(json);
        expect(a.isCanonical, isFalse);
      });
    });
  });

  // ═══════════════════════════════════════════════════════════════════
  // 4. PoiSourceLink
  // ═══════════════════════════════════════════════════════════════════

  group('PoiSourceLink', () {
    group('construction & defaults', () {
      test('valid link passes validation', () {
        final l = _validLink();
        expect(l.validate(), isEmpty);
        expect(l.isValid, isTrue);
      });

      test('source_raw_data defaults to empty map', () {
        final l = PoiSourceLink(
          linkId: 'x',
          poiId: 'p1',
          sourceId: 's1',
          createdAt: DateTime.now(),
        );
        expect(l.sourceRawData, equals(<String, dynamic>{}));
      });
    });

    group('round-trip JSON', () {
      test('toJson then fromJson preserves values', () {
        final original = _validLink(
          sourcePoiIdentifier: 'Q12345',
          sourceUrl: 'https://wikidata.org/wiki/Q12345',
          sourceRawData: {'raw': 'data'},
          verifiedAt: _ts('2024-06-01T12:00:00Z'),
        );
        final json = original.toJson();
        final decoded = PoiSourceLink.fromJson(json);
        expect(decoded, equals(original));
        expect(decoded.hashCode, equals(original.hashCode));
      });

      test('verified_at null round-trips', () {
        final original = _validLink();
        final json = original.toJson();
        expect(json['verified_at'], isNull);
        final decoded = PoiSourceLink.fromJson(json);
        expect(decoded.verifiedAt, isNull);
      });
    });

    group('fromJson defaults', () {
      test('missing source_raw_data defaults to empty map', () {
        final json = {
          'link_id': 'x',
          'poi_id': 'p1',
          'source_id': 's1',
          'created_at': '2024-01-01T00:00:00Z',
        };
        final l = PoiSourceLink.fromJson(json);
        expect(l.sourceRawData, equals(<String, dynamic>{}));
      });
    });
  });

  // ═══════════════════════════════════════════════════════════════════
  // 5. PoiTag
  // ═══════════════════════════════════════════════════════════════════

  group('PoiTag', () {
    group('construction & defaults', () {
      test('valid tag passes validation', () {
        final t = _validTag();
        expect(t.validate(), isEmpty);
        expect(t.isValid, isTrue);
      });

      test('confidence out of range fails validation', () {
        final t = _validTag(confidence: 101);
        expect(t.validate(), isNotEmpty);
      });

      test('negative confidence fails validation', () {
        final t = _validTag(confidence: -1);
        expect(t.validate(), isNotEmpty);
      });
    });

    group('round-trip JSON', () {
      test('toJson then fromJson preserves values', () {
        final original = _validTag();
        final json = original.toJson();
        final decoded = PoiTag.fromJson(json);
        expect(decoded, equals(original));
        expect(decoded.hashCode, equals(original.hashCode));
      });

      test('nullable fields can be null', () {
        final original = _validTag(
          tagCategory: null,
          confidence: null,
          sourceId: null,
        );
        final json = original.toJson();
        expect(json['tag_category'], isNull);
        expect(json['confidence'], isNull);
        expect(json['source_id'], isNull);
        final decoded = PoiTag.fromJson(json);
        expect(decoded.tagCategory, isNull);
        expect(decoded.confidence, isNull);
        expect(decoded.sourceId, isNull);
      });
    });
  });

  // ═══════════════════════════════════════════════════════════════════
  // 6. PoiQualityFlag
  // ═══════════════════════════════════════════════════════════════════

  group('PoiQualityFlag', () {
    group('construction & defaults', () {
      test('valid flag passes validation', () {
        final f = _validFlag();
        expect(f.validate(), isEmpty);
        expect(f.isValid, isTrue);
      });

      test('empty flag_id fails validation', () {
        final f = _validFlag(flagId: '');
        expect(f.validate(), isNotEmpty);
      });
    });

    group('round-trip JSON', () {
      test('toJson then fromJson preserves values', () {
        final original = _validFlag(
          resolvedAt: _ts('2024-06-01T12:00:00Z'),
          resolutionNotes: 'Fixed',
        );
        final json = original.toJson();
        final decoded = PoiQualityFlag.fromJson(json);
        expect(decoded, equals(original));
        expect(decoded.hashCode, equals(original.hashCode));
      });

      test('resolved_at null round-trips', () {
        final original = _validFlag();
        final json = original.toJson();
        expect(json['resolved_at'], isNull);
        final decoded = PoiQualityFlag.fromJson(json);
        expect(decoded.resolvedAt, isNull);
      });
    });

    group('enum serialization', () {
      test('all PoiFlagType values round-trip', () {
        for (final t in PoiFlagType.values) {
          final f = PoiQualityFlag(
            flagId: 'x',
            poiId: 'p1',
            flagType: t,
            createdAt: DateTime.now(),
          );
          final json = f.toJson();
          expect(json['flag_type'], equals(t.toJsonString()));
          final decoded = PoiQualityFlag.fromJson(json);
          expect(decoded.flagType, equals(t));
        }
      });

      test('unknown flag_type throws FormatException', () {
        final json = {
          'flag_id': 'x',
          'poi_id': 'p1',
          'flag_type': 'bogus_flag',
          'created_at': '2024-01-01T00:00:00Z',
        };
        expect(() => PoiQualityFlag.fromJson(json), throwsFormatException);
      });
    });
  });

  // ═══════════════════════════════════════════════════════════════════
  // 7. Cross-model coherence
  // ═══════════════════════════════════════════════════════════════════

  group('Cross-model coherence', () {
    test('all models use snake_case JSON keys', () {
      final source = _validSource().toJson();
      expect(source, contains('source_id'));
      expect(source, contains('source_type'));
      expect(source, contains('trust_level'));
      expect(source, contains('is_active'));
      expect(source, contains('created_at'));
      expect(source, contains('updated_at'));

      final poi = _validPoi().toJson();
      expect(poi, contains('poi_id'));
      expect(poi, contains('destination_key'));
      expect(poi, contains('normalized_name'));
      expect(poi, contains('source_primary_id'));
      expect(poi, contains('editorial_score'));
      expect(poi, contains('is_must_see'));
      expect(poi, contains('typical_duration_minutes'));
      expect(poi, contains('price_level'));
      expect(poi, contains('google_place_id'));
      expect(poi, contains('same_complex_group_key'));
      expect(poi, contains('created_at'));
      expect(poi, contains('updated_at'));

      final alias = _validAlias().toJson();
      expect(alias, contains('alias_id'));
      expect(alias, contains('poi_id'));
      expect(alias, contains('alias_normalized'));
      expect(alias, contains('is_canonical'));

      final link = _validLink().toJson();
      expect(link, contains('link_id'));
      expect(link, contains('poi_id'));
      expect(link, contains('source_id'));
      expect(link, contains('source_poi_identifier'));
      expect(link, contains('source_url'));
      expect(link, contains('source_raw_data'));
      expect(link, contains('verified_at'));

      final tag = _validTag().toJson();
      expect(tag, contains('tag_id'));
      expect(tag, contains('poi_id'));
      expect(tag, contains('tag_category'));

      final flag = _validFlag().toJson();
      expect(flag, contains('flag_id'));
      expect(flag, contains('poi_id'));
      expect(flag, contains('flag_type'));
      expect(flag, contains('flag_reason'));
      expect(flag, contains('reported_by'));
      expect(flag, contains('resolved_at'));
      expect(flag, contains('resolution_notes'));
    });

    test('all models have toString', () {
      expect(_validSource().toString(), contains('PoiSource'));
      expect(_validPoi().toString(), contains('Poi'));
      expect(_validAlias().toString(), contains('PoiAlias'));
      expect(_validLink().toString(), contains('PoiSourceLink'));
      expect(_validTag().toString(), contains('PoiTag'));
      expect(_validFlag().toString(), contains('PoiQualityFlag'));
    });
  });
}
