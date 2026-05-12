/// POI-0.5 — Modèle domaine `Poi`.
///
/// Cœur de la base de connaissances POI Lunao. Aligné strictement avec
/// `public.pois` du schéma SQL (`supabase/sql/poi_knowledge_base.sql`).
///
/// Couche domain pure : aucun Supabase, aucun réseau, aucun provider.
library;

/// Catégories POI autorisées. Cohérent avec la contrainte CHECK
/// `pois_category_check` du DDL.
enum PoiCategory {
  mustSee,
  museum,
  monument,
  viewpoint,
  park,
  nature,
  beach,
  neighborhood,
  market,
  food,
  shopping,
  nightlife,
  family,
  wellness,
  transportHub,
  photoSpot,
  rainyDay,
  localExperience;

  static const _toSql = <PoiCategory, String>{
    mustSee: 'must_see',
    museum: 'museum',
    monument: 'monument',
    viewpoint: 'viewpoint',
    park: 'park',
    nature: 'nature',
    beach: 'beach',
    neighborhood: 'neighborhood',
    market: 'market',
    food: 'food',
    shopping: 'shopping',
    nightlife: 'nightlife',
    family: 'family',
    wellness: 'wellness',
    transportHub: 'transport_hub',
    photoSpot: 'photo_spot',
    rainyDay: 'rainy_day',
    localExperience: 'local_experience',
  };

  static final _fromSql = <String, PoiCategory>{
    for (final e in _toSql.entries) e.value: e.key,
  };

  String toJsonString() => _toSql[this]!;

  static PoiCategory fromJsonString(String raw) {
    final v = _fromSql[raw];
    if (v == null) {
      throw FormatException('Unknown PoiCategory value: "$raw"');
    }
    return v;
  }
}

/// Lieu touristique de référence Lunao.
class Poi {
  /// UUID primary key.
  final String poiId;

  /// Clé destination (ex: "singapore").
  final String destinationKey;

  /// Nom user-facing.
  final String name;

  /// Nom normalisé (lower, trim, collapse espaces) pour matching.
  final String normalizedName;

  /// Catégorie éditoriale (contrainte SQL CHECK).
  final PoiCategory category;

  /// Sous-catégorie libre (ex: "botanic_garden", "integrated_resort").
  final String? subcategory;

  /// Latitude WGS-84. Nullable. Contrainte SQL : null ou [-90, 90].
  final double? lat;

  /// Longitude WGS-84. Nullable. Contrainte SQL : null ou [-180, 180].
  final double? lng;

  final String? address;
  final String? countryCode;
  final String? zoneName;
  final String? officialUrl;

  /// FK vers `poi_sources.source_id` (source primaire / éditoriale).
  final String sourcePrimaryId;

  /// Score qualité Lunao 0-100. Nullable.
  final int? editorialScore;

  /// Importance touristique 1-5. Nullable.
  final int? touristicImportance;

  /// Must-see éditorial. Default `false`.
  final bool isMustSee;

  final bool? isFamilyFriendly;
  final bool? isRainFriendly;
  final bool? isFree;

  /// Durée typique de visite en minutes. Nullable. Contrainte SQL : > 0.
  final int? typicalDurationMinutes;

  final String? openingNotes;

  /// Niveau de prix 1-4. Nullable.
  final int? priceLevel;

  /// Place ID Google pour enrichissement futur contrôlé.
  final String? googlePlaceId;

  /// Référence vers `same_complex_groups.complex_key` (Phase 2+).
  final String? sameComplexGroupKey;

  /// Champs extensibles futurs sans migration. Default `{}`.
  final Map<String, dynamic> payload;

  final DateTime createdAt;
  final DateTime updatedAt;

  static const int minEditorialScore = 0;
  static const int maxEditorialScore = 100;
  static const int minTouristicImportance = 1;
  static const int maxTouristicImportance = 5;
  static const int minPriceLevel = 1;
  static const int maxPriceLevel = 4;

  const Poi({
    required this.poiId,
    required this.destinationKey,
    required this.name,
    required this.normalizedName,
    required this.category,
    this.subcategory,
    this.lat,
    this.lng,
    this.address,
    this.countryCode,
    this.zoneName,
    this.officialUrl,
    required this.sourcePrimaryId,
    this.editorialScore,
    this.touristicImportance,
    this.isMustSee = false,
    this.isFamilyFriendly,
    this.isRainFriendly,
    this.isFree,
    this.typicalDurationMinutes,
    this.openingNotes,
    this.priceLevel,
    this.googlePlaceId,
    this.sameComplexGroupKey,
    this.payload = const <String, dynamic>{},
    required this.createdAt,
    required this.updatedAt,
  });

  List<String> validate({String prefix = 'Poi'}) {
    final errors = <String>[];
    if (poiId.trim().isEmpty) {
      errors.add('$prefix.poi_id must be non-empty');
    }
    if (destinationKey.trim().isEmpty) {
      errors.add('$prefix.destination_key must be non-empty');
    }
    if (name.trim().isEmpty) {
      errors.add('$prefix.name must be non-empty');
    }
    if (normalizedName.trim().isEmpty) {
      errors.add('$prefix.normalized_name must be non-empty');
    }
    if (sourcePrimaryId.trim().isEmpty) {
      errors.add('$prefix.source_primary_id must be non-empty');
    }
    if (lat != null && (lat! < -90 || lat! > 90 || lat!.isNaN)) {
      errors.add('$prefix.lat must be in [-90, 90] or null, got $lat');
    }
    if (lng != null && (lng! < -180 || lng! > 180 || lng!.isNaN)) {
      errors.add('$prefix.lng must be in [-180, 180] or null, got $lng');
    }
    if (editorialScore != null &&
        (editorialScore! < minEditorialScore || editorialScore! > maxEditorialScore)) {
      errors.add(
        '$prefix.editorial_score must be in [$minEditorialScore, '
        '$maxEditorialScore] or null, got $editorialScore',
      );
    }
    if (touristicImportance != null &&
        (touristicImportance! < minTouristicImportance ||
            touristicImportance! > maxTouristicImportance)) {
      errors.add(
        '$prefix.touristic_importance must be in [$minTouristicImportance, '
        '$maxTouristicImportance] or null, got $touristicImportance',
      );
    }
    if (priceLevel != null &&
        (priceLevel! < minPriceLevel || priceLevel! > maxPriceLevel)) {
      errors.add(
        '$prefix.price_level must be in [$minPriceLevel, $maxPriceLevel] '
        'or null, got $priceLevel',
      );
    }
    if (typicalDurationMinutes != null && typicalDurationMinutes! <= 0) {
      errors.add(
        '$prefix.typical_duration_minutes must be > 0 or null, '
        'got $typicalDurationMinutes',
      );
    }
    return errors;
  }

  bool get isValid => validate().isEmpty;

  Map<String, dynamic> toJson() => {
    'poi_id': poiId,
    'destination_key': destinationKey,
    'name': name,
    'normalized_name': normalizedName,
    'category': category.toJsonString(),
    'subcategory': subcategory,
    'lat': lat,
    'lng': lng,
    'address': address,
    'country_code': countryCode,
    'zone_name': zoneName,
    'official_url': officialUrl,
    'source_primary_id': sourcePrimaryId,
    'editorial_score': editorialScore,
    'touristic_importance': touristicImportance,
    'is_must_see': isMustSee,
    'is_family_friendly': isFamilyFriendly,
    'is_rain_friendly': isRainFriendly,
    'is_free': isFree,
    'typical_duration_minutes': typicalDurationMinutes,
    'opening_notes': openingNotes,
    'price_level': priceLevel,
    'google_place_id': googlePlaceId,
    'same_complex_group_key': sameComplexGroupKey,
    'payload': payload,
    'created_at': createdAt.toIso8601String(),
    'updated_at': updatedAt.toIso8601String(),
  };

  factory Poi.fromJson(Map<String, dynamic> json) {
    String reqString(String key) {
      final v = json[key];
      if (v is! String) {
        throw FormatException('Poi.$key must be a string');
      }
      return v;
    }

    DateTime optDateTime(String key) {
      final v = json[key];
      if (v == null) return DateTime.now();
      if (v is DateTime) return v;
      if (v is String) return DateTime.parse(v);
      throw FormatException('Poi.$key must be a DateTime or ISO string');
    }

    double? optDouble(String key) {
      final v = json[key];
      if (v == null) return null;
      if (v is double) return v;
      if (v is int) return v.toDouble();
      if (v is num) return v.toDouble();
      throw FormatException('Poi.$key must be a number or null');
    }

    int? optInt(String key) {
      final v = json[key];
      if (v == null) return null;
      if (v is int) return v;
      throw FormatException('Poi.$key must be an int or null');
    }

    final categoryRaw = json['category'];
    if (categoryRaw is! String) {
      throw const FormatException('Poi.category must be a string');
    }

    final payloadRaw = json['payload'];
    final payload = payloadRaw is Map<String, dynamic>
        ? payloadRaw
        : const <String, dynamic>{};

    return Poi(
      poiId: reqString('poi_id'),
      destinationKey: reqString('destination_key'),
      name: reqString('name'),
      normalizedName: reqString('normalized_name'),
      category: PoiCategory.fromJsonString(categoryRaw),
      subcategory: json['subcategory'] as String?,
      lat: optDouble('lat'),
      lng: optDouble('lng'),
      address: json['address'] as String?,
      countryCode: json['country_code'] as String?,
      zoneName: json['zone_name'] as String?,
      officialUrl: json['official_url'] as String?,
      sourcePrimaryId: reqString('source_primary_id'),
      editorialScore: optInt('editorial_score'),
      touristicImportance: optInt('touristic_importance'),
      isMustSee: json['is_must_see'] is bool ? json['is_must_see'] as bool : false,
      isFamilyFriendly: json['is_family_friendly'] as bool?,
      isRainFriendly: json['is_rain_friendly'] as bool?,
      isFree: json['is_free'] as bool?,
      typicalDurationMinutes: optInt('typical_duration_minutes'),
      openingNotes: json['opening_notes'] as String?,
      priceLevel: optInt('price_level'),
      googlePlaceId: json['google_place_id'] as String?,
      sameComplexGroupKey: json['same_complex_group_key'] as String?,
      payload: payload,
      createdAt: optDateTime('created_at'),
      updatedAt: optDateTime('updated_at'),
    );
  }

  @override
  bool operator ==(Object other) =>
      other is Poi &&
      other.poiId == poiId &&
      other.destinationKey == destinationKey &&
      other.name == name &&
      other.normalizedName == normalizedName &&
      other.category == category &&
      other.subcategory == subcategory &&
      other.lat == lat &&
      other.lng == lng &&
      other.address == address &&
      other.countryCode == countryCode &&
      other.zoneName == zoneName &&
      other.officialUrl == officialUrl &&
      other.sourcePrimaryId == sourcePrimaryId &&
      other.editorialScore == editorialScore &&
      other.touristicImportance == touristicImportance &&
      other.isMustSee == isMustSee &&
      other.isFamilyFriendly == isFamilyFriendly &&
      other.isRainFriendly == isRainFriendly &&
      other.isFree == isFree &&
      other.typicalDurationMinutes == typicalDurationMinutes &&
      other.openingNotes == openingNotes &&
      other.priceLevel == priceLevel &&
      other.googlePlaceId == googlePlaceId &&
      other.sameComplexGroupKey == sameComplexGroupKey &&
      _mapEq(other.payload, payload) &&
      other.createdAt == createdAt &&
      other.updatedAt == updatedAt;

  @override
  int get hashCode => Object.hashAll([
    poiId,
    destinationKey,
    name,
    normalizedName,
    category,
    subcategory,
    lat,
    lng,
    address,
    countryCode,
    zoneName,
    officialUrl,
    sourcePrimaryId,
    editorialScore,
    touristicImportance,
    isMustSee,
    isFamilyFriendly,
    isRainFriendly,
    isFree,
    typicalDurationMinutes,
    openingNotes,
    priceLevel,
    googlePlaceId,
    sameComplexGroupKey,
    payload,
    createdAt,
    updatedAt,
  ]);

  @override
  String toString() => 'Poi($poiId, $name, ${category.toJsonString()})';

  static bool _mapEq(Map<String, dynamic> a, Map<String, dynamic> b) {
    if (a.length != b.length) return false;
    for (final key in a.keys) {
      if (!b.containsKey(key) || a[key] != b[key]) return false;
    }
    return true;
  }
}
