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
///   2. **zone primary bucket ASC** (4.7 — 0 ≤ 2km, 1 ∈ ]2,5]km,
///      2 ∈ ]5,10]km, 3 = no-coord ou no-zone). Bypass si pas
///      de `primaryZoneCenter` fourni.
///   3. `score` DESC
///   4. `rating` DESC nulls last
///   5. `userRatingCount` DESC nulls last
///   6. `title` ASC
///   7. `placeKey` ASC (tiebreaker final ultime)
///
/// ## Stabilisation 4.7 (cf. `docs/migrations/phase4_task4_7.md`)
///
/// 4 axes ajoutés au-dessus de la base 4.4 :
///   1. **Anti-zigzag / zone primaire** : si `primaryZoneCenter`
///      fourni, distance haversine > 10 km rejetée sauf anchor
///      recommandé ; bucket de zone injecté en critère de tri 2.
///   2. **Respect `freeTime`** : slot `ExpectedSlotType.freeTime`
///      reste vide volontairement (pas de warning
///      `missingCandidateForSlot`). N'entre pas dans le calcul
///      `isFallback`.
///   3. **Quality floor** : pour slots non-meal et non-rest,
///      rejet des candidats `rating < 4.0` OU `reviews < 50`,
///      sauf si `anchorKey` ∈ `recommendedAnchorKeys`.
///   4. **Hawker / food-centre block en visit** : substring match
///      sur `title` rejette les centres food en slots non-meal
///      (`hawker centre`, `food centre`, `food court`, etc.).
///      Autorisés en slot `meal`.
library;

import 'dart:math' as math;

import 'package:voyage/models/day_template.dart';
import 'package:voyage/models/destination_intelligence.dart' show GeoPoint;

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

  /// 4.7 — Centre canonique de la zone primaire du template
  /// (résolu par le caller via `di.zones` à partir de
  /// `template.primaryZoneName`). Drives l'axe anti-zigzag :
  /// rejet > 10 km sauf anchor recommandé, bucket de zone injecté
  /// en critère de tri 2.
  ///
  /// **Optionnel** : si `null`, l'axe anti-zigzag est en bypass
  /// complet (rétro-compatible avec les tests Phase 4.4/4.5).
  final GeoPoint? primaryZoneCenter;

  const TemplateDayBuildInput({
    required this.template,
    required this.date,
    required this.dayIndex,
    required this.candidates,
    this.destinationKey,
    this.alreadyUsedPlaceKeys = const <String>{},
    this.alreadyUsedAnchorKeys = const <String>{},
    this.primaryZoneCenter,
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

  // ── 4.7 — Pré-filtre anti-zigzag (Axe 1) ──────────────────────────
  // Si `primaryZoneCenter` fourni : rejet > 10 km, sauf si le
  // candidat est un anchor recommandé du template (compromis :
  // un anchor recommandé hors zone reste acceptable, c'est le
  // choix éditorial du template). Si aucun centre fourni →
  // bypass complet (rétro-compat).
  final zoneCenter = input.primaryZoneCenter;
  final afterZoneReject = <TemplateCandidate>[];
  if (zoneCenter != null) {
    for (final c in notForbidden) {
      final isRecommendedAnchor = c.anchorKey != null &&
          recommendedAnchorsNorm
              .contains(c.anchorKey!.trim().toLowerCase());
      if (isRecommendedAnchor) {
        afterZoneReject.add(c);
        continue;
      }
      final dKm = _candidateDistanceKm(c, zoneCenter);
      if (dKm == null || dKm <= _kZoneRejectKm) {
        afterZoneReject.add(c);
      }
    }
  } else {
    afterZoneReject.addAll(notForbidden);
  }

  // ── 2. Walk slots dans l'ordre ────────────────────────────────────
  final assignments = <TemplateSlotAssignment>[];
  final selectedThisDay = <String>{}; // placeKey set intra-jour

  for (final slot in template.slots) {
    // 4.7 — Axe 2 : freeTime reste volontairement vide. Pas de
    // pioche, pas de warning. N'entre pas dans le compte
    // `isFallback`.
    if (slot.expectedType == ExpectedSlotType.freeTime) {
      assignments.add(TemplateSlotAssignment(
        slot: slot,
        candidate: null,
        effectiveDurationMinutes: slot.typicalDurationMinutes,
        warnings: const <TemplateDayBuildWarning>[],
      ));
      continue;
    }

    final eligible = afterZoneReject
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
      recommendedAnchorsNorm: recommendedAnchorsNorm,
      checkCategory: true,
      checkAlreadyUsedPlace: true,
      checkAlreadyUsedAnchor: true,
      applyQualityFloor: true,
      applyVisitNameBlock: true,
    );

    // Tier 2 : relax anchor cross-trip.
    if (tier.isEmpty) {
      tier = _filterTier(
        eligible,
        slot: slot,
        alreadyUsedPlaceKeys: alreadyUsedPlaceKeys,
        alreadyUsedAnchorKeys: alreadyUsedAnchorKeys,
        recommendedAnchorsNorm: recommendedAnchorsNorm,
        checkCategory: true,
        checkAlreadyUsedPlace: true,
        checkAlreadyUsedAnchor: false,
        applyQualityFloor: true,
        applyVisitNameBlock: true,
      );
    }
    // Tier 3 : relax category.
    if (tier.isEmpty) {
      tier = _filterTier(
        eligible,
        slot: slot,
        alreadyUsedPlaceKeys: alreadyUsedPlaceKeys,
        alreadyUsedAnchorKeys: alreadyUsedAnchorKeys,
        recommendedAnchorsNorm: recommendedAnchorsNorm,
        checkCategory: false,
        checkAlreadyUsedPlace: true,
        checkAlreadyUsedAnchor: false,
        applyQualityFloor: true,
        applyVisitNameBlock: true,
      );
    }
    // Tier 4 : relax quality floor + visit name block (mais
    // recommendedAnchor reste exempt par construction du filtre).
    if (tier.isEmpty) {
      tier = _filterTier(
        eligible,
        slot: slot,
        alreadyUsedPlaceKeys: alreadyUsedPlaceKeys,
        alreadyUsedAnchorKeys: alreadyUsedAnchorKeys,
        recommendedAnchorsNorm: recommendedAnchorsNorm,
        checkCategory: false,
        checkAlreadyUsedPlace: true,
        checkAlreadyUsedAnchor: false,
        applyQualityFloor: false,
        applyVisitNameBlock: false,
      );
    }
    // Tier 5 : relax alreadyUsedPlaceKeys (réutilisation autorisée).
    if (tier.isEmpty) {
      tier = eligible;
    }

    // Tri déterministe + pioche.
    tier.sort((a, b) =>
        _compareCandidate(a, b, recommendedAnchorsNorm, zoneCenter));
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

  // ── isFallback : > 50% slots NON-freeTime vides ───────────────────
  // 4.7 — Axe 2 : les slots `freeTime` volontairement vides ne
  // sont pas comptés dans le ratio (sinon `free_day` serait
  // toujours `isFallback`).
  final nonFreeSlots = assignments
      .where((a) => a.slot.expectedType != ExpectedSlotType.freeTime)
      .toList();
  final emptyCount =
      nonFreeSlots.where((a) => a.candidate == null).length;
  final isFallback =
      nonFreeSlots.isNotEmpty && emptyCount > nonFreeSlots.length / 2;

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

// ─── 4.7 — Constantes de stabilisation ────────────────────────────────

/// Anti-zigzag — Axe 1 :
/// - ≤ 2 km du centre de zone primaire : bucket 0 (très bon).
/// - ]2, 5] km : bucket 1 (ok).
/// - ]5, 10] km : bucket 2 (déprioriser fort).
/// - > 10 km : rejet sauf anchor recommandé.
/// - no-coord ou no-zone-center : bucket 3 (neutre, départage
///   passe au score).
const double _kZoneNearKm = 2.0;
const double _kZoneFarKm = 5.0;
const double _kZoneRejectKm = 10.0;

/// Quality floor — Axe 3. Appliqué uniquement aux slots
/// non-meal et non-rest. Exception : anchor recommandé du
/// template échappe au filtre.
const double _kMinRatingForVisit = 4.0;
const int _kMinReviewsForVisit = 50;

/// Hawker / food-centre block — Axe 4. Substrings comparées
/// case-insensitive sur `candidate.title`. Bloque en slot
/// non-meal. En slot `meal`, ces lieux sont au contraire les
/// bienvenus (hawker centre = expérience food structurante).
///
/// Liste intentionnellement courte : on bloque les indicateurs
/// génériques (« hawker centre », « food centre », « food court »)
/// et quelques noms de hawker emblématiques de Singapour qui ont
/// été observés comme rejets en V8.28b1 (cf. A/B 4.6). Pas de
/// liste exhaustive — c'est le moteur, pas un catalogue.
const List<String> _kVisitBlockedNamePatterns = <String>[
  'hawker centre',
  'hawker center',
  'food centre',
  'food center',
  'food court',
  'lau pa sat',
  'maxwell food centre',
  'maxwell food center',
  'hong lim food centre',
  'hong lim market',
  'tekka centre',
  'tekka market',
];

/// Distance haversine en km entre `c` et `center`. Retourne
/// `null` si le candidat n'a pas de coordonnées (pas pénalisé,
/// pas favorisé — c'est l'absence d'information).
double? _candidateDistanceKm(TemplateCandidate c, GeoPoint center) {
  if (c.lat == null || c.lng == null) return null;
  return _haversineKm(c.lat!, c.lng!, center.lat, center.lng);
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

/// Bucket de tri zone (0 = très proche, 3 = inconnu). Sert le
/// critère 2 du comparator. `null` zoneCenter ou null coords →
/// bucket 3 (neutre).
int _zoneBucket(TemplateCandidate c, GeoPoint? zoneCenter) {
  if (zoneCenter == null) return 3;
  final dKm = _candidateDistanceKm(c, zoneCenter);
  if (dKm == null) return 3;
  if (dKm <= _kZoneNearKm) return 0;
  if (dKm <= _kZoneFarKm) return 1;
  if (dKm <= _kZoneRejectKm) return 2;
  // > 10 km est censé être rejeté en amont (axe 1 pré-filtre)
  // sauf si anchor recommandé : on retombe en bucket 2 pour ce
  // cas (déprioriser fort mais accepter pour ne pas perdre
  // l'anchor du template).
  return 2;
}

/// 4.7 — Axe 3 quality floor : rejet si rating ou reviews
/// sous le seuil. Exempté pour anchor recommandé.
bool _passesQualityFloor(
  TemplateCandidate c,
  SlotSpec slot,
  Set<String> recommendedAnchorsNorm,
) {
  if (slot.expectedType == ExpectedSlotType.meal ||
      slot.expectedType == ExpectedSlotType.rest) {
    return true;
  }
  final isRecommendedAnchor = c.anchorKey != null &&
      recommendedAnchorsNorm
          .contains(c.anchorKey!.trim().toLowerCase());
  if (isRecommendedAnchor) return true;
  if (c.rating != null && c.rating! < _kMinRatingForVisit) return false;
  if (c.userRatingCount != null &&
      c.userRatingCount! < _kMinReviewsForVisit) {
    return false;
  }
  return true;
}

/// 4.7 — Axe 4 hawker / food-centre block en visit. Bloque
/// les centres food en slots non-meal. Retourne `true` si le
/// candidat passe (n'est PAS bloqué).
bool _passesVisitNameBlock(TemplateCandidate c, SlotSpec slot) {
  if (slot.expectedType == ExpectedSlotType.meal) return true;
  final titleLower = c.title.toLowerCase();
  for (final pattern in _kVisitBlockedNamePatterns) {
    if (titleLower.contains(pattern)) return false;
  }
  return true;
}

List<TemplateCandidate> _filterTier(
  List<TemplateCandidate> base, {
  required SlotSpec slot,
  required Set<String> alreadyUsedPlaceKeys,
  required Set<String> alreadyUsedAnchorKeys,
  required Set<String> recommendedAnchorsNorm,
  required bool checkCategory,
  required bool checkAlreadyUsedPlace,
  required bool checkAlreadyUsedAnchor,
  required bool applyQualityFloor,
  required bool applyVisitNameBlock,
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
    if (applyQualityFloor &&
        !_passesQualityFloor(c, slot, recommendedAnchorsNorm)) {
      return false;
    }
    if (applyVisitNameBlock && !_passesVisitNameBlock(c, slot)) {
      return false;
    }
    return true;
  }).toList();
}

/// Tri déterministe stable conforme à la spec étendue 4.7 :
///   1. anchor match recommandé (rang 0 = match, 1 = sinon)
///   2. **zone bucket ASC** (0 ≤ 2km, 1 ∈ ]2,5]km, 2 ∈ ]5,10]km,
///      3 = inconnu). Bypass effectif si pas de `zoneCenter`.
///   3. score DESC
///   4. rating DESC nulls last
///   5. userRatingCount DESC nulls last
///   6. title ASC
///   7. placeKey ASC (tiebreaker ultime)
int _compareCandidate(
  TemplateCandidate a,
  TemplateCandidate b,
  Set<String> recommendedAnchorsNorm,
  GeoPoint? zoneCenter,
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

  // 2. Zone bucket ASC (4.7). Bypass si pas de zoneCenter
  // (tous les buckets = 3 → égalité, départage passe au
  // score, comportement identique à pré-4.7).
  final aBucket = _zoneBucket(a, zoneCenter);
  final bBucket = _zoneBucket(b, zoneCenter);
  if (aBucket != bBucket) return aBucket.compareTo(bBucket);

  // 3. score DESC.
  final scoreCmp = b.score.compareTo(a.score);
  if (scoreCmp != 0) return scoreCmp;

  // 4. rating DESC nulls last (null = -inf).
  final aRating = a.rating ?? double.negativeInfinity;
  final bRating = b.rating ?? double.negativeInfinity;
  final ratingCmp = bRating.compareTo(aRating);
  if (ratingCmp != 0) return ratingCmp;

  // 5. userRatingCount DESC nulls last (null = -1).
  final aReviews = a.userRatingCount ?? -1;
  final bReviews = b.userRatingCount ?? -1;
  final reviewsCmp = bReviews.compareTo(aReviews);
  if (reviewsCmp != 0) return reviewsCmp;

  // 6. title ASC.
  final titleCmp = a.title.compareTo(b.title);
  if (titleCmp != 0) return titleCmp;

  // 7. placeKey ASC (tiebreaker final).
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
