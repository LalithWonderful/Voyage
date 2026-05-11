/// Phase 0 / Tâche 0.2 — Module métriques qualité planning.
///
/// Calcule 5 scores qualité sur une `List<ActivitySuggestion>` produite
/// par le pipeline Lunao (visites + repas confondus, séparation par
/// heuristique). Pure logique de calcul, AUCUN accès réseau, AUCUNE
/// dépendance à Google Places ou Supabase.
///
/// Pas de modèle `Planning` agrégé artificiel (cf. feedback memory
/// `no_parallel_models`). Le pipeline retourne `List<ActivitySuggestion>` ;
/// le rapport `PlanningQualityReport` capture les métriques sans
/// recréer une structure planning parallèle.
///
/// Distinction visite/repas via heuristique startTime :
///   - `12:30` → déjeuner
///   - `19:30` → dîner
/// Cohérent avec `insertDeterministicMeals` qui produit ces slots fixes.
/// Hors scope ici de détecter les complexes sémantiques (Sentosa /
/// Universal / Resorts World) — Phase 2 `SameComplexGroup`.
library;

import 'dart:math' as math;

import 'package:voyage/features/planning/models/activity_suggestion_model.dart';

/// Seuils transition (km) pour le scoring inter-slot. Définis ici pour
/// pouvoir être ajustés / référencés dans les tests et la doc.
const double _kTransitionExcellentKm = 2.0;
const double _kTransitionAcceptableKm = 5.0;
const double _kTransitionPenalizedKm = 10.0;

/// Score 0-100 par hop selon distance km. Linéaire entre bornes pour
/// éviter les discontinuités brutales (un slot à 5.001 km ne doit pas
/// chuter de 80 à 40 d'un coup).
///
/// - 0 km     → 100
/// - 2 km     → 100
/// - 3.5 km   → 90 (linéaire entre 2 et 5)
/// - 5 km     → 80
/// - 7.5 km   → 60 (linéaire entre 5 et 10)
/// - 10 km    → 40
/// - 15 km    → 20 (linéaire au-delà, plancher 0 à 20 km)
/// - >= 20 km → 0
double _scoreForTransitionKm(double km) {
  if (km <= _kTransitionExcellentKm) return 100.0;
  if (km <= _kTransitionAcceptableKm) {
    // Linéaire 100 → 80 entre 2 et 5 km
    final ratio = (km - _kTransitionExcellentKm) /
        (_kTransitionAcceptableKm - _kTransitionExcellentKm);
    return 100.0 - 20.0 * ratio;
  }
  if (km <= _kTransitionPenalizedKm) {
    // Linéaire 80 → 40 entre 5 et 10 km
    final ratio = (km - _kTransitionAcceptableKm) /
        (_kTransitionPenalizedKm - _kTransitionAcceptableKm);
    return 80.0 - 40.0 * ratio;
  }
  // Linéaire 40 → 0 entre 10 et 20 km. Au-delà : 0.
  const farFloorKm = 20.0;
  if (km >= farFloorKm) return 0.0;
  final ratio = (km - _kTransitionPenalizedKm) /
      (farFloorKm - _kTransitionPenalizedKm);
  return 40.0 - 40.0 * ratio;
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

/// Convention `insertDeterministicMeals` du pipeline : déjeuner 12:30,
/// dîner 19:30. Heuristique pragmatique — si le pipeline changeait ces
/// horaires standards, mettre à jour ici.
bool _isMealSlot(ActivitySuggestion a) =>
    a.startTime == '12:30' || a.startTime == '19:30';

String _normalizeTitle(String s) =>
    s.toLowerCase().trim().replaceAll(RegExp(r'\s+'), ' ');

DateTime _dateKey(DateTime d) => DateTime.utc(d.year, d.month, d.day);

/// Détail qualité d'une journée du voyage.
///
/// Sert au diagnostic granulaire : quelle journée pose problème
/// (trop dispersée, trop vide, lieu répété). Les warnings sont des
/// codes stables consommables par le script baseline et la doc.
class DayQualityDetail {
  /// Date de la journée (UTC, normalisée).
  final DateTime date;

  /// Nombre total de slots (visites + repas).
  final int totalSlots;

  /// Nombre de visites (slots != 12:30 / 19:30).
  final int visitsCount;

  /// Nombre de repas (slots == 12:30 / 19:30).
  final int mealsCount;

  /// Distance moyenne entre slots consécutifs (mètres) pour les hops
  /// avec coordonnées disponibles des deux côtés. `null` si aucun hop
  /// avec coords.
  final double? avgInterSlotMeters;

  /// Distance max entre slots consécutifs (mètres). `null` si pas de
  /// hop avec coords.
  final double? maxInterSlotMeters;

  /// Codes de warning émis pour cette journée. Vide = journée OK.
  ///
  /// Codes possibles :
  /// - `empty_day` : aucune activité ce jour-là (jour libre).
  /// - `missing_coordinates` : ≥1 slot sans lat/lng → distances non
  ///   calculables sur ce hop, métriques transition dégradées.
  /// - `long_transition` : ≥1 hop > 5 km dans la journée.
  /// - `low_activity_count` : journée non vide mais < 2 slots
  ///   (équivalent à 1 seul pick, journée peu remplie).
  /// - `repeated_place` : titre normalisé déjà vu un autre jour du
  ///   voyage. Indice de re-pick cross-cluster.
  final List<String> warnings;

  const DayQualityDetail({
    required this.date,
    required this.totalSlots,
    required this.visitsCount,
    required this.mealsCount,
    required this.avgInterSlotMeters,
    required this.maxInterSlotMeters,
    required this.warnings,
  });

  Map<String, dynamic> toJson() => {
        'date': date.toIso8601String().split('T').first,
        'total_slots': totalSlots,
        'visits_count': visitsCount,
        'meals_count': mealsCount,
        'avg_inter_slot_meters': avgInterSlotMeters,
        'max_inter_slot_meters': maxInterSlotMeters,
        'warnings': warnings,
      };
}

/// Rapport qualité d'un planning complet.
///
/// 5 scores agrégés sur [0, 100]. `overallScore` est la moyenne des 5
/// (ignore les `null`). Tous les scores peuvent être `null` si la
/// donnée d'entrée ne permet pas le calcul (ex: `transitionScore` null
/// si aucun hop avec coordonnées dans tout le voyage).
class PlanningQualityReport {
  /// Cohérence géographique par jour (0-100). Pénalise les journées
  /// avec longues transitions inter-slot. Plus élevé = packs de jour
  /// compacts.
  final double? coherenceScore;

  /// Variété des `tag` ActivitySuggestion sur l'ensemble du voyage
  /// (0-100). Mesurée via entropie de Shannon normalisée — capture la
  /// distribution, pas juste le nombre de tags uniques.
  final double? diversityScore;

  /// Anti-répétitions (0-100, plus haut = moins de répétitions).
  /// Détecte les titres normalisés répétés exactement (même string
  /// après lowercase + trim + whitespace collapse). NE détecte PAS les
  /// complexes sémantiques (Sentosa Island vs Sentosa) — Phase 2.
  final double? repetitionScore;

  /// Distances raisonnables entre slots consécutifs (0-100). Moyenne
  /// des scores par hop selon paliers : ≤2 km / 2-5 km / 5-10 km / >10 km.
  final double? transitionScore;

  /// Pourcentage de journées correctement remplies vs journées libres
  /// involontaires (0-100). Par défaut, "remplie" = ≥1 slot.
  /// `expectedTripDays` si fourni, sinon déduit du min/max `dayDate`.
  final double? coverageScore;

  /// Moyenne arithmétique des 5 scores ci-dessus (ignore les `null`).
  /// `null` si TOUS les 5 sont `null`.
  final double? overallScore;

  /// Détail par jour (trié chronologiquement croissant). Permet
  /// l'analyse fine post-run du baseline et la détection de patterns
  /// (un jour qui plombe le score global).
  final List<DayQualityDetail> byDay;

  /// Liste des titres normalisés répétés (apparaissant ≥2 fois sur le
  /// voyage entier). Affichée dans le résumé console et le JSON pour
  /// diagnostic immédiat.
  final List<String> repeatedTitlesNormalized;

  /// Nombre total de slots pris en compte dans le calcul.
  final int totalSlots;

  /// Nombre total de visites (slots != meal slots).
  final int totalVisits;

  /// Nombre total de repas (slots == 12:30 / 19:30).
  final int totalMeals;

  /// Nombre de journées attendues (fourni ou déduit du span dayDate).
  final int totalExpectedDays;

  /// Nombre de journées avec au moins une activité.
  final int totalDaysWithActivity;

  const PlanningQualityReport({
    required this.coherenceScore,
    required this.diversityScore,
    required this.repetitionScore,
    required this.transitionScore,
    required this.coverageScore,
    required this.overallScore,
    required this.byDay,
    required this.repeatedTitlesNormalized,
    required this.totalSlots,
    required this.totalVisits,
    required this.totalMeals,
    required this.totalExpectedDays,
    required this.totalDaysWithActivity,
  });

  Map<String, dynamic> toJson() => {
        'overall_score': overallScore,
        'scores': {
          'coherence': coherenceScore,
          'diversity': diversityScore,
          'repetition': repetitionScore,
          'transition': transitionScore,
          'coverage': coverageScore,
        },
        'totals': {
          'slots': totalSlots,
          'visits': totalVisits,
          'meals': totalMeals,
          'expected_days': totalExpectedDays,
          'days_with_activity': totalDaysWithActivity,
        },
        'repeated_titles_normalized': repeatedTitlesNormalized,
        'by_day': byDay.map((d) => d.toJson()).toList(),
      };
}

/// Calcule les métriques qualité d'un planning.
///
/// `suggestions` : tous les slots (visites + repas confondus) tels que
/// produits par le pipeline. La fonction sépare en interne via
/// l'heuristique startTime.
///
/// `expectedTripDays` : nombre de jours attendus du voyage. Si null,
/// déduit du span min..max des `dayDate`. Sert au `coverageScore` —
/// crucial quand le voyage commence ou se termine sur une journée
/// vide (sinon `dayDate` ne couvre pas tout).
///
/// Retourne un `PlanningQualityReport` avec 5 scores + détail par
/// jour. Aucun side-effect, déterministe à entrée identique.
PlanningQualityReport computePlanningMetrics(
  List<ActivitySuggestion> suggestions, {
  int? expectedTripDays,
}) {
  // ─── Groupement par jour ────────────────────────────────────────────
  final byDay = <DateTime, List<ActivitySuggestion>>{};
  for (final s in suggestions) {
    final key = _dateKey(s.dayDate);
    byDay.putIfAbsent(key, () => []).add(s);
  }

  // Trie les slots de chaque jour par startTime pour calculer les hops.
  for (final list in byDay.values) {
    list.sort((a, b) => a.startTime.compareTo(b.startTime));
  }

  // ─── Détermination de la fenêtre du voyage ──────────────────────────
  int totalExpectedDays;
  if (expectedTripDays != null && expectedTripDays > 0) {
    totalExpectedDays = expectedTripDays;
  } else if (byDay.isEmpty) {
    totalExpectedDays = 0;
  } else {
    final sortedDates = byDay.keys.toList()..sort();
    totalExpectedDays =
        sortedDates.last.difference(sortedDates.first).inDays + 1;
  }

  // ─── Détection des titres répétés (globale au voyage) ──────────────
  final titleCount = <String, int>{};
  for (final s in suggestions) {
    final n = _normalizeTitle(s.title);
    titleCount[n] = (titleCount[n] ?? 0) + 1;
  }
  final repeatedTitles = titleCount.entries
      .where((e) => e.value > 1)
      .map((e) => e.key)
      .toList()
    ..sort();
  final repeatedSet = repeatedTitles.toSet();

  // ─── Détail par jour + collecte signaux pour scores agrégés ────────
  final dayDetails = <DayQualityDetail>[];
  final allHopsKm = <double>[];
  final perDayScores = <double>[];

  // Pour ne reporter `low_activity_count` que sur les jours non vides.
  // Pour `empty_day`, on émet une entry day même si le jour n'a aucune
  // activité — utile au consommateur. On doit donc itérer sur les jours
  // attendus du voyage. Mais si `expectedTripDays` est fourni mais sans
  // dayDate de référence, on ne sait pas quelle est la date de début.
  // Pratique : on émet `DayQualityDetail` uniquement pour les jours
  // présents dans `byDay` + on compte les jours manquants côté coverage.
  final sortedKeys = byDay.keys.toList()..sort();
  for (final dayKey in sortedKeys) {
    final list = byDay[dayKey]!;
    final visits = list.where((s) => !_isMealSlot(s)).toList();
    final meals = list.where(_isMealSlot).toList();
    final hopsKm = <double>[];
    var anyMissingCoords = false;
    for (var i = 1; i < list.length; i++) {
      final a = list[i - 1];
      final b = list[i];
      if (a.latitude == null || a.longitude == null ||
          b.latitude == null || b.longitude == null) {
        anyMissingCoords = true;
        continue;
      }
      hopsKm.add(_haversineKm(
          a.latitude!, a.longitude!, b.latitude!, b.longitude!));
    }
    allHopsKm.addAll(hopsKm);

    final avgM = hopsKm.isEmpty
        ? null
        : (hopsKm.reduce((x, y) => x + y) / hopsKm.length) * 1000;
    final maxM = hopsKm.isEmpty ? null : hopsKm.reduce(math.max) * 1000;
    final hasLongTransition =
        hopsKm.any((k) => k > _kTransitionAcceptableKm);
    final hasRepeated =
        list.any((s) => repeatedSet.contains(_normalizeTitle(s.title)));

    final warnings = <String>[];
    if (list.isEmpty) warnings.add('empty_day');
    if (anyMissingCoords) warnings.add('missing_coordinates');
    if (hasLongTransition) warnings.add('long_transition');
    if (list.isNotEmpty && list.length < 2) {
      warnings.add('low_activity_count');
    }
    if (hasRepeated) warnings.add('repeated_place');

    dayDetails.add(DayQualityDetail(
      date: dayKey,
      totalSlots: list.length,
      visitsCount: visits.length,
      mealsCount: meals.length,
      avgInterSlotMeters: avgM,
      maxInterSlotMeters: maxM,
      warnings: warnings,
    ));

    // Score per-day pour coherenceScore : pénalise plus durement
    // qu'un transitionScore agrégé brut. Formule :
    //   100 - 10 × nbLongHops - 4 × maxTransitionKm
    // Clampé [0, 100]. Un jour compact (<2 km max, 0 long hop) score 92+.
    // Un jour avec 1 long hop à 8 km score 100 - 10 - 32 = 58.
    // Un jour vide est exclu du calcul (n'affecte pas le score moyen).
    if (list.isNotEmpty && hopsKm.isNotEmpty) {
      final longCount =
          hopsKm.where((k) => k > _kTransitionAcceptableKm).length;
      final maxKm = hopsKm.reduce(math.max);
      final dayScore =
          math.max(0.0, math.min(100.0, 100.0 - 10.0 * longCount - 4.0 * maxKm));
      perDayScores.add(dayScore);
    }
  }

  // ─── transitionScore : moyenne des scores par hop ──────────────────
  double? transitionScore;
  if (allHopsKm.isNotEmpty) {
    final perHopScores = allHopsKm.map(_scoreForTransitionKm).toList();
    transitionScore =
        perHopScores.reduce((a, b) => a + b) / perHopScores.length;
  }

  // ─── coherenceScore : moyenne des scores par jour ──────────────────
  double? coherenceScore;
  if (perDayScores.isNotEmpty) {
    coherenceScore =
        perDayScores.reduce((a, b) => a + b) / perDayScores.length;
  }

  // ─── diversityScore : entropie Shannon normalisée sur les tags
  //     des VISITES uniquement (pas les repas, qui sont tous tag
  //     "Gastronomie" et fausseraient la mesure) ──────────────────────
  double? diversityScore;
  final visitTags = suggestions
      .where((s) => !_isMealSlot(s))
      .map((s) => s.tag)
      .where((t) => t.isNotEmpty)
      .toList();
  if (visitTags.length >= 2) {
    final tagCount = <String, int>{};
    for (final t in visitTags) {
      tagCount[t] = (tagCount[t] ?? 0) + 1;
    }
    // Shannon : H = -Σ pi log2(pi). Max H = log2(K) où K = nb tags
    // uniques. Normalisation par log2(N) où N = total visits (borne
    // sup réelle, plus stricte que log2(K) qui sature à 1.0).
    final n = visitTags.length.toDouble();
    var h = 0.0;
    for (final c in tagCount.values) {
      final p = c / n;
      h -= p * (math.log(p) / math.ln2);
    }
    final hMax = math.log(n) / math.ln2;
    diversityScore = hMax == 0 ? 100.0 : (h / hMax) * 100.0;
  } else if (visitTags.length == 1) {
    // 1 seule visite : pas de diversité possible mais pas pénalisable.
    diversityScore = 100.0;
  }

  // ─── repetitionScore : 100 - 100×(repetitions/totalVisits) ─────────
  double? repetitionScore;
  final totalVisitsForRep = suggestions.where((s) => !_isMealSlot(s)).length;
  if (totalVisitsForRep > 0) {
    // `repetitions` compte les occurrences "au-delà" de la 1ʳᵉ pour
    // chaque titre répété (ex: 1 lieu picked 3× → 2 répétitions).
    // Seulement sur les VISITES (les repas peuvent se répéter
    // légitimement, autorisé par `insertDeterministicMeals` cap).
    var repetitions = 0;
    final visitTitleCount = <String, int>{};
    for (final s in suggestions.where((s) => !_isMealSlot(s))) {
      final n = _normalizeTitle(s.title);
      visitTitleCount[n] = (visitTitleCount[n] ?? 0) + 1;
    }
    for (final c in visitTitleCount.values) {
      if (c > 1) repetitions += c - 1;
    }
    repetitionScore =
        math.max(0.0, 100.0 - 100.0 * repetitions / totalVisitsForRep);
  }

  // ─── coverageScore : journées remplies vs total expected ───────────
  double? coverageScore;
  final daysWithActivity = byDay.entries
      .where((e) => e.value.isNotEmpty)
      .length;
  if (totalExpectedDays > 0) {
    coverageScore = 100.0 * daysWithActivity / totalExpectedDays;
  }

  // ─── overallScore : moyenne des 5 (ignore null) ───────────────────
  final allScores = <double>[
    ?coherenceScore,
    ?diversityScore,
    ?repetitionScore,
    ?transitionScore,
    ?coverageScore,
  ];
  final overallScore = allScores.isEmpty
      ? null
      : allScores.reduce((a, b) => a + b) / allScores.length;

  return PlanningQualityReport(
    coherenceScore: coherenceScore,
    diversityScore: diversityScore,
    repetitionScore: repetitionScore,
    transitionScore: transitionScore,
    coverageScore: coverageScore,
    overallScore: overallScore,
    byDay: dayDetails,
    repeatedTitlesNormalized: repeatedTitles,
    totalSlots: suggestions.length,
    totalVisits: totalVisitsForRep,
    totalMeals: suggestions.where(_isMealSlot).length,
    totalExpectedDays: totalExpectedDays,
    totalDaysWithActivity: daysWithActivity,
  );
}
