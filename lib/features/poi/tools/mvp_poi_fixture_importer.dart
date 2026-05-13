// MVP POI fixture importer.
//
// Reads static offline fixtures and builds Supabase table-shaped payloads.
// Dry-run is the default and only implemented behavior for now.

library;

import 'dart:convert';
import 'dart:io';

import 'package:voyage/config/live_api_guards.dart';
import 'package:voyage/features/poi/tools/supabase_live_guard.dart';

const mvpPoiFixtureImportWriteOperation = 'MvpPoiFixtureImporter.write';

const _fixturePaths = {
  'paris': 'assets/poi_fixtures/paris_mvp_pois.json',
  'lisbon': 'assets/poi_fixtures/lisbon_mvp_pois.json',
};

class MvpPoiFixtureImportException implements Exception {
  final String message;

  const MvpPoiFixtureImportException(this.message);

  @override
  String toString() => 'MvpPoiFixtureImportException: $message';
}

class MvpPoiFixtureImportOptions {
  final String city;
  final bool dryRun;
  final bool write;

  const MvpPoiFixtureImportOptions({
    this.city = 'all',
    this.dryRun = true,
    this.write = false,
  });

  factory MvpPoiFixtureImportOptions.fromArgs(List<String> args) {
    var city = 'all';
    var dryRun = true;
    var write = false;

    for (var i = 0; i < args.length; i++) {
      final arg = args[i];
      switch (arg) {
        case '--city':
          if (i + 1 >= args.length) {
            throw const MvpPoiFixtureImportException(
              'Missing value for --city. Expected paris, lisbon, or all.',
            );
          }
          city = args[++i];
        case '--dry-run':
          dryRun = true;
          write = false;
        case '--write':
          write = true;
          dryRun = false;
        case '--help':
        case '-h':
          throw const MvpPoiFixtureImportException(_usageText);
        default:
          throw MvpPoiFixtureImportException('Unknown argument: $arg');
      }
    }

    return MvpPoiFixtureImportOptions(city: city, dryRun: dryRun, write: write);
  }
}

class MvpPoiFixtureImporter {
  final String repoRoot;
  final LiveApiGuards guards;

  const MvpPoiFixtureImporter({
    this.repoRoot = '.',
    this.guards = const LiveApiGuards(),
  });

  Future<MvpPoiFixtureImportRun> run(MvpPoiFixtureImportOptions options) async {
    final cities = _citiesFor(options.city);

    if (options.write) {
      assertLiveSupabaseAllowedForPoiTool(
        operation: mvpPoiFixtureImportWriteOperation,
        guards: guards,
      );
      throw const MvpPoiFixtureImportException(
        '--write is guarded but intentionally deferred for MVP POI fixtures. '
        'This tool currently produces dry-run Supabase-ready payloads only.',
      );
    }

    final reports = <MvpPoiFixtureImportReport>[];
    for (final city in cities) {
      final fixture = _readFixture(city);
      reports.add(_buildReport(city, fixture, dryRun: options.dryRun));
    }

    return MvpPoiFixtureImportRun(dryRun: options.dryRun, reports: reports);
  }

  Map<String, dynamic> _readFixture(String city) {
    final relativePath = _fixturePaths[city];
    if (relativePath == null) {
      throw MvpPoiFixtureImportException('Unsupported city: $city');
    }

    final file = File('$repoRoot/$relativePath');
    if (!file.existsSync()) {
      throw MvpPoiFixtureImportException('Fixture not found: ${file.path}');
    }

    final decoded = json.decode(file.readAsStringSync());
    if (decoded is! Map<String, dynamic>) {
      throw MvpPoiFixtureImportException(
        'Fixture root must be a JSON object: ${file.path}',
      );
    }
    return decoded;
  }

  MvpPoiFixtureImportReport _buildReport(
    String city,
    Map<String, dynamic> fixture, {
    required bool dryRun,
  }) {
    _validateFixture(city, fixture);
    final payload = MvpPoiFixturePayload.fromFixture(fixture);
    return MvpPoiFixtureImportReport(
      city: city,
      dryRun: dryRun,
      payload: payload,
      importIssues: const [],
    );
  }
}

class MvpPoiFixturePayload {
  final List<Map<String, dynamic>> poiSources;
  final List<Map<String, dynamic>> poiCategories;
  final List<Map<String, dynamic>> pois;
  final List<Map<String, dynamic>> poiLocalizedNames;
  final List<Map<String, dynamic>> poiDestinationLinks;
  final List<Map<String, dynamic>> poiExternalRefs;
  final List<Map<String, dynamic>> poiQualityScores;
  final List<Map<String, dynamic>> poiImportBatches;
  final List<Map<String, dynamic>> poiImportIssues;
  final List<Map<String, dynamic>> poiEditorialOverrides;

  const MvpPoiFixturePayload({
    required this.poiSources,
    required this.poiCategories,
    required this.pois,
    required this.poiLocalizedNames,
    required this.poiDestinationLinks,
    required this.poiExternalRefs,
    required this.poiQualityScores,
    required this.poiImportBatches,
    required this.poiImportIssues,
    required this.poiEditorialOverrides,
  });

  factory MvpPoiFixturePayload.fromFixture(Map<String, dynamic> fixture) {
    final sources = (fixture['sources'] as List).cast<Map<String, dynamic>>();
    final categories = (fixture['categories'] as List)
        .cast<Map<String, dynamic>>();
    final pois = (fixture['pois'] as List).cast<Map<String, dynamic>>();
    final importBatch = fixture['import_batch'] as Map<String, dynamic>;
    final primarySourceId = sources.first['source_id'] as String;

    final poiRows = <Map<String, dynamic>>[];
    final localizedNames = <Map<String, dynamic>>[];
    final destinationLinks = <Map<String, dynamic>>[];
    final externalRefs = <Map<String, dynamic>>[];
    final qualityScores = <Map<String, dynamic>>[];

    for (final poi in pois) {
      final poiId = poi['poi_id'] as String;
      final quality = poi['quality_scores'] as Map<String, dynamic>;

      poiRows.add({
        'poi_id': poiId,
        'destination_key': poi['destination_key'],
        'name': poi['name'],
        'canonical_name': poi['canonical_name'],
        'normalized_name': poi['normalized_name'],
        'category': poi['category'],
        'primary_category_key': poi['primary_category_key'],
        'lat': poi['lat'],
        'lng': poi['lng'],
        'country_code': poi['country_code'],
        'zone_name': poi['neighborhood'],
        'source_primary_id': primarySourceId,
        'editorial_score': quality['editorial_score'],
        'touristic_importance': quality['touristic_importance'],
        'is_must_see': poi['is_must_see'],
        'is_family_friendly': poi['is_family_friendly'],
        'is_rain_friendly': poi['is_rain_friendly'],
        'typical_duration_minutes': poi['typical_duration_minutes'],
        'locality': poi['locality'],
        'neighborhood': poi['neighborhood'],
        'is_active': true,
        'is_hidden_gem': poi['is_hidden_gem'],
        'payload': {
          'poi_slug': poi['poi_slug'],
          'tags': poi['tags'],
          'fixture_schema_version': fixture['schema_version'],
        },
      });

      for (final localizedName
          in (poi['localized_names'] as List).cast<Map<String, dynamic>>()) {
        localizedNames.add({
          'poi_id': poiId,
          'locale': localizedName['locale'],
          'name': localizedName['name'],
          'normalized_name': localizedName['normalized_name'],
          'name_type': localizedName['name_type'],
          'is_primary': localizedName['is_primary'],
          'source_id': primarySourceId,
        });
      }

      for (final link
          in (poi['destination_links'] as List).cast<Map<String, dynamic>>()) {
        destinationLinks.add({
          'poi_id': poiId,
          'destination_key': link['destination_key'],
          'destination_scope': link['destination_scope'],
          'country_code': link['country_code'],
          'city_key': link['city_key'],
          'zone_key': link['zone_key'],
          'relevance_score': link['relevance_score'],
          'is_primary': link['is_primary'],
        });
      }

      for (final ref
          in (poi['external_refs'] as List).cast<Map<String, dynamic>>()) {
        externalRefs.add({
          'poi_id': poiId,
          'source_id': ref['source_id'],
          'ref_type': ref['ref_type'],
          'ref_value': ref['ref_value'],
          'source_payload': <String, dynamic>{},
        });
      }

      qualityScores.add({
        'poi_id': poiId,
        'touristic_importance': quality['touristic_importance'],
        'editorial_score': quality['editorial_score'],
        'source_confidence': quality['source_confidence'],
        'category_priority': quality['category_priority'],
        'duplicate_confidence': quality['duplicate_confidence'],
        'freshness_score': quality['freshness_score'],
        'overall_score': quality['overall_score'],
        'score_version': quality['score_version'],
        'explanation': {
          'fixture': fixture['fixture_name'],
          'must_see': poi['is_must_see'],
          'hidden_gem': poi['is_hidden_gem'],
        },
      });
    }

    return MvpPoiFixturePayload(
      poiSources: sources
          .map(
            (source) => {
              'source_id': source['source_id'],
              'name': source['name'],
              'source_type': source['source_type'],
              'trust_level': source['trust_level'],
              'is_active': source['is_active'],
              'notes': source['notes'],
            },
          )
          .toList(),
      poiCategories: categories
          .map(
            (category) => {
              'category_key': category['category_key'],
              'label_fr': category['label_fr'],
              'label_en': category['label_en'],
              'priority': category['priority'],
              'default_duration_minutes': category['default_duration_minutes'],
              'is_meal_category': false,
              'is_visit_category': true,
              'payload': <String, dynamic>{},
            },
          )
          .toList(),
      pois: poiRows,
      poiLocalizedNames: localizedNames,
      poiDestinationLinks: destinationLinks,
      poiExternalRefs: externalRefs,
      poiQualityScores: qualityScores,
      poiImportBatches: [
        {
          'batch_id': importBatch['batch_id'],
          'batch_type': importBatch['batch_type'],
          'destination_key': importBatch['destination_key'],
          'source_id': primarySourceId,
          'input_uri': _fixturePaths[fixture['destination_key']],
          'input_hash': importBatch['input_hash'],
          'status': importBatch['status'],
          'dry_run': importBatch['dry_run'],
          'summary': importBatch['summary'],
        },
      ],
      poiImportIssues: const [],
      poiEditorialOverrides: const [],
    );
  }

  Map<String, int> get counts => {
    'poi_sources': poiSources.length,
    'poi_categories': poiCategories.length,
    'pois': pois.length,
    'poi_localized_names': poiLocalizedNames.length,
    'poi_destination_links': poiDestinationLinks.length,
    'poi_external_refs': poiExternalRefs.length,
    'poi_quality_scores': poiQualityScores.length,
    'poi_import_batches': poiImportBatches.length,
    'poi_import_issues': poiImportIssues.length,
    'poi_editorial_overrides': poiEditorialOverrides.length,
  };
}

class MvpPoiFixtureImportReport {
  final String city;
  final bool dryRun;
  final MvpPoiFixturePayload payload;
  final List<Map<String, dynamic>> importIssues;

  const MvpPoiFixtureImportReport({
    required this.city,
    required this.dryRun,
    required this.payload,
    required this.importIssues,
  });

  String summaryText() {
    final counts = payload.counts;
    return [
      'city: $city',
      'dry_run: $dryRun',
      'poi_count: ${counts['pois']}',
      'destination_links_count: ${counts['poi_destination_links']}',
      'localized_names_count: ${counts['poi_localized_names']}',
      'quality_scores_count: ${counts['poi_quality_scores']}',
      'external_refs_count: ${counts['poi_external_refs']}',
      'import_issues_count: ${counts['poi_import_issues']}',
    ].join('\n');
  }
}

class MvpPoiFixtureImportRun {
  final bool dryRun;
  final List<MvpPoiFixtureImportReport> reports;

  const MvpPoiFixtureImportRun({required this.dryRun, required this.reports});

  String summaryText() =>
      reports.map((report) => report.summaryText()).join('\n---\n');
}

List<String> _citiesFor(String city) {
  switch (city) {
    case 'all':
      return const ['paris', 'lisbon'];
    case 'paris':
    case 'lisbon':
      return [city];
    default:
      throw MvpPoiFixtureImportException(
        'Unsupported city "$city". Expected paris, lisbon, or all.',
      );
  }
}

void _validateFixture(String city, Map<String, dynamic> fixture) {
  _expectString(fixture, 'schema_version');
  _expectString(fixture, 'destination_key');
  _expectList(fixture, 'sources');
  _expectList(fixture, 'categories');
  _expectList(fixture, 'pois');
  _expectMap(fixture, 'import_batch');

  if (fixture['destination_key'] != city) {
    throw MvpPoiFixtureImportException(
      'Fixture destination_key ${fixture['destination_key']} does not match $city.',
    );
  }

  final sources = (fixture['sources'] as List).cast<Map<String, dynamic>>();
  if (sources.isEmpty) {
    throw const MvpPoiFixtureImportException('Fixture must include a source.');
  }

  final sourceIds = <String>{};
  for (final source in sources) {
    _expectString(source, 'source_id');
    _expectString(source, 'name');
    _expectString(source, 'source_type');
    sourceIds.add(source['source_id'] as String);
  }

  final categories = (fixture['categories'] as List)
      .cast<Map<String, dynamic>>();
  final categoryKeys = <String>{};
  for (final category in categories) {
    _expectString(category, 'category_key');
    _expectString(category, 'label_fr');
    _expectString(category, 'label_en');
    _expectIntRange(category, 'priority', min: 0, max: 100);
    categoryKeys.add(category['category_key'] as String);
  }

  final ids = <String>{};
  final slugs = <String>{};
  final pois = (fixture['pois'] as List).cast<Map<String, dynamic>>();
  if (pois.isEmpty) {
    throw const MvpPoiFixtureImportException('Fixture must include POIs.');
  }

  for (final poi in pois) {
    _expectString(poi, 'poi_id');
    _expectString(poi, 'poi_slug');
    _expectString(poi, 'destination_key');
    _expectString(poi, 'name');
    _expectString(poi, 'canonical_name');
    _expectString(poi, 'normalized_name');
    _expectString(poi, 'category');
    _expectString(poi, 'primary_category_key');
    _expectString(poi, 'country_code');
    _expectString(poi, 'locality');
    _expectBool(poi, 'is_must_see');
    _expectBool(poi, 'is_hidden_gem');
    _expectIntRange(poi, 'typical_duration_minutes', min: 1);
    _expectList(poi, 'localized_names');
    _expectList(poi, 'destination_links');
    _expectList(poi, 'external_refs');
    _expectMap(poi, 'quality_scores');

    if (poi['destination_key'] != city) {
      throw MvpPoiFixtureImportException(
        'POI ${poi['poi_slug']} has destination_key ${poi['destination_key']} '
        'but expected $city.',
      );
    }
    if (!ids.add(poi['poi_id'] as String)) {
      throw MvpPoiFixtureImportException('Duplicate poi_id: ${poi['poi_id']}');
    }
    if (!slugs.add(poi['poi_slug'] as String)) {
      throw MvpPoiFixtureImportException(
        'Duplicate poi_slug: ${poi['poi_slug']}',
      );
    }
    if (!categoryKeys.contains(poi['primary_category_key'])) {
      throw MvpPoiFixtureImportException(
        'POI ${poi['poi_slug']} references unknown category '
        '${poi['primary_category_key']}.',
      );
    }
    if (poi.containsKey('lat')) {
      _expectNumRange(poi, 'lat', min: -90, max: 90);
    }
    if (poi.containsKey('lng')) {
      _expectNumRange(poi, 'lng', min: -180, max: 180);
    }
    if (poi.containsKey('lat') != poi.containsKey('lng')) {
      throw MvpPoiFixtureImportException(
        'POI ${poi['poi_slug']} must provide lat/lng together.',
      );
    }

    for (final localizedName
        in (poi['localized_names'] as List).cast<Map<String, dynamic>>()) {
      _expectString(localizedName, 'locale');
      _expectString(localizedName, 'name');
      _expectString(localizedName, 'normalized_name');
      _expectString(localizedName, 'name_type');
      _expectBool(localizedName, 'is_primary');
    }

    for (final link
        in (poi['destination_links'] as List).cast<Map<String, dynamic>>()) {
      _expectString(link, 'destination_key');
      _expectString(link, 'destination_scope');
      _expectString(link, 'country_code');
      _expectString(link, 'city_key');
      _expectIntRange(link, 'relevance_score', min: 0, max: 100);
    }

    for (final ref
        in (poi['external_refs'] as List).cast<Map<String, dynamic>>()) {
      _expectString(ref, 'source_id');
      _expectString(ref, 'ref_type');
      _expectString(ref, 'ref_value');
      if (!sourceIds.contains(ref['source_id'])) {
        throw MvpPoiFixtureImportException(
          'POI ${poi['poi_slug']} references unknown source ${ref['source_id']}.',
        );
      }
    }

    final quality = poi['quality_scores'] as Map<String, dynamic>;
    _expectIntRange(quality, 'touristic_importance', min: 1, max: 5);
    for (final key in [
      'editorial_score',
      'source_confidence',
      'category_priority',
      'duplicate_confidence',
      'freshness_score',
      'overall_score',
    ]) {
      _expectIntRange(quality, key, min: 0, max: 100);
    }
    _expectString(quality, 'score_version');
  }
}

void _expectString(Map<String, dynamic> map, String key) {
  final value = map[key];
  if (value is! String || value.trim().isEmpty) {
    throw MvpPoiFixtureImportException('Missing or invalid string field: $key');
  }
}

void _expectBool(Map<String, dynamic> map, String key) {
  if (map[key] is! bool) {
    throw MvpPoiFixtureImportException('Missing or invalid bool field: $key');
  }
}

void _expectList(Map<String, dynamic> map, String key) {
  if (map[key] is! List) {
    throw MvpPoiFixtureImportException('Missing or invalid list field: $key');
  }
}

void _expectMap(Map<String, dynamic> map, String key) {
  if (map[key] is! Map<String, dynamic>) {
    throw MvpPoiFixtureImportException('Missing or invalid object field: $key');
  }
}

void _expectIntRange(
  Map<String, dynamic> map,
  String key, {
  required int min,
  int? max,
}) {
  final value = map[key];
  if (value is! int || value < min || (max != null && value > max)) {
    final range = max == null ? '>=$min' : '$min..$max';
    throw MvpPoiFixtureImportException(
      'Missing or invalid integer field: $key ($range)',
    );
  }
}

void _expectNumRange(
  Map<String, dynamic> map,
  String key, {
  required num min,
  required num max,
}) {
  final value = map[key];
  if (value is! num || value < min || value > max) {
    throw MvpPoiFixtureImportException(
      'Missing or invalid numeric field: $key ($min..$max)',
    );
  }
}

const _usageText = '''
Usage: dart run tool/poi/import_mvp_poi_fixtures.dart [--city paris|lisbon|all] [--dry-run|--write]

Defaults:
  --city all
  --dry-run

Writes:
  --write is guarded by ALLOW_LIVE_SUPABASE=true but intentionally deferred.
''';
