/// POI-0.5 — Modèle domaine `PoiTag`.
///
/// Tag sémantique granulaire attaché à un POI. Aligné strictement
/// avec `public.poi_tags` du schéma SQL
/// (`supabase/sql/poi_knowledge_base.sql`).
///
/// Couche domain pure : aucun Supabase, aucun réseau, aucun provider.
library;

/// Tag sémantique d'un POI (vibe, accessibilité, audience, etc.).
class PoiTag {
  /// UUID primary key.
  final String tagId;

  /// FK vers `pois.poi_id`.
  final String poiId;

  /// Texte du tag (ex: "night_photography", "wheelchair_accessible").
  final String tag;

  /// Catégorie du tag : vibe, accessibility, activity_type, audience,
  /// season. Pas de contrainte CHECK SQL — valeur libre mais documentée.
  final String? tagCategory;

  /// Confiance dans le tag, 0-100. Nullable.
  final int? confidence;

  /// FK optionnelle vers `poi_sources.source_id`.
  final String? sourceId;

  final DateTime createdAt;

  static const int minConfidence = 0;
  static const int maxConfidence = 100;

  const PoiTag({
    required this.tagId,
    required this.poiId,
    required this.tag,
    this.tagCategory,
    this.confidence,
    this.sourceId,
    required this.createdAt,
  });

  List<String> validate({String prefix = 'PoiTag'}) {
    final errors = <String>[];
    if (tagId.trim().isEmpty) {
      errors.add('$prefix.tag_id must be non-empty');
    }
    if (poiId.trim().isEmpty) {
      errors.add('$prefix.poi_id must be non-empty');
    }
    if (tag.trim().isEmpty) {
      errors.add('$prefix.tag must be non-empty');
    }
    if (confidence != null &&
        (confidence! < minConfidence || confidence! > maxConfidence)) {
      errors.add(
        '$prefix.confidence must be in [$minConfidence, $maxConfidence] '
        'or null, got $confidence',
      );
    }
    return errors;
  }

  bool get isValid => validate().isEmpty;

  Map<String, dynamic> toJson() => {
    'tag_id': tagId,
    'poi_id': poiId,
    'tag': tag,
    'tag_category': tagCategory,
    'confidence': confidence,
    'source_id': sourceId,
    'created_at': createdAt.toIso8601String(),
  };

  factory PoiTag.fromJson(Map<String, dynamic> json) {
    String reqString(String key) {
      final v = json[key];
      if (v is! String) {
        throw FormatException('PoiTag.$key must be a string');
      }
      return v;
    }

    DateTime optDateTime(String key) {
      final v = json[key];
      if (v == null) return DateTime.now();
      if (v is DateTime) return v;
      if (v is String) return DateTime.parse(v);
      throw FormatException('PoiTag.$key must be a DateTime or ISO string');
    }

    int? optInt(String key) {
      final v = json[key];
      if (v == null) return null;
      if (v is int) return v;
      throw FormatException('PoiTag.$key must be an int or null');
    }

    return PoiTag(
      tagId: reqString('tag_id'),
      poiId: reqString('poi_id'),
      tag: reqString('tag'),
      tagCategory: json['tag_category'] as String?,
      confidence: optInt('confidence'),
      sourceId: json['source_id'] as String?,
      createdAt: optDateTime('created_at'),
    );
  }

  @override
  bool operator ==(Object other) =>
      other is PoiTag &&
      other.tagId == tagId &&
      other.poiId == poiId &&
      other.tag == tag &&
      other.tagCategory == tagCategory &&
      other.confidence == confidence &&
      other.sourceId == sourceId &&
      other.createdAt == createdAt;

  @override
  int get hashCode => Object.hash(
    tagId,
    poiId,
    tag,
    tagCategory,
    confidence,
    sourceId,
    createdAt,
  );

  @override
  String toString() => 'PoiTag($tagId, $tag, poi=$poiId)';
}
