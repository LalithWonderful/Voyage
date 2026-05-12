/// POI-0.5 — Modèle domaine `PoiSource`.
///
/// Représente une source de données POI autorisée dans la base
/// Lunao. Aligné strictement avec `public.poi_sources` du schéma SQL
/// (`supabase/sql/poi_knowledge_base.sql`).
///
/// Couche domain pure : aucun Supabase, aucun réseau, aucun provider.
library;

/// Types de source autorisés. Cohérent avec la contrainte CHECK
/// `poi_sources_source_type_check` du DDL.
enum PoiSourceType {
  officialBoard,
  officialVenue,
  unesco,
  wikidata,
  openstreetmap,
  openDataGov,
  editorial;

  static const _toSql = <PoiSourceType, String>{
    officialBoard: 'official_board',
    officialVenue: 'official_venue',
    unesco: 'unesco',
    wikidata: 'wikidata',
    openstreetmap: 'openstreetmap',
    openDataGov: 'open_data_gov',
    editorial: 'editorial',
  };

  static final _fromSql = <String, PoiSourceType>{
    for (final e in _toSql.entries) e.value: e.key,
  };

  String toJsonString() => _toSql[this]!;

  static PoiSourceType fromJsonString(String raw) {
    final v = _fromSql[raw];
    if (v == null) {
      throw FormatException('Unknown PoiSourceType value: "$raw"');
    }
    return v;
  }
}

/// Référentiel des sources de données POI autorisées.
class PoiSource {
  /// UUID primary key. Généré côté DB si non fourni.
  final String sourceId;

  /// Nom lisible de la source (ex: "Singapore Tourism Board").
  final String name;

  /// Type de source (contrainte SQL CHECK).
  final PoiSourceType sourceType;

  /// URL racine de la source, si applicable.
  final String? baseUrl;

  /// Nom de la licence (ex: "CC0 1.0").
  final String? licenseName;

  /// URL de la licence.
  final String? licenseUrl;

  /// Niveau de confiance éditorial 1 (faible) à 5 (officiel).
  /// Default 3. Contrainte SQL : [1, 5].
  final int trustLevel;

  /// Source active ? Default `true`.
  final bool isActive;

  /// Notes libres.
  final String? notes;

  /// Création (timestamptz). Default `now()` en SQL.
  final DateTime createdAt;

  /// Dernière mise à jour (timestamptz). Default `now()` en SQL.
  final DateTime updatedAt;

  static const int minTrustLevel = 1;
  static const int maxTrustLevel = 5;
  static const int defaultTrustLevel = 3;

  const PoiSource({
    required this.sourceId,
    required this.name,
    required this.sourceType,
    this.baseUrl,
    this.licenseName,
    this.licenseUrl,
    this.trustLevel = defaultTrustLevel,
    this.isActive = true,
    this.notes,
    required this.createdAt,
    required this.updatedAt,
  });

  /// Validation pure. Retourne la liste des erreurs (vide = OK).
  List<String> validate({String prefix = 'PoiSource'}) {
    final errors = <String>[];
    if (sourceId.trim().isEmpty) {
      errors.add('$prefix.source_id must be non-empty');
    }
    if (name.trim().isEmpty) {
      errors.add('$prefix.name must be non-empty');
    }
    if (trustLevel < minTrustLevel || trustLevel > maxTrustLevel) {
      errors.add(
        '$prefix.trust_level must be in [$minTrustLevel, $maxTrustLevel], '
        'got $trustLevel',
      );
    }
    return errors;
  }

  bool get isValid => validate().isEmpty;

  Map<String, dynamic> toJson() => {
    'source_id': sourceId,
    'name': name,
    'source_type': sourceType.toJsonString(),
    'base_url': baseUrl,
    'license_name': licenseName,
    'license_url': licenseUrl,
    'trust_level': trustLevel,
    'is_active': isActive,
    'notes': notes,
    'created_at': createdAt.toIso8601String(),
    'updated_at': updatedAt.toIso8601String(),
  };

  factory PoiSource.fromJson(Map<String, dynamic> json) {
    String reqString(String key) {
      final v = json[key];
      if (v is! String) {
        throw FormatException('PoiSource.$key must be a string');
      }
      return v;
    }

    DateTime optDateTime(String key) {
      final v = json[key];
      if (v == null) return DateTime.now();
      if (v is DateTime) return v;
      if (v is String) return DateTime.parse(v);
      throw FormatException('PoiSource.$key must be a DateTime or ISO string');
    }

    final sourceTypeRaw = json['source_type'];
    if (sourceTypeRaw is! String) {
      throw const FormatException('PoiSource.source_type must be a string');
    }

    final trustLevelRaw = json['trust_level'];
    final trustLevel = trustLevelRaw is int
        ? trustLevelRaw
        : defaultTrustLevel;

    final isActiveRaw = json['is_active'];
    final isActive = isActiveRaw is bool ? isActiveRaw : true;

    return PoiSource(
      sourceId: reqString('source_id'),
      name: reqString('name'),
      sourceType: PoiSourceType.fromJsonString(sourceTypeRaw),
      baseUrl: json['base_url'] as String?,
      licenseName: json['license_name'] as String?,
      licenseUrl: json['license_url'] as String?,
      trustLevel: trustLevel,
      isActive: isActive,
      notes: json['notes'] as String?,
      createdAt: optDateTime('created_at'),
      updatedAt: optDateTime('updated_at'),
    );
  }

  @override
  bool operator ==(Object other) =>
      other is PoiSource &&
      other.sourceId == sourceId &&
      other.name == name &&
      other.sourceType == sourceType &&
      other.baseUrl == baseUrl &&
      other.licenseName == licenseName &&
      other.licenseUrl == licenseUrl &&
      other.trustLevel == trustLevel &&
      other.isActive == isActive &&
      other.notes == notes &&
      other.createdAt == createdAt &&
      other.updatedAt == updatedAt;

  @override
  int get hashCode => Object.hash(
    sourceId,
    name,
    sourceType,
    baseUrl,
    licenseName,
    licenseUrl,
    trustLevel,
    isActive,
    notes,
    createdAt,
    updatedAt,
  );

  @override
  String toString() => 'PoiSource($sourceId, $name, ${sourceType.toJsonString()})';
}
