/// Phase 4 / Tâche 4.4 — `TemplateFirstDayBuilder`.
///
/// **Service pur, dormant.** Transforme un `DayTemplate` +
/// un pool de candidats `TemplateCandidate` en une journée
/// structurée `TemplateDayBuildResult` (slots remplis dans
/// l'ordre du template).
///
/// **Premier composant runtime de la Phase 4**, mais reste
/// déconnecté du pipeline production : aucun import vers
/// `places_first_pipeline.dart` ni vers `day_builder.dart`
/// legacy. Le flag `useDayTemplates` reste OFF et n'est
/// consommé nulle part.
///
/// ## Pourquoi ce nom explicite ?
///
/// Le projet possède déjà `lib/features/planning/services/day_builder.dart`
/// (Day Builder greedy V8.20+). Pour éviter toute confusion :
/// - **`day_builder.dart`** = legacy, slot-first, branché au
///   pipeline.
/// - **`template_first_day_builder.dart`** = nouveau, template-
///   first, dormant (cette tâche).
///
/// Un éventuel `template_first_pipeline.dart` futur (Tâche 4.5+)
/// orchestrera ce builder par journée.
///
/// ## Garanties
///
/// - **Déterministe** : mêmes inputs → même output.
/// - **Insensible à l'ordre** : `candidates` shuffled → même
///   résultat (tri interne stable).
/// - **Jamais crash** : pool vide → résultat avec warnings,
///   pas exception.
/// - **Pas d'appel réseau** : Google Places, Supabase,
///   Gemini = zéro.
/// - **Pas de couplage** : aucun import vers `Trip`,
///   `NearbyCandidate`, `PlaceInfo`. Adapter local
///   `TemplateCandidate`.
///
/// ## Algorithme
///
/// 1. **Filtrage day-level** : exclure les candidats dont
///    `complexKey` ∈ `template.forbiddenComplexKeys`.
/// 2. **Pour chaque slot** dans `template.slots` (ordre du
///    template) :
///    a. Tier 1 : candidats non-utilisés-dans-jour, non-utilisés-
///       cross-trip (place + anchor), catégorie matche.
///    b. Tier 2 : relâcher anchor cross-trip.
///    c. Tier 3 : relâcher catégorie.
///    d. Tier 4 : relâcher `alreadyUsedPlaceKeys` (réutilisation
///       autorisée, warning émis).
///    e. Trier déterministe + pioche premier.
/// 3. **Émettre warnings** : `missingCandidateForSlot`,
///    `missingRecommendedAnchor`, `reusedPlaceDueToNoAlternative`,
///    `reusedAnchorDueToNoAlternative`, `forbiddenComplexFiltered`,
///    `emptyCandidatePool`.
///
/// ## Tri déterministe (cf. spec 4.4)
///
/// Comparator stable :
///   1. anchor match recommandé d'abord (rang 0 vs 1)
///   2. `score` DESC
///   3. `rating` DESC nulls last
///   4. `userRatingCount` DESC nulls last
///   5. `title` ASC
///   6. `placeKey` ASC (tiebreaker final ultime)
library;

import 'package:voyage/models/day_template.dart';

// ─── Adapter local : TemplateCandidate ────────────────────────────────

/// Candidat unitaire pour remplir un slot. **Adapter local
/// minimal** (cf. règle d'or 7) — pas de couplage à
/// `NearbyCandidate` (Google Places) ni `PlaceInfo`. Le caller
/// projette son modèle dans cette structure.
class TemplateCandidate {
  /// Clé unique (typiquement `Google place_id`). Sert à la
  /// dédup intra-jour et cross-trip. Non vide attendu.
  final String placeKey;

  /// Nom user-facing (ex: `"Marina Bay Sands"`). Sert au tri
  /// stable et au debug.
  final String title;

  /// Référence à un `DestinationAnchor.name` si le candidat est
  /// un anchor curé. `null` si non-anchor (resto random, etc.).
  final String? anchorKey;

  /// Référence à un `SameComplexGroup.complexKey` si le candidat
  /// appartient à un complexe identifié. `null` si non.
  final String? complexKey;

  /// Catégorie du candidat. Match exact sur
  /// `ExpectedSlotType.name` (`'anchor'`, `'meal'`, `'shopping'`,
  /// etc.) OU match via synonymes (`'restaurant'` → meal). Cf.
  /// `_categoryMatchesSlot`.
  final String category;

  /// Score éditorial du candidat. Plus haut = priorité au tri.
  final double score;

  /// Note Google (optionnelle).
  final double? rating;

  /// Nombre d'avis Google (optionnel).
  final int? userRatingCount;

  /// Coordonnées WGS-84 (optionnelles, réservées pour usages
  /// futurs — distance vs anchor de zone, etc.).
  final double? lat;
  final double? lng;

  /// Durée estimée de visite en minutes. Si null, le builder
  /// utilise `slot.typicalDurationMinutes` comme fallback.
  final int? estimatedDurationMinutes;

  const TemplateCandidate({
    required this.placeKey,
    required this.title,
    required this.category,
    required this.score,
    this.anchorKey,
    this.complexKey,
    this.rating,
    this.userRatingCount,
    this.lat,
    this.lng,
    this.estimatedDurationMinutes,
  });
}

// ─── Input ────────────────────────────────────────────────────────────

/// Input encapsulé du builder. Tout passe par cette structure
/// pour faciliter l'évolution future (ajout de champs sans
/// breaking change de signature).
class TemplateDayBuildInput {
  final DayTemplate template;
  final DateTime date;
  final int dayIndex;
  final List<TemplateCandidate> candidates;

  /// Optionnel : clé destination si pertinent (debug / cohérence
  /// future).
  final String? destinationKey;

  /// PlaceKeys déjà sélectionnés par le builder dans les jours
  /// précédents du même voyage. Le builder les évite si une
  /// alternative existe (Tier 1-3), les réutilise en dernier
  /// recours (Tier 4 → warning).
  final Set<String> alreadyUsedPlaceKeys;

  /// AnchorKeys déjà consommés dans le voyage. Le builder évite
  /// de re-sélectionner un anchor déjà vu si une alternative
  /// existe (Tier 1 → 2 → 3 relâché).
  final Set<String> alreadyUsedAnchorKeys;

  const TemplateDayBuildInput({
    required this.template,
    required this.date,
    required this.dayIndex,
    required this.candidates,
    this.destinationKey,
    this.alreadyUsedPlaceKeys = const <String>{},
    this.alreadyUsedAnchorKeys = const <String>{},
  });
}

// ─── Warnings ─────────────────────────────────────────────────────────

/// Codes warning stables émis par le builder. Utile pour les
/// logs runtime futurs (Tâche 4.5+) et les tests.
enum TemplateDayBuildWarning {
  /// Pool initial vide ou intégralement filtré.
  emptyCandidatePool,

  /// Au moins un candidat exclu via `forbiddenComplexKeys`.
  forbiddenComplexFiltered,

  /// Slot resté sans candidat (warning émis dans
  /// `TemplateSlotAssignment.warnings`).
  missingCandidateForSlot,

  /// Slot `anchor` rempli mais avec un candidat dont
  /// `anchorKey` n'est pas dans `template.recommendedAnchorKeys`.
  missingRecommendedAnchor,

  /// Slot rempli avec un candidat déjà présent dans
  /// `alreadyUsedPlaceKeys` (réutilisation cross-trip parce
  /// qu'aucune alternative n'existait).
  reusedPlaceDueToNoAlternative,

  /// Slot rempli avec un candidat dont `anchorKey` est déjà
  /// dans `alreadyUsedAnchorKeys` (anchor cross-trip réutilisé
  /// parce qu'aucune alternative n'existait).
  reusedAnchorDueToNoAlternative,
}

// ─── Per-slot result ──────────────────────────────────────────────────

class TemplateSlotAssignment {
  /// Slot concerné (référence directe au `SlotSpec` du template).
  final SlotSpec slot;

  /// Candidat retenu, ou `null` si slot resté vide.
  final TemplateCandidate? candidate;

  /// Durée effective utilisée pour ce slot :
  /// `candidate.estimatedDurationMinutes` si non null, sinon
  /// `slot.typicalDurationMinutes` (fallback).
  final int effectiveDurationMinutes;

  /// Warnings spécifiques à ce slot.
  final List<TemplateDayBuildWarning> warnings;

  const TemplateSlotAssignment({
    required this.slot,
    required this.candidate,
    required this.effectiveDurationMinutes,
    this.warnings = const <TemplateDayBuildWarning>[],
  });

  bool get isEmpty => candidate == null;
}

// ─── Day result ───────────────────────────────────────────────────────

class TemplateDayBuildResult {
  final DateTime date;
  final int dayIndex;
  final String templateKey;
  final List<TemplateSlotAssignment> assignments;

  /// Warnings day-level (`emptyCandidatePool`,
  /// `forbiddenComplexFiltered`). Les warnings per-slot vivent
  /// dans `assignments[i].warnings`.
  final List<TemplateDayBuildWarning> warnings;

  /// `true` si le résultat est jugé "dégradé" :
  ///   - pool initial vide, OU
  ///   - plus de la moitié des slots sont vides.
  final bool isFallback;

  const TemplateDayBuildResult({
    required this.date,
    required this.dayIndex,
    required this.templateKey,
    required this.assignments,
    required this.warnings,
    required this.isFallback,
  });

  /// Validation simple du résultat. Retourne `List<String>` agrégée
  /// (vide = OK). Cohérent style modèles existants.
  List<String> validate() {
    final errors = <String>[];
    if (assignments.isEmpty) {
      errors.add('assignments must be non-empty');
    }
    // Pas de duplication de placeKey intra-jour.
    final seenKeys = <String>{};
    for (var i = 0; i < assignments.length; i++) {
      final a = assignments[i];
      if (a.candidate != null) {
        if (!seenKeys.add(a.candidate!.placeKey)) {
          errors.add(
              'assignments[$i].candidate.placeKey '
              '"${a.candidate!.placeKey}" duplicated within day');
        }
      }
    }
    return errors;
  }

  /// Convenience : nombre de slots remplis (candidate non null).
  int get filledSlotsCount =>
      assignments.where((a) => a.candidate != null).length;
}

// ─── API publique ─────────────────────────────────────────────────────

/// Construit une journée à partir d'un template + un pool de
/// candidats. Voir doc de tête pour la stratégie.
///
/// **Jamais throw** : un pool vide ou des slots non remplis
/// produisent un résultat avec warnings, pas une exception.
TemplateDayBuildResult buildTemplateFirstDay(TemplateDayBuildInput input) {
  final template = input.template;
  final candidates = input.candidates;
  final recommendedAnchorsNorm = template.recommendedAnchorKeys
      .map((s) => s.trim().toLowerCase())
      .toSet();
  final forbiddenComplexesNorm = template.forbiddenComplexKeys
      .map((s) => s.trim().toLowerCase())
      .toSet();
  final alreadyUsedPlaceKeys = input.alreadyUsedPlaceKeys;
  final alreadyUsedAnchorKeys = input.alreadyUsedAnchorKeys;

  final dayWarnings = <TemplateDayBuildWarning>[];

  // ── 1. Filtrage day-level forbidden complexes ─────────────────────
  final notForbidden = <TemplateCandidate>[];
  for (final c in candidates) {
    final complexNorm = c.complexKey?.trim().toLowerCase();
    if (complexNorm != null &&
        forbiddenComplexesNorm.contains(complexNorm)) {
      continue;
    }
    notForbidden.add(c);
  }
  if (notForbidden.length < candidates.length) {
    dayWarnings.add(TemplateDayBuildWarning.forbiddenComplexFiltered);
  }

  // ── Cas pool vide ─────────────────────────────────────────────────
  if (notForbidden.isEmpty) {
    if (!dayWarnings.contains(TemplateDayBuildWarning.emptyCandidatePool)) {
      dayWarnings.add(TemplateDayBuildWarning.emptyCandidatePool);
    }
    final emptyAssignments = template.slots
        .map((slot) => TemplateSlotAssignment(
              slot: slot,
              candidate: null,
              effectiveDurationMinutes: slot.typicalDurationMinutes,
              warnings: const [
                TemplateDayBuildWarning.missingCandidateForSlot
              ],
            ))
        .toList();
    return TemplateDayBuildResult(
      date: input.date,
      dayIndex: input.dayIndex,
      templateKey: template.templateKey,
      assignments: emptyAssignments,
      warnings: dayWarnings,
      isFallback: true,
    );
  }

  // ── 2. Walk slots dans l'ordre ────────────────────────────────────
  final assignments = <TemplateSlotAssignment>[];
  final selectedThisDay = <String>{}; // placeKey set intra-jour

  for (final slot in template.slots) {
    final eligible = notForbidden
        .where((c) => !selectedThisDay.contains(c.placeKey))
        .toList();

    if (eligible.isEmpty) {
      assignments.add(TemplateSlotAssignment(
        slot: slot,
        candidate: null,
        effectiveDurationMinutes: slot.typicalDurationMinutes,
        warnings: const [TemplateDayBuildWarning.missingCandidateForSlot],
      ));
      continue;
    }

    // Cascading tier filter — du plus strict au plus relâché.
    // Tier 1 : category match + not used place + not used anchor.
    var tier = _filterTier(
      eligible,
      slot: slot,
      alreadyUsedPlaceKeys: alreadyUsedPlaceKeys,
      alreadyUsedAnchorKeys: alreadyUsedAnchorKeys,
      checkCategory: true,
      checkAlreadyUsedPlace: true,
      checkAlreadyUsedAnchor: true,
    );

    // Tier 2 : relax anchor cross-trip.
    if (tier.isEmpty) {
      tier = _filterTier(
        eligible,
        slot: slot,
        alreadyUsedPlaceKeys: alreadyUsedPlaceKeys,
        alreadyUsedAnchorKeys: alreadyUsedAnchorKeys,
        checkCategory: true,
        checkAlreadyUsedPlace: true,
        checkAlreadyUsedAnchor: false,
      );
    }
    // Tier 3 : relax category.
    if (tier.isEmpty) {
      tier = _filterTier(
        eligible,
        slot: slot,
        alreadyUsedPlaceKeys: alreadyUsedPlaceKeys,
        alreadyUsedAnchorKeys: alreadyUsedAnchorKeys,
        checkCategory: false,
        checkAlreadyUsedPlace: true,
        checkAlreadyUsedAnchor: false,
      );
    }
    // Tier 4 : relax alreadyUsedPlaceKeys (réutilisation autorisée).
    if (tier.isEmpty) {
      tier = eligible;
    }

    // Tri déterministe + pioche.
    tier.sort((a, b) => _compareCandidate(a, b, recommendedAnchorsNorm));
    final pick = tier.first;

    // Émettre warnings selon le pick final.
    final slotWarnings = <TemplateDayBuildWarning>[];
    if (alreadyUsedPlaceKeys.contains(pick.placeKey)) {
      slotWarnings
          .add(TemplateDayBuildWarning.reusedPlaceDueToNoAlternative);
    }
    if (pick.anchorKey != null &&
        alreadyUsedAnchorKeys.contains(pick.anchorKey)) {
      slotWarnings
          .add(TemplateDayBuildWarning.reusedAnchorDueToNoAlternative);
    }
    if (slot.expectedType == ExpectedSlotType.anchor) {
      final anchorMatchesRecommended = pick.anchorKey != null &&
          recommendedAnchorsNorm
              .contains(pick.anchorKey!.trim().toLowerCase());
      if (!anchorMatchesRecommended) {
        slotWarnings
            .add(TemplateDayBuildWarning.missingRecommendedAnchor);
      }
    }

    assignments.add(TemplateSlotAssignment(
      slot: slot,
      candidate: pick,
      effectiveDurationMinutes:
          pick.estimatedDurationMinutes ?? slot.typicalDurationMinutes,
      warnings: slotWarnings,
    ));
    selectedThisDay.add(pick.placeKey);
  }

  // ── isFallback : > 50% slots vides ────────────────────────────────
  final emptyCount =
      assignments.where((a) => a.candidate == null).length;
  final isFallback = emptyCount > assignments.length / 2;

  return TemplateDayBuildResult(
    date: input.date,
    dayIndex: input.dayIndex,
    templateKey: template.templateKey,
    assignments: assignments,
    warnings: dayWarnings,
    isFallback: isFallback,
  );
}

// ─── Helpers privés ───────────────────────────────────────────────────

List<TemplateCandidate> _filterTier(
  List<TemplateCandidate> base, {
  required SlotSpec slot,
  required Set<String> alreadyUsedPlaceKeys,
  required Set<String> alreadyUsedAnchorKeys,
  required bool checkCategory,
  required bool checkAlreadyUsedPlace,
  required bool checkAlreadyUsedAnchor,
}) {
  return base.where((c) {
    if (checkCategory && !_categoryMatchesSlot(c.category, slot.expectedType)) {
      return false;
    }
    if (checkAlreadyUsedPlace &&
        alreadyUsedPlaceKeys.contains(c.placeKey)) {
      return false;
    }
    if (checkAlreadyUsedAnchor &&
        c.anchorKey != null &&
        alreadyUsedAnchorKeys.contains(c.anchorKey)) {
      return false;
    }
    return true;
  }).toList();
}

/// Tri déterministe stable conforme à la spec :
///   1. anchor match recommandé (rang 0 = match, 1 = sinon)
///   2. score DESC
///   3. rating DESC nulls last
///   4. userRatingCount DESC nulls last
///   5. title ASC
///   6. placeKey ASC (tiebreaker ultime)
int _compareCandidate(
  TemplateCandidate a,
  TemplateCandidate b,
  Set<String> recommendedAnchorsNorm,
) {
  // 1. Anchor recommended match.
  final aMatch = a.anchorKey != null &&
          recommendedAnchorsNorm
              .contains(a.anchorKey!.trim().toLowerCase())
      ? 0
      : 1;
  final bMatch = b.anchorKey != null &&
          recommendedAnchorsNorm
              .contains(b.anchorKey!.trim().toLowerCase())
      ? 0
      : 1;
  if (aMatch != bMatch) return aMatch.compareTo(bMatch);

  // 2. score DESC.
  final scoreCmp = b.score.compareTo(a.score);
  if (scoreCmp != 0) return scoreCmp;

  // 3. rating DESC nulls last (null = -inf).
  final aRating = a.rating ?? double.negativeInfinity;
  final bRating = b.rating ?? double.negativeInfinity;
  final ratingCmp = bRating.compareTo(aRating);
  if (ratingCmp != 0) return ratingCmp;

  // 4. userRatingCount DESC nulls last (null = -1).
  final aReviews = a.userRatingCount ?? -1;
  final bReviews = b.userRatingCount ?? -1;
  final reviewsCmp = bReviews.compareTo(aReviews);
  if (reviewsCmp != 0) return reviewsCmp;

  // 5. title ASC.
  final titleCmp = a.title.compareTo(b.title);
  if (titleCmp != 0) return titleCmp;

  // 6. placeKey ASC (tiebreaker final).
  return a.placeKey.compareTo(b.placeKey);
}

/// Matching catégorie ↔ `ExpectedSlotType` :
///   - `freeTime` : matche tout
///   - exact : `category == expectedType.name`
///   - synonymes (Google Places-style) : table interne
bool _categoryMatchesSlot(String category, ExpectedSlotType expectedType) {
  if (expectedType == ExpectedSlotType.freeTime) return true;
  final norm = category.trim().toLowerCase();
  if (norm == expectedType.name.toLowerCase()) return true;
  final synonyms =
      _kCategorySynonyms[expectedType] ?? const <String>{};
  return synonyms.contains(norm);
}

/// Table interne de synonymes catégorie. Pragmatique, étendue
/// au besoin (Tâche 4.5+).
const Map<ExpectedSlotType, Set<String>> _kCategorySynonyms = {
  ExpectedSlotType.anchor: {
    'tourist_attraction',
    'landmark',
    'monument',
    'point_of_interest',
  },
  ExpectedSlotType.visit: {
    'tourist_attraction',
    'museum',
    'park',
    'point_of_interest',
    'landmark',
  },
  ExpectedSlotType.meal: {
    'restaurant',
    'cafe',
    'food',
    'food_court',
  },
  ExpectedSlotType.rest: {
    'park',
    'cafe',
  },
  ExpectedSlotType.shopping: {
    'shopping_mall',
    'market',
    'store',
  },
  ExpectedSlotType.viewpoint: {
    'observation_deck',
    'tower',
  },
  ExpectedSlotType.show: {
    'performance',
    'event',
    'theater',
  },
  ExpectedSlotType.transfer: {
    'transport',
  },
  // freeTime intentionnellement absent — la règle "match tout"
  // dans `_categoryMatchesSlot` couvre ce cas.
};
