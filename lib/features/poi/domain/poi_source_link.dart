/// POI-0.5 — Modèle domaine `PoiSourceLink`.
///
/// Lien de traçabilité entre un POI et une source externe. Aligné
/// strictement avec `public.poi_source_links` du schéma SQL
/// (`supabase/sql/poi_knowledge_base.sql`).
///
/// Couche domain pure : aucun Supabase, aucun réseau, aucun provider.
library;

/// Lien de traçabilité POI ↔ source externe.
class PoiSourceLink {
  /// UUID primary key.
  final String linkId;

  /// FK vers `pois.poi_id`.
  final String poiId;

  /// FK vers `poi_sources.source_id`.
  final String sourceId;

  /// Identifiant brut du POI dans la source (ex: "Q12345").
  final String? sourcePoiIdentifier;

  /// URL directe vers la fiche source.
  final String? sourceUrl;

  /// Données brutes stockées pour audit. Default `{}`.
  final Map<String, dynamic> sourceRawData;

  /// Date de vérification manuelle, si applicable.
  final DateTime? verifiedAt;

  final DateTime createdAt;

  const PoiSourceLink({
    required this.linkId,
    required this.poiId,
    required this.sourceId,
    this.sourcePoiIdentifier,
    this.sourceUrl,
    this.sourceRawData = const <String, dynamic>{},
    this.verifiedAt,
    required this.createdAt,
  });

  List<String> validate({String prefix = 'PoiSourceLink'}) {
    final errors = <String>[];
    if (linkId.trim().isEmpty) {
      errors.add('$prefix.link_id must be non-empty');
    }
    if (poiId.trim().isEmpty) {
      errors.add('$prefix.poi_id must be non-empty');
    }
    if (sourceId.trim().isEmpty) {
      errors.add('$prefix.source_id must be non-empty');
    }
    return errors;
  }

  bool get isValid => validate().isEmpty;

  Map<String, dynamic> toJson() => {
    'link_id': linkId,
    'poi_id': poiId,
    'source_id': sourceId,
    'source_poi_identifier': sourcePoiIdentifier,
    'source_url': sourceUrl,
    'source_raw_data': sourceRawData,
    'verified_at': verifiedAt?.toIso8601String(),
    'created_at': createdAt.toIso8601String(),
  };

  factory PoiSourceLink.fromJson(Map<String, dynamic> json) {
    String reqString(String key) {
      final v = json[key];
      if (v is! String) {
        throw FormatException('PoiSourceLink.$key must be a string');
      }
      return v;
    }

    DateTime optDateTime(String key) {
      final v = json[key];
      if (v == null) return DateTime.now();
      if (v is DateTime) return v;
      if (v is String) return DateTime.parse(v);
      throw FormatException(
        'PoiSourceLink.$key must be a DateTime or ISO string',
      );
    }

    DateTime? maybeDateTime(String key) {
      final v = json[key];
      if (v == null) return null;
      if (v is DateTime) return v;
      if (v is String) return DateTime.parse(v);
      throw FormatException(
        'PoiSourceLink.$key must be a DateTime, ISO string, or null',
      );
    }

    final rawDataRaw = json['source_raw_data'];
    final rawData = rawDataRaw is Map<String, dynamic>
        ? rawDataRaw
        : const <String, dynamic>{};

    return PoiSourceLink(
      linkId: reqString('link_id'),
      poiId: reqString('poi_id'),
      sourceId: reqString('source_id'),
      sourcePoiIdentifier: json['source_poi_identifier'] as String?,
      sourceUrl: json['source_url'] as String?,
      sourceRawData: rawData,
      verifiedAt: maybeDateTime('verified_at'),
      createdAt: optDateTime('created_at'),
    );
  }

  @override
  bool operator ==(Object other) =>
      other is PoiSourceLink &&
      other.linkId == linkId &&
      other.poiId == poiId &&
      other.sourceId == sourceId &&
      other.sourcePoiIdentifier == sourcePoiIdentifier &&
      other.sourceUrl == sourceUrl &&
      _mapEq(other.sourceRawData, sourceRawData) &&
      other.verifiedAt == verifiedAt &&
      other.createdAt == createdAt;

  @override
  int get hashCode => Object.hash(
    linkId,
    poiId,
    sourceId,
    sourcePoiIdentifier,
    sourceUrl,
    sourceRawData,
    verifiedAt,
    createdAt,
  );

  @override
  String toString() => 'PoiSourceLink($linkId, poi=$poiId, src=$sourceId)';

  static bool _mapEq(Map<String, dynamic> a, Map<String, dynamic> b) {
    if (a.length != b.length) return false;
    for (final key in a.keys) {
      if (!b.containsKey(key) || a[key] != b[key]) return false;
    }
    return true;
  }
}
