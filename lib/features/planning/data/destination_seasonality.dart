/// Saisonnalité par destination — données statiques côté Dart, lookup
/// déterministe sans appel IA. Cf. `feedback_no_gemini_patchwork.md` :
/// privilégier les données déterministes pour les infos stables.
///
/// Structure pensée pour scaler :
/// - Une entrée pays générale ("Brésil") → match large via le nom du pays
///   et ses variants dans le texte de destination
/// - Une ou plusieurs entrées régionales ("Brésil — Nordeste",
///   "Thaïlande — Sud Andaman") → matchent des mots-clés (villes/régions)
///   plus spécifiques, et sont **préférées** au match général quand elles
///   touchent
///
/// V1 : ~25 entrées couvrant les destinations FR populaires. À étendre via
/// les retours utilisateurs (cf. backlog "Mapping seasonality étendu").
///
/// Unités : mois en `int` 1-12. `bestMonths` = idéal météo/touristique,
/// `okMonths` = correct mais haute saison ou conditions moyennes,
/// `avoidMonths` = mousson/chaleur extrême/cyclones/etc.
library;

class SeasonalEvent {
  /// Nom court ("Carnaval", "Ramadan", "Hanami").
  final String name;
  /// Mois 1-12 où l'événement a lieu (peut chevaucher 2 mois).
  final List<int> months;
  /// Note courte ("très animé mais plus cher", "horaires perturbés").
  final String note;

  const SeasonalEvent({required this.name, required this.months, required this.note});
}

class DestinationSeasonality {
  /// Étiquette affichée dans la sheet ("Brésil", "Thaïlande — Sud Andaman").
  final String displayName;

  /// Mots-clés (matching case+accents-insensible) à chercher dans le texte
  /// de destination. Pour entrée pays : nom du pays + variants. Pour entrée
  /// régionale : villes/sous-régions concernées.
  final List<String> matchKeywords;

  /// Quand true, cette entrée est plus spécifique qu'une entrée pays
  /// générale et est préférée si elle matche le texte de destination.
  final bool isRegional;

  /// Mois idéaux (météo + tourisme).
  final List<int> bestMonths;

  /// Mois corrects (souvent haute saison touristique : météo OK mais
  /// foule/prix). Vide = pas de "deuxième tier" notable.
  final List<int> okMonths;

  /// Mois à éviter (mousson, cyclones, chaleur extrême...). Vide = pas de
  /// mois clairement déconseillé.
  final List<int> avoidMonths;

  /// Notes courtes (1 phrase chacune) à afficher dans la section "À savoir".
  final List<String> notes;

  /// Événements saisonniers notables qui peuvent influencer le choix.
  final List<SeasonalEvent> events;

  const DestinationSeasonality({
    required this.displayName,
    required this.matchKeywords,
    this.isRegional = false,
    required this.bestMonths,
    this.okMonths = const [],
    this.avoidMonths = const [],
    this.notes = const [],
    this.events = const [],
  });

  /// Mois recommandé par défaut quand l'utilisateur clique "Choisir [mois]"
  /// dans la sheet. Premier `bestMonths` futur (à partir de `now`), bouclant
  /// sur l'année suivante si tous les bestMonths sont passés cette année.
  int defaultRecommendedMonth(DateTime now) {
    if (bestMonths.isEmpty) {
      // Filet de sécurité : devrait pas arriver vu les data, on prend mois courant.
      return now.month;
    }
    final sorted = [...bestMonths]..sort();
    for (final m in sorted) {
      if (m >= now.month) return m;
    }
    return sorted.first; // tous passés cette année → premier mois l'année prochaine
  }

  /// Année cible pour le mois recommandé : si le mois est déjà passé cette
  /// année, on bascule sur l'année suivante.
  int defaultRecommendedYear(DateTime now) {
    final m = defaultRecommendedMonth(now);
    return m >= now.month ? now.year : now.year + 1;
  }
}

const List<DestinationSeasonality> _data = [
  // === BRÉSIL ===
  DestinationSeasonality(
    displayName: 'Brésil',
    matchKeywords: ['bresil', 'brazil', 'sao paulo', 'brasilia'],
    bestMonths: [5, 6, 7, 8, 9],
    okMonths: [4, 10],
    avoidMonths: [1, 2, 3, 12],
    notes: [
      'Mai à septembre : saison sèche, températures plus douces, idéal pour la plupart des régions.',
      'Décembre à mars : saison des pluies au Sud-Est et en Amazonie, très chaud et humide.',
    ],
    events: [
      SeasonalEvent(name: 'Carnaval', months: [2, 3], note: 'Très animé partout, prix×2-3 surtout à Rio.'),
      SeasonalEvent(name: 'Réveillon', months: [12], note: 'Plages bondées (Copacabana, Salvador).'),
    ],
  ),
  DestinationSeasonality(
    displayName: 'Brésil — Côte Nordeste',
    matchKeywords: ['salvador', 'recife', 'fortaleza', 'natal', 'jericoacoara', 'maragogi', 'porto de galinhas', 'nordeste'],
    isRegional: true,
    bestMonths: [9, 10, 11, 12, 1, 2, 3],
    okMonths: [4, 8],
    avoidMonths: [5, 6, 7],
    notes: [
      'Climat tropical sec d\'octobre à février — soleil quasi garanti.',
      'Mai-juillet : saison des pluies sur la côte (averses brèves mais fréquentes).',
    ],
  ),
  DestinationSeasonality(
    displayName: 'Brésil — Amazonie',
    matchKeywords: ['manaus', 'amazonie', 'amazonas', 'belem', 'iquitos'],
    isRegional: true,
    bestMonths: [6, 7, 8, 9, 10],
    okMonths: [11],
    avoidMonths: [1, 2, 3, 4, 5],
    notes: [
      'Saison sèche de juin à octobre : niveau du fleuve plus bas, sentiers praticables.',
      'Saison des pluies de janvier à mai : crues, navigation possible mais moustiques actifs.',
    ],
  ),

  // === THAÏLANDE ===
  DestinationSeasonality(
    displayName: 'Thaïlande',
    matchKeywords: ['thailande', 'thailand'],
    bestMonths: [11, 12, 1, 2],
    okMonths: [3, 10],
    avoidMonths: [6, 7, 8, 9],
    notes: [
      'Novembre à février : saison fraîche, peu humide, idéal partout.',
      'Mars-mai : très chaud (40°C+ au Nord). Juin-octobre : mousson sur la majorité du pays.',
    ],
    events: [
      SeasonalEvent(name: 'Songkran', months: [4], note: 'Nouvel an thaï, batailles d\'eau, ambiance unique mais transports saturés.'),
      SeasonalEvent(name: 'Loy Krathong', months: [11], note: 'Festival des lumières, magnifique à Chiang Mai.'),
    ],
  ),
  DestinationSeasonality(
    displayName: 'Thaïlande — Sud Andaman (Phuket, Krabi, Phi Phi)',
    matchKeywords: ['phuket', 'krabi', 'phi phi', 'phang nga', 'koh lanta', 'koh yao'],
    isRegional: true,
    bestMonths: [12, 1, 2, 3],
    okMonths: [11, 4],
    avoidMonths: [6, 7, 8, 9, 10],
    notes: [
      'Novembre à avril : mer calme, beau temps, parfait pour les îles.',
      'Mai à octobre : mousson Andaman, beaucoup de pluie, mer agitée. Beaucoup d\'hôtels ferment.',
    ],
  ),
  DestinationSeasonality(
    displayName: 'Thaïlande — Sud Golfe (Koh Samui, Koh Phangan, Koh Tao)',
    matchKeywords: ['koh samui', 'samui', 'koh phangan', 'phangan', 'koh tao', 'tao'],
    isRegional: true,
    bestMonths: [2, 3, 4, 5, 6, 7, 8, 9],
    okMonths: [1],
    avoidMonths: [10, 11, 12],
    notes: [
      'Météo inversée par rapport à Phuket : beau de février à septembre.',
      'Octobre à décembre : saison des pluies sur le Golfe (averses tropicales fréquentes).',
    ],
    events: [
      SeasonalEvent(name: 'Full Moon Party', months: [1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12], note: 'Mensuel à Koh Phangan — vérifier les dates précises.'),
    ],
  ),
  DestinationSeasonality(
    displayName: 'Thaïlande — Nord (Chiang Mai, Chiang Rai)',
    matchKeywords: ['chiang mai', 'chiang rai', 'pai'],
    isRegional: true,
    bestMonths: [11, 12, 1, 2],
    okMonths: [10, 3],
    avoidMonths: [4, 5, 6, 7, 8, 9],
    notes: [
      'Novembre à février : températures fraîches, sec, idéal pour la randonnée.',
      'Mars-avril : saison des brûlis (fumée importante, qualité de l\'air dégradée).',
    ],
  ),

  // === JAPON ===
  DestinationSeasonality(
    displayName: 'Japon',
    matchKeywords: ['japon', 'japan', 'tokyo', 'kyoto', 'osaka', 'hiroshima', 'nara'],
    bestMonths: [3, 4, 5, 10, 11],
    okMonths: [9, 12],
    avoidMonths: [6, 7, 8],
    notes: [
      'Mars-avril : cerisiers en fleur (sakura) — temps idéal mais foule et prix×1.5.',
      'Octobre-novembre : couleurs d\'automne (momiji), météo douce, moins de monde.',
      'Juin-juillet : saison des pluies (tsuyu). Août : très chaud et humide, typhons possibles.',
    ],
    events: [
      SeasonalEvent(name: 'Hanami (sakura)', months: [3, 4], note: 'Pic des cerisiers, à réserver tôt.'),
      SeasonalEvent(name: 'Golden Week', months: [4, 5], note: '29 avril → 5 mai : tout est plein, à éviter pour les premières fois.'),
      SeasonalEvent(name: 'Obon', months: [8], note: 'Mi-août : trains et hôtels saturés (vacances familiales).'),
    ],
  ),
  DestinationSeasonality(
    displayName: 'Japon — Hokkaido',
    matchKeywords: ['hokkaido', 'sapporo', 'hakodate', 'niseko'],
    isRegional: true,
    bestMonths: [6, 7, 8, 9, 1, 2],
    okMonths: [5, 10, 12, 3],
    avoidMonths: [4, 11],
    notes: [
      'Été (juin-septembre) : températures douces, lavandes en juillet, randonnée.',
      'Hiver (janvier-février) : neige excellente, ski mondial à Niseko.',
    ],
  ),
  DestinationSeasonality(
    displayName: 'Japon — Okinawa',
    matchKeywords: ['okinawa', 'naha', 'ishigaki', 'miyako'],
    isRegional: true,
    bestMonths: [3, 4, 5, 10, 11],
    okMonths: [6, 9],
    avoidMonths: [7, 8],
    notes: [
      'Climat subtropical : meilleur au printemps et en automne.',
      'Juillet-août : chaud, humide, saison des typhons.',
    ],
  ),

  // === MAROC ===
  DestinationSeasonality(
    displayName: 'Maroc',
    matchKeywords: ['maroc', 'morocco', 'marrakech', 'fes', 'casablanca', 'tanger', 'rabat'],
    bestMonths: [3, 4, 5, 9, 10, 11],
    okMonths: [2, 12],
    avoidMonths: [7, 8],
    notes: [
      'Printemps et automne : températures parfaites partout (20-28°C).',
      'Été (juillet-août) : très chaud à Marrakech et au Sud (40°C+). La côte (Essaouira, Tanger) reste douce.',
      'Hiver doux mais nuits froides à Marrakech, neige possible dans l\'Atlas.',
    ],
    events: [
      SeasonalEvent(name: 'Ramadan', months: [3], note: 'Dates variables selon le calendrier lunaire — beaucoup de restaurants fermés en journée.'),
    ],
  ),
  DestinationSeasonality(
    displayName: 'Maroc — Sahara (Merzouga, Zagora)',
    matchKeywords: ['merzouga', 'zagora', 'sahara', 'erg chebbi', 'mhamid'],
    isRegional: true,
    bestMonths: [10, 11, 3, 4],
    okMonths: [12, 1, 2, 5, 9],
    avoidMonths: [6, 7, 8],
    notes: [
      'Octobre-novembre et mars-avril : températures idéales (20-25°C jour, 5-15°C nuit).',
      'Été : chaleur écrasante (45°C+). Hiver : nuits très froides en bivouac.',
    ],
  ),

  // === ÉGYPTE ===
  DestinationSeasonality(
    displayName: 'Égypte',
    matchKeywords: ['egypte', 'egypt', 'le caire', 'cairo', 'louxor', 'aswan', 'assouan'],
    bestMonths: [10, 11, 2, 3, 4],
    okMonths: [12, 1, 5, 9],
    avoidMonths: [6, 7, 8],
    notes: [
      'Octobre à avril : températures agréables pour les sites historiques.',
      'Été : chaleur extrême à Louxor/Assouan (45°C). Mer Rouge supportable mais chaud.',
    ],
  ),
  DestinationSeasonality(
    displayName: 'Égypte — Mer Rouge',
    matchKeywords: ['hurghada', 'sharm', 'charm el-cheikh', 'dahab', 'marsa alam'],
    isRegional: true,
    bestMonths: [3, 4, 5, 10, 11],
    okMonths: [2, 9, 12],
    avoidMonths: [],
    notes: [
      'Plongée et soleil quasi toute l\'année. Été chaud mais supportable au bord de l\'eau.',
      'Décembre-février : eau plus fraîche (22°C), combinaison conseillée.',
    ],
  ),

  // === VIETNAM ===
  DestinationSeasonality(
    displayName: 'Vietnam — Nord (Hanoï, Halong, Sapa)',
    matchKeywords: ['hanoi', 'halong', 'baie d\'halong', 'sapa', 'ninh binh'],
    isRegional: true,
    bestMonths: [10, 11, 3, 4],
    okMonths: [9, 12, 5],
    avoidMonths: [1, 2, 6, 7, 8],
    notes: [
      'Octobre-avril : sec, températures douces. Sapa peut être très brumeuse en hiver.',
      'Juin-août : chaleur lourde + typhons possibles sur Halong.',
    ],
  ),
  DestinationSeasonality(
    displayName: 'Vietnam — Sud (Hô Chi Minh, Mékong, Phu Quoc)',
    matchKeywords: ['ho chi minh', 'saigon', 'mekong', 'phu quoc', 'can tho', 'mui ne'],
    isRegional: true,
    bestMonths: [12, 1, 2, 3, 4],
    okMonths: [11, 5],
    avoidMonths: [6, 7, 8, 9, 10],
    notes: [
      'Décembre à avril : saison sèche, ensoleillé.',
      'Mai à novembre : mousson, averses fortes mais courtes en général.',
    ],
  ),

  // === INDONÉSIE / BALI ===
  DestinationSeasonality(
    displayName: 'Bali / Indonésie',
    matchKeywords: ['bali', 'indonesie', 'indonesia', 'jakarta', 'lombok', 'gili', 'ubud'],
    bestMonths: [4, 5, 6, 7, 8, 9],
    okMonths: [3, 10],
    avoidMonths: [11, 12, 1, 2],
    notes: [
      'Avril-octobre : saison sèche, idéal partout en Indonésie.',
      'Novembre-mars : saison des pluies (averses quotidiennes), chaud et humide.',
    ],
  ),

  // === GRÈCE ===
  DestinationSeasonality(
    displayName: 'Grèce',
    matchKeywords: ['grece', 'greece', 'athenes', 'athens', 'crete', 'santorin', 'mykonos', 'rhodes', 'corfou'],
    bestMonths: [5, 6, 9, 10],
    okMonths: [4, 7, 8],
    avoidMonths: [],
    notes: [
      'Mai-juin et septembre-octobre : températures parfaites, mer chaude, moins de foule.',
      'Juillet-août : très chaud (40°C+), îles surchargées, prix au plus haut.',
    ],
  ),

  // === ITALIE ===
  DestinationSeasonality(
    displayName: 'Italie',
    matchKeywords: ['italie', 'italy', 'rome', 'florence', 'venise', 'milan', 'naples', 'sicile', 'sardaigne'],
    bestMonths: [4, 5, 6, 9, 10],
    okMonths: [3, 7, 11],
    avoidMonths: [],
    notes: [
      'Printemps et automne : météo idéale dans tout le pays.',
      'Juillet-août : très chaud au Sud et dans les villes, foule importante.',
    ],
  ),

  // === ESPAGNE ===
  DestinationSeasonality(
    displayName: 'Espagne',
    matchKeywords: ['espagne', 'spain', 'madrid', 'barcelone', 'seville', 'valence', 'andalousie'],
    bestMonths: [4, 5, 6, 9, 10],
    okMonths: [3, 7, 11],
    avoidMonths: [],
    notes: [
      'Andalousie : juillet-août très chaud (40°C+), préférer printemps/automne.',
      'Côte méditerranéenne : juin-septembre pour la baignade.',
    ],
  ),
  DestinationSeasonality(
    displayName: 'Canaries',
    matchKeywords: ['tenerife', 'lanzarote', 'fuerteventura', 'gran canaria', 'la palma', 'canaries'],
    isRegional: true,
    bestMonths: [3, 4, 5, 6, 9, 10, 11, 12],
    okMonths: [1, 2, 7, 8],
    avoidMonths: [],
    notes: [
      '"Printemps éternel" : climat doux toute l\'année (18-26°C).',
      'Juillet-août : plus chaud + foule. Hiver : agréable mais eau plus fraîche.',
    ],
  ),

  // === PORTUGAL ===
  DestinationSeasonality(
    displayName: 'Portugal',
    matchKeywords: ['portugal', 'lisbonne', 'lisbon', 'porto', 'algarve', 'madere', 'madeira'],
    bestMonths: [5, 6, 9, 10],
    okMonths: [4, 7, 8],
    avoidMonths: [],
    notes: [
      'Mai-octobre : excellent partout. Algarve agréable de mars à novembre.',
      'Madère : doux toute l\'année (18-25°C).',
    ],
  ),

  // === CROATIE ===
  DestinationSeasonality(
    displayName: 'Croatie',
    matchKeywords: ['croatie', 'croatia', 'dubrovnik', 'split', 'hvar', 'zagreb', 'plitvice'],
    bestMonths: [5, 6, 9],
    okMonths: [4, 7, 8, 10],
    avoidMonths: [],
    notes: [
      'Mai-juin et septembre : météo parfaite, mer chaude (juin), moins de monde.',
      'Juillet-août : très touristique, prix au max sur la côte.',
    ],
  ),

  // === TURQUIE ===
  DestinationSeasonality(
    displayName: 'Turquie',
    matchKeywords: ['turquie', 'turkey', 'istanbul', 'cappadoce', 'cappadocia', 'antalya', 'bodrum'],
    bestMonths: [4, 5, 6, 9, 10],
    okMonths: [3, 7, 8, 11],
    avoidMonths: [],
    notes: [
      'Cappadoce : avril-mai et septembre-octobre pour les montgolfières (vent calme).',
      'Côte sud : juin-septembre pour la baignade.',
    ],
  ),

  // === ÉTATS-UNIS ===
  DestinationSeasonality(
    displayName: 'États-Unis — Côte Est (NYC, Boston, DC)',
    matchKeywords: ['new york', 'nyc', 'boston', 'washington', 'philadelphie', 'philadelphia'],
    isRegional: true,
    bestMonths: [5, 6, 9, 10],
    okMonths: [4, 7, 8, 11],
    avoidMonths: [1, 2],
    notes: [
      'Printemps et automne (foliage) : températures idéales.',
      'Hiver : froid (-5 à 0°C, neige). Été : chaud et humide à NYC.',
    ],
  ),
  DestinationSeasonality(
    displayName: 'États-Unis — Californie',
    matchKeywords: ['californie', 'california', 'los angeles', 'san francisco', 'san diego', 'yosemite'],
    isRegional: true,
    bestMonths: [4, 5, 6, 9, 10],
    okMonths: [3, 7, 8, 11],
    avoidMonths: [],
    notes: [
      'Climat doux toute l\'année sur la côte. Yosemite : juin-septembre pour les chutes.',
      'San Francisco : brouillard fréquent en juillet-août (apporter un pull).',
    ],
  ),
  DestinationSeasonality(
    displayName: 'États-Unis — Sud-Ouest (Las Vegas, Grand Canyon)',
    matchKeywords: ['las vegas', 'grand canyon', 'arizona', 'utah', 'monument valley', 'antelope canyon'],
    isRegional: true,
    bestMonths: [4, 5, 9, 10],
    okMonths: [3, 11],
    avoidMonths: [6, 7, 8],
    notes: [
      'Printemps et automne : températures parfaites pour les parcs.',
      'Été : chaleur extrême (45°C+ à Las Vegas, dangereux pour la rando).',
    ],
  ),
  DestinationSeasonality(
    displayName: 'États-Unis — Floride',
    matchKeywords: ['miami', 'orlando', 'florida', 'floride', 'key west'],
    isRegional: true,
    bestMonths: [12, 1, 2, 3, 4],
    okMonths: [11, 5],
    avoidMonths: [6, 7, 8, 9, 10],
    notes: [
      'Décembre-avril : sec, doux, idéal.',
      'Juin-novembre : saison des ouragans (pic août-octobre), très humide.',
    ],
  ),
  DestinationSeasonality(
    displayName: 'États-Unis — Hawaï',
    matchKeywords: ['hawaii', 'hawai', 'honolulu', 'maui', 'big island', 'kauai'],
    isRegional: true,
    bestMonths: [4, 5, 9, 10],
    okMonths: [3, 6, 7, 8, 11],
    avoidMonths: [],
    notes: [
      'Climat agréable toute l\'année (22-28°C). Avril-mai et sept-octobre : moins de foule, prix plus doux.',
      'Décembre-février : surf gigantesque (pour pros) sur la côte Nord.',
    ],
  ),

  // === MEXIQUE ===
  DestinationSeasonality(
    displayName: 'Mexique',
    matchKeywords: ['mexique', 'mexico', 'cancun', 'tulum', 'playa del carmen', 'oaxaca', 'yucatan'],
    bestMonths: [11, 12, 1, 2, 3, 4],
    okMonths: [5, 10],
    avoidMonths: [6, 7, 8, 9],
    notes: [
      'Novembre à avril : sec, ensoleillé, idéal partout.',
      'Juin-octobre : saison des pluies + risque ouragans sur la côte caraïbe.',
    ],
  ),

  // === INDE ===
  DestinationSeasonality(
    displayName: 'Inde',
    matchKeywords: ['inde', 'india', 'delhi', 'agra', 'jaipur', 'rajasthan', 'mumbai'],
    bestMonths: [11, 12, 1, 2],
    okMonths: [10, 3],
    avoidMonths: [4, 5, 6, 7, 8, 9],
    notes: [
      'Novembre-février : sec, températures parfaites pour le Nord (Rajasthan, Delhi, Agra).',
      'Mars-mai : très chaud (45°C+). Juin-septembre : mousson, déplacements compliqués.',
    ],
    events: [
      SeasonalEvent(name: 'Diwali', months: [10, 11], note: 'Festival des lumières, magnifique mais transports saturés.'),
      SeasonalEvent(name: 'Holi', months: [3], note: 'Festival des couleurs, expérience unique mais dates variables.'),
    ],
  ),
  DestinationSeasonality(
    displayName: 'Inde — Kerala et Sud',
    matchKeywords: ['kerala', 'cochin', 'kochi', 'goa', 'tamil nadu', 'pondichery'],
    isRegional: true,
    bestMonths: [11, 12, 1, 2, 3],
    okMonths: [10],
    avoidMonths: [6, 7, 8, 9],
    notes: [
      'Novembre à mars : sec, agréable, idéal pour les backwaters et les plages.',
      'Juin-septembre : mousson très intense au Kerala.',
    ],
  ),

  // === AUSTRALIE ===
  DestinationSeasonality(
    displayName: 'Australie',
    matchKeywords: ['australie', 'australia', 'sydney', 'melbourne'],
    bestMonths: [10, 11, 3, 4],
    okMonths: [9, 12, 5],
    avoidMonths: [],
    notes: [
      'Printemps austral (oct-nov) et automne (mars-avril) : doux dans le Sud.',
      'L\'Australie est immense : le Nord (tropical) et le Sud (tempéré) ont des saisons inversées.',
    ],
  ),
  DestinationSeasonality(
    displayName: 'Australie — Nord tropical (Cairns, Darwin)',
    matchKeywords: ['cairns', 'darwin', 'great barrier reef', 'grande barriere', 'kakadu'],
    isRegional: true,
    bestMonths: [5, 6, 7, 8, 9],
    okMonths: [4, 10],
    avoidMonths: [11, 12, 1, 2, 3],
    notes: [
      'Saison sèche (mai-octobre) : chaud, ensoleillé, idéal pour la barrière de corail.',
      'Saison humide (nov-avril) : moustiques, méduses (eaux fermées), cyclones possibles.',
    ],
  ),

  // === ÎLES INDIEN ===
  DestinationSeasonality(
    displayName: 'Maurice / Réunion',
    matchKeywords: ['maurice', 'mauritius', 'reunion', 'la reunion', 'saint-denis'],
    bestMonths: [5, 6, 9, 10, 11],
    okMonths: [4, 7, 8, 12],
    avoidMonths: [1, 2, 3],
    notes: [
      'Mai-novembre : sec, températures douces (20-26°C).',
      'Janvier-mars : été austral, chaud et risque cyclonique.',
    ],
  ),
  DestinationSeasonality(
    displayName: 'Maldives',
    matchKeywords: ['maldives', 'male', 'maafushi'],
    bestMonths: [12, 1, 2, 3, 4],
    okMonths: [11, 5],
    avoidMonths: [6, 7, 8, 9, 10],
    notes: [
      'Décembre-avril : saison sèche, mer claire, idéal plongée.',
      'Mai-novembre : mousson humide, prix plus doux mais visibilité réduite.',
    ],
  ),
  DestinationSeasonality(
    displayName: 'Sri Lanka',
    matchKeywords: ['sri lanka', 'colombo', 'galle', 'kandy', 'ella'],
    bestMonths: [12, 1, 2, 3],
    okMonths: [11, 4],
    avoidMonths: [5, 6, 7, 8, 9, 10],
    notes: [
      'Décembre-mars : sec sur la côte Sud-Ouest et au centre. Idéal circuits.',
      'Mai-septembre : mousson Sud-Ouest. La côte Est (Trincomalee) est meilleure de mai à septembre.',
    ],
  ),

  // === ISLANDE ===
  DestinationSeasonality(
    displayName: 'Islande',
    matchKeywords: ['islande', 'iceland', 'reykjavik'],
    bestMonths: [6, 7, 8],
    okMonths: [5, 9],
    avoidMonths: [],
    notes: [
      'Juin-août : jours longs (soleil de minuit), routes praticables, températures douces (10-15°C).',
      'Hiver (nov-mars) : aurores boréales possibles mais routes souvent fermées.',
    ],
  ),
];

/// Recherche la meilleure entrée saisonnière pour un texte de destination.
/// Retourne null si aucune entrée ne matche (l'UI cache alors la CTA).
///
/// Priorité :
/// 1. Une entrée régionale (`isRegional: true`) qui matche un mot-clé →
///    plus précise, retournée immédiatement.
/// 2. Sinon, la première entrée pays générale qui matche.
DestinationSeasonality? findSeasonalityFor(String destinationText) {
  final norm = _normalize(destinationText);
  if (norm.isEmpty) return null;

  DestinationSeasonality? generalMatch;

  for (final entry in _data) {
    final hits = entry.matchKeywords.any((kw) => norm.contains(_normalize(kw)));
    if (!hits) continue;
    if (entry.isRegional) return entry;
    generalMatch ??= entry;
  }

  return generalMatch;
}

/// Normalise pour matcher : minuscules + suppression accents courants FR/EN.
/// Suffisant pour les destinations grand public (pas de translit complète).
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
