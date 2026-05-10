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

  /// Liste explicite de primary types à rejeter pour cet intérêt. Utile pour
  /// des exclusions précises qui ne tombent pas sous excludeFoodPrimaryType :
  /// - Gastronomie/Bons plans : exclure supermarket, grocery_store, fast_food_restaurant.
  /// - Hors circuit : exclure tourist_attraction (par définition pas hors-circuit).
  final List<String> excludedPrimaryTypes;

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
    this.excludedPrimaryTypes = const [],
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
    if (excludedPrimaryTypes.isNotEmpty &&
        c.types.isNotEmpty &&
        excludedPrimaryTypes.contains(c.types.first)) {
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
    // Queries en FR : Places searchText fonctionne mieux dans la langue locale.
    // Test 27/04 en France : queries EN ('hiking trail') retournaient 0 résultat.
    textQueries: ['sentier de randonnée', 'point de vue', 'balade nature'],
    minRating: 4.2,
  ),
  'Shopping': InterestPlacesQuery(
    includedTypes: ['shopping_mall', 'clothing_store', 'department_store', 'market', 'store'],
    textQueries: ['rue commerçante', 'marché local', 'boutique souvenirs', 'magasin d\'usine'],
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
    // Les lieux dont le primary type est `tourist_attraction` sont par
    // définition mainstream, pas hors-circuit. Test Nancy : la cathédrale
    // et l'église Saint-Sébastien remontaient ici, on les exclut.
    excludedPrimaryTypes: ['tourist_attraction'],
    rule: 'éviter chaînes connues, éviter lieux trop touristiques',
  ),
  'Bons plans': InterestPlacesQuery(
    includedTypes: ['restaurant', 'cafe', 'bakery', 'park', 'museum', 'market'],
    textQueries: ['pas cher', 'gratuit', 'entrée libre', 'petit prix'],
    maxPriceLevel: 1,
    // Test Nancy : E.Leclerc (supermarché) remontait via la requête `bakery`,
    // Burger King via fast_food_restaurant. Pas glamour pour un voyage.
    excludedPrimaryTypes: [
      'supermarket',
      'grocery_store',
      'convenience_store',
      'fast_food_restaurant',
    ],
  ),
  'Wellness': InterestPlacesQuery(
    includedTypes: ['spa', 'beauty_salon', 'gym'],
    minRating: 4.4,
    minUserRatingCount: 50,
  ),
  'Esthétique': InterestPlacesQuery(
    includedTypes: ['beauty_salon', 'hair_care', 'spa'],
    textQueries: ['soin du visage', 'soins de la peau', 'épilation laser', 'institut de beauté'],
    minRating: 4.4,
  ),
  'Gastronomie': InterestPlacesQuery(
    includedTypes: ['restaurant', 'cafe', 'bakery', 'meal_takeaway'],
    textQueries: ['cuisine locale', 'cuisine traditionnelle', 'street food', 'restaurant gastronomique'],
    // Bumpé de 4.0 à 4.3 — pour Gastronomie on ne veut pas d'options
    // moyennes type Burger King à 4.1.
    minRating: 4.3,
    // Test Nancy : E.Leclerc remonté via le search `bakery` (supermarché
    // qui a `bakery` en type secondaire). Idem Burger King via fast_food_restaurant.
    excludedPrimaryTypes: [
      'supermarket',
      'grocery_store',
      'convenience_store',
      'fast_food_restaurant',
    ],
  ),
  'Culture': InterestPlacesQuery(
    includedTypes: ['museum', 'art_gallery', 'library', 'church'],
    textQueries: ['monument historique', 'site culturel', 'patrimoine'],
    minRating: 4.0,
    rule: 'vérifier ouverture aux horaires du créneau et durée compatible',
  ),
  'Plage': InterestPlacesQuery(
    // Plage doit RESTER limité aux types nautiques. `tourist_attraction`
    // était trop large : à Marrakech (intérieur des terres) il ramenait
    // Jemaa el-Fnaa, Bahia Palace, etc. comme "Plage" (logs Lalith
    // 2026-05-08). Si la ville n'est pas côtière, l'intérêt Plage doit
    // rester vide pour ce centre.
    //
    // Important : `natural_feature` est UNIQUEMENT un type retourné par
    // Google Places (sur les beaches notamment), PAS un type accepté en
    // input par searchNearby (HTTP 400 "Unsupported types: natural_feature").
    // Il reste utile en post-fetch (filtre sur `c.types`) mais on ne le
    // passe plus à l'API.
    //
    // `water_park` retiré (Lalith 2026-05-09) : un parc aquatique n'est
    // PAS une plage. Reste taggué 'Activité' (pratiqué, pas baignade
    // littorale). Si un voyageur veut un water park, ça remonte via
    // l'intérêt Activité ou Spots populaires.
    includedTypes: ['beach'],
    textQueries: ['plage', 'lac', 'bord de mer', 'front de mer'],
    minRating: 4.0,
    // Test Marrakech 2026-05-06 : avec profil "Grand luxe" + budget élevé, des
    // queries premium ('luxury spa', 'fine dining', 'boutique hotel') ramenaient
    // restos/spas/hôtels comme "Plage" (Le Bistro Arabe, PEPE NERO, Céline Spa).
    // Le filtre de compatibilité query↔intérêt protège côté profil, mais on
    // double-verrouille ici : Plage rejette explicitement tout primary type
    // de restauration/wellness/lodging/bar — quel que soit le chemin.
    excludedPrimaryTypes: [
      'restaurant', 'cafe', 'bakery', 'meal_takeaway', 'meal_delivery',
      'food_court', 'fast_food_restaurant',
      'spa', 'beauty_salon', 'hair_care', 'massage',
      'lodging', 'hotel', 'hostel', 'guest_house', 'motel', 'resort_hotel',
      'bar', 'pub', 'night_club', 'lounge_bar', 'cocktail_bar',
    ],
    rule: 'limité aux zones côtières/nautiques. Pour les villes intérieures, '
        'l\'intérêt reste vide (pas de fallback sur tourist_attraction).',
  ),
  'Sports': InterestPlacesQuery(
    includedTypes: ['gym', 'stadium'],
    textQueries: ['location vélo', 'kayak', 'salle d\'escalade', 'court de tennis'],
    minRating: 4.0,
  ),
  'Nature': InterestPlacesQuery(
    includedTypes: ['park', 'national_park', 'zoo'],
    textQueries: ['forêt', 'lac', 'point de vue', 'réserve naturelle', 'jardin botanique'],
    minRating: 4.0,
  ),
  'Événements': InterestPlacesQuery(
    // Lieux de représentation (spectacles, concerts, cinéma, sport pro).
    // Distincts de "Activité" (à pratiquer). night_club retiré (rentre
    // dans Nightlife). Stadium/arena/sports_complex restent ici car la
    // plupart de leur usage = événement à regarder (foot, kick-boxing pro).
    includedTypes: [
      'performing_arts_theater',
      'event_venue',
      'cultural_center',
      'convention_center',
      'movie_theater',
      'stadium',
      'arena',
      'sports_complex',
    ],
    // V8.3 (Lalith 2026-05-10 — Phase Cost-3) — pruning textQueries de
    // 11 → 4. Les 8 includedTypes captent déjà les venues, les
    // textQueries n'ajoutaient que des doublons (`salle de concert` ↔
    // `concert`, `spectacle` ↔ `salle de spectacle`) ou du bruit
    // ultra-niche (`kick boxing event`, `cabaret`). Économie ≈ 7
    // searchText par groupe sur cold cache (1 par centre × 1 par
    // cascade). Validé Lalith.
    textQueries: [
      'salle de spectacle',
      'théâtre',
      'concert',
      'cinéma',
    ],
    minRating: 4.0,
    excludeFoodPrimaryType: true,
    rule: 'Places valide le venue mais pas l\'événement réel — à compléter post-MVP avec une API événementielle',
  ),
};

/// Seuil global appliqué EN PLUS du `minRating` par intérêt.
/// Spec : "rating ≥ 4.0 minimum" pour TOUTES les requêtes.
const placesGlobalMinRating = 4.0;
