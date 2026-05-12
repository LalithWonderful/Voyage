/// Phase 4 / Tâche 4.5 — Pipeline alternatif template-first.
///
/// **Orchestrateur runtime** qui assemble les briques Phase 4 :
///
/// ```
/// Trip + DI + templates + complexGroups + DayCandidates pool
///   │
///   ├─→ TripSkeleton (Tâche 4.3)
///   │     │
///   │     └─→ assignThemesToDays() → jour → DayTemplate
///   │
///   ├─→ Pour chaque jour :
///   │     ├─→ Filtrer DayCandidates.allUnique → candidates du jour
///   │     ├─→ Convertir NearbyCandidate → TemplateCandidate (via
///   │     │   adapter local + matchComplex pour complexKey +
///   │     │   détection anchor par nom)
///   │     ├─→ buildTemplateFirstDay() (Tâche 4.4)
///   │     └─→ Convertir TemplateDayBuildResult → ActivitySuggestion
///   │
///   └─→ TemplateFirstResult { activities, isUsable, fallbackReason }
/// ```
///
/// **Activé derrière `FeatureFlags.useDayTemplates` (OFF par
/// défaut).** Le routing flag-gated est dans
/// `_runAutoPlacesFirstBody` de `places_first_pipeline.dart` :
///
/// ```
/// if (category == SuggestionCategory.all && flag ON) {
///   final result = tryTemplateFirstPipeline(...);
///   if (result.isUsable) return result.activities; // (+ meals via legacy)
///   // else fallback legacy
/// }
/// // legacy continue inchangé
/// ```
///
/// ## Critère "isUsable"
///
/// Le template-first est considéré utilisable si :
/// - au moins 1 activité générée AU TOTAL **ET**
/// - (≥ 3 activités totales) **OU** (≥ 50% des jours assignés
///   ont reçu au moins 1 activité)
///
/// Sinon → `fallbackReason` non null → caller fallback legacy.
///
/// ## Pas de meals dans cette tâche
///
/// La Tâche 4.5 ne fait pas de meal insertion par elle-même.
/// Le caller (`_runAutoPlacesFirstBody`) appelle
/// `insertDeterministicMeals` APRÈS le template-first si le
/// résultat est usable. Permet à la Tâche 4.6 de mesurer la
/// qualité du template-first **isolé** sur les visites.
///
/// ## Déterminisme
///
/// Cette fonction n'introduit AUCUNE non-déterminisme : tri
/// stable de `buildTemplateFirstDay` + `assignThemesToDays` +
/// itération par jour fixe. Les seuls inputs variables (pool
/// Google Places) sont absorbés par l'ordre stable.
///
/// ## Erreur safe
///
/// Toute exception capturée → `TemplateFirstResult(isUsable: false,
/// fallbackReason: 'exception')`. Garantit que le caller fallback
/// legacy proprement.
library;

import 'dart:math' as math;

import 'package:flutter/foundation.dart' show debugPrint;
import 'package:voyage/features/planning/models/activity_suggestion_model.dart';
import 'package:voyage/features/planning/services/places_first_pipeline.dart'
    show DayCandidates;
import 'package:voyage/features/planning/services/places_nearby_service.dart';
import 'package:voyage/features/trips/models/trip_model.dart';
import 'package:voyage/models/day_template.dart';
import 'package:voyage/models/destination_intelligence.dart'
    show DestinationIntelligence, GeoPoint;
import 'package:voyage/models/same_complex_group.dart';
import 'package:voyage/services/complex_matcher.dart';
import 'package:voyage/services/day_theme_assigner.dart';
import 'package:voyage/services/template_first_day_builder.dart';

// ─── Résultat top-level ───────────────────────────────────────────────

class TemplateFirstResult {
  /// Activités générées (sans meals — cf. doc de tête).
  final List<ActivitySuggestion> activities;

  /// `true` si le résultat est jugé suffisant pour remplacer le
  /// pipeline legacy. `false` → caller fallback legacy.
  final bool isUsable;

  /// Raison du fallback (`null` si `isUsable == true`).
  /// Codes stables : `missing_di`, `missing_templates`,
  /// `no_assignments`, `result_too_sparse`, `exception`,
  /// `empty_pool`.
  final String? fallbackReason;

  const TemplateFirstResult({
    required this.activities,
    required this.isUsable,
    this.fallbackReason,
  });
}

// ─── API publique ─────────────────────────────────────────────────────

/// Orchestrateur template-first. **Synchrone côté visites** —
/// aucun appel réseau. Le `pool` est pré-fetché par le caller via
/// `gatherCandidatesForTrip` (logique legacy réutilisée).
///
/// Retourne toujours un `TemplateFirstResult` (jamais throw).
TemplateFirstResult tryTemplateFirstPipeline({
  required Trip trip,
  required DestinationIntelligence di,
  required List<DayTemplate> templates,
  required List<DayCandidates> pool,
  List<SameComplexGroup> complexGroups = const <SameComplexGroup>[],
}) {
  if (templates.isEmpty) {
    return const TemplateFirstResult(
      activities: <ActivitySuggestion>[],
      isUsable: false,
      fallbackReason: 'missing_templates',
    );
  }
  if (pool.isEmpty) {
    return const TemplateFirstResult(
      activities: <ActivitySuggestion>[],
      isUsable: false,
      fallbackReason: 'empty_pool',
    );
  }

  try {
    final tripSkeleton = TripSkeleton(
      destinationKey: di.destinationKey,
      startDate: trip.startDate,
      endDate: trip.endDate,
      interests: trip.interests ?? const <String>[],
      travelerType: trip.travelerType,
    );

    final assignments = assignThemesToDays(tripSkeleton, di, templates);
    if (assignments.isEmpty) {
      return const TemplateFirstResult(
        activities: <ActivitySuggestion>[],
        isUsable: false,
        fallbackReason: 'no_assignments',
      );
    }

    // Index pool par jour ISO pour lookup O(1).
    final poolByDay = <String, DayCandidates>{};
    for (final d in pool) {
      poolByDay[_dayIsoKey(d.day)] = d;
    }

    final knownAnchorNames =
        di.anchors.map((a) => a.name).toSet();

    // 4.7 — Index zones par nom normalisé pour résoudre rapide
    // `template.primaryZoneName` → `TouristZone.center`. Permet
    // au builder d'appliquer l'axe anti-zigzag (rejet > 10 km
    // hors zone primaire, bucket de tri).
    final zonesByNameNorm = <String, GeoPoint>{};
    for (final z in di.zones) {
      zonesByNameNorm[z.name.trim().toLowerCase()] = z.center;
    }

    final allActivities = <ActivitySuggestion>[];
    final usedPlaceKeys = <String>{};
    final usedAnchorKeys = <String>{};
    final daysWithActivities = <String>{};

    for (final assignment in assignments) {
      final dayKey = _dayIsoKey(assignment.date);
      final dayCands = poolByDay[dayKey];
      if (dayCands == null) continue;

      // Adapter chaque NearbyCandidate → TemplateCandidate.
      final templateCandidates = <TemplateCandidate>[];
      dayCands.allUnique.forEach((_, entry) {
        templateCandidates.add(templateCandidateFromNearbyCandidate(
          entry.candidate,
          matchedInterests: entry.matchedInterests,
          complexGroups: complexGroups,
          knownAnchorNames: knownAnchorNames,
        ));
      });

      if (templateCandidates.isEmpty) continue;

      final zoneCenter = zonesByNameNorm[
          assignment.template.primaryZoneName.trim().toLowerCase()];

      final result = buildTemplateFirstDay(TemplateDayBuildInput(
        template: assignment.template,
        date: assignment.date,
        dayIndex: assignment.dayIndex,
        candidates: templateCandidates,
        destinationKey: di.destinationKey,
        alreadyUsedPlaceKeys: Set<String>.from(usedPlaceKeys),
        alreadyUsedAnchorKeys: Set<String>.from(usedAnchorKeys),
        primaryZoneCenter: zoneCenter,
      ));

      final dayActivities =
          templateDayBuildResultToActivities(result);
      if (dayActivities.isNotEmpty) {
        daysWithActivities.add(dayKey);
      }
      allActivities.addAll(dayActivities);

      // Track usages pour les jours suivants (anti-duplication
      // cross-trip).
      for (final a in result.assignments) {
        final c = a.candidate;
        if (c == null) continue;
        usedPlaceKeys.add(c.placeKey);
        if (c.anchorKey != null) {
          usedAnchorKeys.add(c.anchorKey!);
        }
      }
    }

    // Critère isUsable.
    final totalDays = assignments.length;
    final daysFilled = daysWithActivities.length;
    final fillRatio = totalDays > 0 ? daysFilled / totalDays : 0.0;
    final isUsable = allActivities.isNotEmpty &&
        (allActivities.length >= 3 || fillRatio >= 0.5);

    return TemplateFirstResult(
      activities: allActivities,
      isUsable: isUsable,
      fallbackReason: isUsable ? null : 'result_too_sparse',
    );
  } catch (e) {
    debugPrint('[template_first_pipeline_exception] $e');
    return const TemplateFirstResult(
      activities: <ActivitySuggestion>[],
      isUsable: false,
      fallbackReason: 'exception',
    );
  }
}

// ─── Adapter NearbyCandidate → TemplateCandidate ──────────────────────

/// Convertit un `NearbyCandidate` (Google Places legacy) en
/// `TemplateCandidate` (adapter Tâche 4.4).
///
/// Stratégie :
/// - `placeKey` : `placeId` si non vide, sinon fallback stable
///   `nameNorm@latRounded,lngRounded`.
/// - `title` : `name` du candidate.
/// - `category` : 1er type Google Places (`tourist_attraction`,
///   `restaurant`, …). Géré par les synonymes de
///   `template_first_day_builder.dart`.
/// - `score` : `rating × log(reviews)` (formule cohérente avec
///   le scoring legacy `selectVisitsDeterministic`).
/// - `anchorKey` : match exact case-insensitive sur
///   `knownAnchorNames` (issus de `di.anchors.name`). Permet la
///   priorisation anchor du builder.
/// - `complexKey` : résolu via `matchComplex` (Tâche 2.3) si
///   `complexGroups` fournis.
/// - `rating`, `userRatingCount`, `lat`, `lng` : pass-through.
/// - `estimatedDurationMinutes` : `null` (le builder utilise
///   `slot.typicalDurationMinutes` en fallback).
TemplateCandidate templateCandidateFromNearbyCandidate(
  NearbyCandidate c, {
  List<String> matchedInterests = const <String>[],
  List<SameComplexGroup> complexGroups = const <SameComplexGroup>[],
  Set<String> knownAnchorNames = const <String>{},
}) {
  // placeKey stable (Google placeId si dispo, sinon fallback).
  final placeKey = c.placeId.isNotEmpty
      ? c.placeId
      : _fallbackPlaceKey(c);

  // Détection anchor par match nom (case-insensitive + trim).
  String? anchorKey;
  final nameLower = c.name.trim().toLowerCase();
  for (final a in knownAnchorNames) {
    if (a.trim().toLowerCase() == nameLower) {
      anchorKey = a;
      break;
    }
  }

  // Détection complex via matcher (placeId + nom, fuzzy 0.85).
  String? complexKey;
  if (complexGroups.isNotEmpty) {
    complexKey = matchComplex(
      name: c.name,
      placeId: c.placeId,
      groups: complexGroups,
    );
  }

  // Category = 1er type Google (les synonymes du builder
  // gèrent `tourist_attraction` → anchor, etc.).
  final category = c.types.isNotEmpty
      ? c.types.first
      : 'point_of_interest';

  // Score = rating × log(reviews) — cohérent legacy. Borne 1
  // pour log si reviews <= 1.
  final reviews = c.userRatingCount ?? 0;
  final rating = c.rating ?? 0.0;
  final score = rating * (reviews <= 1 ? 1.0 : math.log(reviews));

  return TemplateCandidate(
    placeKey: placeKey,
    title: c.name,
    category: category,
    score: score,
    anchorKey: anchorKey,
    complexKey: complexKey,
    rating: c.rating,
    userRatingCount: c.userRatingCount,
    lat: c.latitude,
    lng: c.longitude,
    estimatedDurationMinutes: null,
  );
}

// ─── Conversion TemplateDayBuildResult → ActivitySuggestion ───────────

/// Convertit le résultat du builder en liste plate
/// d'`ActivitySuggestion`. Les slots sans candidat sont **ignorés**
/// (pas de placeholder UI, cf. spec 4.5).
List<ActivitySuggestion> templateDayBuildResultToActivities(
    TemplateDayBuildResult result) {
  final out = <ActivitySuggestion>[];
  for (final assignment in result.assignments) {
    final c = assignment.candidate;
    if (c == null) continue;
    out.add(ActivitySuggestion(
      dayDate: result.date,
      startTime: assignment.slot.startTime,
      title: c.title,
      tag: _tagFromCategory(c.category, assignment.slot.expectedType),
      durationMinutes: assignment.effectiveDurationMinutes,
      latitude: c.lat,
      longitude: c.lng,
    ));
  }
  return out;
}

// ─── Helpers privés ───────────────────────────────────────────────────

String _dayIsoKey(DateTime d) => d.toIso8601String().split('T').first;

String _fallbackPlaceKey(NearbyCandidate c) {
  final nameNorm = c.name.trim().toLowerCase().replaceAll(
      RegExp(r'\s+'), ' ');
  final lat = c.latitude.toStringAsFixed(4);
  final lng = c.longitude.toStringAsFixed(4);
  return '$nameNorm@$lat,$lng';
}

/// Tag user-facing dérivé de la catégorie Google + le slot type
/// attendu. Mapping pragmatique cohérent avec les tags existants
/// du projet (`Culture`, `Gastronomie`, `Nature`, `Shopping`,
/// `Activité`, `Événements`).
String _tagFromCategory(String category, ExpectedSlotType expectedType) {
  final c = category.toLowerCase().trim();
  // 1) Mapping par catégorie Google
  if (c.contains('restaurant') || c == 'meal' || c.contains('cafe') ||
      c.contains('food')) {
    return 'Gastronomie';
  }
  if (c.contains('shopping') || c == 'shopping_mall' ||
      c.contains('market') || c.contains('store')) {
    return 'Shopping';
  }
  if (c == 'park' || c == 'rest' || c.contains('garden') ||
      c.contains('nature')) {
    return 'Nature';
  }
  if (c.contains('museum') || c == 'art_museum' ||
      c.contains('historical') || c == 'tourist_attraction' ||
      c == 'landmark' || c == 'monument' || c == 'anchor' ||
      c == 'visit' || c == 'point_of_interest') {
    return 'Culture';
  }
  if (c == 'observation_deck' || c == 'viewpoint' || c == 'tower') {
    return 'Culture';
  }
  if (c == 'show' || c == 'performance' || c == 'theater' ||
      c == 'event' || c == 'night_club') {
    return 'Événements';
  }
  // 2) Fallback via slot type
  switch (expectedType) {
    case ExpectedSlotType.meal:
      return 'Gastronomie';
    case ExpectedSlotType.shopping:
      return 'Shopping';
    case ExpectedSlotType.show:
      return 'Événements';
    case ExpectedSlotType.anchor:
    case ExpectedSlotType.visit:
    case ExpectedSlotType.viewpoint:
      return 'Culture';
    case ExpectedSlotType.rest:
    case ExpectedSlotType.freeTime:
    case ExpectedSlotType.transfer:
      return 'Activité';
  }
}
