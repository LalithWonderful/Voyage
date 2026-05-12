/// POI-0.5 — Modèle domaine `PoiQualityFlag`.
///
/// Signalement qualité pour la curation des POI. Aligné strictement
/// avec `public.poi_quality_flags` du schéma SQL
/// (`supabase/sql/poi_knowledge_base.sql`).
///
/// Couche domain pure : aucun Supabase, aucun réseau, aucun provider.
library;

/// Types de signalement qualité. Cohérent avec la contrainte CHECK
/// `poi_quality_flags_flag_type_check` du DDL.
enum PoiFlagType {
  duplicate,
  locationInaccurate,
  nameDisputed,
  closed,
  deprecated,
  needsReview;

  static const _toSql = <PoiFlagType, String>{
    duplicate: 'duplicate',
    locationInaccurate: 'location_inaccurate',
    nameDisputed: 'name_disputed',
    closed: 'closed',
    deprecated: 'deprecated',
    needsReview: 'needs_review',
  };

  static final _fromSql = <String, PoiFlagType>{
    for (final e in _toSql.entries) e.value: e.key,
  };

  String toJsonString() => _toSql[this]!;

  static PoiFlagType fromJsonString(String raw) {
    final v = _fromSql[raw];
    if (v == null) {
      throw FormatException('Unknown PoiFlagType value: "$raw"');
    }
    return v;
  }
}

/// Signalement qualité pour un POI.
class PoiQualityFlag {
  /// UUID primary key.
  final String flagId;

  /// FK vers `pois.poi_id`.
  final String poiId;

  /// Type de signalement (contrainte SQL CHECK).
  final PoiFlagType flagType;

  /// Description libre du problème.
  final String? flagReason;

  /// Rapporteur : "system", "admin", ou "user:&lt;uuid&gt;.
  final String? reportedBy;

  /// Date de résolution. Null = non résolu.
  final DateTime? resolvedAt;

  /// Notes de résolution.
  final String? resolutionNotes;

  final DateTime createdAt;

  const PoiQualityFlag({
    required this.flagId,
    required this.poiId,
    required this.flagType,
    this.flagReason,
    this.reportedBy,
    this.resolvedAt,
    this.resolutionNotes,
    required this.createdAt,
  });

  List<String> validate({String prefix = 'PoiQualityFlag'}) {
    final errors = <String>[];
    if (flagId.trim().isEmpty) {
      errors.add('$prefix.flag_id must be non-empty');
    }
    if (poiId.trim().isEmpty) {
      errors.add('$prefix.poi_id must be non-empty');
    }
    return errors;
  }

  bool get isValid => validate().isEmpty;

  Map<String, dynamic> toJson() => {
    'flag_id': flagId,
    'poi_id': poiId,
    'flag_type': flagType.toJsonString(),
    'flag_reason': flagReason,
    'reported_by': reportedBy,
    'resolved_at': resolvedAt?.toIso8601String(),
    'resolution_notes': resolutionNotes,
    'created_at': createdAt.toIso8601String(),
  };

  factory PoiQualityFlag.fromJson(Map<String, dynamic> json) {
    String reqString(String key) {
      final v = json[key];
      if (v is! String) {
        throw FormatException('PoiQualityFlag.$key must be a string');
      }
      return v;
    }

    DateTime optDateTime(String key) {
      final v = json[key];
      if (v == null) return DateTime.now();
      if (v is DateTime) return v;
      if (v is String) return DateTime.parse(v);
      throw FormatException(
        'PoiQualityFlag.$key must be a DateTime or ISO string',
      );
    }

    DateTime? maybeDateTime(String key) {
      final v = json[key];
      if (v == null) return null;
      if (v is DateTime) return v;
      if (v is String) return DateTime.parse(v);
      throw FormatException(
        'PoiQualityFlag.$key must be a DateTime, ISO string, or null',
      );
    }

    final flagTypeRaw = json['flag_type'];
    if (flagTypeRaw is! String) {
      throw const FormatException(
        'PoiQualityFlag.flag_type must be a string',
      );
    }

    return PoiQualityFlag(
      flagId: reqString('flag_id'),
      poiId: reqString('poi_id'),
      flagType: PoiFlagType.fromJsonString(flagTypeRaw),
      flagReason: json['flag_reason'] as String?,
      reportedBy: json['reported_by'] as String?,
      resolvedAt: maybeDateTime('resolved_at'),
      resolutionNotes: json['resolution_notes'] as String?,
      createdAt: optDateTime('created_at'),
    );
  }

  @override
  bool operator ==(Object other) =>
      other is PoiQualityFlag &&
      other.flagId == flagId &&
      other.poiId == poiId &&
      other.flagType == flagType &&
      other.flagReason == flagReason &&
      other.reportedBy == reportedBy &&
      other.resolvedAt == resolvedAt &&
      other.resolutionNotes == resolutionNotes &&
      other.createdAt == createdAt;

  @override
  int get hashCode => Object.hash(
    flagId,
    poiId,
    flagType,
    flagReason,
    reportedBy,
    resolvedAt,
    resolutionNotes,
    createdAt,
  );

  @override
  String toString() =>
      'PoiQualityFlag($flagId, ${flagType.toJsonString()}, poi=$poiId)';
}
