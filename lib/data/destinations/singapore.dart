/// Phase 1 / Tâche 1.2 — Données Singapour pour `DestinationIntelligence`.
///
/// **Fichier de DONNÉES uniquement**, pas une intégration cachée. Le
/// pipeline production reste strictement intact : aucun branchement,
/// aucun loader, aucune consommation du feature flag
/// `useDestinationIntelligence` (qui reste OFF par défaut).
///
/// Construit un objet `DestinationIntelligence` Singapour en
/// fusionnant les informations actuellement dispersées dans :
///
/// **Source mapping** :
/// - `destinationKey` / `canonicalCenter` / `countryCode` :
///   from `lib/features/planning/data/segment_city_canonicals.dart`
///   (`_canonicalCities['singapore']`) + cohérent avec
///   `lib/features/planning/data/metro_profile.dart` (`_singaporeMetro.lat`
///   / `.lng`).
/// - `allowedCountryCodes` :
///   déduit du `countryCode` (un seul pays pour Singapour).
/// - `blockedCountryCodes` :
///   from `_singaporeMetro.blockedAddressPatterns` (V8.28b1 Johor +
///   V8.28b1.2 Bintan/Batam) — réduit aux codes ISO 3166-1.
///   Les patterns littéraux fins (`ksl city`, `komtar`, `jbcc`,
///   `lagoi`, `tanjung pinang`, `kepri`) ne sont PAS représentables
///   dans le modèle DestinationIntelligence Phase 1.1 — cf. section
///   "Notes" ci-dessous.
/// - `borderSensitivity` :
///   `BorderSensitivity.high` — Singapour est limitrophe de Johor
///   Bahru (Malaisie, ~25 km au sud de Woodlands) et de Bintan/Batam
///   (Indonésie, ~50-75 km au SE). Le geocoder ou le radius dérivait
///   historiquement dans ces deux pays (V8.28b1 + V8.28b1.2).
/// - `tripMode` :
///   `TripMode.megaCity` — Singapour est explicitement marqué
///   `isMegaCity: true` dans `_singaporeMetro`.
/// - `zones` :
///   10 zones (cf. spec Tâche 1.2). Issues du split des 5 zones
///   combinées du MetroProfile (`singaporeChinatownCivicDay` →
///   Chinatown + Civic District + Clarke Quay ; `singaporeOrchard
///   BotanicDay` → Orchard + Botanic Gardens ; `singaporeKampongGlam
///   LittleIndiaDay` → Kampong Glam + Little India). Bugis est
///   AJOUTÉ pour satisfaire la spec — pas une zone MetroProfile
///   standalone existante. Coordonnées issues des `touristAnchors`
///   du MetroProfile quand disponibles, sinon valeurs stables
///   curated.
/// - `anchors` :
///   15 anchors fusionnés depuis `_singaporeBlueprint.mustSeeQueries`
///   (10) + `_singaporeBlueprint.experienceQueries` (5), avec dédup
///   contre les `touristAnchors` du MetroProfile. Importance et
///   duration assignées selon convention :
///   * 5 = incontournable absolu
///   * 4 = très recommandé
///   * 3 = intéressant / experience
///   * 2 / 1 = optionnel (non utilisé ici)
/// - `transportRules.maxTransitionKm` :
///   `5.0` — cohérent avec `_kMaxTransitionMegaCityKm = 5.0` (cap
///   Day Builder mégacité V8.28d-fix + cap fallback slot picker
///   mégacité V8.28b1.3 `fallbackTransitionCapsForDay`).
/// - `transportRules.dominantMode` :
///   `'public_transport'` — Singapore MRT + bus très dense.
/// - `transportRules.hasMetro` : `true`.
/// - `transportRules.hasMetroAnchorLogic` : `true` — `_singaporeMetro`
///   définit des `touristAnchors` consommés par le fan-out V8.28d
///   `metro_anchor_fanout` du pipeline.
///
/// ## Notes (informations non représentables dans le modèle 1.1)
///
/// Certaines informations existantes pertinentes pour Singapour ne
/// rentrent **pas encore** dans le modèle `DestinationIntelligence`
/// Phase 1.1. Elles sont **documentées ici** pour mémoire — aucun
/// hack Singapour spécifique n'est introduit. Voies de traitement :
///
/// 1. **`blockedAddressPatterns` littéraux fins** (`ksl city`,
///    `komtar`, `jbcc`, `lagoi`, `tanjung pinang`, `kepri`,
///    `johor bahru`, `johor darul ta'zim`, `riau islands`) — patterns
///    de noms de lieux / quartiers / mots-clés plus fins que les
///    `blockedCountryCodes` ISO 3166-1. Devront être repris en
///    **Phase 3 — DestinationScope** via une abstraction générique
///    (ex: `DestinationScope.blockedPlacePatterns: List<String>`),
///    sans hack Singapour spécifique. Phase 1.1 ne couvre PAS ce
///    grain.
///
/// 2. **`visitBlockedNamePatterns` hawker centres** (`lau pa sat`,
///    `maxwell food centre`, `hong lim market`, `food centre`) —
///    règle business "hawker centre = repas, jamais visite". Le
///    modèle 1.1 n'a pas de field pour catégoriser un anchor en
///    `visit` vs `meal`. Conséquence ici : Lau Pa Sat et Maxwell
///    Food Centre sont inclus dans `anchors` (provenance
///    `experienceQueries`) mais SANS catégorisation
///    visite/repas. À traiter dans une phase ultérieure
///    (`DestinationAnchor.category` ou tag équivalent).
///
/// 3. **`disabledArchetypes` legacy** (`_singaporeMetro` désactive
///    `oldCityDay` / `riversideDay` / `marketDay` / `modernDay` au
///    profit des 5 archétypes spécifiques) — concept propre au Day
///    Builder actuel, pas transposable directement. La structure
///    de `zones` dans `DestinationIntelligence` remplace
///    conceptuellement ce mécanisme (10 zones = vraie taxonomie,
///    plus de fallback générique). Ne nécessite pas de field
///    additionnel.
///
/// 4. **`clusterRadiusKm: 35.0`** (`_singaporeMetro`) — rayon
///    d'activation du Day Builder autour du centre canonique. Le
///    modèle 1.1 a `transportRules.maxTransitionKm` (cap intra-
///    journée) mais pas de rayon global de destination. À
///    considérer pour Phase ultérieure si une logique de scope
///    géographique en a besoin (probablement Phase 3
///    DestinationScope).
library;

import 'package:voyage/models/destination_intelligence.dart';

/// Construit l'objet `DestinationIntelligence` Singapour.
///
/// Approche fonction (vs constante const) : `Duration` et `GeoPoint`
/// imbriqués profondément ne sont pas évidents à instancier en
/// `const` literal sans alourdir le code, et la fonction reste
/// triviale à appeler. Une migration vers `const` est possible
/// ultérieurement si performance / immuabilité forte requise.
DestinationIntelligence buildSingaporeDestinationIntelligence() {
  return DestinationIntelligence(
    destinationKey: 'singapore',
    canonicalCenter: const GeoPoint(lat: 1.3521, lng: 103.8198),
    countryCode: 'SG',
    allowedCountryCodes: const ['SG'],
    blockedCountryCodes: const ['MY', 'ID'],
    // Phase 3 / Tâche 3.2 — régions / quartiers / zones bloquées
    // à grain plus fin que les country codes. Migration des
    // `blockedAddressPatterns` legacy de `_singaporeMetro`
    // (`metro_profile.dart`) hors des country names (déjà
    // couverts par `blockedCountryCodes`).
    //
    //   - Malaysia side (Johor) : ville voisine + termes fréquents
    //     (mall, station bus, etc.) qui apparaissent dans les
    //     adresses Google même quand le countryCode est absent.
    //   - Indonésie side (Bintan / Batam) : îles et province.
    //
    // Format : lowercase, sans trailing whitespace. Le matching se
    // fait via `String.contains` (substring case-insensitive)
    // côté `ScopeValidator`, cohérent avec
    // `isCandidateAddressBlocked` legacy.
    blockedNeighborRegions: const [
      // MY side
      'johor bahru',
      'johor',
      'ksl city',
      'komtar',
      'jbcc',
      // ID side
      'batam',
      'bintan',
      'lagoi',
      'tanjung pinang',
      'kepri',
    ],
    borderSensitivity: BorderSensitivity.high,
    tripMode: TripMode.megaCity,
    zones: [
      // 1. Marina Bay — waterfront + Marina Bay Sands + Gardens by the Bay.
      //    Centre = Marina Bay Sands area (cohérent touristAnchor
      //    `Marina Bay Sands` du MetroProfile).
      const TouristZone(
        name: 'Marina Bay',
        center: GeoPoint(lat: 1.2830, lng: 103.8600),
        radiusKm: 1.5,
        theme: 'waterfront_iconic',
      ),
      // 2. Chinatown — split de `singaporeChinatownCivicDay`.
      //    Centre = Buddha Tooth Relic Temple area (cohérent
      //    touristAnchor `Chinatown` du MetroProfile, lat 1.2842).
      const TouristZone(
        name: 'Chinatown',
        center: GeoPoint(lat: 1.2814, lng: 103.8443),
        radiusKm: 0.8,
        theme: 'chinatown_heritage',
      ),
      // 3. Civic District — split de `singaporeChinatownCivicDay`.
      //    Centre = National Gallery / Asian Civilisations Museum area.
      const TouristZone(
        name: 'Civic District',
        center: GeoPoint(lat: 1.2906, lng: 103.8512),
        radiusKm: 0.8,
        theme: 'civic_museums',
      ),
      // 4. Orchard — split de `singaporeOrchardBotanicDay`.
      //    Centre = Orchard Road (cohérent touristAnchor `Orchard Road`
      //    du MetroProfile).
      const TouristZone(
        name: 'Orchard',
        center: GeoPoint(lat: 1.3050, lng: 103.8327),
        radiusKm: 1.0,
        theme: 'shopping_modern',
      ),
      // 5. Sentosa — île (cohérent touristAnchor `Sentosa` du
      //    MetroProfile, lat 1.2494, radius 3000m).
      const TouristZone(
        name: 'Sentosa',
        center: GeoPoint(lat: 1.2494, lng: 103.8303),
        radiusKm: 3.0,
        theme: 'island_resort',
      ),
      // 6. Little India — split de `singaporeKampongGlamLittleIndiaDay`.
      //    Centre = Sri Veeramakaliamman area (cohérent touristAnchor
      //    `Little India` du MetroProfile, lat 1.3066).
      const TouristZone(
        name: 'Little India',
        center: GeoPoint(lat: 1.3066, lng: 103.8520),
        radiusKm: 0.7,
        theme: 'little_india_ethnic',
      ),
      // 7. Kampong Glam — split de `singaporeKampongGlamLittleIndiaDay`.
      //    Centre = Sultan Mosque / Arab Street (cohérent touristAnchor
      //    `Kampong Glam / Arab Street` du MetroProfile, lat 1.3019).
      const TouristZone(
        name: 'Kampong Glam',
        center: GeoPoint(lat: 1.3019, lng: 103.8590),
        radiusKm: 0.6,
        theme: 'muslim_quarter_arab',
      ),
      // 8. Botanic Gardens — split de `singaporeOrchardBotanicDay`.
      //    Centre = Singapore Botanic Gardens (cohérent touristAnchor
      //    `Singapore Botanic Gardens` du MetroProfile, lat 1.3138,
      //    radius 2500m).
      const TouristZone(
        name: 'Botanic Gardens',
        center: GeoPoint(lat: 1.3138, lng: 103.8159),
        radiusKm: 1.5,
        theme: 'nature_garden',
      ),
      // 9. Bugis — AJOUT user (zone non standalone du MetroProfile).
      //    Centre approximatif Bugis MRT / Bugis Junction area.
      //    Couvre Bugis Street market + Sultan Mosque proximité.
      //    Coordonnées dérivées (Bugis MRT ~1.3007 / 103.8559).
      const TouristZone(
        name: 'Bugis',
        center: GeoPoint(lat: 1.3007, lng: 103.8559),
        radiusKm: 0.6,
        theme: 'street_market',
      ),
      // 10. Clarke Quay — split de `singaporeChinatownCivicDay`.
      //     Centre = Clarke Quay (cohérent touristAnchor
      //     `Clarke Quay / Boat Quay` du MetroProfile, lat 1.2904).
      const TouristZone(
        name: 'Clarke Quay',
        center: GeoPoint(lat: 1.2904, lng: 103.8467),
        radiusKm: 0.6,
        theme: 'riverside_nightlife',
      ),
    ],
    anchors: const [
      // ─── 10 must-see (from `_singaporeBlueprint.mustSeeQueries`) ──
      DestinationAnchor(
        name: 'Marina Bay Sands',
        placeQueries: ['Marina Bay Sands Singapore'],
        importance: 5,
        recommendedDuration: Duration(minutes: 120),
      ),
      DestinationAnchor(
        name: 'Gardens by the Bay',
        placeQueries: ['Gardens by the Bay Supertree'],
        importance: 5,
        recommendedDuration: Duration(minutes: 180),
      ),
      DestinationAnchor(
        name: 'Sentosa Island',
        placeQueries: ['Sentosa Island Singapore'],
        importance: 5,
        recommendedDuration: Duration(minutes: 360),
      ),
      DestinationAnchor(
        name: 'Chinatown',
        placeQueries: ['Chinatown Singapore'],
        importance: 4,
        recommendedDuration: Duration(minutes: 120),
      ),
      DestinationAnchor(
        name: 'Little India',
        placeQueries: ['Little India Singapore'],
        importance: 4,
        recommendedDuration: Duration(minutes: 90),
      ),
      DestinationAnchor(
        name: 'Singapore Botanic Gardens',
        placeQueries: ['Singapore Botanic Gardens'],
        importance: 5,
        recommendedDuration: Duration(minutes: 150),
      ),
      DestinationAnchor(
        name: 'Merlion Park',
        placeQueries: ['Merlion Park Singapore'],
        importance: 4,
        recommendedDuration: Duration(minutes: 30),
      ),
      DestinationAnchor(
        name: 'Orchard Road',
        placeQueries: ['Orchard Road Singapore'],
        importance: 4,
        recommendedDuration: Duration(minutes: 120),
      ),
      DestinationAnchor(
        name: 'ArtScience Museum',
        placeQueries: ['ArtScience Museum Singapore'],
        importance: 4,
        recommendedDuration: Duration(minutes: 120),
      ),
      DestinationAnchor(
        name: 'Buddha Tooth Relic Temple',
        placeQueries: ['Buddha Tooth Relic Temple Singapore'],
        importance: 5,
        recommendedDuration: Duration(minutes: 60),
      ),
      // ─── 5 experience (from `_singaporeBlueprint.experienceQueries`) ──
      DestinationAnchor(
        name: 'Clarke Quay',
        placeQueries: ['Clarke Quay Singapore night'],
        importance: 3,
        recommendedDuration: Duration(minutes: 90),
      ),
      // Note : Lau Pa Sat est un hawker centre, actuellement bloqué
      // des visit-slots côté pipeline V8.28b1
      // (`visitBlockedNamePatterns`) car réservé aux repas. Le
      // modèle DestinationIntelligence 1.1 n'a pas de catégorie
      // visit/meal — inclus ici par fidélité au blueprint
      // `experienceQueries`. Cf. doc migration phase1_task1_2.md
      // section "Notes".
      DestinationAnchor(
        name: 'Lau Pa Sat',
        placeQueries: ['Lau Pa Sat hawker centre'],
        importance: 3,
        recommendedDuration: Duration(minutes: 60),
      ),
      DestinationAnchor(
        name: 'Maxwell Food Centre',
        placeQueries: ['Maxwell Food Centre Singapore'],
        importance: 3,
        recommendedDuration: Duration(minutes: 60),
      ),
      DestinationAnchor(
        name: 'Singapore Flyer',
        placeQueries: ['Singapore Flyer'],
        importance: 3,
        recommendedDuration: Duration(minutes: 60),
      ),
      DestinationAnchor(
        name: 'Kampong Glam / Arab Street',
        placeQueries: ['Kampong Glam Arab Street'],
        importance: 4,
        recommendedDuration: Duration(minutes: 90),
      ),
    ],
    transportRules: const TransportRules(
      // V8.28d-fix mégacité cap 5 km (Day Builder pack-level) +
      // V8.28b1.3 cap fallback slot picker mégacité 5 km / 0 long
      // hop. La valeur 5.0 est la convention Lunao pour mégacité
      // dense.
      maxTransitionKm: 5.0,
      // Singapore MRT + bus très denses. Convention `Trip
      // .localTransportMode = 'public_transport'`.
      dominantMode: 'public_transport',
      // Singapore MRT couvre tout le territoire intra-îleux,
      // y compris Sentosa via Sentosa Express.
      hasMetro: true,
      // `_singaporeMetro` définit 9 `touristAnchors` consommés
      // par le fan-out V8.28d `metro_anchor_fanout` côté pipeline.
      hasMetroAnchorLogic: true,
    ),
  );
}
