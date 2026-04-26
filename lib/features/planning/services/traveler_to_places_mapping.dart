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

  /// Rayon de recherche **principal** autour du centre du jour pour le
  /// `searchNearby` Places. Correspond au mode "marche" du profil — c'est la
  /// zone à privilégier (lieux atteignables sans transport).
  /// Calibré : Senior/Chill 600m, Voyage pro/Couple 800m, En famille 1000m,
  /// Fun 1200m, Backpack/Meilleur prix 1500m, Road-trip 2000m, Grand luxe 800m
  /// (taxi facile). Default (sans profil) : voir `defaultSearchRadiusMeters`.
  final int? searchRadiusMeters;

  /// Rayon de recherche **étendu** activé en cascade quand la pool walking est
  /// trop maigre (< `minPoolForCascade`). Représente la zone accessible en
  /// transport public ou taxi/voiture selon le profil. Si null, pas de cascade.
  ///
  /// Cf. `project_open_improvements.md` "Cascade de modes de transport".
  final int? transitRadiusMeters;

  /// Seuil minimum de candidats récoltés en walking en-dessous duquel on étend
  /// la recherche à `transitRadiusMeters`. Garantit qu'un Senior dans une zone
  /// peu dense ait quand même des suggestions (via transport public). Default
  /// 20 quand `transitRadiusMeters` est défini.
  final int? minPoolForCascade;

  /// Volume maximum d'activités à proposer par jour pour ce profil. Sert à
  /// adapter le rythme de la journée — un Senior doit avoir 2-3 activités
  /// (rythme tranquille), Chill 1-2, Famille/Voyage pro 3, profils standards
  /// 4-5. Pour `category=all` les repas (déjeuner+dîner) viennent en SUS de
  /// ce compte (insertion déterministe).
  final int? maxActivitiesPerDay;

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
    this.searchRadiusMeters,
    this.transitRadiusMeters,
    this.minPoolForCascade,
    this.maxActivitiesPerDay,
    this.rule,
  });
}

/// Rayon de recherche par défaut quand le voyageur n'a pas de type renseigné
/// sur le voyage. ~30 min mixte marche/transit dans la moyenne des profils.
const int defaultSearchRadiusMeters = 4000;

/// Mapping type voyageur (= dbValue stocké dans `trips.traveler_type` ou
/// `user_profiles.traveler_type`) → profil Places. Implémente strictement
/// `project_traveler_types_places_mapping.md` validé par Lalith.
const travelerPlacesProfiles = <String, TravelerPlacesProfile>{
  'Road-trip': TravelerPlacesProfile(
    additionalTypes: ['tourist_attraction', 'park', 'historical_landmark', 'gas_station', 'parking'],
    additionalTextQueries: ['viewpoint', 'scenic stop', 'roadside diner'],
    minRating: 4.1,
    maxActivityMinutes: 120,
    searchRadiusMeters: 2000, // walk autour de l'étape (centre-ville)
    transitRadiusMeters: 10000, // voiture, étapes ≤15 min de route
    minPoolForCascade: 20,
    rule: 'détours ≤15-25 min, étapes courtes 30 min-2h le long du trajet',
  ),
  'Grand luxe': TravelerPlacesProfile(
    additionalTypes: ['spa', 'art_gallery', 'jewelry_store'],
    additionalTextQueries: ['fine dining', 'luxury spa', 'rooftop bar', 'boutique hotel', 'Michelin'],
    minRating: 4.5,
    minPriceLevel: 3,
    minUserRatingCount: 100,
    searchRadiusMeters: 800, // walk
    transitRadiusMeters: 3000, // taxi facile
    minPoolForCascade: 20,
    rule: 'éviter low-cost et lieux trop touristiques',
  ),
  'Meilleur prix': TravelerPlacesProfile(
    additionalTypes: ['bakery', 'meal_takeaway', 'supermarket'],
    additionalTextQueries: ['cheap eats', 'free activities', 'budget restaurant', 'pique-nique'],
    minRating: 4.0,
    maxPriceLevel: 1,
    searchRadiusMeters: 1500, // walk volontiers
    transitRadiusMeters: 4000, // transport public
    minPoolForCascade: 20,
    rule: 'distance courte pour réduire transports',
  ),
  'Backpack': TravelerPlacesProfile(
    additionalTypes: ['lodging', 'meal_takeaway', 'laundry'],
    additionalTextQueries: ['hostel', 'street food', 'free walking tour', 'local bar'],
    minRating: 4.0,
    maxPriceLevel: 2,
    searchRadiusMeters: 1500, // marche volontiers
    transitRadiusMeters: 4000, // transport public
    minPoolForCascade: 20,
    rule: 'planning souple, social, proche transports publics',
  ),
  'En famille': TravelerPlacesProfile(
    additionalTypes: ['zoo', 'aquarium', 'amusement_park', 'ice_cream_shop'],
    minRating: 4.1,
    excludedInterests: ['Nightlife'],
    maxActivityMinutes: 120,
    maxConsecutiveDistanceMeters: 1000,
    searchRadiusMeters: 1000, // walk avec enfants
    transitRadiusMeters: 2500, // transport public + taxi
    minPoolForCascade: 20,
    maxActivitiesPerDay: 3,
    rule: 'éviter trop de marche et horaires tardifs, prévoir pauses, kids-friendly',
  ),
  'Voyage pro': TravelerPlacesProfile(
    additionalTypes: ['lodging'],
    additionalTextQueries: ['coworking', 'business lunch', 'hotel bar'],
    minRating: 4.2,
    maxConsecutiveDistanceMeters: 800,
    searchRadiusMeters: 800, // walk autour de l'hôtel/centre business
    transitRadiusMeters: 2500, // taxi/VTC
    minPoolForCascade: 15,
    rule: 'autour hôtel/gare, ouvert tôt/tard, créneaux courts entre travail',
  ),
  // ─── Nouveaux types (validés 2026-04-25) ────────────────────────────────
  'Couple': TravelerPlacesProfile(
    additionalTypes: ['spa'],
    additionalTextQueries: ['romantic restaurant', 'sunset spot', 'rooftop bar', 'boutique hotel'],
    minRating: 4.3,
    searchRadiusMeters: 800, // walk romantique
    transitRadiusMeters: 2500, // taxi
    minPoolForCascade: 20,
    rule: 'coucher de soleil, dîner sympa, balade, expériences intimes',
  ),
  'Chill': TravelerPlacesProfile(
    additionalTypes: ['spa', 'park', 'botanical_garden', 'beach'],
    additionalTextQueries: ['cozy cafe', 'quiet park', 'wellness'],
    minRating: 4.2,
    excludedInterests: ['Nightlife', 'Sports'],
    maxActivityMinutes: 90,
    maxConsecutiveDistanceMeters: 800,
    searchRadiusMeters: 600, // walk court
    transitRadiusMeters: 2000, // transport public si nécessaire
    minPoolForCascade: 15,
    maxActivitiesPerDay: 2,
    rule: '1-2 activités max par jour, beaucoup de temps libre, faible distance',
  ),
  'Fun': TravelerPlacesProfile(
    additionalTypes: ['night_club', 'amusement_park', 'beach'],
    additionalTextQueries: ['photo spot', 'food hall', 'night market', 'lively bar'],
    minRating: 4.0,
    searchRadiusMeters: 1200, // walk dynamique
    transitRadiusMeters: 3000, // transport public
    minPoolForCascade: 20,
    rule: 'activités fin d\'après-midi/soirée, lieux animés, spots photo',
  ),
  'Senior': TravelerPlacesProfile(
    additionalTypes: ['historical_landmark', 'museum'],
    additionalTextQueries: ['guided tour'],
    minRating: 4.2,
    excludedInterests: ['Nightlife', 'Sports'],
    maxActivityMinutes: 90,
    maxConsecutiveDistanceMeters: 300,
    searchRadiusMeters: 600, // walk court (validé Lalith 26/04)
    transitRadiusMeters: 2000, // transport public/taxi quand pool walk insuffisante
    minPoolForCascade: 20,
    maxActivitiesPerDay: 3,
    rule: 'peu de marche, pauses fréquentes, activités assises/indoor, éviter fortes chaleurs',
  ),
};
