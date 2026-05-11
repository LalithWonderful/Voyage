/// V8.27 (Lalith 2026-05-10) — abstraction MetroProfile.
///
/// Remplace le `_BuilderCity` hardcodé de `day_builder.dart`. Permet
/// d'étendre Day Builder à de nouvelles métropoles (Tokyo, NYC,
/// Istanbul, Séoul, Londres…) en ajoutant uniquement un MetroProfile
/// au registre `metroProfiles`. Aucune modification de la logique
/// métier requise.
///
/// Architecture :
/// - `MetroProfile` : description d'une ville Day-Builder enabled.
///   Centre canonique + rayon d'activation + zones thématiques +
///   flags de configuration.
/// - `MetroZone` : zone thématique + géographique = patterns
///   nominaux + DayPackType associé. Une ville peut avoir plusieurs
///   zones du même DayPackType (ex: Bangkok = 1 oldCity + 3 market_*
///   zoned + 1 riverside + 1 modern).
/// - `getMetroProfileForCluster(lat, lng)` : lookup haversine sur
///   `metroProfiles`. Retourne null si aucun profile ne couvre.
///
/// Règles génériques (V8.21/V8.23/V8.26) — anti-zigzag, coherence
/// guard, second-pick guard — sont city-agnostic et restent dans le
/// slot picker. Les MetroProfile ne configurent QUE l'archetype
/// detection (zones + patterns nominaux).
///
/// Étapes V8.28+ : ajouter Tokyo (Shinjuku/Shibuya/Asakusa/Ginza/
/// Akihabara/Roppongi), NYC (Manhattan downtown/midtown/Brooklyn),
/// Istanbul (Sultanahmet/Beyoğlu/Kadıköy), etc. Au-delà : clustering
/// automatique pour les villes sans profil curated.
library;

import 'dart:math' as math;

import 'package:voyage/features/planning/services/day_builder.dart'
    show DayPackType;

/// Une zone thématique d'une métropole. `type` détermine l'archétype
/// Day Builder ciblé. `patterns` sont matchés case-insensitive sur le
/// nom du candidat (après strip diacritiques).
///
/// Une ville peut déclarer plusieurs MetroZone du même type (rare,
/// ex: 2 sous-zones modern dans une mégalopole étendue) ou — plus
/// commun — plusieurs types distincts pour grouper par thème.
class MetroZone {
  final DayPackType type;
  final List<String> patterns;
  const MetroZone({required this.type, required this.patterns});
}

/// V8.28d (Lalith 2026-05-10) — ancre tourisme curated. Centre
/// géographique d'une zone touristique reconnue (Shibuya, Asakusa,
/// Ginza pour Tokyo ; Westminster, Camden pour Londres ; etc.).
///
/// Utilisée par `gatherCandidatesForTrip` pour enrichir le pool
/// quand la destination géocodée tombe sur un point résidentiel
/// (cas Tokyo : geocoder retourne 35.676/139.650 = Setagaya, loin
/// des hotspots tourisme). Pour chaque ancre, un `searchNearby`
/// avec types `tourist_attraction/museum/historical_landmark/
/// monument/place_of_worship/park` est lancé → injection au pool
/// global.
class TouristAnchor {
  final String label;
  final double lat;
  final double lng;
  /// Rayon `searchNearby` en mètres. Default 1500 m couvre un
  /// quartier (Shibuya, Sultanahmet…). Augmenter pour les zones
  /// étendues (Central Park 3000 m).
  final int radiusMeters;
  const TouristAnchor({
    required this.label,
    required this.lat,
    required this.lng,
    this.radiusMeters = 1500,
  });
}

/// Description d'une ville Day-Builder enabled.
///
/// `clusterRadiusKm` : distance max haversine entre `cluster.center`
/// et `(lat, lng)` pour activer Day Builder. ~35 km couvre la
/// métropole étendue (Bangkok depuis Bang Na ~12 km).
///
/// `disableMarketTypeFallback` : si true, le fallback type-based
/// `market` ne s'applique pas pour cette ville. Utile pour les
/// villes multi-zone marché (Bangkok = 3 zones), où un place avec
/// type `market` mais sans pattern serait sinon assigné arbitrairement
/// à `marketDay` générique.
///
/// `isMegaCity` : informationnel pour V8.27. Future utilisation :
/// thresholds slot-level (centroid, second-pick) durcis pour mégapoles
/// vs villes moyennes.
class MetroProfile {
  final String cityKey;
  final double lat;
  final double lng;
  final double clusterRadiusKm;
  final bool disableMarketTypeFallback;
  final bool isMegaCity;
  final List<MetroZone> zones;
  /// V8.28d — ancres tourisme curated. `gatherCandidatesForTrip`
  /// lance un `searchNearby` autour de chaque ancre quand un
  /// MetroProfile match le cluster. Évite que le geocoder
  /// résidentiel (Tokyo 35.676 = Setagaya, loin de Shibuya/Asakusa)
  /// tire le pool vers le local. Liste vide = pas de fan-out
  /// (compatible villes non-mégalopoles).
  final List<TouristAnchor> touristAnchors;

  /// V8.28d3 (Lalith 2026-05-11) — archétypes legacy désactivés pour
  /// cette ville. Le builder n'utilise ni la zone ni le fallback type
  /// associés. Cas Tokyo : `modernDay` est désactivé au profit des
  /// 2 zones géo-séparées `modernWestDay` (W) et `roppongiMinatoDay`
  /// (S central). Sans ce flag, le fallback `park`/`art_gallery` →
  /// `modernDay` ré-injecte Hibiya Park, Mitsubishi Ichigokan Museum,
  /// Parc d'Ueno (non-matched FR) dans des packs `modernDay` Tokyo
  /// qui mélangent Tokyo Tower + Ueno + Marunouchi.
  ///
  /// Bangkok / Paris / NYC / London / Rome / Istanbul : default
  /// empty set → comportement V8.28d2 préservé.
  final Set<DayPackType> disabledArchetypes;

  /// V8.28b1 (Lalith 2026-05-11) — patterns d'adresses (substring,
  /// case-insensitive) qui rejettent un candidat de cette
  /// destination. Utile pour les villes proches d'une frontière où
  /// le geocoder ou la recherche par radius tirent le pool vers le
  /// pays voisin. Cas Singapour : cluster centré ~(1.43,103.78)
  /// avec rayon 20 km tirait KSL City Mall / KOMTAR JBCC /
  /// Johor Zoo / Bazar JB / etc. depuis Johor Bahru, Malaysia.
  ///
  /// Le filter s'applique dans `_isAllowedFinalVisitCandidate`
  /// (pool gate) avec reason `out_of_country` quand le cluster
  /// MetroProfile match cette ville. Empty pour les villes qui
  /// n'ont pas ce problème (default).
  final List<String> blockedAddressPatterns;

  /// V8.28b1 — patterns de noms (substring, case-insensitive) qui
  /// rejettent un candidat des visit-slots. Utilisé pour Singapour
  /// où les hawker centres iconiques (Lau Pa Sat, Maxwell Food
  /// Centre, Hong Lim Market & Food Centre) sont curés dans le
  /// blueprint (experience marker) mais ne doivent pas être picked
  /// comme visites classiques — réservés à l'insertion repas.
  /// L'exception curated (V8.28f2) ne s'applique PAS ici (le marker
  /// blueprint ne sauve pas le candidat du visit-slot filter).
  final List<String> visitBlockedNamePatterns;

  const MetroProfile({
    required this.cityKey,
    required this.lat,
    required this.lng,
    this.clusterRadiusKm = 35.0,
    this.disableMarketTypeFallback = false,
    this.isMegaCity = false,
    required this.zones,
    this.touristAnchors = const [],
    this.disabledArchetypes = const <DayPackType>{},
    this.blockedAddressPatterns = const <String>[],
    this.visitBlockedNamePatterns = const <String>[],
  });
}

const _bangkokMetro = MetroProfile(
  cityKey: 'bangkok',
  lat: 13.7563,
  lng: 100.5018,
  clusterRadiusKm: 35.0,
  disableMarketTypeFallback: true,
  isMegaCity: true,
  touristAnchors: [
    TouristAnchor(label: 'Grand Palace / Phra Nakhon',
        lat: 13.7499, lng: 100.4916),
    TouristAnchor(label: 'Wat Pho', lat: 13.7464, lng: 100.4928),
    TouristAnchor(label: 'Wat Arun', lat: 13.7437, lng: 100.4889),
    TouristAnchor(label: 'Khao San', lat: 13.7589, lng: 100.4977),
    TouristAnchor(label: 'Chinatown / Yaowarat',
        lat: 13.7414, lng: 100.5103),
    TouristAnchor(label: 'Siam', lat: 13.7460, lng: 100.5340),
    TouristAnchor(label: 'Sukhumvit / Asoke',
        lat: 13.7480, lng: 100.5602),
    TouristAnchor(label: 'Chatuchak', lat: 13.7997, lng: 100.5505),
    TouristAnchor(label: 'IconSiam riverside',
        lat: 13.7262, lng: 100.5106),
  ],
  zones: [
    MetroZone(type: DayPackType.oldCityDay, patterns: [
      'grand palace', 'wat pho', 'wat arun',
      'temple of the emerald buddha', 'emerald buddha',
      'sanam luang', 'city pillar', 'museum siam', 'national museum',
      'khao san', 'khaosan',
      'wat phra', 'wat saket', 'wat traimit', 'wat suthat',
      'wat ratchanatda', 'wat benchamabophit', 'wat mahathat',
      'phra nakhon',
      'golden mount', 'golden buddha', 'marble temple', 'vimanmek',
    ]),
    MetroZone(type: DayPackType.riversideDay, patterns: [
      'iconsiam', 'icon siam', 'chao phraya', 'asiatique',
      'wang lang', 'the riverfront', 'riverfront', 'river cruise',
      'tha tien', 'tha maharaj', 'phra athit', 'sathorn pier',
      'saphan taksin',
    ]),
    // Old City : Chinatown / Yaowarat / Pak Khlong / Sampeng /
    // Bang Lamphu / Khlong Toei. Zone compacte ~13.74-13.76 N.
    MetroZone(type: DayPackType.marketOldCityDay, patterns: [
      'chinatown', 'yaowarat', 'pak khlong', 'sampeng',
      'bang lamphu', 'flower market', 'khlong toei',
    ]),
    // Chatuchak / nord : Chatuchak Weekend, JJ Mall, Or Tor Kor,
    // Ratchada Rot Fai. Zone ~13.77-13.80 N.
    MetroZone(type: DayPackType.marketChatuchakDay, patterns: [
      'chatuchak', 'jj market', 'jj mall', 'or tor kor',
      'ratchada rot fai', 'rot fai ratchada',
    ]),
    // Srinagarindra / est : Train Night Market, Seacon Square,
    // Paradise Park. Zone ~13.69 N, 100.65 E.
    MetroZone(type: DayPackType.marketSrinagarindraDay, patterns: [
      'train night market srinagarindra', 'srinagarindra',
      'seacon square', 'paradise park srinagarindra',
    ]),
    // V8.28f (Lalith 2026-05-11) — `erawan shrine` + `ratchaprasong`
    // + `chit lom` ajoutés. Sans ce pattern explicite, Erawan
    // (`hindu_temple` à 13.744/100.540, près de Siam) était capturé
    // par le fallback `hindu_temple` → oldCityDay (FAUX : Erawan est
    // à Ratchaprasong, pas Old City). V8.28f retire ce fallback ;
    // Erawan doit donc être capturé soit via blueprintMustSeeMarker
    // (déjà dans blueprint Bangkok V8.25), soit via ce pattern.
    MetroZone(type: DayPackType.modernDay, patterns: [
      'jim thompson', 'mahanakhon', 'lumpini', 'lumphini',
      'siam paragon', 'siam center', 'siam discovery', 'centralworld',
      'central world', 'terminal 21', 'mbk', 'emquartier',
      'em district', 'emporium', 'sky walk', 'skywalk',
      'benjasiri', 'benjakitti', 'kingpower', 'king power',
      'samyan mitrtown',
      'erawan shrine', 'ratchaprasong', 'chit lom', 'chitlom',
    ]),
  ],
);

const _parisMetro = MetroProfile(
  cityKey: 'paris',
  lat: 48.8566,
  lng: 2.3522,
  clusterRadiusKm: 35.0,
  disableMarketTypeFallback: false,
  isMegaCity: true,
  touristAnchors: [
    TouristAnchor(label: 'Tour Eiffel', lat: 48.8584, lng: 2.2945),
    TouristAnchor(label: 'Louvre', lat: 48.8606, lng: 2.3376),
    TouristAnchor(label: 'Notre-Dame / Île de la Cité',
        lat: 48.8530, lng: 2.3499),
    TouristAnchor(label: 'Montmartre / Sacré-Cœur',
        lat: 48.8867, lng: 2.3431),
    TouristAnchor(label: 'Le Marais', lat: 48.8566, lng: 2.3622),
    TouristAnchor(label: 'Quartier Latin / Panthéon',
        lat: 48.8462, lng: 2.3460),
    TouristAnchor(label: 'Trocadéro', lat: 48.8625, lng: 2.2870),
    TouristAnchor(label: 'Champs-Élysées / Arc de Triomphe',
        lat: 48.8738, lng: 2.2950),
  ],
  zones: [
    MetroZone(type: DayPackType.oldCityDay, patterns: [
      'notre-dame', 'notre dame', 'sainte-chapelle', 'sainte chapelle',
      'le marais', 'place des vosges', 'pantheon', 'panthéon',
      'sacre-coeur', 'sacré-cœur', 'sacre coeur', 'montmartre',
      'conciergerie', 'place de la bastille', 'ile de la cite',
      'île de la cité', 'saint-germain', 'saint germain',
    ]),
    MetroZone(type: DayPackType.riversideDay, patterns: [
      'seine', 'pont alexandre', 'pont des arts', 'pont neuf',
      'tuileries', 'orsay', 'quai', 'bateaux', 'bateau-mouche',
      'orangerie', 'berges de seine',
    ]),
    // Paris : 1 zone marché unique (intra-périphérique compacte).
    MetroZone(type: DayPackType.marketDay, patterns: [
      'rue mouffetard', 'marche bastille', 'marché bastille',
      'marche aligre', 'marché aligre', 'aligre',
      'marche des enfants', 'marché des enfants',
      'rue cler', 'marche monge', 'marché monge',
      'marche beauvau', 'marché beauvau',
      'marche saint-quentin', 'marché saint-quentin',
    ]),
    MetroZone(type: DayPackType.modernDay, patterns: [
      'eiffel', 'tour eiffel', 'trocadero', 'trocadéro',
      'champs-elysees', 'champs-élysées', 'champs elysees',
      'arc de triomphe', 'galeries lafayette', 'centre pompidou',
      'pompidou', 'la defense', 'la défense',
      'orsay', 'musee d\'orsay', 'musée d\'orsay',
      'luxembourg garden', 'jardin du luxembourg', 'louvre',
    ]),
  ],
);

/// V8.28a (Lalith 2026-05-10) — 5 MetroProfiles additionnels pour
/// les métropoles prioritaires. Patterns curated par zones. Blueprint
/// correspondant ajouté dans `destination_blueprints.dart`.
///
/// Note : les zones ici sont génériques (oldCity/riverside/market/
/// modern). Pas de split géo intra-ville (équivalent Bangkok
/// market_chatuchak/srinagarindra). Si une simu révèle des zigzags
/// type Tokyo Shinjuku↔Asakusa, on splittera comme Bangkok l'a été
/// en V8.24.

const _tokyoMetro = MetroProfile(
  cityKey: 'tokyo',
  // V8.28d — centre canonique recalé sur Tokyo Station (au lieu de
  // 35.6762/139.6503 = Setagaya/Yoyogi-Hachiman résidentiel, où le
  // geocoder "Tokyo, Japan" tombe parfois). Le lookup haversine
  // tolère bien les deux puisque le clusterRadiusKm = 40 km couvre
  // tout l'intra-Yamanote.
  lat: 35.6812,
  lng: 139.7671,
  clusterRadiusKm: 40.0,
  disableMarketTypeFallback: false,
  isMegaCity: true,
  // V8.28d3 — désactive `modernDay` legacy pour Tokyo. Sans ce
  // filtre, le fallback type-based `park`/`art_gallery` → modernDay
  // ré-injectait Hibiya Park / Mitsubishi Ichigokan / Parc d'Ueno
  // (FR non matché) dans des packs `modernDay` Tokyo qui mélangeaient
  // Tokyo Tower + Ueno + Marunouchi. Tokyo doit utiliser uniquement
  // oldCityDay / marketDay / riversideDay / modernWestDay /
  // roppongiMinatoDay.
  disabledArchetypes: {DayPackType.modernDay},
  // V8.28d — 9 ancres tourisme couvrant les hotspots Tokyo. Le
  // geocoder "Tokyo, Japan" tombe souvent sur Setagaya/Yoyogi
  // (35.676/139.650), loin de Shibuya/Asakusa/Ginza. Sans ces
  // ancres, le searchNearby autour du centre récolte du local
  // résidentiel.
  touristAnchors: [
    TouristAnchor(label: 'Asakusa (Senso-ji)',
        lat: 35.7148, lng: 139.7967),
    TouristAnchor(label: 'Shibuya', lat: 35.6580, lng: 139.7016),
    TouristAnchor(label: 'Shinjuku', lat: 35.6896, lng: 139.7006),
    TouristAnchor(label: 'Harajuku / Meiji Jingu',
        lat: 35.6716, lng: 139.7030),
    TouristAnchor(label: 'Ginza', lat: 35.6717, lng: 139.7650),
    TouristAnchor(label: 'Akihabara', lat: 35.7022, lng: 139.7745),
    TouristAnchor(label: 'Ueno', lat: 35.7141, lng: 139.7774),
    TouristAnchor(label: 'Roppongi', lat: 35.6628, lng: 139.7314),
    TouristAnchor(label: 'Tokyo Station / Marunouchi',
        lat: 35.6812, lng: 139.7671),
  ],
  // V8.28d-fix (Lalith 2026-05-11) — zones Tokyo restructurées en 4
  // clusters géographiques compacts (≤ 5 km inter-pick, aligné sur
  // `_kMaxTransitionMegaCityKm`). La simu 2026-05-11 a montré que
  // l'ancien découpage mélangeait Meiji-jingū (W) avec Senso-ji (NE)
  // dans `oldCityDay`, et Shibuya (W) avec Tokyo Tower (S) +
  // Tokyo Skytree (NE) dans `modernDay`. Résultat : packs acceptés
  // à 9.7 km de transition. Nouveau découpage par quartier compact :
  // - oldCityDay = NE (Asakusa / Ueno / Skytree / Akihabara)
  // - modernDay = W + S central (Shibuya / Shinjuku / Meiji /
  //   Harajuku / Roppongi / Tokyo Tower)
  // - riversideDay = SE coast (Odaiba / Toyosu / teamLab / Sumida)
  // - marketDay = central est (Tsukiji / Ginza / Imperial Palace /
  //   Tokyo Station). Label "market" un peu loose ici (Imperial Palace
  //   n'est pas un marché) mais geographically Tsukiji est l'ancre
  //   thématique et le pack reste cohérent <5 km inter-pick.
  zones: [
    // NE Tokyo : Asakusa cluster + Ueno + Skytree + Akihabara.
    // Toutes <5 km de Senso-ji (35.7148/139.7967).
    // V8.28d3 — variantes FR : "Parc d'Ueno", "Sanctuaire Asakusa"
    // (Google Places renvoie souvent les labels traduits selon
    // languageCode=fr).
    MetroZone(type: DayPackType.oldCityDay, patterns: [
      'senso-ji', 'sensoji', 'sanctuaire asakusa', 'asakusa', 'nakamise',
      'tokyo skytree', 'skytree',
      'ueno park', 'ueno zoo', 'ueno toshogu',
      "parc d'ueno", 'parc ueno', 'ueno-koen',
      'ameya-yokocho', 'ameyoko',
      'akihabara',
      'kappabashi', 'kanda', 'nezu shrine', 'gokokuji',
    ]),
    // SE coast : Odaiba / Toyosu / teamLab Planets / Sumida.
    MetroZone(type: DayPackType.riversideDay, patterns: [
      'sumida river', 'sumida park',
      'odaiba', 'rainbow bridge', 'kachidoki',
      'toyosu', 'teamlab',
      'asakusa pier',
    ]),
    // Central est : Tsukiji / Toyosu market / Ginza / Imperial Palace
    // / Tokyo Station / Hamarikyu / Yasukuni. Cluster compact ~2.5 km.
    MetroZone(type: DayPackType.marketDay, patterns: [
      'tsukiji outer market', 'tsukiji',
      'toyosu market',
      'ginza',
      'imperial palace', 'kokyo', 'kōkyo',
      'tokyo station', 'marunouchi',
      'hamarikyu', 'hama-rikyu', 'hama rikyu',
      'yasukuni',
    ]),
    // V8.28d2 — split modernDay Tokyo en 2 zones géo distinctes. La
    // simu 2026-05-11 a montré Shibuya Crossing + Shinjuku Gyoen +
    // Tokyo Tower acceptés ensemble (maxTransitionKm=4.4, sous cap)
    // mais ce n'est pas un vrai pack compact. Tokyo Tower appartient
    // au cluster Roppongi/Minato (S central), pas à l'axe
    // Shibuya/Harajuku/Shinjuku (W).
    //
    // W Tokyo : Shibuya / Shinjuku / Meiji / Harajuku / Yoyogi
    // (axe Yamanote ouest). Inter-pick max ~3.5 km.
    // V8.28d3 — patterns enrichis (variantes nom + macrons stripped
    // par _normName : meiji jingū → meiji jingu).
    MetroZone(type: DayPackType.modernWestDay, patterns: [
      'shibuya crossing', 'shibuya scramble', 'shibuya sky',
      'hachiko', 'shibuya',
      'shinjuku gyoen', 'shinjuku',
      'meiji shrine', 'meiji jingu', 'meiji-jingu',
      'sanctuaire meiji',
      'harajuku',
      'takeshita street', 'takeshita-dori', 'takeshita',
      'omotesando',
      'yoyogi park', 'parc yoyogi', 'yoyogi',
      'shinjuku golden-gai', 'golden gai', 'golden-gai',
      'tokyo metropolitan government building',
      'tokyo metropolitan government',
      'gouvernement metropolitain de tokyo',
    ]),
    // S central : Roppongi / Tokyo Tower / Mori Tower / Azabudai.
    // Cluster compact <1.5 km autour de 35.66/139.74.
    // V8.28d3 — landmarks Roppongi/Minato listés (Mori Art Museum,
    // National Art Center, 21_21 Design Sight, Azabudai Hills) +
    // variantes FR "La Tour de Tokyo" / "Tour de Tokyo".
    MetroZone(type: DayPackType.roppongiMinatoDay, patterns: [
      'roppongi hills', 'roppongi',
      'tokyo tower', 'tour de tokyo', 'la tour de tokyo',
      'zojo-ji', 'zojoji',
      'mori tower', 'tokyo city view', 'mori art museum',
      'azabudai hills', 'azabudai', 'azabu',
      'the national art center', 'national art center tokyo',
      'national art centre tokyo',
      '21_21 design sight', '21 21 design sight', 'design sight',
      'minato',
    ]),
  ],
);

const _nycMetro = MetroProfile(
  cityKey: 'new york',
  lat: 40.7589,
  lng: -73.9851,
  clusterRadiusKm: 35.0,
  disableMarketTypeFallback: false,
  isMegaCity: true,
  touristAnchors: [
    TouristAnchor(label: 'Times Square', lat: 40.7589, lng: -73.9851),
    TouristAnchor(label: 'Empire State Building',
        lat: 40.7484, lng: -73.9857),
    TouristAnchor(label: 'Central Park',
        lat: 40.7829, lng: -73.9654, radiusMeters: 3000),
    TouristAnchor(label: 'Statue of Liberty / Battery Park',
        lat: 40.6892, lng: -74.0445),
    TouristAnchor(label: 'Brooklyn Bridge / DUMBO',
        lat: 40.7061, lng: -73.9969),
    TouristAnchor(label: '9/11 Memorial / WTC',
        lat: 40.7115, lng: -74.0134),
    TouristAnchor(label: 'High Line / Chelsea',
        lat: 40.7480, lng: -74.0048),
    TouristAnchor(label: 'Greenwich Village / Soho',
        lat: 40.7336, lng: -74.0028),
  ],
  zones: [
    MetroZone(type: DayPackType.oldCityDay, patterns: [
      'wall street', 'statue of liberty', 'ellis island',
      'battery park', '9/11 memorial', 'world trade center',
      'trinity church', 'st patrick', 'st paul\'s chapel',
      'federal hall',
    ]),
    MetroZone(type: DayPackType.riversideDay, patterns: [
      'brooklyn bridge', 'manhattan bridge', 'pier 17',
      'hudson yards', 'hudson river', 'east river',
      'brooklyn bridge park', 'roosevelt island',
    ]),
    MetroZone(type: DayPackType.marketDay, patterns: [
      'chelsea market', 'time out market', 'bryant park market',
      'union square greenmarket',
    ]),
    MetroZone(type: DayPackType.modernDay, patterns: [
      'empire state building', 'top of the rock', 'rockefeller',
      'times square', 'broadway', 'central park',
      'metropolitan museum', 'met museum', 'moma',
      'museum of modern art', 'guggenheim', 'whitney museum',
      'one world observatory', 'high line', 'fifth avenue',
      'soho', 'tribeca', 'greenwich village', 'east village',
    ]),
  ],
);

const _londonMetro = MetroProfile(
  cityKey: 'london',
  lat: 51.5074,
  lng: -0.1278,
  clusterRadiusKm: 35.0,
  disableMarketTypeFallback: false,
  isMegaCity: true,
  touristAnchors: [
    TouristAnchor(label: 'Westminster / Big Ben',
        lat: 51.4994, lng: -0.1245),
    TouristAnchor(label: 'Tower of London / Tower Bridge',
        lat: 51.5081, lng: -0.0759),
    TouristAnchor(label: 'Buckingham Palace',
        lat: 51.5014, lng: -0.1419),
    TouristAnchor(label: 'British Museum / Bloomsbury',
        lat: 51.5194, lng: -0.1270),
    TouristAnchor(label: 'Camden Town', lat: 51.5414, lng: -0.1444),
    TouristAnchor(label: 'Borough Market / South Bank',
        lat: 51.5055, lng: -0.0908),
    TouristAnchor(label: 'Greenwich', lat: 51.4826, lng: 0.0077),
    TouristAnchor(label: 'Soho / Covent Garden',
        lat: 51.5142, lng: -0.1330),
  ],
  zones: [
    MetroZone(type: DayPackType.oldCityDay, patterns: [
      'tower of london', 'westminster abbey', 'buckingham palace',
      'big ben', 'houses of parliament', 'st paul\'s cathedral',
      'st pauls cathedral', 'kensington palace', 'hampton court',
      'churchill war rooms',
    ]),
    MetroZone(type: DayPackType.riversideDay, patterns: [
      'tower bridge', 'london eye', 'thames', 'southbank',
      'greenwich', 'cutty sark', 'hms belfast', 'thames river cruise',
    ]),
    MetroZone(type: DayPackType.marketDay, patterns: [
      'camden market', 'borough market', 'portobello road',
      'spitalfields', 'old spitalfields', 'broadway market',
      'leadenhall market', 'columbia road flower market',
    ]),
    MetroZone(type: DayPackType.modernDay, patterns: [
      'british museum', 'national gallery', 'tate modern',
      'tate britain', 'natural history museum', 'science museum',
      'victoria and albert', 'v&a museum',
      'covent garden', 'soho', 'shoreditch', 'notting hill',
      'hyde park', 'regents park', 'st james\'s park',
      'the shard', 'sky garden',
    ]),
  ],
);

const _romeMetro = MetroProfile(
  cityKey: 'rome',
  lat: 41.9028,
  lng: 12.4964,
  clusterRadiusKm: 30.0,
  disableMarketTypeFallback: false,
  isMegaCity: true,
  touristAnchors: [
    TouristAnchor(label: 'Colosseo / Foro Romano',
        lat: 41.8902, lng: 12.4922),
    TouristAnchor(label: 'Pantheon', lat: 41.8986, lng: 12.4769),
    TouristAnchor(label: 'Vatican / St Peter',
        lat: 41.9022, lng: 12.4534),
    TouristAnchor(label: 'Trevi / Piazza di Spagna',
        lat: 41.9009, lng: 12.4833),
    TouristAnchor(label: 'Piazza Navona', lat: 41.8992, lng: 12.4731),
    TouristAnchor(label: 'Trastevere', lat: 41.8896, lng: 12.4683),
    TouristAnchor(label: 'Villa Borghese',
        lat: 41.9134, lng: 12.4861, radiusMeters: 2500),
    TouristAnchor(label: 'Castel Sant\'Angelo',
        lat: 41.9031, lng: 12.4663),
  ],
  zones: [
    MetroZone(type: DayPackType.oldCityDay, patterns: [
      'colosseum', 'colosseo', 'roman forum', 'foro romano',
      'pantheon', 'trevi fountain', 'fontana di trevi',
      'piazza navona', 'piazza di spagna', 'spanish steps',
      'castel sant\'angelo', 'castel sant angelo',
      'palatine hill', 'capitoline', 'campidoglio',
      'circo massimo', 'baths of caracalla',
    ]),
    MetroZone(type: DayPackType.riversideDay, patterns: [
      'tiber', 'tevere', 'ponte sant\'angelo', 'isola tiberina',
      'lungotevere', 'trastevere',
    ]),
    MetroZone(type: DayPackType.marketDay, patterns: [
      'campo de\' fiori', 'campo dei fiori', 'mercato trionfale',
      'mercato testaccio', 'mercato di san cosimato',
      'nuovo mercato esquilino',
    ]),
    MetroZone(type: DayPackType.modernDay, patterns: [
      'vatican museums', 'st peter\'s basilica', 'st peters basilica',
      'basilica di san pietro', 'sistine chapel', 'cappella sistina',
      'villa borghese', 'galleria borghese', 'galleria nazionale',
      'maxxi', 'macro',
    ]),
  ],
);

const _istanbulMetro = MetroProfile(
  cityKey: 'istanbul',
  lat: 41.0082,
  lng: 28.9784,
  clusterRadiusKm: 35.0,
  disableMarketTypeFallback: false,
  isMegaCity: true,
  touristAnchors: [
    TouristAnchor(label: 'Sultanahmet / Hagia Sophia',
        lat: 41.0086, lng: 28.9802),
    TouristAnchor(label: 'Eminönü / Spice Bazaar',
        lat: 41.0163, lng: 28.9700),
    TouristAnchor(label: 'Galata Tower',
        lat: 41.0257, lng: 28.9740),
    TouristAnchor(label: 'Beyoğlu / Istiklal',
        lat: 41.0319, lng: 28.9778),
    TouristAnchor(label: 'Taksim Square',
        lat: 41.0367, lng: 28.9851),
    TouristAnchor(label: 'Ortaköy / Bosphorus',
        lat: 41.0476, lng: 29.0269),
    TouristAnchor(label: 'Karaköy', lat: 41.0245, lng: 28.9794),
    TouristAnchor(label: 'Kadıköy', lat: 40.9909, lng: 29.0260),
  ],
  zones: [
    MetroZone(type: DayPackType.oldCityDay, patterns: [
      'hagia sophia', 'ayasofya', 'blue mosque', 'sultan ahmed mosque',
      'sultanahmet', 'topkapı palace', 'topkapi palace',
      'basilica cistern', 'yerebatan', 'süleymaniye mosque',
      'suleymaniye mosque', 'chora church', 'kariye',
      'hippodrome', 'sultanahmet square',
    ]),
    MetroZone(type: DayPackType.riversideDay, patterns: [
      'bosphorus', 'boğaz', 'golden horn', 'haliç', 'halic',
      'galata bridge', 'ortaköy', 'ortakoy', 'bebek',
      'beşiktaş', 'besiktas', 'eminönü', 'eminonu',
    ]),
    MetroZone(type: DayPackType.marketDay, patterns: [
      'grand bazaar', 'kapalı çarşı', 'kapali carsi',
      'spice bazaar', 'egyptian bazaar', 'mısır çarşısı',
      'misir carsisi', 'arasta bazaar',
    ]),
    MetroZone(type: DayPackType.modernDay, patterns: [
      'galata tower', 'galata kulesi', 'istiklal avenue',
      'istiklal caddesi', 'taksim square', 'taksim',
      'beyoğlu', 'beyoglu', 'dolmabahçe palace', 'dolmabahce palace',
      'çamlıca hill', 'camlica hill', 'pierre loti hill',
      'karaköy', 'karakoy', 'kadıköy', 'kadikoy',
    ]),
  ],
);

/// V8.28b (Lalith 2026-05-11) — +5 MetroProfiles : Séoul, Barcelone,
/// Lisbonne, Ho Chi Minh City, Singapour. Zones génériques
/// (oldCity/riverside/market/modern). Split géo intra-ville à
/// envisager plus tard si simu révèle des zigzags (cas Bangkok V8.24
/// ou Tokyo V8.28d2/d3).

const _seoulMetro = MetroProfile(
  cityKey: 'seoul',
  lat: 37.5665,
  lng: 126.9780,
  clusterRadiusKm: 35.0,
  disableMarketTypeFallback: false,
  isMegaCity: true,
  touristAnchors: [
    TouristAnchor(label: 'Gyeongbokgung / Bukchon',
        lat: 37.5796, lng: 126.9770),
    TouristAnchor(label: 'Myeongdong', lat: 37.5636, lng: 126.9869),
    TouristAnchor(label: 'Insadong', lat: 37.5747, lng: 126.9853),
    TouristAnchor(label: 'Hongdae', lat: 37.5563, lng: 126.9236),
    TouristAnchor(label: 'Gangnam', lat: 37.4979, lng: 127.0276),
    TouristAnchor(label: 'N Seoul Tower / Namsan',
        lat: 37.5512, lng: 126.9882),
    TouristAnchor(label: 'Itaewon', lat: 37.5345, lng: 126.9947),
    TouristAnchor(label: 'Dongdaemun', lat: 37.5664, lng: 127.0091),
    TouristAnchor(label: 'Yeouido / Han River',
        lat: 37.5285, lng: 126.9326, radiusMeters: 2500),
  ],
  zones: [
    MetroZone(type: DayPackType.oldCityDay, patterns: [
      'gyeongbokgung', 'changdeokgung', 'changgyeonggung',
      'deoksugung', 'bukchon hanok', 'bukchon', 'insadong',
      'jongmyo', 'jogyesa', 'seonjeongneung', 'unhyeongung',
      'gwanghwamun',
    ]),
    MetroZone(type: DayPackType.riversideDay, patterns: [
      'han river', 'hangang', 'yeouido', 'banpo bridge',
      'banpo rainbow', 'seoul forest',
    ]),
    MetroZone(type: DayPackType.marketDay, patterns: [
      'gwangjang market', 'namdaemun market', 'tongin market',
      'mangwon market', 'gyeongdong market', 'noryangjin',
      'dongdaemun market',
    ]),
    MetroZone(type: DayPackType.modernDay, patterns: [
      'myeongdong', 'hongdae', 'hongik', 'gangnam', 'apgujeong',
      'sinsa-dong', 'sinsadong', 'garosu-gil', 'garosugil',
      'itaewon', 'coex', 'lotte world tower', 'lotte world',
      'n seoul tower', 'namsan', 'dongdaemun design plaza',
      'ddp', 'cheonggyecheon', 'seoul plaza',
    ]),
  ],
);

const _barcelonaMetro = MetroProfile(
  cityKey: 'barcelona',
  lat: 41.3851,
  lng: 2.1734,
  clusterRadiusKm: 30.0,
  disableMarketTypeFallback: false,
  isMegaCity: true,
  touristAnchors: [
    TouristAnchor(label: 'Sagrada Família',
        lat: 41.4036, lng: 2.1744),
    TouristAnchor(label: 'Park Güell',
        lat: 41.4145, lng: 2.1527, radiusMeters: 2000),
    TouristAnchor(label: 'Gothic Quarter / Las Ramblas',
        lat: 41.3818, lng: 2.1731),
    TouristAnchor(label: 'Passeig de Gràcia / Casa Batlló',
        lat: 41.3919, lng: 2.1649),
    TouristAnchor(label: 'Barceloneta', lat: 41.3789, lng: 2.1925),
    TouristAnchor(label: 'Montjuïc',
        lat: 41.3636, lng: 2.1655, radiusMeters: 2500),
    TouristAnchor(label: 'El Born', lat: 41.3838, lng: 2.1809),
    TouristAnchor(label: 'Camp Nou', lat: 41.3809, lng: 2.1228),
  ],
  zones: [
    MetroZone(type: DayPackType.oldCityDay, patterns: [
      'gothic quarter', 'barri gòtic', 'barri gotic',
      'las ramblas', 'la rambla',
      'barcelona cathedral', 'catedral de barcelona',
      'plaça reial', 'placa reial',
      'el born', 'born', 'palau de la música',
      'palau de la musica', 'santa maria del mar',
      'picasso museum', 'museu picasso',
    ]),
    MetroZone(type: DayPackType.riversideDay, patterns: [
      'barceloneta', 'port vell', 'maremagnum',
      'platja de la barceloneta', 'port olímpic', 'port olimpic',
      'platja del bogatell',
    ]),
    MetroZone(type: DayPackType.marketDay, patterns: [
      'la boqueria', 'mercat de la boqueria',
      'mercat de sant antoni', 'mercat de la concepció',
      'mercat de la concepcio', 'mercat de santa caterina',
      'mercat dels encants',
    ]),
    MetroZone(type: DayPackType.modernDay, patterns: [
      'sagrada familia', 'sagrada família',
      'park güell', 'park guell',
      'casa batlló', 'casa batllo',
      'casa milà', 'casa mila', 'la pedrera',
      'passeig de gràcia', 'passeig de gracia',
      'plaça catalunya', 'placa catalunya',
      'montjuïc', 'montjuic', 'magic fountain',
      'camp nou', 'tibidabo', 'bunkers del carmel',
      'park de la ciutadella', 'arc de triomf',
    ]),
  ],
);

const _lisbonMetro = MetroProfile(
  cityKey: 'lisbon',
  lat: 38.7223,
  lng: -9.1393,
  clusterRadiusKm: 30.0,
  disableMarketTypeFallback: false,
  isMegaCity: true,
  touristAnchors: [
    TouristAnchor(label: 'Belém / Torre de Belém',
        lat: 38.6916, lng: -9.2160),
    TouristAnchor(label: 'Alfama / Castelo',
        lat: 38.7115, lng: -9.1300),
    TouristAnchor(label: 'Bairro Alto / Chiado',
        lat: 38.7110, lng: -9.1430),
    TouristAnchor(label: 'Baixa / Praça do Comércio',
        lat: 38.7077, lng: -9.1366),
    TouristAnchor(label: 'Sé / Cathedral',
        lat: 38.7098, lng: -9.1329),
    TouristAnchor(label: 'LX Factory', lat: 38.7036, lng: -9.1799),
    TouristAnchor(label: 'Parque das Nações',
        lat: 38.7681, lng: -9.0942),
    TouristAnchor(label: 'Gulbenkian / Eduardo VII',
        lat: 38.7367, lng: -9.1538),
  ],
  zones: [
    MetroZone(type: DayPackType.oldCityDay, patterns: [
      'alfama', 'castelo de são jorge', 'castelo de sao jorge',
      'são jorge castle', 'sao jorge castle',
      'sé de lisboa', 'se de lisboa', 'sé cathedral', 'se cathedral',
      'baixa', 'praça do comércio', 'praca do comercio',
      'chiado', 'rossio', 'praça do rossio', 'praca do rossio',
      'mouraria', 'graça', 'graca',
      'miradouro santa luzia', 'miradouro das portas do sol',
    ]),
    MetroZone(type: DayPackType.riversideDay, patterns: [
      'tagus', 'tejo', 'torre de belém', 'torre de belem',
      'belém tower', 'belem tower',
      'padrão dos descobrimentos', 'padrao dos descobrimentos',
      'monument of the discoveries',
      'cais do sodré', 'cais do sodre',
      'doca de santo amaro', 'ponte 25 de abril',
    ]),
    MetroZone(type: DayPackType.marketDay, patterns: [
      'time out market lisboa', 'time out market',
      'mercado da ribeira',
      'mercado de campo de ourique',
      'feira da ladra',
    ]),
    MetroZone(type: DayPackType.modernDay, patterns: [
      'mosteiro dos jerónimos', 'mosteiro dos jeronimos',
      'jerónimos monastery', 'jeronimos monastery',
      'maat', 'museu coleção berardo', 'berardo museum',
      'bairro alto', 'príncipe real', 'principe real',
      'lx factory', 'parque das nações', 'parque das nacoes',
      'oceanário', 'oceanario', 'gulbenkian',
      'eduardo vii', 'avenida da liberdade',
      'miradouro santa catarina', 'miradouro de são pedro',
      'miradouro de sao pedro',
      'tram 28', 'elétrico 28', 'electrico 28',
    ]),
  ],
);

const _hoChiMinhMetro = MetroProfile(
  cityKey: 'ho chi minh',
  lat: 10.7769,
  lng: 106.7009,
  clusterRadiusKm: 30.0,
  disableMarketTypeFallback: false,
  isMegaCity: true,
  touristAnchors: [
    TouristAnchor(label: 'Notre-Dame Cathedral / Post Office',
        lat: 10.7798, lng: 106.6989),
    TouristAnchor(label: 'Ben Thanh Market',
        lat: 10.7724, lng: 106.6981),
    TouristAnchor(label: 'Reunification Palace',
        lat: 10.7770, lng: 106.6953),
    TouristAnchor(label: 'War Remnants Museum',
        lat: 10.7794, lng: 106.6920),
    TouristAnchor(label: 'Bitexco Financial Tower',
        lat: 10.7716, lng: 106.7045),
    TouristAnchor(label: 'Bui Vien / Pham Ngu Lao',
        lat: 10.7666, lng: 106.6929),
    TouristAnchor(label: 'Dong Khoi / Opera House',
        lat: 10.7770, lng: 106.7037),
    TouristAnchor(label: 'Cho Lon / Chinatown',
        lat: 10.7541, lng: 106.6589),
  ],
  zones: [
    MetroZone(type: DayPackType.oldCityDay, patterns: [
      'notre-dame cathedral', 'notre dame cathedral basilica',
      'saigon central post office', 'saigon post office',
      'reunification palace', 'independence palace',
      'saigon opera house', 'municipal theatre',
      'people\'s committee', 'city hall ho chi minh',
      'jade emperor pagoda', 'phuoc hai tu',
      'mariamman temple', 'thien hau temple',
      'cha tam church',
    ]),
    MetroZone(type: DayPackType.riversideDay, patterns: [
      'saigon river', 'song sai gon', 'bach dang wharf',
      'bach dang park', 'thu thiem', 'phu my bridge',
      'nha rong wharf',
    ]),
    MetroZone(type: DayPackType.marketDay, patterns: [
      'ben thanh market', 'cho ben thanh',
      'binh tay market', 'cho binh tay',
      'an dong market', 'cho an dong',
      'tan dinh market', 'cho lon',
    ]),
    MetroZone(type: DayPackType.modernDay, patterns: [
      'bitexco financial tower', 'saigon skydeck',
      'landmark 81', 'landmark81',
      'bui vien', 'pham ngu lao',
      'dong khoi', 'nguyen hue walking street',
      'war remnants museum', 'fine arts museum ho chi minh',
      'tao dan park', 'september 23 park',
      'vincom center', 'diamond plaza',
    ]),
  ],
);

// V8.28b1 (Lalith 2026-05-11) — restructure Singapour. Simu post
// V8.28b a montré :
//   1. Cluster centré ~(1.43,103.78) avec rayon ~20 km tirait
//      KSL City Mall / KOMTAR JBCC / Johor Zoo / Bazar JB depuis
//      Johor Bahru, Malaysia → blocage via blockedAddressPatterns.
//   2. Packs fourre-tout (Jardin botanique → Orchard → ArtScience
//      Museum → Buddha Tooth Relic Temple) → 5 zones géo
//      Singapore-specific qui remplacent les 4 zones génériques.
//   3. Lau Pa Sat / Maxwell Food Centre picked comme visite
//      classique → visitBlockedNamePatterns rejette des visit-slots
//      (restent disponibles pour insertion repas).
//
// Zones legacy désactivées via `disabledArchetypes` pour éviter que
// les fallbacks `park`/`art_gallery`/`market` ré-injectent des
// candidats hors zone.
const _singaporeMetro = MetroProfile(
  cityKey: 'singapore',
  lat: 1.3521,
  lng: 103.8198,
  clusterRadiusKm: 35.0,
  disableMarketTypeFallback: false,
  isMegaCity: true,
  disabledArchetypes: {
    DayPackType.oldCityDay,
    DayPackType.riversideDay,
    DayPackType.marketDay,
    DayPackType.modernDay,
  },
  blockedAddressPatterns: [
    // V8.28b1 — frontière Malaysia (Johor Bahru limitrophe à Woodlands).
    'malaysia',
    'johor',
    'johor bahru',
    'johor darul ta\'zim',
    'jbcc',
    'ksl city',
    'komtar',
    // V8.28b1.2 (Lalith 2026-05-11) — frontière Indonésie. Sous-cluster
    // observé centré (1.14, 104.43) ≈ Bintan/Lagoi (~75 km SE de
    // Singapour). Sans Singapore MetroProfile match côté cluster, le
    // filter retombait sur empty list → candidats Indonésie leakaient.
    // Le fallback `tripDestinationMetro` V8.28b1.2 applique ces
    // patterns aux sous-clusters drift. Patterns : pays + îles +
    // province + capitale Riau Islands.
    'indonesia',
    'bintan',
    'batam',
    'lagoi',
    'tanjung pinang',
    'kepulauan riau',
    'riau islands',
    'kepri',
  ],
  visitBlockedNamePatterns: [
    'lau pa sat',
    'maxwell food centre',
    'hong lim market',
    'food centre',
  ],
  touristAnchors: [
    TouristAnchor(label: 'Marina Bay Sands',
        lat: 1.2834, lng: 103.8607),
    TouristAnchor(label: 'Gardens by the Bay',
        lat: 1.2816, lng: 103.8636, radiusMeters: 2500),
    TouristAnchor(label: 'Sentosa',
        lat: 1.2494, lng: 103.8303, radiusMeters: 3000),
    TouristAnchor(label: 'Chinatown', lat: 1.2842, lng: 103.8439),
    TouristAnchor(label: 'Little India', lat: 1.3066, lng: 103.8520),
    TouristAnchor(label: 'Kampong Glam / Arab Street',
        lat: 1.3019, lng: 103.8590),
    TouristAnchor(label: 'Orchard Road', lat: 1.3050, lng: 103.8327),
    TouristAnchor(label: 'Clarke Quay / Boat Quay',
        lat: 1.2904, lng: 103.8467),
    TouristAnchor(label: 'Singapore Botanic Gardens',
        lat: 1.3138, lng: 103.8159, radiusMeters: 2500),
  ],
  zones: [
    // Marina Bay / civic waterfront (~1.28/103.86).
    MetroZone(type: DayPackType.singaporeMarinaBayDay, patterns: [
      'marina bay sands', 'gardens by the bay', 'supertree grove',
      'cloud forest', 'flower dome', 'marina barrage',
      'merlion park', 'merlion',
      'artscience museum', 'art science museum',
      'singapore flyer', 'helix bridge', 'jubilee bridge',
      'spectra', 'esplanade theatres', 'esplanade',
      'sands skypark',
    ]),
    // Sentosa + Mount Faber (~1.25/103.83).
    MetroZone(type: DayPackType.singaporeSentosaDay, patterns: [
      'sentosa', 'universal studios singapore', 'usss',
      'singapore oceanarium', 's.e.a. aquarium',
      'skyline luge', 'madame tussauds singapore',
      'adventure cove', 'wings of time',
      'siloso beach', 'palawan beach', 'tanjong beach',
      'singapore cable car', 'mount faber',
    ]),
    // Chinatown + Civic District (~1.28-1.29/103.85).
    MetroZone(type: DayPackType.singaporeChinatownCivicDay, patterns: [
      'buddha tooth relic temple', 'chinatown singapore',
      'chinatown heritage centre',
      'sri mariamman temple', 'thian hock keng',
      'asian civilisations museum',
      'national gallery singapore', 'national gallery',
      'national museum of singapore', 'national museum singapore',
      'peranakan museum',
      'fort canning park', 'fort canning tree tunnel', 'fort canning',
      'old hill street police station',
      'boat quay', 'clarke quay', 'robertson quay',
      'pinnacle@duxton', 'pinnacle duxton',
    ]),
    // Orchard / Botanic Gardens (~1.30-1.31/103.81-103.83).
    MetroZone(type: DayPackType.singaporeOrchardBotanicDay, patterns: [
      'singapore botanic gardens', 'botanic gardens singapore',
      'jardin botanique de singapour', 'national orchid garden',
      'gallop extension', 'ginger garden', 'swan lake',
      'rainforest trail',
      'orchard road', 'ion sky', 'ion orchard', 'ion art gallery',
      'museum of ice cream singapore',
      'dempsey hill',
    ]),
    // Kampong Glam + Little India (~1.30-1.31/103.85).
    MetroZone(type: DayPackType.singaporeKampongGlamLittleIndiaDay,
        patterns: [
      'sultan mosque', 'masjid sultan',
      'arab street', 'haji lane', 'kampong glam',
      'little india singapore', 'little india',
      'sri veeramakaliamman', 'sri srinivasa perumal',
      'indian heritage centre',
      'former house of tan teng niah', 'tan teng niah',
      'church of our lady of lourdes',
      'angullia mosque',
    ]),
  ],
);

/// Registre des MetroProfile actifs. V8.27 = 2 villes (Bangkok,
/// Paris). V8.28a = +5 (Tokyo, New York, London, Rome, Istanbul).
/// V8.28b = +5 (Séoul, Barcelone, Lisbonne, HCM, Singapour).
/// Ajouter ici pour activer Day Builder sur de nouvelles
/// métropoles. L'ordre n'a pas d'importance (lookup par haversine).
const metroProfiles = <MetroProfile>[
  _bangkokMetro,
  _parisMetro,
  _tokyoMetro,
  _nycMetro,
  _londonMetro,
  _romeMetro,
  _istanbulMetro,
  _seoulMetro,
  _barcelonaMetro,
  _lisbonMetro,
  _hoChiMinhMetro,
  _singaporeMetro,
];

/// Lookup MetroProfile pour un cluster donné. Retourne le 1er profile
/// dont le centre est à ≤ `clusterRadiusKm` du `(centerLat, centerLng)`,
/// ou null si aucun profile ne couvre.
MetroProfile? getMetroProfileForCluster(double centerLat, double centerLng) {
  for (final p in metroProfiles) {
    final d = _haversineKm(centerLat, centerLng, p.lat, p.lng);
    if (d <= p.clusterRadiusKm) return p;
  }
  return null;
}

double _haversineKm(double lat1, double lng1, double lat2, double lng2) {
  const earthKm = 6371.0;
  final dLat = (lat2 - lat1) * math.pi / 180.0;
  final dLng = (lng2 - lng1) * math.pi / 180.0;
  final a = math.sin(dLat / 2) * math.sin(dLat / 2) +
      math.cos(lat1 * math.pi / 180.0) *
          math.cos(lat2 * math.pi / 180.0) *
          math.sin(dLng / 2) *
          math.sin(dLng / 2);
  return earthKm * 2 * math.atan2(math.sqrt(a), math.sqrt(1 - a));
}
