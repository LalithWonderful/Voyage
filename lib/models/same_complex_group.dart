/// Phase 2 / Tâche 2.1 — Modèle de données `SameComplexGroup`.
///
/// Schéma + validation + sérialisation JSON + normalisation
/// UNIQUEMENT. Cette tâche NE crée aucune donnée Singapour (Tâche
/// 2.2), NE branche RIEN au pipeline et NE consomme PAS le flag
/// `useSameComplexDedup`. Conforme aux règles d'or 1 (*"Ne JAMAIS
/// casser le pipeline existant"*) et 5 (*"Tests dans le même
/// commit que la production"*).
///
/// ## Problème adressé (à terme — pas Tâche 2.1)
///
/// Plusieurs entrées Google Places différentes peuvent appartenir
/// au même complexe touristique pour un voyageur :
///   - Sentosa Island / Universal Studios Singapore / Resorts World
///     Sentosa / Singapore Oceanarium / Wings of Time
///   - Gardens by the Bay / Supertree Grove / Cloud Forest / Flower
///     Dome
///   - Marina Bay Sands / SkyPark Observation Deck / The Shoppes
///
/// La dédup `iconic`/`name_clusters` existante (V8.28b1.x) n'attrape
/// pas ces cas car les `place_id` et noms diffèrent vraiment.
///
/// `SameComplexGroup` permettra (Tâche 2.3+) de :
///   - matcher un candidat (par `placeId` ou nom normalisé) à son
///     complexe ;
///   - appliquer des caps `max_per_day` / `max_per_trip` sur ce
///     complexe au sélecteur déterministe (Tâche 2.4) ;
///   - prioriser entre candidats du même complexe via `priority`.
///
/// ## Convention JSON
///
/// `snake_case` pour cohérence avec les modèles existants
/// (`DestinationIntelligence`, `activity_suggestion_model.dart`,
/// etc.). Cf. `lib/models/destination_intelligence.dart` pour la
/// référence.
///
/// ## Validation
///
/// `validate()` retourne `List<String>` — vide = OK, sinon liste
/// agrégée d'erreurs. Même style que `DestinationIntelligence`.
library;

/// Normalise une chaîne pour matching d'alias.
///
/// Comportement :
///   1. `toLowerCase`
///   2. remplacement des accents courants (NFD-light interne, pas
///      de dépendance `package:characters` lourde)
///   3. remplacement de la ponctuation par un espace
///   4. collapse des espaces multiples
///   5. trim
///
/// Idempotent : `normalizeComplexText(normalizeComplexText(s)) ==
/// normalizeComplexText(s)`.
///
/// Exemples :
///   - `"SENTOSA ISLAND"`        → `"sentosa island"`
///   - `"Sentosa   Island"`      → `"sentosa island"`
///   - `"Musée d'Orsay"`         → `"musee d orsay"`
///   - `"Gardens-by-the Bay!"`   → `"gardens by the bay"`
///   - `"  Café  Niçois  "`      → `"cafe nicois"`
///
/// Utilisé par `SameComplexGroup.matchesAlias` et (à terme) par le
/// matcher de Tâche 2.3. Maintenu top-level pour pouvoir être
/// testé directement et réutilisé sans instancier un groupe.
String normalizeComplexText(String value) {
  var s = value.toLowerCase().trim();
  if (s.isEmpty) return s;

  // Step 1 — accents courants (latin extended-A subset).
  // Liste compacte et explicite ; aucune dépendance externe. Couvre
  // les cas pratiques attendus dans les noms touristiques (fr, es,
  // pt, de, it, scandinave).
  const Map<String, String> accentMap = {
    'à': 'a', 'á': 'a', 'â': 'a', 'ã': 'a', 'ä': 'a', 'å': 'a', 'ā': 'a',
    'è': 'e', 'é': 'e', 'ê': 'e', 'ë': 'e', 'ē': 'e',
    'ì': 'i', 'í': 'i', 'î': 'i', 'ï': 'i', 'ī': 'i',
    'ò': 'o', 'ó': 'o', 'ô': 'o', 'õ': 'o', 'ö': 'o', 'ø': 'o', 'ō': 'o',
    'ù': 'u', 'ú': 'u', 'û': 'u', 'ü': 'u', 'ū': 'u',
    'ý': 'y', 'ÿ': 'y',
    'ç': 'c', 'č': 'c', 'ć': 'c',
    'ñ': 'n', 'ń': 'n',
    'š': 's', 'ś': 's',
    'ž': 'z', 'ź': 'z', 'ż': 'z',
    'ł': 'l',
    'æ': 'ae', 'œ': 'oe', 'ß': 'ss',
  };
  final buf = StringBuffer();
  for (final ch in s.split('')) {
    buf.write(accentMap[ch] ?? ch);
  }
  s = buf.toString();

  // Step 2 — toute non-alphanumérique (lettres/chiffres ASCII)
  // devient un espace. Cohérent avec la spec : ponctuation,
  // apostrophes et tirets ne doivent pas empêcher un match.
  s = s.replaceAll(RegExp(r'[^a-z0-9]+'), ' ');

  // Step 3 — collapse + trim.
  s = s.replaceAll(RegExp(r'\s+'), ' ').trim();
  return s;
}

/// Groupe d'entrées Google Places qui appartiennent au même
/// complexe touristique pour un voyageur. Immutable.
///
/// Identifié par `(destinationKey, complexKey)` (cf. PK SQL Tâche
/// 2.1). Un même complexKey peut exister pour plusieurs
/// destinations (ex: `central_park` pour `new_york` ≠ pour une
/// hypothétique homonymie).
class SameComplexGroup {
  /// Identifiant stable du complexe, `lowercase snake_case`. Non
  /// vide. Pas d'espace, pas de caractères spéciaux.
  ///
  /// Exemples futurs : `"sentosa"`, `"gardens_by_the_bay"`,
  /// `"marina_bay_sands"`.
  final String complexKey;

  /// Destination parente (cohérent avec
  /// `DestinationIntelligence.destinationKey`). Non vide,
  /// `lowercase snake_case` recommandé.
  final String destinationKey;

  /// Noms / variations utilisés pour le matching textuel. Au moins
  /// une entrée non vide. La comparaison passe par
  /// `normalizeComplexText` — les variantes peuvent être stockées
  /// "lisibles" (ex: `"Sentosa Island"`).
  final List<String> aliases;

  /// Google `place_id` connus appartenant au complexe. Peut être
  /// vide (matching par alias seul). Comparaison exacte après
  /// `trim` (les place_ids sont case-sensitive côté Google).
  final List<String> placeIds;

  /// Cap max de visites du complexe sur une même journée. ≥ 1.
  /// Default `1` (un seul slot Sentosa par jour, etc.).
  final int maxPerDay;

  /// Cap max de visites du complexe sur l'ensemble du voyage.
  /// ≥ `maxPerDay` et ≥ 1. Default `2` (autorise un retour, sans
  /// monopoliser le voyage).
  final int maxPerTrip;

  /// Priorité éditoriale dans [1, 5]. 5 = iconique (à ne pas
  /// rater), 1 = anecdotique. Servira au sélecteur (Tâche 2.4)
  /// pour départager des candidats du même complexe.
  final int priority;

  static const int defaultMaxPerDay = 1;
  static const int defaultMaxPerTrip = 2;
  static const int defaultPriority = 3;
  static const int minPriority = 1;
  static const int maxPriority = 5;

  const SameComplexGroup({
    required this.complexKey,
    required this.destinationKey,
    required this.aliases,
    this.placeIds = const <String>[],
    this.maxPerDay = defaultMaxPerDay,
    this.maxPerTrip = defaultMaxPerTrip,
    this.priority = defaultPriority,
  });

  /// Valide tous les champs et retourne la liste agrégée d'erreurs
  /// (vide = OK).
  List<String> validate() {
    final errors = <String>[];

    if (complexKey.trim().isEmpty) {
      errors.add('complex_key must be non-empty');
    } else if (complexKey != complexKey.trim() ||
        RegExp(r'\s').hasMatch(complexKey)) {
      errors.add('complex_key must not contain whitespace, got "$complexKey"');
    }

    if (destinationKey.trim().isEmpty) {
      errors.add('destination_key must be non-empty');
    }

    if (aliases.isEmpty) {
      errors.add('aliases must have at least one entry');
    } else {
      for (var i = 0; i < aliases.length; i++) {
        if (aliases[i].trim().isEmpty) {
          errors.add('aliases[$i] must be non-empty');
        }
      }
      // Doublons après normalisation.
      final seen = <String>{};
      for (var i = 0; i < aliases.length; i++) {
        final normalized = normalizeComplexText(aliases[i]);
        if (normalized.isEmpty) continue; // déjà signalé ci-dessus
        if (!seen.add(normalized)) {
          errors.add(
              'aliases[$i] duplicates a previous alias after normalization '
              '("$normalized")');
        }
      }
    }

    // placeIds : peut être vide. Si présent, chaque entrée non vide
    // et pas de doublons après trim.
    final seenIds = <String>{};
    for (var i = 0; i < placeIds.length; i++) {
      final trimmed = placeIds[i].trim();
      if (trimmed.isEmpty) {
        errors.add('place_ids[$i] must be non-empty');
        continue;
      }
      if (!seenIds.add(trimmed)) {
        errors.add('place_ids[$i] duplicates a previous place_id '
            '("$trimmed")');
      }
    }

    if (maxPerDay < 1) {
      errors.add('max_per_day must be >= 1, got $maxPerDay');
    }
    if (maxPerTrip < 1) {
      errors.add('max_per_trip must be >= 1, got $maxPerTrip');
    }
    if (maxPerTrip < maxPerDay) {
      errors.add(
          'max_per_trip ($maxPerTrip) must be >= max_per_day ($maxPerDay)');
    }
    if (priority < minPriority || priority > maxPriority) {
      errors.add(
          'priority must be in [$minPriority, $maxPriority], got $priority');
    }

    return errors;
  }

  /// True si `validate()` est vide.
  bool get isValid => validate().isEmpty;

  /// True si `candidateName` matche l'un des `aliases` après
  /// normalisation. Fait pour rester volontairement simple :
  ///   - normalisation des 2 côtés
  ///   - comparaison d'égalité stricte
  ///
  /// Le fuzzy matching (préfixe / substring / Levenshtein) est
  /// hors scope Tâche 2.1 — il appartient au matcher (Tâche 2.3).
  bool matchesAlias(String candidateName) {
    final normalized = normalizeComplexText(candidateName);
    if (normalized.isEmpty) return false;
    for (final alias in aliases) {
      if (normalizeComplexText(alias) == normalized) return true;
    }
    return false;
  }

  /// True si `placeId` (trimmed) est présent dans `placeIds`.
  /// Match exact case-sensitive (cohérent avec le format Google).
  bool containsPlaceId(String placeId) {
    final trimmed = placeId.trim();
    if (trimmed.isEmpty) return false;
    for (final id in placeIds) {
      if (id.trim() == trimmed) return true;
    }
    return false;
  }

  Map<String, dynamic> toJson() => {
        'complex_key': complexKey,
        'destination_key': destinationKey,
        'aliases': aliases,
        'place_ids': placeIds,
        'max_per_day': maxPerDay,
        'max_per_trip': maxPerTrip,
        'priority': priority,
      };

  factory SameComplexGroup.fromJson(Map<String, dynamic> json) {
    final complexKey = json['complex_key'];
    if (complexKey is! String) {
      throw const FormatException(
          'SameComplexGroup.complex_key must be a string');
    }
    final destinationKey = json['destination_key'];
    if (destinationKey is! String) {
      throw const FormatException(
          'SameComplexGroup.destination_key must be a string');
    }
    final aliasesRaw = json['aliases'];
    if (aliasesRaw is! List) {
      throw const FormatException(
          'SameComplexGroup.aliases must be a list');
    }
    final placeIdsRaw = json['place_ids'];
    final maxPerDayRaw = json['max_per_day'];
    final maxPerTripRaw = json['max_per_trip'];
    final priorityRaw = json['priority'];

    return SameComplexGroup(
      complexKey: complexKey,
      destinationKey: destinationKey,
      aliases: aliasesRaw.whereType<String>().toList(),
      placeIds: placeIdsRaw is List
          ? placeIdsRaw.whereType<String>().toList()
          : const <String>[],
      maxPerDay: maxPerDayRaw is int ? maxPerDayRaw : defaultMaxPerDay,
      maxPerTrip: maxPerTripRaw is int ? maxPerTripRaw : defaultMaxPerTrip,
      priority: priorityRaw is int ? priorityRaw : defaultPriority,
    );
  }
}
