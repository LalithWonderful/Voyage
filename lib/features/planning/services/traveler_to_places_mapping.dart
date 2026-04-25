/// Profil de recherche Places associé à un type de voyageur. Vient en
/// complément de `interests_to_places_mapping.dart` : les intérêts disent
/// QUOI proposer (Gastronomie → restaurants), le type de voyageur module
/// COMMENT (Grand luxe → restaurants étoilés, distance courte ; Backpack →
/// hostels + street food, prix bas).
///
/// Règle de cumul (validée Lalith 2026-04-25) :
/// - L'**intérêt explicite gagne** sur le type voyageur quand un seuil
///   contradictoire apparaît (ex: voyageur "Grand luxe" + intérêt "Bons plans"
///   → on respecte priceLevel ≤ 1 du Bons plans, pas le ≥ 3 du luxe).
/// - Le type peut **veter** (`excludedInterests`) un intérêt incompatible
///   (ex: "En famille" exclut Nightlife même si le voyageur l'a coché).
/// - Sinon, les types/textQueries du profil sont AJOUTÉS à ceux des intérêts,
///   et les filtres rating/userRatingCount/priceLevel s'appliquent en parallèle
///   au seuil de l'intérêt (le plus strict des deux gagne pour une catégorie
///   non-conflictuelle).
class TravelerPlacesProfile {
  /// Types Places à AJOUTER aux recherches Nearby pour ce voyageur, en plus
  /// de ce qui vient des intérêts cochés. Ex: "Backpack" ajoute hostel/laundry,
  /// "Voyage pro" ajoute coworking_space.
  final List<String> additionalTypes;

  /// Mots-clés à AJOUTER aux recherches Text Search. Ex: "Grand luxe" ajoute
  /// "fine dining", "rooftop bar", "boutique hotel".
  final List<String> additionalTextQueries;

  /// Boost minimal du rating à appliquer au seuil de l'intérêt. Ex: "Grand luxe"
  /// boost à 4.5 même si l'intérêt acceptait 4.0. Le plus strict des deux gagne.
  final double? minRating;

  /// Plancher priceLevel. Ex: "Grand luxe" pousse priceLevel ≥ 3.
  /// Si conflit avec un intérêt qui pousse maxPriceLevel = 1, l'intérêt gagne
  /// (cf. règle de cumul) — ce minimum est ignoré.
  final int? minPriceLevel;

  /// Plafond priceLevel. Ex: "Meilleur prix" pousse priceLevel ≤ 1.
  /// Si conflit avec minPriceLevel d'un intérêt, l'intérêt gagne.
  final int? maxPriceLevel;

  /// Plancher userRatingCount (boost vs intérêt — ex: "Grand luxe" exige ≥ 100).
  final int? minUserRatingCount;

  /// Liste des libellés d'intérêt à exclure totalement, même si cochés par
  /// le voyageur. Ex: "En famille" exclut "Nightlife" (incompatible).
  final List<String> excludedInterests;

  /// Durée maximale acceptable pour une activité de ce voyageur, en minutes.
  /// Ex: Senior 90 min max, Road-trip 120 min max (étapes courtes).
  final int? maxActivityMinutes;

  /// Distance maximale entre deux activités consécutives sur la même journée,
  /// en mètres. Sert le post-processing de regroupement géographique.
  /// Ex: Senior 300m max (peu de marche), En famille 1000m max.
  final int? maxConsecutiveDistanceMeters;

  /// Note libre pour règles métier sans représentation directe (ex: "éviter
  /// fortes chaleurs", "privilégier indoor", "horaires diurnes uniquement").
  /// À gérer en aval dans le pipeline de sélection.
  final String? rule;

  const TravelerPlacesProfile({
    this.additionalTypes = const [],
    this.additionalTextQueries = const [],
    this.minRating,
    this.minPriceLevel,
    this.maxPriceLevel,
    this.minUserRatingCount,
    this.excludedInterests = const [],
    this.maxActivityMinutes,
    this.maxConsecutiveDistanceMeters,
    this.rule,
  });
}

/// Mapping type voyageur (= dbValue stocké dans `trips.traveler_type` ou
/// `user_profiles.traveler_type`) → profil Places. Implémente strictement
/// `project_traveler_types_places_mapping.md` validé par Lalith.
const travelerPlacesProfiles = <String, TravelerPlacesProfile>{
  'Road-trip': TravelerPlacesProfile(
    additionalTypes: ['tourist_attraction', 'park', 'historical_landmark', 'gas_station', 'parking'],
    additionalTextQueries: ['viewpoint', 'scenic stop', 'roadside diner'],
    minRating: 4.1,
    maxActivityMinutes: 120,
    rule: 'détours ≤15-25 min, étapes courtes 30 min-2h le long du trajet',
  ),
  'Grand luxe': TravelerPlacesProfile(
    additionalTypes: ['spa', 'art_gallery', 'jewelry_store'],
    additionalTextQueries: ['fine dining', 'luxury spa', 'rooftop bar', 'boutique hotel', 'Michelin'],
    minRating: 4.5,
    minPriceLevel: 3,
    minUserRatingCount: 100,
    rule: 'éviter low-cost et lieux trop touristiques',
  ),
  'Meilleur prix': TravelerPlacesProfile(
    additionalTypes: ['bakery', 'meal_takeaway', 'supermarket'],
    additionalTextQueries: ['cheap eats', 'free activities', 'budget restaurant', 'pique-nique'],
    minRating: 4.0,
    maxPriceLevel: 1,
    rule: 'distance courte pour réduire transports',
  ),
  'Backpack': TravelerPlacesProfile(
    additionalTypes: ['lodging', 'meal_takeaway', 'laundry'],
    additionalTextQueries: ['hostel', 'street food', 'free walking tour', 'local bar'],
    minRating: 4.0,
    maxPriceLevel: 2,
    rule: 'planning souple, social, proche transports publics',
  ),
  'En famille': TravelerPlacesProfile(
    additionalTypes: ['zoo', 'aquarium', 'amusement_park', 'ice_cream_shop'],
    minRating: 4.1,
    excludedInterests: ['Nightlife'],
    maxActivityMinutes: 120,
    maxConsecutiveDistanceMeters: 1000,
    rule: 'éviter trop de marche et horaires tardifs, prévoir pauses, kids-friendly',
  ),
  'Voyage pro': TravelerPlacesProfile(
    additionalTypes: ['lodging'],
    additionalTextQueries: ['coworking', 'business lunch', 'hotel bar'],
    minRating: 4.2,
    maxConsecutiveDistanceMeters: 800,
    rule: 'autour hôtel/gare, ouvert tôt/tard, créneaux courts entre travail',
  ),
  // ─── Nouveaux types (validés 2026-04-25) ────────────────────────────────
  'Couple': TravelerPlacesProfile(
    additionalTypes: ['spa'],
    additionalTextQueries: ['romantic restaurant', 'sunset spot', 'rooftop bar', 'boutique hotel'],
    minRating: 4.3,
    rule: 'coucher de soleil, dîner sympa, balade, expériences intimes',
  ),
  'Chill': TravelerPlacesProfile(
    additionalTypes: ['spa', 'park', 'botanical_garden', 'beach'],
    additionalTextQueries: ['cozy cafe', 'quiet park', 'wellness'],
    minRating: 4.2,
    excludedInterests: ['Nightlife', 'Sports'],
    maxActivityMinutes: 90,
    maxConsecutiveDistanceMeters: 800,
    rule: '1-2 activités max par jour, beaucoup de temps libre, faible distance',
  ),
  'Fun': TravelerPlacesProfile(
    additionalTypes: ['night_club', 'amusement_park', 'beach'],
    additionalTextQueries: ['photo spot', 'food hall', 'night market', 'lively bar'],
    minRating: 4.0,
    rule: 'activités fin d\'après-midi/soirée, lieux animés, spots photo',
  ),
  'Senior': TravelerPlacesProfile(
    additionalTypes: ['historical_landmark', 'museum'],
    additionalTextQueries: ['guided tour'],
    minRating: 4.2,
    excludedInterests: ['Nightlife', 'Sports'],
    maxActivityMinutes: 90,
    maxConsecutiveDistanceMeters: 300,
    rule: 'peu de marche, pauses fréquentes, activités assises/indoor, éviter fortes chaleurs',
  ),
};
