/// Phase 4 / Tâche 4.3 — Service pur d'assignation de
/// `DayTemplate` aux jours d'un voyage.
///
/// **Service pur, dormant.** Ne sélectionne aucun lieu, n'appelle
/// pas Google Places, ne construit pas d'`ActivitySuggestion`,
/// n'insère pas de repas. Sa seule responsabilité est de
/// produire un mapping `jour → template` déterministe, qui sera
/// consommé en Tâche 4.4+ par le `DayBuilder template-first`
/// derrière le flag `useDayTemplates`.
///
/// ## Stratégie d'assignation
///
/// 1. **Jour 1** = `arrival_day` si disponible, sinon le template
///    le plus light disponible.
/// 2. **Dernier jour** = `departure_day` si disponible, sinon le
///    template le plus light parmi ceux non utilisés.
/// 3. **Jours du milieu** : pioche dans une queue ordonnée par
///    priorité (iconic d'abord, puis stabilité par `complexKey`),
///    en respectant :
///    - pas deux jours `intense` consécutifs
///    - 1 `free_day` toutes les 5 journées actives (4 pour voyages
///      > 10 jours)
///    - pas de répétition (sauf voyages > 10 jours)
///
/// ## Ordre de priorité du queue middle (déterministe)
///
/// 1. `recommendedAnchorKeys.length` DESC (iconic = plus d'anchors)
/// 2. `intensity` (medium > intense > light)
/// 3. `templateKey` ASC (alphabétique stable)
///
/// Le tri stable garantit que **deux appels avec mêmes inputs
/// produisent la même séquence** (testé).
///
/// ## Edge cases gérés
///
/// - 1 jour : assigne `arrival_day` ou template light.
/// - 2 jours : `arrival_day` puis `departure_day`.
/// - 3+ jours : algo standard.
/// - > 10 jours : répétitions autorisées, ≥ 2 `free_day` si dispo.
/// - Templates manquants : fallbacks documentés (light prioritaire).
/// - Templates vide : `ArgumentError` (impossible d'assigner sans).
/// - `endDate < startDate` : `ArgumentError`.
library;

import 'package:voyage/models/day_template.dart';
import 'package:voyage/models/destination_intelligence.dart';

/// Squelette minimal de voyage. Adapter local (cf. règle d'or 7)
/// pour éviter de coupler ce service au modèle `Trip` lourd du
/// projet. Le caller construit cet objet à partir de son propre
/// modèle.
class TripSkeleton {
  final String destinationKey;
  final DateTime startDate;
  final DateTime endDate;
  final List<String> interests;
  final String? travelerType;

  const TripSkeleton({
    required this.destinationKey,
    required this.startDate,
    required this.endDate,
    this.interests = const [],
    this.travelerType,
  });
}

/// Raison rendue avec chaque `DayTemplateAssignment`. Utile pour
/// le debug, les logs futurs (Tâche 4.4+) et la documentation des
/// décisions du sélecteur.
enum DayAssignmentReason {
  /// Premier jour, `arrival_day` retenu.
  arrival,

  /// Dernier jour, `departure_day` retenu.
  departure,

  /// Template iconique (anchors non vides) choisi en priorité.
  iconicPriority,

  /// Template choisi pour son matching avec les intérêts du
  /// voyageur (réservé Tâche 4.3+ — non émis activement en 4.3
  /// pour rester strictement déterministe).
  interestMatch,

  /// `free_day` inséré pour respecter le rythme repos.
  restBalance,

  /// Aucun rôle spécifique : rotation par défaut depuis la queue.
  defaultRotation,
}

/// Résultat unitaire d'une assignation : un jour, son template,
/// la raison du choix.
class DayTemplateAssignment {
  /// Date calendaire du jour (`trip.startDate + dayIndex jours`).
  final DateTime date;

  /// Index 0-based depuis `startDate`. `dayIndex == 0` = jour
  /// d'arrivée. `dayIndex == numDays - 1` = jour de départ.
  final int dayIndex;

  /// Template assigné à ce jour.
  final DayTemplate template;

  /// Raison du choix (cf. `DayAssignmentReason`).
  final DayAssignmentReason reason;

  const DayTemplateAssignment({
    required this.date,
    required this.dayIndex,
    required this.template,
    required this.reason,
  });
}

// ─── Constantes algorithme ────────────────────────────────────────────

/// Au-delà de ce nombre de jours, les répétitions de template
/// sont autorisées.
const int _kRepeatThresholdDays = 10;

/// Nombre de jours actifs consécutifs avant insertion automatique
/// d'un `free_day` (court séjour).
const int _kFreeDayThresholdShort = 5;

/// Nombre de jours actifs consécutifs avant insertion automatique
/// d'un `free_day` (voyage > `_kRepeatThresholdDays`). Plus
/// resserré pour atteindre la consigne "≥ 2 free_day" sur les
/// voyages longs.
const int _kFreeDayThresholdLong = 4;

// ─── API publique ─────────────────────────────────────────────────────

/// Assigne un `DayTemplate` à chaque jour du voyage.
///
/// Voir doc de tête pour la stratégie. Lève `ArgumentError` si
/// `templates` est vide, si `endDate < startDate`, ou si aucun
/// template ne correspond à `di.destinationKey`.
///
/// `interests` est accepté pour cohérence avec la signature
/// future (Tâche 4.3+) ; **non utilisé activement en 4.3** pour
/// garantir un comportement strictement déterministe à ce
/// stade.
List<DayTemplateAssignment> assignThemesToDays(
  TripSkeleton trip,
  DestinationIntelligence di,
  List<DayTemplate> templates, {
  List<String> interests = const [],
}) {
  if (templates.isEmpty) {
    throw ArgumentError.value(templates, 'templates',
        'must be non-empty (cannot assign templates to days)');
  }
  if (trip.endDate.isBefore(trip.startDate)) {
    throw ArgumentError.value(
      trip,
      'trip',
      'endDate (${trip.endDate.toIso8601String()}) must be >= '
          'startDate (${trip.startDate.toIso8601String()})',
    );
  }

  // Filtre templates par destinationKey. Lève si rien ne matche.
  final eligible = templates
      .where((t) => t.destinationKey == di.destinationKey)
      .toList();
  if (eligible.isEmpty) {
    throw ArgumentError.value(
      templates,
      'templates',
      'No template matches DI.destinationKey "${di.destinationKey}"',
    );
  }

  final numDays = trip.endDate.difference(trip.startDate).inDays + 1;

  // Templates rôles standard.
  final arrivalTemplate = _firstWhereOrNull(
      eligible, (t) => t.templateKey == 'arrival_day');
  final departureTemplate = _firstWhereOrNull(
      eligible, (t) => t.templateKey == 'departure_day');
  final freeTemplate =
      _firstWhereOrNull(eligible, (t) => t.templateKey == 'free_day');

  // ── Edge case : 1 jour ────────────────────────────────────────────
  if (numDays == 1) {
    final tpl = arrivalTemplate ?? _lightestTemplate(eligible);
    return [
      DayTemplateAssignment(
        date: trip.startDate,
        dayIndex: 0,
        template: tpl,
        reason: arrivalTemplate != null
            ? DayAssignmentReason.arrival
            : DayAssignmentReason.defaultRotation,
      ),
    ];
  }

  // ── numDays >= 2 ──────────────────────────────────────────────────
  final assignments = <DayTemplateAssignment>[];

  // Jour 0 : arrival ou fallback light.
  final day0 = arrivalTemplate ?? _lightestTemplate(eligible);
  assignments.add(DayTemplateAssignment(
    date: trip.startDate,
    dayIndex: 0,
    template: day0,
    reason: arrivalTemplate != null
        ? DayAssignmentReason.arrival
        : DayAssignmentReason.defaultRotation,
  ));

  // Dernier jour : departure ou fallback light (différent de day0).
  final dayLast = departureTemplate ??
      _lightestTemplate(
        eligible.where((t) => t.templateKey != day0.templateKey).toList(),
      );

  // ── Jours du milieu (i ∈ [1, numDays-2]) ──────────────────────────
  final middlePool = _buildMiddleQueue(eligible);
  final allowRepeat = numDays > _kRepeatThresholdDays;
  final freeThreshold = allowRepeat
      ? _kFreeDayThresholdLong
      : _kFreeDayThresholdShort;

  final usedInTrip = <String>{day0.templateKey};
  // Évite de réutiliser dayLast dans le milieu pour les voyages
  // courts (où repeat n'est pas autorisé). On l'ajoute au set
  // ici pour qu'il soit "déjà utilisé" du point de vue middle.
  if (!allowRepeat) {
    usedInTrip.add(dayLast.templateKey);
  }

  var activeDaysSinceLastFree = 0;
  var middleQueueIndex = 0;
  DayIntensity? prevIntensity =
      assignments.isNotEmpty ? assignments.last.template.intensity : null;

  for (var i = 1; i < numDays - 1; i++) {
    DayTemplate? chosen;
    DayAssignmentReason chosenReason = DayAssignmentReason.defaultRotation;

    // Règle 1 : free_day si rythme atteint et template dispo.
    if (freeTemplate != null &&
        activeDaysSinceLastFree >= freeThreshold &&
        (allowRepeat || !usedInTrip.contains(freeTemplate.templateKey))) {
      chosen = freeTemplate;
      chosenReason = DayAssignmentReason.restBalance;
      activeDaysSinceLastFree = 0;
    }

    // Règle 2 : pioche depuis la queue iconic.
    if (chosen == null) {
      chosen = _pickFromMiddleQueue(
        queue: middlePool,
        startIndex: middleQueueIndex,
        usedInTrip: usedInTrip,
        allowRepeat: allowRepeat,
        prevIntensity: prevIntensity,
      );
      if (chosen != null) {
        // Avance l'index pour la prochaine itération (round-robin).
        final foundAt = middlePool.indexOf(chosen);
        middleQueueIndex = (foundAt + 1) % middlePool.length;
        chosenReason = chosen.recommendedAnchorKeys.isNotEmpty
            ? DayAssignmentReason.iconicPriority
            : DayAssignmentReason.defaultRotation;
      }
      activeDaysSinceLastFree++;
    }

    // Fallback ultime : prendre le premier eligible non utilisé,
    // ou répéter si rien d'autre (cas template list très petit).
    chosen ??= _fallbackPick(
      eligible: eligible,
      usedInTrip: usedInTrip,
      allowRepeat: allowRepeat,
      day0Key: day0.templateKey,
      dayLastKey: dayLast.templateKey,
    );

    assignments.add(DayTemplateAssignment(
      date: trip.startDate.add(Duration(days: i)),
      dayIndex: i,
      template: chosen,
      reason: chosenReason,
    ));
    usedInTrip.add(chosen.templateKey);
    prevIntensity = chosen.intensity;
  }

  // Dernier jour.
  assignments.add(DayTemplateAssignment(
    date: trip.startDate.add(Duration(days: numDays - 1)),
    dayIndex: numDays - 1,
    template: dayLast,
    reason: departureTemplate != null
        ? DayAssignmentReason.departure
        : DayAssignmentReason.defaultRotation,
  ));

  return assignments;
}

// ─── Helpers internes ─────────────────────────────────────────────────

DayTemplate? _firstWhereOrNull(
    List<DayTemplate> list, bool Function(DayTemplate) test) {
  for (final t in list) {
    if (test(t)) return t;
  }
  return null;
}

/// Retourne le template le plus "light" (intensity light en
/// priorité, puis medium, puis intense). À intensité égale, tri
/// par templateKey ASC pour stabilité.
DayTemplate _lightestTemplate(List<DayTemplate> list) {
  if (list.isEmpty) {
    throw StateError('Cannot pick lightest from empty list');
  }
  final sorted = [...list]..sort((a, b) {
      final ic = _intensityRank(a.intensity)
          .compareTo(_intensityRank(b.intensity));
      if (ic != 0) return ic;
      return a.templateKey.compareTo(b.templateKey);
    });
  return sorted.first;
}

/// Plus petit = plus light.
int _intensityRank(DayIntensity i) {
  switch (i) {
    case DayIntensity.light:
      return 0;
    case DayIntensity.medium:
      return 1;
    case DayIntensity.intense:
      return 2;
  }
}

/// Construit la queue ordonnée pour les jours du milieu :
/// exclut arrival_day / departure_day / free_day, trie par
/// iconic-ness puis stable par templateKey.
List<DayTemplate> _buildMiddleQueue(List<DayTemplate> eligible) {
  final filtered = eligible
      .where((t) =>
          t.templateKey != 'arrival_day' &&
          t.templateKey != 'departure_day' &&
          t.templateKey != 'free_day')
      .toList();
  filtered.sort((a, b) {
    // 1. anchors count DESC
    final ac =
        b.recommendedAnchorKeys.length.compareTo(a.recommendedAnchorKeys.length);
    if (ac != 0) return ac;
    // 2. intensity (medium > intense > light), via rank custom
    final ic = _middleIntensityRank(a.intensity)
        .compareTo(_middleIntensityRank(b.intensity));
    if (ic != 0) return ic;
    // 3. templateKey ASC pour stabilité déterministe
    return a.templateKey.compareTo(b.templateKey);
  });
  return filtered;
}

/// Pour le tri queue middle : medium=0 (top), intense=1, light=2.
/// Différent de `_intensityRank` qui priorise light pour les
/// fallbacks arrivée/départ.
int _middleIntensityRank(DayIntensity i) {
  switch (i) {
    case DayIntensity.medium:
      return 0;
    case DayIntensity.intense:
      return 1;
    case DayIntensity.light:
      return 2;
  }
}

/// Pioche dans la queue à partir de `startIndex`, en sautant
/// les déjà-utilisés (sauf si `allowRepeat`) et les `intense`
/// consécutifs.
DayTemplate? _pickFromMiddleQueue({
  required List<DayTemplate> queue,
  required int startIndex,
  required Set<String> usedInTrip,
  required bool allowRepeat,
  required DayIntensity? prevIntensity,
}) {
  if (queue.isEmpty) return null;
  // Parcours circulaire pour répétitions, sinon parcours linéaire.
  for (var k = 0; k < queue.length; k++) {
    final idx = (startIndex + k) % queue.length;
    final candidate = queue[idx];
    if (!allowRepeat && usedInTrip.contains(candidate.templateKey)) {
      continue;
    }
    // Éviter intense après intense.
    if (prevIntensity == DayIntensity.intense &&
        candidate.intensity == DayIntensity.intense) {
      continue;
    }
    return candidate;
  }
  // Si rien n'a passé les filtres ci-dessus : relaxer le filtre
  // intense (le cap répétition reste actif si applicable).
  for (var k = 0; k < queue.length; k++) {
    final idx = (startIndex + k) % queue.length;
    final candidate = queue[idx];
    if (!allowRepeat && usedInTrip.contains(candidate.templateKey)) {
      continue;
    }
    return candidate;
  }
  return null;
}

/// Fallback ultime quand la queue middle est épuisée. Cherche
/// dans `eligible` un template encore non utilisé (ou réutilise
/// si voyage long), en évitant d'écraser day0 / dayLast.
DayTemplate _fallbackPick({
  required List<DayTemplate> eligible,
  required Set<String> usedInTrip,
  required bool allowRepeat,
  required String day0Key,
  required String dayLastKey,
}) {
  for (final t in eligible) {
    if (t.templateKey == day0Key) continue;
    if (!allowRepeat && t.templateKey == dayLastKey) continue;
    if (!allowRepeat && usedInTrip.contains(t.templateKey)) continue;
    return t;
  }
  // Dernier recours : retourne n'importe quel template (peut
  // dupliquer day0 / dayLast en voyage très court avec très
  // peu de templates).
  return eligible.first;
}
