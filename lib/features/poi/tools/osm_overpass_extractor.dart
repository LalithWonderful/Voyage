/// POI-1.1 — Extracteur de POI depuis OpenStreetMap via Overpass API.
///
/// Outil 100 % Dart (pas de Flutter, pas de Riverpod, pas de Supabase).
/// Transforme une réponse Overpass JSON en fixture Lunao compatible
/// avec [PoiFixtureValidator] (POI-0.2).
///
/// ## Usage offline (tests)
///
/// ```dart
/// final extractor = OsmOverpassExtractor();
/// final result = extractor.extractFromResponse(
///   mockOverpassJson,
///   destinationKey: 'singapore',
///   countryCode: 'SG',
///   sourcePrimaryId: _osmSourceUuid,
/// );
/// ```
///
/// ## Usage live (opt-in explicite)
///
/// ```dart
/// final overpassJson = await extractor.fetchOverpass(bbox);
/// final result = extractor.extractFromResponse(...);
/// ```
///
/// ## Licence OSM
///
/// Les données OSM sont sous licence ODbL 1.0. Tout fixture généré doit
/// inclure l'attribution et la licence dans `_comment`.
library;

import 'dart:convert';
import 'dart:math';

import 'package:http/http.dart' as http;

// ─── Modèles publics ───

/// Bounding box géographique (WGS-84).
class BoundingBox {
  final double minLat;
  final double minLon;
  final double maxLat;
  final double maxLon;

  const BoundingBox({
    required this.minLat,
    required this.minLon,
    required this.maxLat,
    required this.maxLon,
  });

  /// Bbox approximatif de Singapour.
  static const singapore = BoundingBox(
    minLat: 1.1300,
    minLon: 103.5700,
    maxLat: 1.4700,
    maxLon: 104.1300,
  );

  /// Bbox approximatif de Paris intra-muros.
  static const paris = BoundingBox(
    minLat: 48.8156,
    minLon: 2.2241,
    maxLat: 48.9021,
    maxLon: 2.4699,
  );

  @override
  String toString() => 'BoundingBox($minLat,$minLon,$maxLat,$maxLon)';
}

/// Résultat d'une extraction Overpass → fixture.
class OsmExtractionResult {
  /// Fixture JSON compatible PoiFixtureValidator.
  final Map<String, dynamic> fixtureJson;

  /// Nombre total d'éléments OSM reçus.
  final int elementCount;

  /// Nombre d'éléments ignorés (sans nom, sans catégorie mappée, etc.).
  final int skippedCount;

  /// Avertissements non bloquants.
  final List<String> warnings;

  const OsmExtractionResult({
    required this.fixtureJson,
    required this.elementCount,
    required this.skippedCount,
    required this.warnings,
  });

  int get poiCount => (fixtureJson['pois'] as List<dynamic>).length;
}

// ─── Extracteur ───

/// Extracteur OSM/Overpass vers fixture Lunao.
class OsmOverpassExtractor {
  static const _overpassUrl = 'https://overpass-api.de/api/interpreter';

  /// Heuristiques de durée typique (minutes) par catégorie Lunao.
  static const _durationByCategory = <String, int>{
    'museum': 120,
    'monument': 45,
    'viewpoint': 30,
    'park': 90,
    'nature': 120,
    'beach': 120,
    'market': 60,
    'family': 240,
    'must_see': 60,
    'food': 60,
    'shopping': 90,
    'nightlife': 120,
    'wellness': 90,
    'transport_hub': 30,
    'photo_spot': 30,
    'rainy_day': 90,
    'local_experience': 90,
    'neighborhood': 120,
  };

  // ═══════════════════════════════════════════════════════════
  //  Requête Overpass
  // ═══════════════════════════════════════════════════════════

  /// Construit une requête Overpass QL pour la bounding box donnée.
  ///
  /// Les catégories touristiques ciblées :
  /// - `tourism=museum|attraction|viewpoint|theme_park|zoo|aquarium`
  /// - `historic=*`
  /// - `leisure=park|nature_reserve`
  /// - `amenity=marketplace`
  /// - `natural=beach`
  String buildOverpassQuery(BoundingBox bbox) {
    final s = bbox.minLat.toStringAsFixed(6);
    final w = bbox.minLon.toStringAsFixed(6);
    final n = bbox.maxLat.toStringAsFixed(6);
    final e = bbox.maxLon.toStringAsFixed(6);

    return '''
[out:json][timeout:90];
(
  node["tourism"="museum"]($s,$w,$n,$e);
  way["tourism"="museum"]($s,$w,$n,$e);
  relation["tourism"="museum"]($s,$w,$n,$e);

  node["tourism"="attraction"]($s,$w,$n,$e);
  way["tourism"="attraction"]($s,$w,$n,$e);
  relation["tourism"="attraction"]($s,$w,$n,$e);

  node["historic"]($s,$w,$n,$e);
  way["historic"]($s,$w,$n,$e);
  relation["historic"]($s,$w,$n,$e);

  node["leisure"="park"]($s,$w,$n,$e);
  way["leisure"="park"]($s,$w,$n,$e);
  relation["leisure"="park"]($s,$w,$n,$e);

  node["leisure"="nature_reserve"]($s,$w,$n,$e);
  way["leisure"="nature_reserve"]($s,$w,$n,$e);
  relation["leisure"="nature_reserve"]($s,$w,$n,$e);

  node["tourism"="viewpoint"]($s,$w,$n,$e);
  way["tourism"="viewpoint"]($s,$w,$n,$e);
  relation["tourism"="viewpoint"]($s,$w,$n,$e);

  node["amenity"="marketplace"]($s,$w,$n,$e);
  way["amenity"="marketplace"]($s,$w,$n,$e);
  relation["amenity"="marketplace"]($s,$w,$n,$e);

  node["tourism"="theme_park"]($s,$w,$n,$e);
  way["tourism"="theme_park"]($s,$w,$n,$e);
  relation["tourism"="theme_park"]($s,$w,$n,$e);

  node["tourism"="zoo"]($s,$w,$n,$e);
  way["tourism"="zoo"]($s,$w,$n,$e);
  relation["tourism"="zoo"]($s,$w,$n,$e);

  node["tourism"="aquarium"]($s,$w,$n,$e);
  way["tourism"="aquarium"]($s,$w,$n,$e);
  relation["tourism"="aquarium"]($s,$w,$n,$e);

  node["natural"="beach"]($s,$w,$n,$e);
  way["natural"="beach"]($s,$w,$n,$e);
  relation["natural"="beach"]($s,$w,$n,$e);
);
out center body;
>;
out skel qt;
'''.trim();
  }

  // ═══════════════════════════════════════════════════════════
  //  Appel réseau (live — opt-in explicite)
  // ═══════════════════════════════════════════════════════════

  /// Exécute une requête Overpass live et retourne le JSON brut.
  ///
  /// **À n'utiliser qu'avec opt-in explicite** (pas de test par défaut).
  /// Overpass est gratuit mais a des limites de fair-use :
  /// - ~1 req / seconde max
  /// - timeout serveur configurable (90s ici)
  Future<Map<String, dynamic>> fetchOverpass(
    BoundingBox bbox, {
    http.Client? client,
    Duration? timeout,
  }) async {
    final c = client ?? http.Client();
    final query = buildOverpassQuery(bbox);

    final response = await c
        .post(
          Uri.parse(_overpassUrl),
          body: query,
          headers: {'Content-Type': 'application/x-www-form-urlencoded'},
        )
        .timeout(timeout ?? const Duration(minutes: 2));

    if (response.statusCode != 200) {
      final snippet = response.body.length > 200
          ? response.body.substring(0, 200)
          : response.body;
      throw OverpassException(
        'HTTP ${response.statusCode}: $snippet',
      );
    }

    return json.decode(response.body) as Map<String, dynamic>;
  }

  // ═══════════════════════════════════════════════════════════
  //  Transformation Overpass → Fixture Lunao
  // ═══════════════════════════════════════════════════════════

  /// Transforme un JSON Overpass en fixture Lunao validable.
  OsmExtractionResult extractFromResponse(
    Map<String, dynamic> overpassJson, {
    required String destinationKey,
    required String countryCode,
    required String sourcePrimaryId,
  }) {
    final elements = (overpassJson['elements'] as List<dynamic>? ?? [])
        .cast<Map<String, dynamic>>();

    final warnings = <String>[];
    final poiList = <Map<String, dynamic>>[];
    var skipped = 0;
    final seenOsmIds = <String>{};

    for (final element in elements) {
      final type = element['type'] as String? ?? '';
      final id = element['id'] as int? ?? 0;
      final osmKey = '$type:$id';

      if (!seenOsmIds.add(osmKey)) continue; // dédoublonnage

      final tags = (element['tags'] as Map<String, dynamic>?) ?? {};

      // Pas de nom utilisable → skip
      final name = _sanitizeName(tags['name'] as String?);
      if (name == null || name.isEmpty) {
        skipped++;
        continue;
      }

      final category = _mapCategory(tags);
      if (category == null) {
        skipped++;
        continue;
      }

      // Coordonnées obligatoires
      final coords = _extractCoordinates(element);
      if (coords == null) {
        warnings.add('$osmKey: pas de coordonnées, ignoré');
        skipped++;
        continue;
      }

      final poiId = _randomUuid();
      final aliases = _buildAliases(name, tags);
      final tagsList = _buildTags(tags, category);
      final feeTag = tags['fee'] as String?;

      poiList.add(<String, dynamic>{
        'poi_id': poiId,
        'destination_key': destinationKey,
        'name': name,
        'normalized_name': _normalizeName(name),
        'category': category,
        'subcategory': _mapSubcategory(tags),
        'lat': coords.lat,
        'lng': coords.lon,
        'address': _buildAddress(tags),
        'country_code': countryCode,
        'zone_name': tags['addr:district'] as String? ??
            tags['addr:suburb'] as String?,
        'official_url': tags['website'] as String? ??
            tags['contact:website'] as String?,
        'source_primary_id': sourcePrimaryId,
        'editorial_score': _estimateEditorialScore(tags),
        'touristic_importance': _estimateTouristicImportance(category, tags),
        'is_must_see': category == 'must_see',
        'is_family_friendly': _isFamilyFriendly(category, tags),
        'is_rain_friendly': _isRainFriendly(category, tags),
        'is_free': feeTag == 'no',
        'typical_duration_minutes': _durationByCategory[category] ?? 60,
        'opening_notes': null,
        'price_level': _estimatePriceLevel(feeTag, tags),
        'google_place_id': null,
        'same_complex_group_key': null,
        'aliases': aliases,
        'tags': tagsList,
      });
    }

    final fixture = <String, dynamic>{
      '_comment': 'Generated by OsmOverpassExtractor from OpenStreetMap. '
          'License: ODbL 1.0 — https://opendatacommons.org/licenses/odbl/1.0/',
      'sources': [
        {
          'source_id': sourcePrimaryId,
          'name': 'OpenStreetMap',
          'source_type': 'openstreetmap',
          'base_url': 'https://www.openstreetmap.org',
          'license_name': 'ODbL 1.0',
          'license_url': 'https://opendatacommons.org/licenses/odbl/1.0/',
          'trust_level': 3,
          'is_active': true,
        },
      ],
      'pois': poiList,
    };

    return OsmExtractionResult(
      fixtureJson: fixture,
      elementCount: elements.length,
      skippedCount: skipped,
      warnings: warnings,
    );
  }

  // ═══════════════════════════════════════════════════════════
  //  Helpers privés
  // ═══════════════════════════════════════════════════════════

  static String _normalizeName(String name) =>
      name.toLowerCase().trim().replaceAll(RegExp(r'\s+'), ' ');

  static String? _sanitizeName(String? raw) {
    if (raw == null) return null;
    final cleaned = raw.trim();
    return cleaned.isEmpty ? null : cleaned;
  }

  /// UUID v4 pseudo-aléatoire (suffisant pour un script CLI).
  static String _randomUuid() {
    final rnd = Random();
    final bytes = List<int>.generate(16, (_) => rnd.nextInt(256));
    bytes[6] = (bytes[6] & 0x0F) | 0x40; // version 4
    bytes[8] = (bytes[8] & 0x3F) | 0x80; // variant RFC 4122
    final hex = bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
    return '${hex.substring(0, 8)}-${hex.substring(8, 12)}-'
        '${hex.substring(12, 16)}-${hex.substring(16, 20)}-${hex.substring(20, 32)}';
  }

  static ({double lat, double lon})? _extractCoordinates(
    Map<String, dynamic> element,
  ) {
    // Node
    final lat = element['lat'] as double?;
    final lon = element['lon'] as double?;
    if (lat != null && lon != null) return (lat: lat, lon: lon);

    // Way / Relation avec `out center`
    final center = element['center'] as Map<String, dynamic>?;
    if (center != null) {
      final cLat = center['lat'] as double?;
      final cLon = center['lon'] as double?;
      if (cLat != null && cLon != null) return (lat: cLat, lon: cLon);
    }
    return null;
  }

  // ─── Mapping OSM → Lunao ───

  /// Mappe les tags OSM vers une catégorie Lunao.
  /// Retourne `null` si aucune catégorie ne correspond.
  static String? _mapCategory(Map<String, dynamic> tags) {
    final tourism = tags['tourism'] as String?;
    final historic = tags['historic'] as String?;
    final leisure = tags['leisure'] as String?;
    final natural = tags['natural'] as String?;
    final amenity = tags['amenity'] as String?;

    // Ordre de priorité (du plus spécifique au plus général)
    if (tourism == 'museum') return 'museum';
    if (tourism == 'theme_park' ||
        tourism == 'zoo' ||
        tourism == 'aquarium') {
      return 'family';
    }
    if (tourism == 'viewpoint') return 'viewpoint';
    if (historic == 'monument' || historic == 'memorial') return 'monument';
    if (historic == 'castle' || historic == 'fort') return 'monument';
    if (historic != null && historic.isNotEmpty) return 'monument';
    if (leisure == 'park') return 'park';
    if (leisure == 'nature_reserve') return 'nature';
    if (natural == 'beach') return 'beach';
    if (amenity == 'marketplace') return 'market';
    if (tourism == 'attraction') return 'must_see';

    return null;
  }

  static String? _mapSubcategory(Map<String, dynamic> tags) {
    for (final key in ['tourism', 'historic', 'leisure', 'natural', 'amenity']) {
      final v = tags[key] as String?;
      if (v != null && v.isNotEmpty) return v;
    }
    return null;
  }

  static String? _buildAddress(Map<String, dynamic> tags) {
    final parts = <String>[];
    final housenumber = tags['addr:housenumber'] as String?;
    final street = tags['addr:street'] as String?;
    final city = tags['addr:city'] as String?;
    if (housenumber != null) parts.add(housenumber);
    if (street != null) parts.add(street);
    if (city != null) parts.add(city);
    return parts.isEmpty ? null : parts.join(', ');
  }

  static List<Map<String, dynamic>> _buildAliases(
    String name,
    Map<String, dynamic> tags,
  ) {
    final aliases = <Map<String, dynamic>>[
      {
        'alias': name,
        'alias_normalized': _normalizeName(name),
        'is_canonical': true,
      },
    ];
    for (final altKey in ['alt_name', 'old_name', 'name:en']) {
      final alt = _sanitizeName(tags[altKey] as String?);
      if (alt != null && alt != name && alt.isNotEmpty) {
        aliases.add({
          'alias': alt,
          'alias_normalized': _normalizeName(alt),
          'is_canonical': false,
        });
      }
    }
    return aliases;
  }

  static int _estimateEditorialScore(Map<String, dynamic> tags) {
    var score = 60;
    if (tags.containsKey('wikipedia')) score += 15;
    if (tags.containsKey('wikidata')) score += 10;
    if (tags.containsKey('website') || tags.containsKey('contact:website')) {
      score += 5;
    }
    return score.clamp(0, 100);
  }

  static int _estimateTouristicImportance(
    String category,
    Map<String, dynamic> tags,
  ) {
    return switch (category) {
      'must_see' => 5,
      'museum' || 'monument' || 'family' => 4,
      'viewpoint' || 'park' || 'beach' || 'market' => 3,
      _ => 2,
    };
  }

  static bool _isFamilyFriendly(String category, Map<String, dynamic> tags) =>
      const {'family', 'park', 'beach', 'museum', 'viewpoint'}
          .contains(category);

  static bool _isRainFriendly(String category, Map<String, dynamic> tags) =>
      category == 'museum' || category == 'family';

  static int? _estimatePriceLevel(String? feeTag, Map<String, dynamic> tags) {
    if (feeTag == 'no') return 1;
    if (feeTag == 'yes') {
      final tourism = tags['tourism'] as String?;
      if (tourism == 'theme_park' || tourism == 'zoo' || tourism == 'aquarium') {
        return 3;
      }
      if (tourism == 'museum') return 2;
      return 2;
    }
    return null;
  }

  static List<Map<String, dynamic>> _buildTags(
    Map<String, dynamic> tags,
    String category,
  ) {
    final result = <Map<String, dynamic>>[];

    void add(String tag, String tagCategory, int confidence) {
      result.add({
        'tag': tag,
        'tag_category': tagCategory,
        'confidence': confidence,
      });
    }

    if (tags.containsKey('historic')) add('historic', 'vibe', 85);
    if (tags.containsKey('wikipedia') || tags.containsKey('wikidata')) {
      add('cultural', 'vibe', 80);
    }
    if (const {'park', 'nature', 'beach'}.contains(category)) {
      add('outdoor', 'vibe', 90);
    }
    if (category == 'museum') add('rainy_day', 'activity_type', 85);
    if (category == 'family') add('family_friendly', 'audience', 95);
    if (const {'viewpoint', 'photo_spot'}.contains(category)) {
      add('photo_spot', 'vibe', 90);
    }
    if (tags.containsKey('wheelchair')) {
      add('wheelchair_accessible', 'accessibility', 80);
    }

    return result;
  }
}

/// Exception Overpass.
class OverpassException implements Exception {
  final String message;
  OverpassException(this.message);
  @override
  String toString() => 'OverpassException: $message';
}
