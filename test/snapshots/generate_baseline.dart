// Snapshot baseline generator — Phase 0 / Tâche 0.1.
//
// Génère un planning Singapour 18/05/2026 → 25/05/2026 avec le pipeline
// PRODUCTION ACTUEL (V8.28c, commit du run) et sauvegarde le résultat
// complet en JSON dans `test/snapshots/singapore_baseline.json`.
//
// Ce fichier sert de référence "avant refonte". Une fois généré, il NE
// DOIT PLUS être modifié (cf. règle d'or 2 du plan de refonte). Toutes
// les phases ultérieures comparent leur output à ce baseline.
//
// ─── Exécution ──────────────────────────────────────────────────────────
//
//   flutter test test/snapshots/generate_baseline.dart
//
// Le nom de fichier ne se termine PAS par `_test.dart` afin qu'il NE
// soit PAS picked-up automatiquement par `flutter test` (qui scanne
// `*_test.dart`). Lancement manuel et explicite uniquement.
//
// ─── Coût et déterminisme ───────────────────────────────────────────────
//
// HIT LA VRAIE API Google Places via la clé hardcodée dans
// `AiConstants.googleMapsApiKey`. ~50-100 RPC par run (8 jours × ~10
// calls/jour selon profil). NON DÉTERMINISTE au sens strict : Google
// peut renvoyer des lieux différents d'un run à l'autre (rotation des
// résultats, mise à jour catalogue, etc.).
//
// Le baseline est donc immuable PAR ENGAGEMENT HUMAIN : on génère une
// fois, on commit le JSON, et on ne le re-génère plus. Si une régression
// future nécessite une nouvelle baseline, créer un nouveau fichier
// (ex: `singapore_baseline_v2.json`) sans toucher au premier.
//
// ─── Stratégie de capture ───────────────────────────────────────────────
//
// Le pipeline log via `print` les compteurs `[places_selector_summary]`
// (incluant rejectedByOutOfCountry, rejectedByRestaurantOutOfScope,
// rejectedByIconicTripDedup, etc.). Capture via `runZoned` avec
// `zoneSpecification.print` pour les inclure dans le JSON. Sans ça,
// les logs partent à stdout et sont perdus.

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:voyage/config/feature_flags.dart';
import 'package:voyage/data/complexes/complex_registry.dart';
import 'package:voyage/data/day_templates/day_template_registry.dart';
import 'package:voyage/data/destinations/destination_intelligence_registry.dart';
import 'package:voyage/features/planning/models/activity_suggestion_model.dart';
import 'package:voyage/features/planning/services/geocoding_service.dart';
import 'package:voyage/features/planning/services/places_first_pipeline.dart';
import 'package:voyage/features/planning/services/places_nearby_service.dart';
import 'package:voyage/features/planning/services/template_first_pipeline.dart';
import 'package:voyage/features/planning/services/traveler_to_places_mapping.dart';
import 'package:voyage/features/trips/models/trip_model.dart';
import 'package:voyage/quality/planning_metrics.dart';
import '../helpers/live_api_script_guards.dart';

// ─── Trip fixture standard ────────────────────────────────────────────────
//
// Paramètres "moyens / standards" tels que spécifiés par la Tâche 0.1 :
// - destination : Singapour
// - dates : 18/05/2026 → 25/05/2026 (8 jours)
// - profil voyageur : Couple (le plus représentatif d'un voyage standard,
//   transport public natif, intérêts variés)
// - intérêts : Culture / Gastronomie / Spots populaires / Nature / Shopping
//   (couvre les 5 zones spécifiques Singapore — Marina Bay / Sentosa /
//   Chinatown Civic / Orchard Botanic / Kampong Glam Little India)
// - budget : 800 € / personne / 8 jours (~100 €/j → priceLevelCap=3,
//   standard non économique non premium)
// - transport local : public_transport
Trip _buildSingaporeTrip() {
  return Trip(
    id: 'baseline-singapore-2026-05',
    userId: 'baseline-snapshot',
    title: 'Singapour baseline',
    destination: 'Singapore',
    destinationCountryCode: 'sg',
    destinationCountryName: 'Singapour',
    destinationKind: 'city',
    startDate: DateTime.utc(2026, 5, 18),
    endDate: DateTime.utc(2026, 5, 25),
    coverEmoji: '🇸🇬',
    travelerType: 'Couple',
    interests: const [
      'Culture',
      'Gastronomie',
      'Spots populaires',
      'Nature',
      'Shopping',
    ],
    localTransportMode: 'public_transport',
    budgetPerPersonEur: 800,
    itinerarySegments: const [],
    createdAt: DateTime.utc(2026, 5, 11),
  );
}

// ─── Pipeline runner ──────────────────────────────────────────────────────

class _RunOutput {
  final List<ActivitySuggestion> visits;
  final List<ActivitySuggestion> meals;
  final List<String> capturedLogs;
  const _RunOutput({
    required this.visits,
    required this.meals,
    required this.capturedLogs,
  });
}

Future<_RunOutput> _runPipeline(Trip trip) async {
  final geocoder = GeocodingService();
  final nearbyService = PlacesNearbyService();
  final logs = <String>[];

  Future<({List<ActivitySuggestion> visits, List<ActivitySuggestion> meals})>
      runBody() async {
    final pool = await gatherCandidatesForTrip(
      trip: trip,
      hotels: const [],
      geocoder: geocoder,
      nearbyService: nearbyService,
      languageCode: 'fr',
    );

    final groups = groupDaysByCenter(pool);
    final clusters = partitionByQuartier(groups);

    final travelerProfile = travelerPlacesProfiles[trip.travelerType];

    // Phase 2 / Tâche 2.4 + Phase 3 / Tâche 3.2 + Phase 4 / 4.5
    // — flag-aware câblage. Par défaut OFF (`fromEnvironment()`
    // retourne false sans `--dart-define`). Activables via :
    //   flutter test --dart-define=USE_SAME_COMPLEX_DEDUP=true \
    //     test/snapshots/generate_baseline.dart
    //   flutter test --dart-define=USE_DESTINATION_SCOPE=true \
    //     test/snapshots/generate_baseline.dart
    //   flutter test --dart-define=USE_DAY_TEMPLATES=true \
    //     test/snapshots/generate_baseline.dart
    // pour observer l'impact des nouvelles politiques sur le
    // planning Singapour.
    final featureFlags = FeatureFlags.fromEnvironment();
    final complexGroupsForTrip =
        loadLocalComplexGroupsForDestination(trip.destination);
    final destinationIntelligenceForTrip =
        lookupLocalDestinationIntelligence(trip.destination);

    // Phase 4 / Tâche 4.5 — Pipeline template-first (flag-gated).
    // Mirror du routing présent dans `_runAutoPlacesFirstBody` :
    // tente template-first si flag ON + DI + templates dispos,
    // sinon fallback à la logique legacy ci-dessous.
    if (featureFlags.useDayTemplates &&
        destinationIntelligenceForTrip != null) {
      final tfTemplates =
          loadLocalDayTemplatesForDestination(trip.destination);
      if (tfTemplates.isNotEmpty) {
        final tfResult = tryTemplateFirstPipeline(
          trip: trip,
          di: destinationIntelligenceForTrip,
          templates: tfTemplates,
          pool: pool,
          complexGroups: complexGroupsForTrip,
        );
        if (tfResult.isUsable) {
          // ignore: avoid_print
          print(
            '[template_first_pipeline] using template-first '
            '${tfResult.activities.length} visits',
          );
          final tfBudgetCap = priceLevelCapForBudget(
            budgetPerPersonEur: trip.budgetPerPersonEur,
            durationDays:
                trip.endDate.difference(trip.startDate).inDays + 1,
          );
          final tfMeals = await insertDeterministicMeals(
            activities: tfResult.activities,
            pool: pool,
            nearbyService: nearbyService,
            travelerProfile: travelerProfile,
            tripInterests: trip.interests ?? const <String>[],
            languageCode: 'fr',
            localTransportMode: trip.localTransportMode,
            budgetPriceCap: tfBudgetCap,
          );
          return (visits: tfResult.activities, meals: tfMeals);
        }
        // ignore: avoid_print
        print(
          '[template_first_fallback] reason=${tfResult.fallbackReason}',
        );
      } else {
        // ignore: avoid_print
        print('[template_first_fallback] reason=missing_templates');
      }
    }

    final visits = selectVisitsDeterministic(
      clusters: clusters,
      trip: trip,
      travelerProfile: travelerProfile,
      useSameComplexDedup: featureFlags.useSameComplexDedup,
      complexGroups: complexGroupsForTrip,
      useDestinationScope: featureFlags.useDestinationScope,
      destinationIntelligence: destinationIntelligenceForTrip,
    );

    final budgetPriceCap = priceLevelCapForBudget(
      budgetPerPersonEur: trip.budgetPerPersonEur,
      durationDays: trip.endDate.difference(trip.startDate).inDays + 1,
    );

    final meals = await insertDeterministicMeals(
      activities: visits,
      pool: pool,
      nearbyService: nearbyService,
      travelerProfile: travelerProfile,
      tripInterests: trip.interests ?? const <String>[],
      languageCode: 'fr',
      localTransportMode: trip.localTransportMode,
      budgetPriceCap: budgetPriceCap,
    );

    return (visits: visits, meals: meals);
  }

  // V8.28b1.x — capture des `print` du pipeline pour récupérer les
  // compteurs `[places_selector_summary]`, `[places_first_skip_visit]`,
  // `[metro_anchor_fanout]`, etc. Sans cette capture, ces signaux sont
  // perdus dans stdout du test runner.
  late ({List<ActivitySuggestion> visits, List<ActivitySuggestion> meals})
      result;
  await runZoned<Future<void>>(() async {
    result = await runBody();
  }, zoneSpecification: ZoneSpecification(
    print: (self, parent, zone, line) {
      logs.add(line);
      parent.print(zone, line);
    },
  ));

  return _RunOutput(
    visits: result.visits,
    meals: result.meals,
    capturedLogs: logs,
  );
}

// ─── Métriques résumé console ────────────────────────────────────────────

String _normalizeName(String s) =>
    s.toLowerCase().trim().replaceAll(RegExp(r'\s+'), ' ');

double _haversineMeters(double lat1, double lng1, double lat2, double lng2) {
  const earthM = 6371000.0;
  final dLat = (lat2 - lat1) * math.pi / 180.0;
  final dLng = (lng2 - lng1) * math.pi / 180.0;
  final a = math.sin(dLat / 2) * math.sin(dLat / 2) +
      math.cos(lat1 * math.pi / 180.0) *
          math.cos(lat2 * math.pi / 180.0) *
          math.sin(dLng / 2) *
          math.sin(dLng / 2);
  return earthM * 2 * math.atan2(math.sqrt(a), math.sqrt(1 - a));
}

class _Summary {
  final int totalVisits;
  final int totalMeals;
  final int totalGeneratedDays;
  final int freeDaysCount;
  final int duplicateNameVisitsCount;
  final List<String> repeatedNames;
  /// `null` si trop peu de slots avec coords pour calculer.
  final double? avgInterSlotDistanceMeters;
  const _Summary({
    required this.totalVisits,
    required this.totalMeals,
    required this.totalGeneratedDays,
    required this.freeDaysCount,
    required this.duplicateNameVisitsCount,
    required this.repeatedNames,
    required this.avgInterSlotDistanceMeters,
  });
}

_Summary _computeSummary(Trip trip, _RunOutput run) {
  final visits = run.visits;

  // Comptage doublons VISITES par nom normalisé (consigne user :
  // "détectable simplement par nom normalisé").
  final nameCount = <String, int>{};
  for (final v in visits) {
    final n = _normalizeName(v.title);
    nameCount[n] = (nameCount[n] ?? 0) + 1;
  }
  final duplicateCount = nameCount.values
      .where((c) => c > 1)
      .fold<int>(0, (sum, c) => sum + (c - 1));
  final repeatedNames = nameCount.entries
      .where((e) => e.value > 1)
      .map((e) => '${e.key} ×${e.value}')
      .toList()
    ..sort();

  // Jours générés vs jours du trip.
  final tripStart = DateTime.utc(
      trip.startDate.year, trip.startDate.month, trip.startDate.day);
  final tripEnd =
      DateTime.utc(trip.endDate.year, trip.endDate.month, trip.endDate.day);
  final totalTripDays = tripEnd.difference(tripStart).inDays + 1;
  final daysWithVisits = visits
      .map((v) => DateTime.utc(v.dayDate.year, v.dayDate.month, v.dayDate.day))
      .toSet();
  final freeDaysCount = totalTripDays - daysWithVisits.length;

  // Distance moyenne entre slots consécutifs du même jour (avec coords).
  final byDay = <DateTime, List<ActivitySuggestion>>{};
  for (final v in visits) {
    final key = DateTime.utc(v.dayDate.year, v.dayDate.month, v.dayDate.day);
    byDay.putIfAbsent(key, () => []).add(v);
  }
  final hops = <double>[];
  for (final day in byDay.entries) {
    final list = [...day.value]..sort((a, b) => a.startTime.compareTo(b.startTime));
    for (var i = 1; i < list.length; i++) {
      final a = list[i - 1];
      final b = list[i];
      if (a.latitude != null && a.longitude != null &&
          b.latitude != null && b.longitude != null) {
        hops.add(_haversineMeters(
            a.latitude!, a.longitude!, b.latitude!, b.longitude!));
      }
    }
  }
  final avgInterSlotDistanceMeters = hops.isEmpty
      ? null
      : hops.reduce((a, b) => a + b) / hops.length;

  return _Summary(
    totalVisits: visits.length,
    totalMeals: run.meals.length,
    totalGeneratedDays: daysWithVisits.length,
    freeDaysCount: freeDaysCount,
    duplicateNameVisitsCount: duplicateCount,
    repeatedNames: repeatedNames,
    avgInterSlotDistanceMeters: avgInterSlotDistanceMeters,
  );
}

// ─── Sérialisation JSON ──────────────────────────────────────────────────

Map<String, dynamic> _activityToJson(ActivitySuggestion a) => {
      'day_date': a.dayDate.toIso8601String().split('T').first,
      'start_time': a.startTime,
      'title': a.title,
      'detail': a.detail,
      'tag': a.tag,
      'kind': a.kind.toString().split('.').last,
      'duration_minutes': a.durationMinutes,
      'price_estimate': a.priceEstimate,
      'match_reason': a.matchReason,
      'latitude': a.latitude,
      'longitude': a.longitude,
    };

String _runGitRevHead() {
  try {
    final result =
        Process.runSync('git', ['rev-parse', 'HEAD'], runInShell: false);
    if (result.exitCode == 0) {
      return (result.stdout as String).trim();
    }
  } catch (_) {}
  return 'unknown';
}

Map<String, dynamic> _buildBaselineJson({
  required Trip trip,
  required _RunOutput run,
  required _Summary summary,
  required PlanningQualityReport qualityReport,
}) {
  return {
    'metadata': {
      'generated_at': DateTime.now().toUtc().toIso8601String(),
      'pipeline_commit': _runGitRevHead(),
      'pipeline_version': 'V8.28c',
      'warning':
          'Baseline immuable PAR ENGAGEMENT HUMAIN (cf. règle d\'or 2 du '
          'plan de refonte). Hit la vraie Google Places API et NON '
          'déterministe au sens strict. Ne pas re-générer ce fichier. '
          'Pour une nouvelle baseline future, créer un fichier séparé.',
      'trip': {
        'id': trip.id,
        'destination': trip.destination,
        'country_code': trip.destinationCountryCode,
        'country_name': trip.destinationCountryName,
        'start_date': trip.startDate.toIso8601String().split('T').first,
        'end_date': trip.endDate.toIso8601String().split('T').first,
        'duration_days':
            trip.endDate.difference(trip.startDate).inDays + 1,
        'traveler_type': trip.travelerType,
        'interests': trip.interests,
        'local_transport_mode': trip.localTransportMode,
        'budget_per_person_eur': trip.budgetPerPersonEur,
      },
    },
    'summary': {
      'total_visits': summary.totalVisits,
      'total_meals': summary.totalMeals,
      'total_generated_days': summary.totalGeneratedDays,
      'free_days_count': summary.freeDaysCount,
      'duplicate_name_visits_count': summary.duplicateNameVisitsCount,
      'repeated_names': summary.repeatedNames,
      'avg_inter_slot_distance_meters':
          summary.avgInterSlotDistanceMeters?.toStringAsFixed(1),
    },
    // Phase 0 / Tâche 0.2 — Métriques qualité agrégées calculées via
    // `computePlanningMetrics` du module `lib/quality/planning_metrics.dart`.
    // Pure compute, déterministe à entrée identique. Voir la doc
    // `docs/migrations/phase0_task0_2.md` pour la définition exacte des
    // scores et seuils.
    'quality_report': qualityReport.toJson(),
    'visits': run.visits.map(_activityToJson).toList(),
    'meals': run.meals.map(_activityToJson).toList(),
    'captured_logs': run.capturedLogs,
  };
}

// ─── Affichage console ───────────────────────────────────────────────────

void _printSummary(_Summary s) {
  // ignore: avoid_print
  print('');
  // ignore: avoid_print
  print('═══════════════════════════════════════════════════════════════');
  // ignore: avoid_print
  print('  SINGAPORE BASELINE SNAPSHOT — résumé');
  // ignore: avoid_print
  print('═══════════════════════════════════════════════════════════════');
  // ignore: avoid_print
  print('  Total visites      : ${s.totalVisits}');
  // ignore: avoid_print
  print('  Total repas        : ${s.totalMeals}');
  // ignore: avoid_print
  print('  Jours avec activité: ${s.totalGeneratedDays}');
  // ignore: avoid_print
  print('  Jours libres       : ${s.freeDaysCount}');
  // ignore: avoid_print
  print('  Doublons (par nom) : ${s.duplicateNameVisitsCount}');
  if (s.repeatedNames.isNotEmpty) {
    // ignore: avoid_print
    print('  Lieux répétés      :');
    for (final r in s.repeatedNames) {
      // ignore: avoid_print
      print('    - $r');
    }
  } else {
    // ignore: avoid_print
    print('  Lieux répétés      : (aucun)');
  }
  // ignore: avoid_print
  print('  Distance inter-slot moyenne : ${s.avgInterSlotDistanceMeters == null
      ? 'not_available (pas assez de slots avec coords)'
      : '${s.avgInterSlotDistanceMeters!.toStringAsFixed(1)} m'}');
  // ignore: avoid_print
  print('═══════════════════════════════════════════════════════════════');
  // ignore: avoid_print
  print('');
}

String _scoreLabel(double? score) =>
    score == null ? 'n/a' : '${score.toStringAsFixed(1)} / 100';

void _printQualityReport(PlanningQualityReport r) {
  // ignore: avoid_print
  print('═══════════════════════════════════════════════════════════════');
  // ignore: avoid_print
  print('  PLANNING QUALITY REPORT (Phase 0 / Tâche 0.2)');
  // ignore: avoid_print
  print('═══════════════════════════════════════════════════════════════');
  // ignore: avoid_print
  print('  Overall score      : ${_scoreLabel(r.overallScore)}');
  // ignore: avoid_print
  print('  ├─ coherence       : ${_scoreLabel(r.coherenceScore)}'
      '   (compacité jour par jour)');
  // ignore: avoid_print
  print('  ├─ diversity       : ${_scoreLabel(r.diversityScore)}'
      '   (entropie Shannon des tags visites)');
  // ignore: avoid_print
  print('  ├─ repetition      : ${_scoreLabel(r.repetitionScore)}'
      '   (haut = peu de répétitions)');
  // ignore: avoid_print
  print('  ├─ transition      : ${_scoreLabel(r.transitionScore)}'
      '   (distances inter-slot)');
  // ignore: avoid_print
  print('  └─ coverage        : ${_scoreLabel(r.coverageScore)}'
      '   (% journées remplies)');
  // ignore: avoid_print
  print('  Totaux             : ${r.totalSlots} slots '
      '(${r.totalVisits} visites + ${r.totalMeals} repas)');
  // ignore: avoid_print
  print('  Jours actifs       : ${r.totalDaysWithActivity}/'
      '${r.totalExpectedDays}');
  if (r.repeatedTitlesNormalized.isNotEmpty) {
    // ignore: avoid_print
    print('  Titres répétés     : ${r.repeatedTitlesNormalized.join(", ")}');
  }
  final daysWithWarnings = r.byDay.where((d) => d.warnings.isNotEmpty).toList();
  if (daysWithWarnings.isNotEmpty) {
    // ignore: avoid_print
    print('  Jours avec warnings :');
    for (final d in daysWithWarnings) {
      // ignore: avoid_print
      print('    - ${d.date.toIso8601String().split("T").first} '
          ': ${d.warnings.join(", ")}');
    }
  } else {
    // ignore: avoid_print
    print('  Jours avec warnings : (aucun)');
  }
  // ignore: avoid_print
  print('═══════════════════════════════════════════════════════════════');
  // ignore: avoid_print
  print('');
}

// ─── Entry point ─────────────────────────────────────────────────────────

void main() {
  // V7+ — `nearbyService.startRun` n'est pas appelé ici (cf. harness
  // existant `places_first_harness.dart`) : le snapshot est un cas
  // unique, pas besoin de scoping budget Cost-1 par trip. Les
  // appels Places passent quand même par le service avec leur
  // dedup intra-run interne.

  test('Singapore baseline — generate + dump JSON snapshot', () async {
    assertLiveApisAllowedForGenerateBaseline();

    final trip = _buildSingaporeTrip();
    // ignore: avoid_print
    print('');
    // ignore: avoid_print
    print('▶ Génération baseline Singapour ${trip.startDate
        .toIso8601String()
        .split('T')
        .first} → ${trip.endDate.toIso8601String().split('T').first}');
    // ignore: avoid_print
    print('  Profil : ${trip.travelerType} · Budget : '
        '${trip.budgetPerPersonEur}€ · Transport : ${trip.localTransportMode}');
    // ignore: avoid_print
    print(
        '  Intérêts : ${trip.interests?.join(", ")}');
    // ignore: avoid_print
    print(
        '  Hit la vraie Google Places API — patientez ~30-90s...');
    // ignore: avoid_print
    print('');

    final run = await _runPipeline(trip);
    final summary = _computeSummary(trip, run);

    // V8.28c+ / Phase 0 Tâche 0.2 — Métriques qualité calculées sur
    // visites + repas combinés. La fonction sépare visites/repas en
    // interne via l'heuristique startTime (12:30 / 19:30 = meal slots).
    // `expectedTripDays` fourni explicitement pour que le coverage
    // score reflète le span complet du voyage même si les premier/
    // dernier jours ne sont pas peuplés.
    final tripDays =
        trip.endDate.difference(trip.startDate).inDays + 1;
    final qualityReport = computePlanningMetrics(
      [...run.visits, ...run.meals],
      expectedTripDays: tripDays,
    );

    _printSummary(summary);
    _printQualityReport(qualityReport);

    // Écriture du JSON. Chemin absolu basé sur cwd = racine du
    // projet Flutter (convention `flutter test`).
    final json = _buildBaselineJson(
      trip: trip,
      run: run,
      summary: summary,
      qualityReport: qualityReport,
    );
    final encoder = const JsonEncoder.withIndent('  ');
    final outputPath = 'test/snapshots/singapore_baseline.json';
    final file = File(outputPath);
    file.writeAsStringSync(encoder.convert(json));

    // ignore: avoid_print
    print('✔ Baseline JSON écrit → $outputPath');
    // ignore: avoid_print
    print('  Taille : ${file.lengthSync()} octets');
    // ignore: avoid_print
    print('');

    // Sanity assertions minimales (non bloquantes pour le snapshot,
    // mais flag si quelque chose est manifestement cassé).
    expect(summary.totalVisits, greaterThan(0),
        reason: 'Baseline doit avoir au moins une visite — sinon échec '
            'pipeline ou API key invalide');
    expect(run.visits.every((v) => v.title.isNotEmpty), isTrue);
  }, timeout: const Timeout(Duration(minutes: 5)));
}
