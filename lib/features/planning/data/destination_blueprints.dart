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

/// Normalise une destination pour le lookup blueprint :
/// - prend le premier token avant la virgule
/// - lowercase
/// - strip accents
/// - normalise variants (Ko Samet / Koh Samet / Samet → koh samet)
String _normalizeBlueprintKey(String s) {
  var n = s.toLowerCase().trim();
  // Strip accents.
  const replacements = <String, String>{
    'é': 'e', 'è': 'e', 'ê': 'e', 'ë': 'e',
    'à': 'a', 'â': 'a', 'ä': 'a',
    'î': 'i', 'ï': 'i',
    'ô': 'o', 'ö': 'o',
    'û': 'u', 'ü': 'u', 'ù': 'u',
    'ç': 'c',
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
