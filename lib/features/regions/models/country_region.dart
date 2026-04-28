/// Région touristique préconfigurée pour un "grand pays" (V1).
/// Vient soit de Supabase (`country_regions` table), soit du JSON asset
/// embarqué (fallback offline / boot rapide), soit du cache local 7j.
///
/// Spec produit : 14 pays "large" (régions obligatoires) + 2 "travel_region"
/// (régions recommandées avec option "Tout le pays" en fallback).
class CountryRegion {
  /// Identifiant Supabase (bigserial). Null si chargé depuis le JSON asset
  /// (fallback offline) — l'id n'est utile que pour persister le choix
  /// utilisateur dans `trips.selected_region_id`.
  final int? id;

  /// ISO 2 (ex: 'US', 'TH'). Clé de lookup principale.
  final String countryCode;

  /// Nom FR du pays (ex: "États-Unis").
  final String countryName;

  /// Nom FR de la région (ex: "New York & Côte Est"). Sert de titre de la
  /// carte et de clé naturelle (unique par pays).
  final String regionName;

  /// Villes/lieux principaux affichés en sous-titre de la carte
  /// (ex: "New York, Boston, Washington DC, Philadelphie").
  final String label;

  /// 1-5, ordre d'affichage des cartes (1 = en premier, "le plus accessible").
  /// Sert aussi de tie-breaker du scoring (priority croissante).
  final int priority;

  /// Rayon par défaut (km) pour cette région — passé tel quel à Gemini quand
  /// l'utilisateur valide cette région. Remplace le sélecteur 50/100/.../500.
  final int recommendedRadiusKm;

  /// Tags du vocabulaire figé V1 (cf. allowedTags dans country_regions.dart).
  /// Contributent au scoring "Je ne sais pas quoi choisir".
  final List<String> tags;

  const CountryRegion({
    this.id,
    required this.countryCode,
    required this.countryName,
    required this.regionName,
    required this.label,
    required this.priority,
    required this.recommendedRadiusKm,
    required this.tags,
  });

  /// Désérialise depuis Supabase (`country_regions` row).
  factory CountryRegion.fromSupabase(Map<String, dynamic> json) {
    return CountryRegion(
      id: (json['id'] as num?)?.toInt(),
      countryCode: json['country_code'] as String,
      countryName: json['country_name'] as String,
      regionName: json['region_name'] as String,
      label: json['label'] as String,
      priority: (json['priority'] as num).toInt(),
      recommendedRadiusKm: (json['recommended_radius_km'] as num).toInt(),
      tags: (json['tags'] as List).cast<String>(),
    );
  }

  /// Désérialise depuis le JSON asset embarqué.
  /// Le format est volontairement identique à Supabase pour simplifier le code.
  factory CountryRegion.fromAssetJson(Map<String, dynamic> json) {
    return CountryRegion(
      id: (json['id'] as num?)?.toInt(),
      countryCode: json['country_code'] as String,
      countryName: json['country_name'] as String,
      regionName: json['region_name'] as String,
      label: json['label'] as String,
      priority: (json['priority'] as num).toInt(),
      recommendedRadiusKm: (json['recommended_radius_km'] as num).toInt(),
      tags: (json['tags'] as List).cast<String>(),
    );
  }

  /// Sérialisation pour le cache local (SharedPreferences).
  Map<String, dynamic> toCacheJson() => {
        if (id != null) 'id': id,
        'country_code': countryCode,
        'country_name': countryName,
        'region_name': regionName,
        'label': label,
        'priority': priority,
        'recommended_radius_km': recommendedRadiusKm,
        'tags': tags,
      };
}
