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

  const MetroProfile({
    required this.cityKey,
    required this.lat,
    required this.lng,
    this.clusterRadiusKm = 35.0,
    this.disableMarketTypeFallback = false,
    this.isMegaCity = false,
    required this.zones,
  });
}

const _bangkokMetro = MetroProfile(
  cityKey: 'bangkok',
  lat: 13.7563,
  lng: 100.5018,
  clusterRadiusKm: 35.0,
  disableMarketTypeFallback: true,
  isMegaCity: true,
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
    MetroZone(type: DayPackType.modernDay, patterns: [
      'jim thompson', 'mahanakhon', 'lumpini', 'lumphini',
      'siam paragon', 'siam center', 'siam discovery', 'centralworld',
      'central world', 'terminal 21', 'mbk', 'emquartier',
      'em district', 'emporium', 'sky walk', 'skywalk',
      'benjasiri', 'benjakitti', 'kingpower', 'king power',
      'samyan mitrtown',
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
  lat: 35.6762,
  lng: 139.6503,
  clusterRadiusKm: 40.0,
  disableMarketTypeFallback: false,
  isMegaCity: true,
  zones: [
    MetroZone(type: DayPackType.oldCityDay, patterns: [
      'senso-ji', 'sensoji', 'asakusa', 'meiji shrine', 'meiji jingu',
      'imperial palace', 'yasukuni', 'kanda', 'nezu shrine',
      'zojoji', 'gokokuji', 'kappabashi',
    ]),
    MetroZone(type: DayPackType.riversideDay, patterns: [
      'sumida river', 'odaiba', 'rainbow bridge', 'kachidoki',
      'asakusa pier', 'sumida park',
    ]),
    MetroZone(type: DayPackType.marketDay, patterns: [
      'tsukiji outer market', 'tsukiji', 'ameya-yokocho',
      'ameyoko', 'toyosu market', 'nakamise',
    ]),
    MetroZone(type: DayPackType.modernDay, patterns: [
      'tokyo tower', 'tokyo skytree', 'skytree',
      'shibuya crossing', 'shibuya', 'shinjuku gyoen', 'shinjuku',
      'akihabara', 'roppongi', 'ginza', 'omotesando',
      'harajuku', 'takeshita', 'teamlab',
      'ueno park', 'yoyogi park',
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

/// Registre des MetroProfile actifs. V8.27 = 2 villes (Bangkok,
/// Paris). V8.28a = +5 (Tokyo, New York, London, Rome, Istanbul).
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
