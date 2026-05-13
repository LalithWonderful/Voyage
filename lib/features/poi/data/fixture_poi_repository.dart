/// Offline POI repository backed by MVP fixture JSON.
///
/// This repository is pure local data access: no Supabase client, no network,
/// no Google Places fallback. Runtime providers are intentionally not wired yet.
library;

import 'dart:convert';
import 'dart:io';

import '../domain/poi.dart';
import '../domain/poi_repository.dart';

const _defaultFixturePaths = {
  'paris': 'assets/poi_fixtures/paris_mvp_pois.json',
  'lisbon': 'assets/poi_fixtures/lisbon_mvp_pois.json',
};

class FixturePoiRepository implements PoiRepository {
  final List<Poi> _pois;
  final Map<String, Set<String>> _searchNamesByPoiId;

  const FixturePoiRepository._({
    required List<Poi> pois,
    required Map<String, Set<String>> searchNamesByPoiId,
  }) : _pois = pois,
       _searchNamesByPoiId = searchNamesByPoiId;

  factory FixturePoiRepository.fromDecodedFixtures(
    Iterable<Map<String, dynamic>> fixtures,
  ) {
    final pois = <Poi>[];
    final searchNamesByPoiId = <String, Set<String>>{};

    for (final fixture in fixtures) {
      final sourceId = _primarySourceId(fixture);
      final rawPois = (fixture['pois'] as List).cast<Map<String, dynamic>>();

      for (final rawPoi in rawPois) {
        final poi = _poiFromFixture(rawPoi, sourceId: sourceId);
        pois.add(poi);
        searchNamesByPoiId[poi.poiId] = _searchNamesFromFixturePoi(rawPoi);
      }
    }

    return FixturePoiRepository._(
      pois: List.unmodifiable(pois),
      searchNamesByPoiId: {
        for (final entry in searchNamesByPoiId.entries)
          entry.key: Set.unmodifiable(entry.value),
      },
    );
  }

  static Future<FixturePoiRepository> loadDefaultFixtures({
    String repoRoot = '.',
  }) async {
    final decoded = <Map<String, dynamic>>[];

    for (final path in _defaultFixturePaths.values) {
      final file = File('$repoRoot/$path');
      final root = json.decode(await file.readAsString());
      if (root is! Map<String, dynamic>) {
        throw FormatException('Fixture root must be an object: ${file.path}');
      }
      decoded.add(root);
    }

    return FixturePoiRepository.fromDecodedFixtures(decoded);
  }

  Future<List<Poi>> getPoisForDestination(String destinationKey) {
    return listPoisByDestination(destinationKey);
  }

  Future<List<Poi>> getMustSeePois(String destinationKey) async {
    final matched = _pois
        .where((poi) => poi.destinationKey == destinationKey && poi.isMustSee)
        .toList(growable: false);
    _sortPois(matched);
    return matched;
  }

  Future<List<Poi>> getPoisByCategory(
    String destinationKey,
    PoiCategory category,
  ) {
    return getPoisByCategories(destinationKey, [category]);
  }

  @override
  Future<List<Poi>> listPoisByDestination(String destinationKey) async {
    final matched = _pois
        .where((poi) => poi.destinationKey == destinationKey)
        .toList(growable: false);
    _sortPois(matched);
    return matched;
  }

  @override
  Future<Poi?> getPoiById(String poiId) async {
    for (final poi in _pois) {
      if (poi.poiId == poiId) return poi;
    }
    return null;
  }

  @override
  Future<List<Poi>> getTopPoisForDestination(
    String destinationKey,
    int limit,
  ) async {
    final matched = await listPoisByDestination(destinationKey);
    if (limit > 0 && matched.length > limit) {
      return matched.sublist(0, limit);
    }
    return matched;
  }

  @override
  Future<List<Poi>> getPoisByCategories(
    String destinationKey,
    List<PoiCategory> categories,
  ) async {
    if (categories.isEmpty) return [];
    final categorySet = categories.toSet();
    final matched = _pois
        .where(
          (poi) =>
              poi.destinationKey == destinationKey &&
              categorySet.contains(poi.category),
        )
        .toList(growable: false);
    _sortPois(matched);
    return matched;
  }

  @override
  Future<List<Poi>> searchPois({
    required String destinationKey,
    String? query,
    List<String>? tags,
    PoiCategory? category,
    bool mustSeeOnly = false,
    int? limit,
  }) async {
    var candidates = _pois.where((poi) => poi.destinationKey == destinationKey);

    final normalizedQuery = _normalize(query);
    if (normalizedQuery != null) {
      candidates = candidates.where((poi) {
        final names = _searchNamesByPoiId[poi.poiId] ?? const <String>{};
        return names.any((name) => name.contains(normalizedQuery));
      });
    }

    if (tags != null && tags.isNotEmpty) {
      final normalizedTags = tags.map(_normalizeRequired).toSet();
      candidates = candidates.where((poi) {
        final rawTags = poi.payload['tags'];
        if (rawTags is! List) return false;
        return rawTags
            .whereType<String>()
            .map(_normalizeRequired)
            .any(normalizedTags.contains);
      });
    }

    if (category != null) {
      candidates = candidates.where((poi) => poi.category == category);
    }

    if (mustSeeOnly) {
      candidates = candidates.where((poi) => poi.isMustSee);
    }

    final result = candidates.toList(growable: false);
    _sortPois(result);

    if (limit != null && limit > 0 && result.length > limit) {
      return result.sublist(0, limit);
    }
    return result;
  }

  static Poi _poiFromFixture(
    Map<String, dynamic> rawPoi, {
    required String sourceId,
  }) {
    final quality = rawPoi['quality_scores'] as Map<String, dynamic>;
    final now = DateTime.utc(2026, 5, 13);

    return Poi(
      poiId: rawPoi['poi_id'] as String,
      destinationKey: rawPoi['destination_key'] as String,
      name: rawPoi['name'] as String,
      normalizedName: rawPoi['normalized_name'] as String,
      category: PoiCategory.fromJsonString(rawPoi['category'] as String),
      lat: _optionalDouble(rawPoi['lat']),
      lng: _optionalDouble(rawPoi['lng']),
      countryCode: rawPoi['country_code'] as String?,
      zoneName: rawPoi['neighborhood'] as String?,
      sourcePrimaryId: sourceId,
      editorialScore: quality['editorial_score'] as int?,
      touristicImportance: quality['touristic_importance'] as int?,
      isMustSee: rawPoi['is_must_see'] as bool? ?? false,
      isFamilyFriendly: rawPoi['is_family_friendly'] as bool?,
      isRainFriendly: rawPoi['is_rain_friendly'] as bool?,
      typicalDurationMinutes: rawPoi['typical_duration_minutes'] as int?,
      payload: {
        'poi_slug': rawPoi['poi_slug'],
        'canonical_name': rawPoi['canonical_name'],
        'primary_category_key': rawPoi['primary_category_key'],
        'locality': rawPoi['locality'],
        'neighborhood': rawPoi['neighborhood'],
        'is_hidden_gem': rawPoi['is_hidden_gem'],
        'tags': rawPoi['tags'],
        'quality_scores': quality,
      },
      createdAt: now,
      updatedAt: now,
    );
  }

  static String _primarySourceId(Map<String, dynamic> fixture) {
    final sources = (fixture['sources'] as List).cast<Map<String, dynamic>>();
    if (sources.isEmpty) {
      throw const FormatException('Fixture must contain at least one source.');
    }
    return sources.first['source_id'] as String;
  }

  static Set<String> _searchNamesFromFixturePoi(Map<String, dynamic> rawPoi) {
    final names = <String>{
      rawPoi['name'] as String,
      rawPoi['normalized_name'] as String,
      rawPoi['canonical_name'] as String,
    };

    final localizedNames = (rawPoi['localized_names'] as List)
        .cast<Map<String, dynamic>>();
    for (final localizedName in localizedNames) {
      names.add(localizedName['name'] as String);
      names.add(localizedName['normalized_name'] as String);
    }

    return names.map(_normalizeRequired).toSet();
  }

  static double? _optionalDouble(Object? value) {
    if (value == null) return null;
    if (value is num) return value.toDouble();
    throw FormatException('Expected numeric coordinate, got $value');
  }

  static void _sortPois(List<Poi> pois) {
    pois.sort((a, b) {
      final mustSeeCmp = _boolRank(
        b.isMustSee,
      ).compareTo(_boolRank(a.isMustSee));
      if (mustSeeCmp != 0) return mustSeeCmp;

      final importanceCmp = (b.touristicImportance ?? -1).compareTo(
        a.touristicImportance ?? -1,
      );
      if (importanceCmp != 0) return importanceCmp;

      final editorialCmp = (b.editorialScore ?? -1).compareTo(
        a.editorialScore ?? -1,
      );
      if (editorialCmp != 0) return editorialCmp;

      final slugCmp = _slug(a).compareTo(_slug(b));
      if (slugCmp != 0) return slugCmp;

      return a.poiId.compareTo(b.poiId);
    });
  }

  static int _boolRank(bool value) => value ? 1 : 0;

  static String _slug(Poi poi) {
    final rawSlug = poi.payload['poi_slug'];
    return rawSlug is String ? rawSlug : poi.poiId;
  }

  static String? _normalize(String? value) {
    if (value == null) return null;
    final normalized = _normalizeRequired(value);
    return normalized.isEmpty ? null : normalized;
  }

  static String _normalizeRequired(String value) {
    return value.trim().toLowerCase();
  }
}
