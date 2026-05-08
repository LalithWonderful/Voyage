/// Suggestions d'étapes "autour du parcours" — données statiques côté Dart,
/// lookup déterministe sans IA. Pattern aligné avec
/// `destination_seasonality.dart` / `destination_baseline_costs.dart`.
///
/// Cas d'usage : un voyage avec plusieurs étapes détectées depuis les vols
/// (gateway cities) où il faut suggérer les vraies destinations de séjour
/// autour. Exemple Vietnam : un vol arrive à Hanoï mais le vrai séjour est
/// à Ninh Bình. Le bouton "Affiner les étapes" remontera ces suggestions.
///
/// V1 : ~6-8 entrées couvrant les villes de la spec Lalith 2026-05-08
/// (Hanoï/Da Nang/Bangkok côté Vietnam-Thaïlande) + quelques extras pour
/// d'autres régions populaires (Tokyo, Paris, Madrid). À étendre selon
/// retours beta.
///
/// Aucune insertion auto en V1 : seulement affichage (Lot 1). Les
/// transformations APPEND/SPLIT/REPLACE sont implémentées en Lot 2 avec
/// validation fine des conflits réservation/planning.
library;

/// Mode d'insertion d'une suggestion par rapport à la ville d'ancrage.
/// Mappés en interne à 3 opérations concrètes (cf. Lot 2) :
/// - APPEND : anchor inchangé, suggested ajouté APRÈS (trip allonge)
/// - SPLIT  : anchor.days -= sum(suggested.days), suggested inséré APRÈS,
///   refus si reste anchor < minAnchorDaysToKeep
/// - REPLACE : anchor disparaît, suggested prend ses jours
enum InsertionMode {
  /// Excursion journée — appendée comme nouveau segment 1j (V1).
  /// Ex: Paris → Versailles 1j.
  dayTrip,
  /// Étape proche distincte ajoutée après l'ancrage (trip allonge).
  /// Ex: Hanoï + Baie d'Ha Long 2 nuits sans toucher Hanoï.
  nearbyStay,
  /// Sous-étape avec retour à l'ancrage : anchor X → [suggested, anchor X-N].
  /// Pattern "aller-retour depuis hub". Ex: Hanoï 4 → Ninh Bình 3 + Hanoï 1.
  splitSegment,
  /// L'ancrage n'était que l'aéroport d'arrivée. Remplacement complet par
  /// la vraie destination de séjour. Ex: Da Nang 3 → Hội An 3.
  replaceAnchorGateway,
  /// Séquence multi-étapes au début d'un séjour gateway. Ex: Bangkok X →
  /// Rayong 1 + Koh Samet 2 + Bangkok X-3 (le user revient à Bangkok après).
  splitGatewaySequence,
}

/// Une étape concrète à insérer si la suggestion est appliquée.
/// Tuple-style : pour les suggestions multi-step (Rayong + Koh Samet),
/// la suggestion porte une liste de ces segments.
class SuggestedSegment {
  /// Nom canonique de la ville (FR si dispo).
  final String city;

  /// Nombre de nuits/jours suggérés pour ce segment.
  final int days;

  /// Pays ISO long ("Vietnam", "Thaïlande") — utilisé pour pré-remplir
  /// `TripSegment.country` à l'insertion.
  final String? country;

  const SuggestedSegment({
    required this.city,
    required this.days,
    this.country,
  });
}

class SubTripSuggestion {
  /// Ville d'ancrage = ville déjà présente dans `trip.itinerarySegments`.
  /// Match case+accent insensible via `_normalize`.
  final String anchorCity;

  /// Étiquette affichée sur la card. "Ninh Bình" pour single-step,
  /// "Rayong + Koh Samet" pour multi-step.
  final String displayName;

  /// 1+ segment(s) à insérer si la suggestion est appliquée. Single-step
  /// = 1 entrée. Multi-step (Rayong + Koh Samet) = 2 entrées dans l'ordre.
  final List<SuggestedSegment> segments;

  /// Jours minimum à garder sur l'ancrage en mode SPLIT/splitGatewaySequence.
  /// Si le calcul donne moins → suggestion masquée.
  /// 0 pour replaceAnchorGateway (l'ancrage disparaît).
  final int minAnchorDaysToKeep;

  /// Mode d'insertion. Détermine l'opération en Lot 2.
  final InsertionMode insertionMode;

  /// Étiquette transport humaine (pas calculée). Ex: "≈ 2h-3h depuis Hanoï".
  final String? travelLabel;

  /// Tags humains affichés sur la card. Ex: ["Nature", "Patrimoine"].
  final List<String> tags;

  /// Priorité d'affichage (plus haut = plus en avant). Plages courantes
  /// 1-10. Sert à ordonner les cards d'un même anchor.
  final int priority;

  /// Texte court "pourquoi cette suggestion ?". Affiché sur la card en V1
  /// (sans le besoin du CTA secondaire "Voir pourquoi" — visible direct).
  final String? whyText;

  /// CTA explicite override. Ex: "Transformer Hanoï en Ninh Bình + Hanoï"
  /// au lieu du générique dérivé. Si null, label dérivé du mode.
  final String? ctaLabel;

  /// Label régional pour la phrase Impact (mode `nearbyStay`).
  /// Doit inclure l'article : "au Vietnam central", "en Toscane",
  /// "dans la baie de Ha Long". Default null → "au parcours".
  final String? regionLabel;

  const SubTripSuggestion({
    required this.anchorCity,
    required this.displayName,
    required this.segments,
    required this.insertionMode,
    this.minAnchorDaysToKeep = 0,
    this.travelLabel,
    this.tags = const [],
    this.priority = 5,
    this.whyText,
    this.ctaLabel,
    this.regionLabel,
  });

  /// Total jours/nuits suggérés (somme `segments.days`).
  int get totalSuggestedDays =>
      segments.fold(0, (sum, s) => sum + s.days);
}

/// Catalogue statique des suggestions par ville d'ancrage. Lookup via
/// `findSuggestionsForAnchor(city)`.
///
/// V1 : 6 villes-ancrages couvertes (Hanoï, Da Nang, Bangkok, Paris, Tokyo,
/// Madrid). Étendre selon les retours beta.
const _subTripSuggestions = <SubTripSuggestion>[
  // ─── Vietnam ────────────────────────────────────────────────────────
  SubTripSuggestion(
    anchorCity: 'Hanoï',
    displayName: 'Ninh Bình',
    segments: [
      SuggestedSegment(city: 'Ninh Bình', days: 3, country: 'Vietnam'),
    ],
    minAnchorDaysToKeep: 1,
    insertionMode: InsertionMode.splitGatewaySequence,
    travelLabel: '≈ 2h-3h depuis Hanoï',
    tags: ['Nature', 'Patrimoine', 'Karst'],
    priority: 10,
    whyText:
        'Rizières et grottes karstiques (la "baie d\'Ha Long terrestre"). '
        'Vrai séjour 3 nuits, retour à Hanoï avant la suite.',
    ctaLabel: 'Transformer le bloc Hanoï',
  ),
  SubTripSuggestion(
    anchorCity: 'Hanoï',
    displayName: 'Baie d\'Ha Long / Lan Ha',
    segments: [
      SuggestedSegment(city: 'Baie d\'Ha Long', days: 2, country: 'Vietnam'),
    ],
    minAnchorDaysToKeep: 1,
    insertionMode: InsertionMode.splitSegment,
    travelLabel: '≈ 2h30 depuis Hanoï',
    tags: ['Nature', 'Mer', 'Croisière'],
    priority: 8,
    whyText:
        'Croisière 1-2 nuits dans la baie d\'Ha Long ou Lan Ha '
        '(moins fréquentée). À combiner avec Hanoï.',
  ),

  // ─── Vietnam — Da Nang gateway ─────────────────────────────────────
  SubTripSuggestion(
    anchorCity: 'Da Nang',
    displayName: 'Hội An',
    segments: [
      SuggestedSegment(city: 'Hội An', days: 3, country: 'Vietnam'),
    ],
    minAnchorDaysToKeep: 0,
    insertionMode: InsertionMode.replaceAnchorGateway,
    travelLabel: '≈ 45 min depuis l\'aéroport de Da Nang',
    tags: ['Patrimoine', 'UNESCO', 'Lanternes'],
    priority: 10,
    whyText:
        'Da Nang est souvent juste l\'aéroport d\'arrivée. Hội An '
        '(vieille ville UNESCO) est la vraie étape de séjour.',
    ctaLabel: 'Remplacer Da Nang par Hội An',
  ),
  SubTripSuggestion(
    anchorCity: 'Da Nang',
    displayName: 'Hué',
    segments: [
      SuggestedSegment(city: 'Hué', days: 2, country: 'Vietnam'),
    ],
    // 2026-05-08 : reclassée nearbyStay (était splitSegment). Hué n'est
    // PAS la correction du segment Da Nang (= Hội An), c'est une option
    // culturelle additionnelle au Vietnam central.
    insertionMode: InsertionMode.nearbyStay,
    travelLabel: '≈ 2h depuis Da Nang (col du Hai Van)',
    tags: ['Patrimoine', 'Cité impériale', 'UNESCO'],
    priority: 7,
    whyText:
        'Cité impériale UNESCO, à combiner avec Hội An. La route via '
        'le col du Hai Van est elle-même un highlight.',
    ctaLabel: 'Ajouter Hué au Vietnam central',
    regionLabel: 'au Vietnam central',
  ),

  // ─── Thaïlande — Bangkok gateway ───────────────────────────────────
  SubTripSuggestion(
    anchorCity: 'Bangkok',
    displayName: 'Rayong + Koh Samet',
    segments: [
      SuggestedSegment(city: 'Rayong', days: 1, country: 'Thaïlande'),
      SuggestedSegment(city: 'Koh Samet', days: 2, country: 'Thaïlande'),
    ],
    minAnchorDaysToKeep: 1,
    insertionMode: InsertionMode.splitGatewaySequence,
    travelLabel: 'Rayong puis ferry vers Koh Samet (~3h30 total)',
    tags: ['Plage', 'Île', 'Détente'],
    priority: 9,
    whyText:
        'Idéal après une arrivée à Bangkok : 1 nuit à Rayong puis '
        '2 nuits sur l\'île, retour à Bangkok ensuite.',
    ctaLabel: 'Ajouter Rayong et Koh Samet',
  ),
  SubTripSuggestion(
    anchorCity: 'Bangkok',
    displayName: 'Ayutthaya',
    segments: [
      SuggestedSegment(city: 'Ayutthaya', days: 1, country: 'Thaïlande'),
    ],
    minAnchorDaysToKeep: 1,
    insertionMode: InsertionMode.dayTrip,
    travelLabel: '≈ 1h30 en train depuis Bangkok',
    tags: ['Patrimoine', 'UNESCO', 'Temples'],
    priority: 7,
    whyText:
        'Ancienne capitale du Siam, ruines UNESCO. Excursion d\'1 jour '
        'facile depuis Bangkok.',
  ),

  // ─── Phú Quốc — surveillance, pas de vraie sub-étape ──────────────
  // V1 : pas de suggestions intra-île. Phú Quốc 5 nuits ≈ une vraie étape.
  // Si retour user demande "Sud Phú Quốc / Grand World", ajouter en V2.

  // ─── Extras hors Asie pour amorcer le catalogue ────────────────────
  SubTripSuggestion(
    anchorCity: 'Paris',
    displayName: 'Versailles',
    segments: [
      SuggestedSegment(city: 'Versailles', days: 1, country: 'France'),
    ],
    minAnchorDaysToKeep: 1,
    insertionMode: InsertionMode.dayTrip,
    travelLabel: '≈ 45 min en RER depuis Paris',
    tags: ['Château', 'Patrimoine', 'UNESCO'],
    priority: 8,
    whyText:
        'Château + jardins. Excursion classique d\'1 jour depuis Paris.',
  ),
  SubTripSuggestion(
    anchorCity: 'Tokyo',
    displayName: 'Kyoto',
    segments: [
      SuggestedSegment(city: 'Kyoto', days: 3, country: 'Japon'),
    ],
    minAnchorDaysToKeep: 1,
    insertionMode: InsertionMode.splitSegment,
    travelLabel: '≈ 2h15 en Shinkansen',
    tags: ['Patrimoine', 'Temples', 'Tradition'],
    priority: 10,
    whyText:
        'Ancienne capitale impériale, temples et jardins zen. '
        'Étape incontournable, à combiner avec Tokyo.',
  ),
  SubTripSuggestion(
    anchorCity: 'Tokyo',
    displayName: 'Nikko',
    segments: [
      SuggestedSegment(city: 'Nikko', days: 1, country: 'Japon'),
    ],
    minAnchorDaysToKeep: 1,
    insertionMode: InsertionMode.dayTrip,
    travelLabel: '≈ 2h depuis Tokyo',
    tags: ['Nature', 'Sanctuaires', 'UNESCO'],
    priority: 6,
    whyText:
        'Sanctuaires bouddhistes en forêt + cascades. Excursion d\'1 '
        'jour depuis Tokyo.',
  ),
  SubTripSuggestion(
    anchorCity: 'Madrid',
    displayName: 'Tolède',
    segments: [
      SuggestedSegment(city: 'Tolède', days: 1, country: 'Espagne'),
    ],
    minAnchorDaysToKeep: 1,
    insertionMode: InsertionMode.dayTrip,
    travelLabel: '≈ 30 min en TGV',
    tags: ['Patrimoine', 'UNESCO', 'Médiéval'],
    priority: 8,
    whyText:
        'Cité médiévale fortifiée UNESCO. Excursion d\'1 jour depuis '
        'Madrid.',
  ),
];

/// Normalise un nom de ville pour comparaison (case + diacritiques).
/// Aligné sur le pattern utilisé dans `flight_timeline_builder.dart` /
/// `trip_segment_sync_service.dart`.
String _normalizeCity(String s) {
  const accents = {
    'à': 'a', 'â': 'a', 'ä': 'a', 'á': 'a', 'ã': 'a',
    'ç': 'c',
    'é': 'e', 'è': 'e', 'ê': 'e', 'ë': 'e',
    'í': 'i', 'ï': 'i', 'î': 'i',
    'ñ': 'n',
    'ó': 'o', 'ô': 'o', 'ö': 'o', 'õ': 'o',
    'ú': 'u', 'û': 'u', 'ü': 'u',
    'ý': 'y', 'ÿ': 'y',
  };
  var out = s.toLowerCase().trim();
  accents.forEach((k, v) => out = out.replaceAll(k, v));
  return out;
}

/// Retourne les suggestions disponibles pour une ville d'ancrage donnée,
/// triées par priorité décroissante. Match case+accents-insensible.
/// Liste vide si aucune suggestion connue pour cette ville.
List<SubTripSuggestion> findSuggestionsForAnchor(String anchorCity) {
  final norm = _normalizeCity(anchorCity);
  final hits = _subTripSuggestions
      .where((s) => _normalizeCity(s.anchorCity) == norm)
      .toList()
    ..sort((a, b) => b.priority.compareTo(a.priority));
  return hits;
}

/// Vrai si AU MOINS une ville parmi `cities` a des suggestions connues.
/// Sert au routing : si le voyage a plusieurs segments mais aucun n'a de
/// suggestion catalogue, le flow régions classique reste plus pertinent.
bool hasAnySuggestionsFor(Iterable<String> cities) {
  return cities.any((c) => findSuggestionsForAnchor(c).isNotEmpty);
}
