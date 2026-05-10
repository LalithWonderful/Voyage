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
  }
  return null;
}

/// Synthetic interest markers stockés dans `matchedInterests` des
/// candidates blueprint. Le selector détecte ces markers pour
/// appliquer le score boost. Préfixe `_` pour ne pas matcher
/// `tripInterests` (qui contient des noms d'intérêts user-facing).
const String blueprintMustSeeMarker = '_BlueprintMustSee';
const String blueprintExperienceMarker = '_BlueprintExperience';
