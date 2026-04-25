import 'package:voyage/features/planning/services/places_nearby_service.dart';

/// Vrai si `primaryType` (= types[0] retourné par Places) désigne un lieu de
/// restauration. Sert au flag `excludeFoodPrimaryType` ci-dessous : Places
/// inclut souvent des restos dans les résultats `night_club`/`bar` parce
/// qu'ils ont ces tags en secondaire (ex: Burger King avec `bar_and_grill`).
/// Pour Nightlife / Événements on veut filtrer ce bruit.
bool isFoodPrimaryType(String primaryType) {
  if (primaryType.contains('restaurant')) return true;
  return const {
    'cafe',
    'bakery',
    'meal_delivery',
    'meal_takeaway',
    'catering_service',
    'food_court',
    'ice_cream_shop',
    'pizza',
    'sandwich_shop',
  }.contains(primaryType);
}

/// Une stratégie de fetch Places pour un centre d'intérêt voyageur.
/// Combine 1+ requêtes (Nearby par types et/ou Text Search par mot-clé)
/// et un set de filtres post-fetch.
///
/// Source de vérité : `project_places_first_mapping.md` en mémoire — toute
/// modification du mapping doit y être reportée.
class InterestPlacesQuery {
  /// Types Google Places à inclure dans la recherche `searchNearby`.
  /// Vide = on saute le call Nearby pour cet intérêt.
  final List<String> includedTypes;

  /// Requêtes en langage naturel pour `searchText`. Une requête = un call.
  /// Plusieurs sont possibles (ex: "hiking" + "trail" + "viewpoint") pour
  /// couvrir différents synonymes — les résultats seront fusionnés et dédupliqués.
  final List<String> textQueries;

  /// Filtres post-fetch — appliqués sur les résultats de TOUTES les requêtes.
  final double? minRating;
  final int? minUserRatingCount;
  final int? maxUserRatingCount;
  /// Niveau max acceptable. 0 = gratuit, 4 = très cher. Null = pas de filtre.
  final int? maxPriceLevel;

  /// Si true, exclut les candidats dont le `types[0]` (primary type Places) est
  /// un type de restauration. Utile pour Nightlife/Événements : Places inclut
  /// souvent des restos dans les résultats `night_club`/`bar` (Burger King avec
  /// `bar_and_grill`, restos italiens avec `lounge_bar`...) — on filtre ce bruit.
  final bool excludeFoodPrimaryType;

  /// Note libre pour documenter une règle métier qui n'a pas de représentation
  /// directe (ex: "proposer uniquement après 18h" pour Nightlife). À gérer
  /// en aval, dans le pipeline de sélection.
  final String? rule;

  const InterestPlacesQuery({
    this.includedTypes = const [],
    this.textQueries = const [],
    this.minRating,
    this.minUserRatingCount,
    this.maxUserRatingCount,
    this.maxPriceLevel,
    this.excludeFoodPrimaryType = false,
    this.rule,
  });

  /// Vrai si un candidat passe les filtres post-fetch de cet intérêt.
  /// La règle globale (rating ≥ 4.0) est appliquée par-dessus dans le pipeline.
  bool matchesFilters(NearbyCandidate c) {
    if (minRating != null && (c.rating == null || c.rating! < minRating!)) {
      return false;
    }
    if (minUserRatingCount != null &&
        (c.userRatingCount == null || c.userRatingCount! < minUserRatingCount!)) {
      return false;
    }
    if (maxUserRatingCount != null &&
        (c.userRatingCount != null && c.userRatingCount! > maxUserRatingCount!)) {
      return false;
    }
    if (maxPriceLevel != null &&
        (c.priceLevel != null && c.priceLevel! > maxPriceLevel!)) {
      return false;
    }
    if (excludeFoodPrimaryType &&
        c.types.isNotEmpty &&
        isFoodPrimaryType(c.types.first)) {
      return false;
    }
    return true;
  }
}

/// Mapping intérêt voyageur (clé = libellé exact dans la BDD `interests`) →
/// stratégie Places. Implémente strictement `project_places_first_mapping.md`.
const interestPlacesQueries = <String, InterestPlacesQuery>{
  'Randonnée': InterestPlacesQuery(
    includedTypes: ['park', 'national_park', 'tourist_attraction'],
    textQueries: ['hiking trail', 'sentier randonnée', 'viewpoint', 'nature walk'],
    minRating: 4.2,
  ),
  'Shopping': InterestPlacesQuery(
    includedTypes: ['shopping_mall', 'clothing_store', 'department_store', 'market', 'store'],
    textQueries: ['outlet', 'shopping street', 'local market', 'souvenir'],
  ),
  'Nightlife': InterestPlacesQuery(
    includedTypes: ['bar', 'night_club'],
    minRating: 4.0,
    minUserRatingCount: 100,
    excludeFoodPrimaryType: true,
    rule: 'proposer uniquement après 18h',
  ),
  'Spots populaires': InterestPlacesQuery(
    includedTypes: ['tourist_attraction', 'museum', 'park'],
    minRating: 4.2,
    minUserRatingCount: 500,
  ),
  'Hors circuit': InterestPlacesQuery(
    includedTypes: ['restaurant', 'cafe', 'art_gallery', 'park', 'tourist_attraction'],
    minRating: 4.2,
    minUserRatingCount: 30,
    // Élargi de 500 à 1500 (test Nancy 2026-04-25 : la fenêtre 30-500 ne
    // retenait quasi rien, les lieux étaient soit < 30 avis, soit > 500).
    maxUserRatingCount: 1500,
    rule: 'éviter chaînes connues, éviter lieux trop touristiques',
  ),
  'Bons plans': InterestPlacesQuery(
    includedTypes: ['restaurant', 'cafe', 'bakery', 'park', 'museum', 'market'],
    textQueries: ['cheap', 'budget', 'gratuit', 'free'],
    maxPriceLevel: 1,
  ),
  'Wellness': InterestPlacesQuery(
    includedTypes: ['spa', 'beauty_salon', 'gym'],
    minRating: 4.4,
    minUserRatingCount: 50,
  ),
  'Esthétique': InterestPlacesQuery(
    includedTypes: ['beauty_salon', 'hair_care', 'spa'],
    textQueries: ['facial', 'skincare', 'laser', 'esthetic'],
    minRating: 4.4,
  ),
  'Gastronomie': InterestPlacesQuery(
    includedTypes: ['restaurant', 'cafe', 'bakery', 'meal_takeaway'],
    textQueries: ['local food', 'traditional cuisine', 'street food', 'fine dining'],
    minRating: 4.0,
  ),
  'Culture': InterestPlacesQuery(
    includedTypes: ['museum', 'art_gallery', 'library', 'church'],
    textQueries: ['historical landmark', 'cultural site'],
    minRating: 4.0,
    rule: 'vérifier ouverture aux horaires du créneau et durée compatible',
  ),
  'Plage': InterestPlacesQuery(
    includedTypes: ['park', 'tourist_attraction'],
    textQueries: ['beach', 'lake', 'seaside', 'waterfront'],
    minRating: 4.0,
    rule: 'vérifier distance réelle au littoral',
  ),
  'Sports': InterestPlacesQuery(
    includedTypes: ['gym', 'stadium'],
    textQueries: ['bike rental', 'kayak', 'climbing gym', 'tennis court'],
    minRating: 4.0,
  ),
  'Nature': InterestPlacesQuery(
    includedTypes: ['park', 'national_park', 'zoo'],
    textQueries: ['forest', 'lake', 'viewpoint', 'nature reserve', 'botanical garden'],
    minRating: 4.0,
  ),
  'Événements': InterestPlacesQuery(
    includedTypes: ['stadium', 'night_club'],
    textQueries: ['concert hall', 'theater', 'event venue'],
    minRating: 4.0,
    excludeFoodPrimaryType: true,
    rule: 'Places valide le venue mais pas l\'événement réel — à compléter post-MVP avec une API événementielle',
  ),
};

/// Seuil global appliqué EN PLUS du `minRating` par intérêt.
/// Spec : "rating ≥ 4.0 minimum" pour TOUTES les requêtes.
const placesGlobalMinRating = 4.0;
