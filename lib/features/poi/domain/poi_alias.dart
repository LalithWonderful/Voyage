/// POI-0.5 — Modèle domaine `PoiAlias`.
///
/// Nom alternatif d'un POI pour matching et déduplication. Aligné
/// strictement avec `public.poi_aliases` du schéma SQL
/// (`supabase/sql/poi_knowledge_base.sql`).
///
/// Couche domain pure : aucun Supabase, aucun réseau, aucun provider.
library;

/// Nom alternatif d'un POI.
class PoiAlias {
  /// UUID primary key.
  final String aliasId;

  /// FK vers `pois.poi_id`.
  final String poiId;

  /// Texte de l'alias (ex: "GBTB", "Gardens by the Bay").
  final String alias;

  /// Alias normalisé (lower, trim, collapse espaces).
  final String aliasNormalized;

  /// True si cet alias est le nom privilégié par la source.
  /// Default `false`.
  final bool isCanonical;

  /// FK optionnelle vers `poi_sources.source_id`.
  final String? sourceId;

  final DateTime createdAt;

  const PoiAlias({
    required this.aliasId,
    required this.poiId,
    required this.alias,
    required this.aliasNormalized,
    this.isCanonical = false,
    this.sourceId,
    required this.createdAt,
  });

  List<String> validate({String prefix = 'PoiAlias'}) {
    final errors = <String>[];
    if (aliasId.trim().isEmpty) {
      errors.add('$prefix.alias_id must be non-empty');
    }
    if (poiId.trim().isEmpty) {
      errors.add('$prefix.poi_id must be non-empty');
    }
    if (alias.trim().isEmpty) {
      errors.add('$prefix.alias must be non-empty');
    }
    if (aliasNormalized.trim().isEmpty) {
      errors.add('$prefix.alias_normalized must be non-empty');
    }
    return errors;
  }

  bool get isValid => validate().isEmpty;

  Map<String, dynamic> toJson() => {
    'alias_id': aliasId,
    'poi_id': poiId,
    'alias': alias,
    'alias_normalized': aliasNormalized,
    'is_canonical': isCanonical,
    'source_id': sourceId,
    'created_at': createdAt.toIso8601String(),
  };

  factory PoiAlias.fromJson(Map<String, dynamic> json) {
    String reqString(String key) {
      final v = json[key];
      if (v is! String) {
        throw FormatException('PoiAlias.$key must be a string');
      }
      return v;
    }

    DateTime optDateTime(String key) {
      final v = json[key];
      if (v == null) return DateTime.now();
      if (v is DateTime) return v;
      if (v is String) return DateTime.parse(v);
      throw FormatException('PoiAlias.$key must be a DateTime or ISO string');
    }

    return PoiAlias(
      aliasId: reqString('alias_id'),
      poiId: reqString('poi_id'),
      alias: reqString('alias'),
      aliasNormalized: reqString('alias_normalized'),
      isCanonical: json['is_canonical'] is bool
          ? json['is_canonical'] as bool
          : false,
      sourceId: json['source_id'] as String?,
      createdAt: optDateTime('created_at'),
    );
  }

  @override
  bool operator ==(Object other) =>
      other is PoiAlias &&
      other.aliasId == aliasId &&
      other.poiId == poiId &&
      other.alias == alias &&
      other.aliasNormalized == aliasNormalized &&
      other.isCanonical == isCanonical &&
      other.sourceId == sourceId &&
      other.createdAt == createdAt;

  @override
  int get hashCode => Object.hash(
    aliasId,
    poiId,
    alias,
    aliasNormalized,
    isCanonical,
    sourceId,
    createdAt,
  );

  @override
  String toString() => 'PoiAlias($aliasId, $alias, poi=$poiId)';
}
