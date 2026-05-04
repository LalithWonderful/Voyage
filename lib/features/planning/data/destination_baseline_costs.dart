/// Estimations budgétaires statiques par destination, depuis l'aéroport
/// d'origine du voyageur. Lookup déterministe sans appel IA — cohérent avec
/// la philosophie `feedback_no_gemini_patchwork.md`.
///
/// V1 : ~25 destinations populaires FR, vol AR estimé depuis Paris (CDG).
/// Pour les autres aéroports d'origine, on applique un facteur multiplicatif
/// approximatif basé sur la distance/desserte (cf. `_originFactor`).
///
/// Méthode :
/// - `flightLowEur` / `flightAvgEur` : prix typiques vol AR éco depuis CDG
///   en hors haute saison. Sources : Skyscanner historiques + retours
///   utilisateurs. Ordres de grandeur (pas du temps réel).
/// - `dailyBudgetEur` : coût quotidien moyen par personne sur place, hors
///   vol. Hébergement standard (3*) + restos + activités modérées.
///
/// L'objectif n'est PAS d'être précis (impossible sans API live), mais de
/// répondre à la question : "Avec 600€, est-ce que je peux aller au
/// Brésil ?" → Non (vol seul ~700-900€) vs Maroc → Oui (vol 80-200€,
/// 50€/jour × 5 jours = 250€ + 80-200€ = 330-450€). C'est suffisant pour
/// un signal fiable.
///
/// Future V2 : intégration API Skyscanner/Kiwi pour les vols réels +
/// Booking aggregé pour l'hébergement.
library;

class DestinationBaselineCost {
  /// Étiquette affichée pour les alternatives ("Maroc", "Portugal").
  final String displayName;

  /// Mots-clés (case+accents-insensible) pour matcher dans le texte de
  /// destination. Mêmes règles que `destination_seasonality.dart`.
  final List<String> matchKeywords;

  /// Code pays ISO 2 — sert au regroupement par pays pour les alternatives.
  final String countryCode;

  /// Vol AR éco basse fourchette depuis CDG, en euros.
  final int flightLowEur;

  /// Vol AR éco fourchette moyenne depuis CDG, en euros.
  final int flightAvgEur;

  /// Coût quotidien moyen par personne sur place (hébergement 3* + restos
  /// + activités modérées), en euros.
  final int dailyBudgetEur;

  /// Note d'ambiance ("Maghreb proche", "Europe low-cost"). Sert à grouper
  /// les alternatives lisiblement.
  final String tier;

  const DestinationBaselineCost({
    required this.displayName,
    required this.matchKeywords,
    required this.countryCode,
    required this.flightLowEur,
    required this.flightAvgEur,
    required this.dailyBudgetEur,
    required this.tier,
  });

  /// Estime le budget total minimum pour ce voyage : vol low-cost + nuits
  /// au quotidien. Utilisé pour la faisabilité ("ton budget couvre/ne
  /// couvre pas").
  int estimateMinTotal({required int days}) {
    return flightLowEur + (dailyBudgetEur * days);
  }

  /// Estime un budget moyen réaliste : vol moyen + 1.2× le quotidien
  /// (extras, imprévus). Utilisé pour communiquer à l'user "Avec X€ tu
  /// peux espérer".
  int estimateAvgTotal({required int days}) {
    return flightAvgEur + ((dailyBudgetEur * days * 1.2).round());
  }
}

const List<DestinationBaselineCost> _data = [
  // === Tier 1 — Maghreb proche (très accessible budget) ===
  DestinationBaselineCost(
    displayName: 'Maroc',
    matchKeywords: ['maroc', 'morocco', 'marrakech', 'fes', 'casablanca', 'tanger', 'rabat', 'agadir'],
    countryCode: 'MA',
    flightLowEur: 80,
    flightAvgEur: 180,
    dailyBudgetEur: 50,
    tier: 'Maghreb proche',
  ),
  DestinationBaselineCost(
    displayName: 'Tunisie',
    matchKeywords: ['tunisie', 'tunisia', 'tunis', 'djerba', 'hammamet'],
    countryCode: 'TN',
    flightLowEur: 80,
    flightAvgEur: 180,
    dailyBudgetEur: 45,
    tier: 'Maghreb proche',
  ),

  // === Tier 2 — Europe low-cost ===
  DestinationBaselineCost(
    displayName: 'Portugal',
    matchKeywords: ['portugal', 'lisbonne', 'lisbon', 'porto', 'algarve', 'madere'],
    countryCode: 'PT',
    flightLowEur: 50,
    flightAvgEur: 150,
    dailyBudgetEur: 70,
    tier: 'Europe low-cost',
  ),
  DestinationBaselineCost(
    displayName: 'Espagne',
    matchKeywords: ['espagne', 'spain', 'madrid', 'barcelone', 'seville', 'valence', 'andalousie'],
    countryCode: 'ES',
    flightLowEur: 40,
    flightAvgEur: 130,
    dailyBudgetEur: 75,
    tier: 'Europe low-cost',
  ),
  DestinationBaselineCost(
    displayName: 'Italie',
    matchKeywords: ['italie', 'italy', 'rome', 'florence', 'venise', 'milan', 'naples', 'sicile', 'sardaigne'],
    countryCode: 'IT',
    flightLowEur: 50,
    flightAvgEur: 150,
    dailyBudgetEur: 90,
    tier: 'Europe low-cost',
  ),
  DestinationBaselineCost(
    displayName: 'Grèce',
    matchKeywords: ['grece', 'greece', 'athenes', 'crete', 'santorin', 'mykonos', 'rhodes', 'corfou'],
    countryCode: 'GR',
    flightLowEur: 100,
    flightAvgEur: 220,
    dailyBudgetEur: 75,
    tier: 'Europe low-cost',
  ),
  DestinationBaselineCost(
    displayName: 'Croatie',
    matchKeywords: ['croatie', 'croatia', 'dubrovnik', 'split', 'zagreb'],
    countryCode: 'HR',
    flightLowEur: 100,
    flightAvgEur: 220,
    dailyBudgetEur: 70,
    tier: 'Europe low-cost',
  ),
  DestinationBaselineCost(
    displayName: 'Pologne',
    matchKeywords: ['pologne', 'poland', 'cracovie', 'krakow', 'varsovie', 'warsaw', 'gdansk'],
    countryCode: 'PL',
    flightLowEur: 60,
    flightAvgEur: 150,
    dailyBudgetEur: 50,
    tier: 'Europe low-cost',
  ),
  DestinationBaselineCost(
    displayName: 'Hongrie / Budapest',
    matchKeywords: ['hongrie', 'hungary', 'budapest'],
    countryCode: 'HU',
    flightLowEur: 80,
    flightAvgEur: 180,
    dailyBudgetEur: 55,
    tier: 'Europe low-cost',
  ),
  DestinationBaselineCost(
    displayName: 'République tchèque / Prague',
    matchKeywords: ['prague', 'tcheque', 'czech'],
    countryCode: 'CZ',
    flightLowEur: 80,
    flightAvgEur: 180,
    dailyBudgetEur: 60,
    tier: 'Europe low-cost',
  ),

  // === Tier 3 — Méditerranée orientale ===
  DestinationBaselineCost(
    displayName: 'Turquie',
    matchKeywords: ['turquie', 'turkey', 'istanbul', 'cappadoce', 'antalya'],
    countryCode: 'TR',
    flightLowEur: 120,
    flightAvgEur: 280,
    dailyBudgetEur: 55,
    tier: 'Méditerranée',
  ),
  DestinationBaselineCost(
    displayName: 'Égypte',
    matchKeywords: ['egypte', 'egypt', 'le caire', 'cairo', 'louxor', 'aswan', 'hurghada', 'sharm'],
    countryCode: 'EG',
    flightLowEur: 200,
    flightAvgEur: 400,
    dailyBudgetEur: 60,
    tier: 'Méditerranée',
  ),

  // === Tier 4 — Long-courrier accessible ===
  DestinationBaselineCost(
    displayName: 'Thaïlande',
    matchKeywords: ['thailande', 'thailand', 'bangkok', 'phuket', 'chiang mai', 'koh samui'],
    countryCode: 'TH',
    flightLowEur: 500,
    flightAvgEur: 800,
    dailyBudgetEur: 50,
    tier: 'Asie du Sud-Est',
  ),
  DestinationBaselineCost(
    displayName: 'Vietnam',
    matchKeywords: ['vietnam', 'hanoi', 'ho chi minh', 'saigon', 'da nang', 'hue'],
    countryCode: 'VN',
    flightLowEur: 550,
    flightAvgEur: 850,
    dailyBudgetEur: 45,
    tier: 'Asie du Sud-Est',
  ),
  DestinationBaselineCost(
    displayName: 'Cambodge',
    matchKeywords: ['cambodge', 'cambodia', 'siem reap', 'phnom penh', 'angkor'],
    countryCode: 'KH',
    flightLowEur: 600,
    flightAvgEur: 900,
    dailyBudgetEur: 40,
    tier: 'Asie du Sud-Est',
  ),
  DestinationBaselineCost(
    displayName: 'Bali / Indonésie',
    matchKeywords: ['bali', 'indonesie', 'indonesia', 'jakarta', 'lombok', 'gili'],
    countryCode: 'ID',
    flightLowEur: 600,
    flightAvgEur: 950,
    dailyBudgetEur: 50,
    tier: 'Asie du Sud-Est',
  ),
  DestinationBaselineCost(
    displayName: 'Inde',
    matchKeywords: ['inde', 'india', 'delhi', 'mumbai', 'rajasthan', 'kerala', 'goa'],
    countryCode: 'IN',
    flightLowEur: 500,
    flightAvgEur: 750,
    dailyBudgetEur: 45,
    tier: 'Asie du Sud',
  ),
  DestinationBaselineCost(
    displayName: 'Sri Lanka',
    matchKeywords: ['sri lanka', 'colombo', 'galle', 'kandy'],
    countryCode: 'LK',
    flightLowEur: 600,
    flightAvgEur: 900,
    dailyBudgetEur: 50,
    tier: 'Asie du Sud',
  ),

  // === Tier 5 — Long-courrier premium ===
  DestinationBaselineCost(
    displayName: 'Japon',
    matchKeywords: ['japon', 'japan', 'tokyo', 'kyoto', 'osaka'],
    countryCode: 'JP',
    flightLowEur: 700,
    flightAvgEur: 1100,
    dailyBudgetEur: 130,
    tier: 'Asie de l\'Est',
  ),
  DestinationBaselineCost(
    displayName: 'États-Unis',
    matchKeywords: ['etats-unis', 'usa', 'new york', 'los angeles', 'san francisco', 'miami', 'chicago'],
    countryCode: 'US',
    flightLowEur: 500,
    flightAvgEur: 900,
    dailyBudgetEur: 150,
    tier: 'Amérique du Nord',
  ),
  DestinationBaselineCost(
    displayName: 'Mexique',
    matchKeywords: ['mexique', 'mexico', 'cancun', 'tulum', 'oaxaca', 'yucatan'],
    countryCode: 'MX',
    flightLowEur: 600,
    flightAvgEur: 1000,
    dailyBudgetEur: 70,
    tier: 'Amérique latine',
  ),
  DestinationBaselineCost(
    displayName: 'Brésil',
    matchKeywords: ['bresil', 'brazil', 'rio', 'sao paulo', 'salvador', 'recife'],
    countryCode: 'BR',
    flightLowEur: 750,
    flightAvgEur: 1200,
    dailyBudgetEur: 80,
    tier: 'Amérique latine',
  ),
  DestinationBaselineCost(
    displayName: 'Pérou',
    matchKeywords: ['perou', 'peru', 'lima', 'cuzco', 'machu picchu'],
    countryCode: 'PE',
    flightLowEur: 800,
    flightAvgEur: 1300,
    dailyBudgetEur: 60,
    tier: 'Amérique latine',
  ),
  DestinationBaselineCost(
    displayName: 'Australie',
    matchKeywords: ['australie', 'australia', 'sydney', 'melbourne', 'cairns'],
    countryCode: 'AU',
    flightLowEur: 1100,
    flightAvgEur: 1700,
    dailyBudgetEur: 130,
    tier: 'Pacifique',
  ),
  DestinationBaselineCost(
    displayName: 'Maldives',
    matchKeywords: ['maldives', 'male'],
    countryCode: 'MV',
    flightLowEur: 800,
    flightAvgEur: 1300,
    dailyBudgetEur: 200,
    tier: 'Îles Indien',
  ),
  DestinationBaselineCost(
    displayName: 'Maurice',
    matchKeywords: ['maurice', 'mauritius'],
    countryCode: 'MU',
    flightLowEur: 700,
    flightAvgEur: 1100,
    dailyBudgetEur: 110,
    tier: 'Îles Indien',
  ),
  DestinationBaselineCost(
    displayName: 'Réunion',
    matchKeywords: ['reunion', 'la reunion', 'saint-denis'],
    countryCode: 'RE',
    flightLowEur: 600,
    flightAvgEur: 1000,
    dailyBudgetEur: 90,
    tier: 'Îles Indien',
  ),
  DestinationBaselineCost(
    displayName: 'Islande',
    matchKeywords: ['islande', 'iceland', 'reykjavik'],
    countryCode: 'IS',
    flightLowEur: 250,
    flightAvgEur: 500,
    dailyBudgetEur: 150,
    tier: 'Europe Nord',
  ),
];

/// Recherche le baseline cost pour un texte de destination.
DestinationBaselineCost? findBaselineCostFor(String destinationText) {
  final norm = _normalize(destinationText);
  if (norm.isEmpty) return null;
  for (final entry in _data) {
    if (entry.matchKeywords.any((kw) => norm.contains(_normalize(kw)))) {
      return entry;
    }
  }
  return null;
}

/// Liste les destinations alternatives compatibles avec un budget donné
/// pour `days` jours, depuis l'aéroport `homeAirport`. Triées par tier
/// (proches d'abord) puis par budget min ascendant. Limitée aux N premières
/// (default 5) pour ne pas surcharger l'UI.
///
/// Exclut une destination si son `displayName` matche `excludeKeywords`
/// (pour ne pas re-suggérer la destination courante en alternative).
List<DestinationBaselineCost> findAlternativesWithinBudget({
  required int budgetEur,
  required int days,
  String? homeAirport,
  List<String> excludeKeywords = const [],
  int limit = 5,
}) {
  final factor = _originFactor(homeAirport);
  final candidates = <DestinationBaselineCost>[];
  for (final entry in _data) {
    final excluded = excludeKeywords.any(
      (kw) => entry.matchKeywords.any((mk) => _normalize(mk) == _normalize(kw)),
    );
    if (excluded) continue;
    final adjustedFlight = (entry.flightLowEur * factor).round();
    final minTotal = adjustedFlight + (entry.dailyBudgetEur * days);
    if (minTotal <= budgetEur) candidates.add(entry);
  }
  // Tri : par tier (Maghreb < Europe low-cost < ...) puis par flightLow.
  const tierOrder = [
    'Maghreb proche',
    'Europe low-cost',
    'Europe Nord',
    'Méditerranée',
    'Asie du Sud-Est',
    'Asie du Sud',
    'Asie de l\'Est',
    'Îles Indien',
    'Amérique latine',
    'Amérique du Nord',
    'Pacifique',
  ];
  candidates.sort((a, b) {
    final ta = tierOrder.indexOf(a.tier);
    final tb = tierOrder.indexOf(b.tier);
    if (ta != tb) return ta.compareTo(tb);
    return a.flightLowEur.compareTo(b.flightLowEur);
  });
  return candidates.take(limit).toList();
}

/// Estimation de la faisabilité d'un voyage à `destination` avec `budgetEur`
/// pour `days` jours, depuis `homeAirport`. Retourne null si la destination
/// n'est pas dans la table.
({
  DestinationBaselineCost cost,
  int adjustedFlight,
  int minTotal,
  int avgTotal,
  bool fits,
  bool tightFit,
})? estimateFeasibility({
  required String destinationText,
  required int budgetEur,
  required int days,
  String? homeAirport,
}) {
  final cost = findBaselineCostFor(destinationText);
  if (cost == null) return null;
  final factor = _originFactor(homeAirport);
  final adjustedFlight = (cost.flightLowEur * factor).round();
  final adjustedAvg = (cost.flightAvgEur * factor).round();
  final minTotal = adjustedFlight + (cost.dailyBudgetEur * days);
  final avgTotal = adjustedAvg + ((cost.dailyBudgetEur * days * 1.2).round());
  final fits = budgetEur >= minTotal;
  final tightFit = fits && budgetEur < avgTotal;
  return (
    cost: cost,
    adjustedFlight: adjustedFlight,
    minTotal: minTotal,
    avgTotal: avgTotal,
    fits: fits,
    tightFit: tightFit,
  );
}

/// Multiplicateur appliqué aux prix vols selon l'aéroport de départ. Tarifs
/// de référence sont depuis CDG (Paris). Les autres aéroports FR ont des
/// prix légèrement plus élevés (moins de fréquences/concurrence) ou
/// inférieurs (low-cost hubs comme BVA, BCN).
///
/// Approximation grossière — l'objectif est juste de refléter "depuis Nice
/// c'est en moyenne 10-20% plus cher" sans calcul fin. Default 1.0 pour
/// CDG ou aéroport inconnu.
double _originFactor(String? iata) {
  if (iata == null || iata.isEmpty) return 1.0;
  final code = iata.toUpperCase();
  switch (code) {
    case 'CDG':
    case 'ORY':
    case 'BVA':
      return 1.0; // référence
    case 'NCE':
    case 'MRS':
    case 'LYS':
    case 'TLS':
    case 'BOD':
    case 'NTE':
      return 1.15; // province FR, moins de fréquences
    case 'GVA':
    case 'BRU':
    case 'LUX':
      return 1.10; // hubs voisins
    default:
      return 1.20; // origine éloignée ou exotique
  }
}

String _normalize(String s) {
  return s
      .toLowerCase()
      .replaceAll(RegExp(r'[éèêë]'), 'e')
      .replaceAll(RegExp(r'[àâä]'), 'a')
      .replaceAll(RegExp(r'[ïî]'), 'i')
      .replaceAll(RegExp(r'[ôö]'), 'o')
      .replaceAll(RegExp(r'[ûü]'), 'u')
      .replaceAll('ç', 'c');
}
