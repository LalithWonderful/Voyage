/// V8.13 (Lalith 2026-05-10 — Quality-1D destination blueprints) —
/// Curated lists of must-sees / experiences per destination, used to
/// seed the candidate pool with destination-relevant places BEFORE
/// the per-day center-based gather. Solves the « Bangkok pool full
/// of Bang Na malls instead of Grand Palace/Wat Pho » problem.
///
/// Architecture :
/// 1. `DestinationBlueprint` = manual data structure with
///    `mustSeeQueries` + `experienceQueries`.
/// 2. `getBlueprintForDestination(name)` normalizes/matches by city
///    name. Returns null for unknown destinations.
/// 3. `places_first_pipeline.gatherCandidatesForTrip` resolves
///    blueprint queries via `searchText` (cached via `gemini_cache`,
///    cost-aware), tags candidates with `_BlueprintMustSee` /
///    `_BlueprintExperience` synthetic markers in `matchedInterests`.
/// 4. `selectVisitsDeterministic` detects markers and applies
///    +100 / +70 score boost.
///
/// V1 scope = 3 destinations seedées (Bangkok, Koh Samet, Paris).
/// Extension future : ajouter blueprints au fil des trips testés
/// (Tokyo, NYC, Rome, Lisbon, Marrakech...).
library;

enum DestinationKind {
  majorCity,
  islandBeach,
  secondaryCity,
  broadRegion,
  unknown,
}

class DestinationBlueprint {
  /// Clé canonique (lowercase, sans accents) — match contre la
  /// destination normalisée du trip.
  final String destinationKey;

  /// Type de destination — drives default selector heuristics
  /// (e.g. islandBeach OK 2-3 activities/day, majorCity 4 default).
  final DestinationKind kind;

  /// Queries text-search à lancer pour seed les must-sees. Format
  /// "Place name City" (Place + city anchor pour bias géographique).
  final List<String> mustSeeQueries;

  /// Queries text-search pour les expériences fortes (souvent moins
  /// iconiques mais culturellement définissantes).
  final List<String> experienceQueries;

  /// Day-trip candidates — destinations excursion d'une journée.
  /// Out of V1 scope (réservé pour mode multi-day excursion future).
  final List<String> optionalDayTrips;

  const DestinationBlueprint({
    required this.destinationKey,
    required this.kind,
    this.mustSeeQueries = const [],
    this.experienceQueries = const [],
    this.optionalDayTrips = const [],
  });
}

/// V1 blueprints. Manual curation par Lalith 2026-05-10.

/// V8.25 (Lalith 2026-05-10) — extension blueprint Bangkok pour les
/// long-stays (6+ jours). Passe de 10+7=17 entrées à 18+10=28. Ajoute
/// les iconiques manquants signalés en simu (Erawan Shrine, Wat Saket
/// /Golden Mount, Wat Traimit/Golden Buddha, Wat Benchamabophit
/// /Marble Temple, MBK Center, Terminal 21, Bang Krachao green lung,
/// Ratchada Rot Fai night market, Vimanmek Mansion). Cost-1 reste
/// dans le budget (~28 calls cold, < cap 80).
const _bangkokBlueprint = DestinationBlueprint(
  destinationKey: 'bangkok',
  kind: DestinationKind.majorCity,
  mustSeeQueries: [
    // Old City iconic
    'Grand Palace Bangkok',
    'Wat Pho Bangkok',
    'Wat Arun Bangkok',
    'Wat Saket Golden Mount Bangkok',
    'Wat Traimit Golden Buddha Bangkok',
    'Wat Benchamabophit Marble Temple Bangkok',
    'Wat Suthat Bangkok',
    'National Museum Bangkok',
    // Riverside iconic
    'Chao Phraya River Bangkok',
    'IconSiam Bangkok',
    // Markets iconic
    'Chinatown Yaowarat Bangkok',
    'Chatuchak Weekend Market Bangkok',
    // Modern iconic
    'Jim Thompson House Bangkok',
    'Lumphini Park Bangkok',
    'Mahanakhon SkyWalk Bangkok',
    'Erawan Shrine Bangkok',
    'MBK Center Bangkok',
    'Terminal 21 Asok Bangkok',
  ],
  experienceQueries: [
    'Khao San Road Bangkok',
    'Asiatique The Riverfront Bangkok',
    'Chao Phraya river cruise',
    'Damnoen Saduak floating market',
    'Maeklong Railway Market',
    'Train Night Market Srinagarindra Bangkok',
    'Ratchada Rot Fai Market Bangkok',
    'Bang Krachao green lung Bangkok',
    'Vimanmek Mansion Bangkok',
    'rooftop bar Bangkok',
  ],
  optionalDayTrips: [
    'Ayutthaya historical park',
  ],
);

const _kohSametBlueprint = DestinationBlueprint(
  destinationKey: 'koh samet',
  kind: DestinationKind.islandBeach,
  mustSeeQueries: [
    'Sai Kaew Beach Koh Samet',
    'Ao Phrao Koh Samet',
    'Ao Wai Koh Samet',
    'Ao Nuan Koh Samet',
    'Sunset viewpoint Koh Samet',
    'Khao Laem Ya National Park',
  ],
  experienceQueries: [
    'snorkeling Koh Samet',
    'boat trip Koh Samet',
    'beach bar sunset Koh Samet',
  ],
);

const _parisBlueprint = DestinationBlueprint(
  destinationKey: 'paris',
  kind: DestinationKind.majorCity,
  mustSeeQueries: [
    'Louvre Museum Paris',
    'Notre-Dame Cathedral Paris',
    'Sainte-Chapelle Paris',
    'Musée d\'Orsay Paris',
    'Eiffel Tower Paris',
    'Trocadéro Paris',
    'Sacré-Cœur Montmartre Paris',
    'Luxembourg Garden Paris',
    'Le Marais Paris',
    'Galeries Lafayette rooftop Paris',
  ],
  experienceQueries: [
    'Seine river cruise Paris',
    'Pont Alexandre III Paris',
    'Pont des Arts Paris',
    'Champs-Élysées Paris',
    'Arc de Triomphe Paris',
  ],
);

/// V8.28a (Lalith 2026-05-10) — 5 blueprints additionnels pour les
/// métropoles prioritaires. Chacun = ~10 must-see + ~5 experience.
/// Suffisant pour seed le pool Day Builder ; extensions futures si
/// long-stay révèle des manques (cf. V8.25 Bangkok 17→28).

const _tokyoBlueprint = DestinationBlueprint(
  destinationKey: 'tokyo',
  kind: DestinationKind.majorCity,
  mustSeeQueries: [
    'Senso-ji Temple Tokyo',
    'Meiji Shrine Tokyo',
    'Tokyo Tower',
    'Tokyo Skytree',
    'Imperial Palace Tokyo',
    'Shibuya Crossing Tokyo',
    'Shinjuku Gyoen Tokyo',
    'Akihabara Tokyo',
    'teamLab Planets Tokyo',
    'Tsukiji Outer Market Tokyo',
  ],
  experienceQueries: [
    'Ginza Tokyo',
    'Harajuku Takeshita Street',
    'Ueno Park Tokyo',
    'Odaiba Tokyo',
    'Roppongi Hills Tokyo',
  ],
);

const _nycBlueprint = DestinationBlueprint(
  destinationKey: 'new york',
  kind: DestinationKind.majorCity,
  mustSeeQueries: [
    'Statue of Liberty New York',
    'Empire State Building',
    'Central Park New York',
    'Times Square New York',
    'Brooklyn Bridge',
    '9/11 Memorial New York',
    'Top of the Rock',
    'Metropolitan Museum of Art',
    'MoMA New York',
    'Wall Street New York',
  ],
  experienceQueries: [
    'Chelsea Market New York',
    'High Line New York',
    'Rockefeller Center New York',
    'Bryant Park New York',
    'Greenwich Village New York',
  ],
);

const _londonBlueprint = DestinationBlueprint(
  destinationKey: 'london',
  kind: DestinationKind.majorCity,
  mustSeeQueries: [
    'Tower of London',
    'Westminster Abbey',
    'Buckingham Palace London',
    'British Museum London',
    'Big Ben London',
    'London Eye',
    'St Paul\'s Cathedral London',
    'Tower Bridge London',
    'Tate Modern London',
    'National Gallery London',
  ],
  experienceQueries: [
    'Camden Market London',
    'Borough Market London',
    'Covent Garden London',
    'Hyde Park London',
    'Greenwich London',
  ],
);

const _romeBlueprint = DestinationBlueprint(
  destinationKey: 'rome',
  kind: DestinationKind.majorCity,
  mustSeeQueries: [
    'Colosseum Rome',
    'Roman Forum Rome',
    'Pantheon Rome',
    'Trevi Fountain Rome',
    'Vatican Museums Rome',
    'St Peter\'s Basilica Rome',
    'Piazza Navona Rome',
    'Piazza di Spagna Rome',
    'Castel Sant\'Angelo Rome',
    'Villa Borghese Rome',
  ],
  experienceQueries: [
    'Trastevere Rome',
    'Campo de\' Fiori Rome',
    'Capitoline Museums Rome',
    'Aventine Hill Rome',
    'Borghese Gallery Rome',
  ],
);

const _istanbulBlueprint = DestinationBlueprint(
  destinationKey: 'istanbul',
  kind: DestinationKind.majorCity,
  mustSeeQueries: [
    'Hagia Sophia Istanbul',
    'Blue Mosque Istanbul',
    'Topkapı Palace Istanbul',
    'Grand Bazaar Istanbul',
    'Basilica Cistern Istanbul',
    'Galata Tower Istanbul',
    'Süleymaniye Mosque Istanbul',
    'Bosphorus Istanbul',
    'Spice Bazaar Istanbul',
    'Istiklal Avenue Istanbul',
  ],
  experienceQueries: [
    'Galata Bridge Istanbul',
    'Ortaköy Istanbul',
    'Dolmabahçe Palace Istanbul',
    'Karaköy Istanbul',
    'Kadıköy Istanbul',
  ],
);

/// V8.28b (Lalith 2026-05-11) — +5 villes mégalopoles : Séoul,
/// Barcelone, Lisbonne, Ho Chi Minh City, Singapour. Précédent V8.28a
/// = Tokyo/NYC/London/Rome/Istanbul. Chaque blueprint contient 10
/// must-see + 5 experience curés sur les iconiques touristiques.
/// MetroProfile correspondant ajouté dans `metro_profile.dart`
/// (zones + 8-9 tourist anchors par ville).

const _seoulBlueprint = DestinationBlueprint(
  destinationKey: 'seoul',
  kind: DestinationKind.majorCity,
  mustSeeQueries: [
    'Gyeongbokgung Palace Seoul',
    'N Seoul Tower Namsan',
    'Bukchon Hanok Village Seoul',
    'Changdeokgung Palace Seoul',
    'Myeongdong Seoul',
    'Insadong Seoul',
    'Gwangjang Market Seoul',
    'Dongdaemun Design Plaza Seoul',
    'Lotte World Tower Seoul',
    'Hongdae walking street Seoul',
  ],
  experienceQueries: [
    'Han River park Seoul',
    'Gangnam Seoul',
    'Cheonggyecheon stream Seoul',
    'Itaewon Seoul',
    'Namsan cable car Seoul',
  ],
);

const _barcelonaBlueprint = DestinationBlueprint(
  destinationKey: 'barcelona',
  kind: DestinationKind.majorCity,
  mustSeeQueries: [
    'Sagrada Familia Barcelona',
    'Park Güell Barcelona',
    'Casa Batlló Barcelona',
    'Casa Milà La Pedrera Barcelona',
    'Gothic Quarter Barcelona',
    'Las Ramblas Barcelona',
    'La Boqueria market Barcelona',
    'Picasso Museum Barcelona',
    'Montjuïc Castle Barcelona',
    'Barceloneta beach Barcelona',
  ],
  experienceQueries: [
    'Camp Nou Barcelona',
    'El Born Barcelona',
    'Tibidabo Barcelona',
    'Magic Fountain Montjuïc',
    'Bunkers del Carmel Barcelona',
  ],
);

const _lisbonBlueprint = DestinationBlueprint(
  destinationKey: 'lisbon',
  kind: DestinationKind.majorCity,
  mustSeeQueries: [
    'Torre de Belém Lisbon',
    'Mosteiro dos Jerónimos Lisbon',
    'Castelo de São Jorge Lisbon',
    'Alfama Lisbon',
    'Praça do Comércio Lisbon',
    'Padrão dos Descobrimentos Lisbon',
    'Tram 28 Lisbon',
    'Bairro Alto Lisbon',
    'Sé Cathedral Lisbon',
    'Praça do Rossio Lisbon',
  ],
  experienceQueries: [
    'Time Out Market Lisboa',
    'LX Factory Lisbon',
    'Pastéis de Belém Lisbon',
    'Fado Alfama Lisbon',
    'Miradouro de Santa Catarina Lisbon',
  ],
);

const _hoChiMinhBlueprint = DestinationBlueprint(
  destinationKey: 'ho chi minh',
  kind: DestinationKind.majorCity,
  mustSeeQueries: [
    'Notre-Dame Cathedral Saigon',
    'Saigon Central Post Office',
    'War Remnants Museum Ho Chi Minh',
    'Reunification Palace Ho Chi Minh',
    'Ben Thanh Market Ho Chi Minh',
    'Bitexco Financial Tower Saigon',
    'Saigon Opera House',
    'Jade Emperor Pagoda Ho Chi Minh',
    'Landmark 81 Vietnam',
    'Cho Lon Chinatown Saigon',
  ],
  experienceQueries: [
    'Bui Vien walking street Saigon',
    'Saigon River cruise',
    'Dong Khoi Street Saigon',
    'Cu Chi tunnels day trip',
    'banh mi street food Saigon',
  ],
);

const _singaporeBlueprint = DestinationBlueprint(
  destinationKey: 'singapore',
  kind: DestinationKind.majorCity,
  mustSeeQueries: [
    'Marina Bay Sands Singapore',
    'Gardens by the Bay Supertree',
    'Sentosa Island Singapore',
    'Chinatown Singapore',
    'Little India Singapore',
    'Singapore Botanic Gardens',
    'Merlion Park Singapore',
    'Orchard Road Singapore',
    'ArtScience Museum Singapore',
    'Buddha Tooth Relic Temple Singapore',
  ],
  experienceQueries: [
    'Clarke Quay Singapore night',
    'Lau Pa Sat hawker centre',
    'Maxwell Food Centre Singapore',
    'Singapore Flyer',
    'Kampong Glam Arab Street',
  ],
);

/// V8.28c (Lalith 2026-05-11) — +5 villes mégalopoles : Dubai,
/// Kuala Lumpur, Bali (île, traitée en majorCity avec isMegaCity=
/// false), Hanoi, Hong Kong. Précédent V8.28b = Séoul/Barcelone/
/// Lisbonne/HCM/Singapour. Chaque blueprint contient 10 must-see +
/// 5 experience. MetroProfile correspondant dans `metro_profile.dart`
/// (zones + anchors).

const _dubaiBlueprint = DestinationBlueprint(
  destinationKey: 'dubai',
  kind: DestinationKind.majorCity,
  mustSeeQueries: [
    'Burj Khalifa Dubai',
    'Dubai Mall',
    'Dubai Fountain',
    'Palm Jumeirah',
    'Dubai Marina',
    'Burj Al Arab',
    'Dubai Frame',
    'Jumeirah Mosque Dubai',
    'Al Fahidi Historical Neighbourhood',
    'Gold Souk Deira Dubai',
  ],
  experienceQueries: [
    'Atlantis Aquaventure Dubai',
    'desert safari Dubai',
    'Dubai Creek abra ride',
    'Madinat Jumeirah souk',
    'Global Village Dubai',
  ],
);

const _kualaLumpurBlueprint = DestinationBlueprint(
  destinationKey: 'kuala lumpur',
  kind: DestinationKind.majorCity,
  mustSeeQueries: [
    'Petronas Twin Towers',
    'KL Tower Menara Kuala Lumpur',
    'KLCC Park',
    'Batu Caves Selangor',
    'Sultan Abdul Samad Building',
    'Merdeka Square Kuala Lumpur',
    'Petaling Street Chinatown KL',
    'Central Market Kuala Lumpur',
    'Masjid Negara National Mosque',
    'Aquaria KLCC',
  ],
  experienceQueries: [
    'Bukit Bintang Kuala Lumpur',
    'Jalan Alor street food',
    'Royal Selangor Pewter Visitor Centre',
    'Heli Lounge Bar KL',
    'Thean Hou Temple Kuala Lumpur',
  ],
);

const _baliBlueprint = DestinationBlueprint(
  destinationKey: 'bali',
  kind: DestinationKind.majorCity,
  mustSeeQueries: [
    'Ubud Monkey Forest',
    'Tegallalang Rice Terraces',
    'Tanah Lot Temple',
    'Uluwatu Temple',
    'Tegenungan Waterfall',
    'Sacred Monkey Forest Sanctuary Ubud',
    'GWK Cultural Park Bali',
    'Besakih Mother Temple',
    'Goa Gajah Elephant Cave',
    'Bali Bird Park',
  ],
  experienceQueries: [
    'Seminyak Beach Bali',
    'Canggu Echo Beach',
    'Ubud Art Market',
    'Jimbaran Beach seafood',
    'Bali traditional dance Ubud',
  ],
);

const _hanoiBlueprint = DestinationBlueprint(
  destinationKey: 'hanoi',
  kind: DestinationKind.majorCity,
  mustSeeQueries: [
    'Hoan Kiem Lake Hanoi',
    'Old Quarter Hanoi',
    'Temple of Literature Hanoi',
    'Ho Chi Minh Mausoleum',
    'One Pillar Pagoda Hanoi',
    'Tran Quoc Pagoda',
    'West Lake Hanoi',
    'Hanoi Opera House',
    'Imperial Citadel of Thang Long',
    'St Joseph Cathedral Hanoi',
  ],
  experienceQueries: [
    'Train Street Hanoi',
    'Thang Long Water Puppet Theatre',
    'Dong Xuan Market Hanoi',
    'Bia Hoi Junction Hanoi',
    'Long Bien Bridge Hanoi',
  ],
);

const _hongKongBlueprint = DestinationBlueprint(
  destinationKey: 'hong kong',
  kind: DestinationKind.majorCity,
  mustSeeQueries: [
    'Victoria Peak Hong Kong',
    'Tsim Sha Tsui Promenade',
    'Star Ferry Hong Kong',
    'Tian Tan Big Buddha Lantau',
    'Po Lin Monastery',
    'Wong Tai Sin Temple',
    'Man Mo Temple Hong Kong',
    'Symphony of Lights Hong Kong',
    'Ngong Ping 360 cable car',
    'Hong Kong Disneyland',
  ],
  experienceQueries: [
    'Temple Street Night Market Hong Kong',
    'Ladies Market Mong Kok',
    'Stanley Market Hong Kong',
    'Lan Kwai Fong Central',
    'Tim Ho Wan dim sum',
  ],
);

/// Normalise une destination pour le lookup blueprint :
/// - prend le premier token avant la virgule
/// - lowercase
/// - strip accents
/// - normalise variants (Ko Samet / Koh Samet / Samet → koh samet)
String _normalizeBlueprintKey(String s) {
  var n = s.toLowerCase().trim();
  // Strip accents.
  // V8.28c — extension Vietnamese diacritics (ạ/ộ/ậ/etc.) pour
  // matcher "Hà Nội" → "ha noi" → alias "hanoi". Aligné sur
  // `segment_city_canonicals.dart::_normalizeCanonicalCityKey`.
  const replacements = <String, String>{
    'á': 'a', 'à': 'a', 'â': 'a', 'ä': 'a', 'ã': 'a', 'å': 'a',
    'ạ': 'a', 'ả': 'a', 'ầ': 'a', 'ấ': 'a', 'ậ': 'a', 'ằ': 'a',
    'é': 'e', 'è': 'e', 'ê': 'e', 'ë': 'e', 'ẽ': 'e', 'ẻ': 'e',
    'ệ': 'e', 'ề': 'e', 'ế': 'e',
    'í': 'i', 'ì': 'i', 'î': 'i', 'ï': 'i', 'ĩ': 'i', 'ị': 'i',
    'ó': 'o', 'ò': 'o', 'ô': 'o', 'ö': 'o', 'õ': 'o', 'ơ': 'o',
    'ọ': 'o', 'ộ': 'o', 'ố': 'o', 'ồ': 'o',
    'ú': 'u', 'ù': 'u', 'û': 'u', 'ü': 'u', 'ũ': 'u', 'ụ': 'u',
    'ư': 'u',
    'ý': 'y', 'ỳ': 'y',
    'ç': 'c', 'đ': 'd', 'ñ': 'n',
  };
  replacements.forEach((from, to) {
    n = n.replaceAll(from, to);
  });
  // Premier token avant virgule.
  n = n.split(',').first.trim();
  // Variants Koh Samet / Ko Samet / Samet.
  if (n == 'ko samet' || n == 'samet') return 'koh samet';
  // Bangkok variants.
  if (n == 'krung thep' || n == 'bkk') return 'bangkok';
  // V8.28a — aliases pour les nouvelles métropoles.
  if (n == 'nyc' || n == 'new york city' || n == 'manhattan' ||
      n == 'newyork') {
    return 'new york';
  }
  if (n == 'tokio' || n == '東京') return 'tokyo';
  if (n == 'londres' || n == 'london uk') return 'london';
  if (n == 'roma') return 'rome';
  if (n == 'constantinople' || n == 'istambul') return 'istanbul';
  // V8.28b — aliases pour les 5 nouvelles métropoles.
  if (n == 'seul' || n == 'soul' || n == 'sŏul') return 'seoul';
  if (n == 'barcelone' || n == 'barca' || n == 'barça' ||
      n == 'bcn') {
    return 'barcelona';
  }
  if (n == 'lisbonne' || n == 'lisboa' || n == 'lissabon') {
    return 'lisbon';
  }
  if (n == 'ho chi minh city' ||
      n == 'ho chi minh ville' ||
      n == 'hcm' ||
      n == 'hcmc' ||
      n == 'saigon' ||
      n == 'sai gon' ||
      n == 'thanh pho ho chi minh') {
    return 'ho chi minh';
  }
  if (n == 'singapour' || n == 'singapura' || n == 'sg') {
    return 'singapore';
  }
  // V8.28c — aliases pour les 5 nouvelles métropoles.
  if (n == 'dubaï' || n == 'dxb' || n == 'duby') return 'dubai';
  if (n == 'kl' || n == 'kuala-lumpur' || n == 'kuala lumpur city') {
    return 'kuala lumpur';
  }
  if (n == 'pulau bali' || n == 'denpasar' || n == 'bali island') {
    return 'bali';
  }
  if (n == 'hanoï' || n == 'hà nội' || n == 'ha noi') return 'hanoi';
  if (n == 'hongkong' || n == 'hong-kong' || n == 'hk' || n == 'hkg' ||
      n == 'hong kong sar') {
    return 'hong kong';
  }
  return n;
}

/// V1 lookup : retourne le blueprint correspondant à la destination
/// du trip, ou null si aucun blueprint ne match. Insensible casse +
/// accents, gère les variants courants.
DestinationBlueprint? getBlueprintForDestination(String? destination) {
  if (destination == null || destination.trim().isEmpty) return null;
  final key = _normalizeBlueprintKey(destination);
  switch (key) {
    case 'bangkok':
      return _bangkokBlueprint;
    case 'koh samet':
      return _kohSametBlueprint;
    case 'paris':
      return _parisBlueprint;
    case 'tokyo':
      return _tokyoBlueprint;
    case 'new york':
      return _nycBlueprint;
    case 'london':
      return _londonBlueprint;
    case 'rome':
      return _romeBlueprint;
    case 'istanbul':
      return _istanbulBlueprint;
    // V8.28b — +5 villes mégalopoles.
    case 'seoul':
      return _seoulBlueprint;
    case 'barcelona':
      return _barcelonaBlueprint;
    case 'lisbon':
      return _lisbonBlueprint;
    case 'ho chi minh':
      return _hoChiMinhBlueprint;
    case 'singapore':
      return _singaporeBlueprint;
    // V8.28c — +5 villes mégalopoles.
    case 'dubai':
      return _dubaiBlueprint;
    case 'kuala lumpur':
      return _kualaLumpurBlueprint;
    case 'bali':
      return _baliBlueprint;
    case 'hanoi':
      return _hanoiBlueprint;
    case 'hong kong':
      return _hongKongBlueprint;
  }
  return null;
}

/// Synthetic interest markers stockés dans `matchedInterests` des
/// candidates blueprint. Le selector détecte ces markers pour
/// appliquer le score boost. Préfixe `_` pour ne pas matcher
/// `tripInterests` (qui contient des noms d'intérêts user-facing).
const String blueprintMustSeeMarker = '_BlueprintMustSee';
const String blueprintExperienceMarker = '_BlueprintExperience';

/// V8.28d — marker injecté pour les candidats issus du fan-out
/// `TouristAnchor` autour des hotspots curated d'une mégalopole
/// MetroProfile. Pas de score boost (contrairement aux blueprint
/// markers) — sert juste à enrichir le pool avec des candidats
/// touristiques quand le geocoder de la destination tombe sur un
/// quartier résidentiel (cas Tokyo Setagaya 35.676/139.650).
/// Les patterns du MetroProfile font le tri archétype ensuite.
const String metroAnchorMarker = '_MetroAnchor';
