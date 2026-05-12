/// Phase 4 / Tâche 4.8 — Fixtures offline pour validation A/B
/// template-first Singapour.
///
/// **Fichier de test/fixtures uniquement.** Aucun appel réseau,
/// aucune dépendance Google Places, aucune migration. Conforme à la
/// règle absolue zéro-API-live de la Tâche 4.8.
///
/// ## Rôle
///
/// Fournit un jeu de `TemplateCandidate` (et helpers `NearbyCandidate`
/// associés pour les tests pipeline end-to-end) représentatifs de
/// Singapour, incluant volontairement :
/// - bons candidats Marina Bay / Sentosa / Orchard / Botanic /
///   Chinatown / Little India / Kampong Glam ;
/// - candidats trop éloignés (Sentosa scénario Marina Bay et
///   inversement) ;
/// - hawker centres / food centres (à bloquer en visit, à autoriser
///   en meal) ;
/// - candidats faibles (rating < 4.0 ou reviews < 50) ;
/// - cafés obscurs.
///
/// Les coordonnées sont des **constantes copiées** depuis sources
/// locales validées :
/// - centres de zones : `buildSingaporeDestinationIntelligence()`
///   (`lib/data/destinations/singapore.dart`) ;
/// - anchors emblématiques : valeurs publiques Google Maps usuelles
///   (Marina Bay Sands 1.2834/103.8607, etc.).
///
/// Pas de fetch, pas de parsing dynamique : tout est `const` ou
/// instancié à la volée.
library;

import 'dart:math' as math;

import 'package:voyage/features/planning/services/day_center_service.dart';
import 'package:voyage/features/planning/services/places_first_pipeline.dart'
    show DayCandidates;
import 'package:voyage/features/planning/services/places_nearby_service.dart';
import 'package:voyage/models/day_template.dart' show ExpectedSlotType;
import 'package:voyage/models/destination_intelligence.dart' show GeoPoint;
import 'package:voyage/services/template_first_day_builder.dart';

// ─── Centres de zones (copiés depuis `singapore.dart`) ────────────────

const GeoPoint kMarinaBayCenter = GeoPoint(lat: 1.2830, lng: 103.8600);
const GeoPoint kSentosaCenter = GeoPoint(lat: 1.2494, lng: 103.8303);
const GeoPoint kChinatownCenter = GeoPoint(lat: 1.2814, lng: 103.8443);
const GeoPoint kOrchardCenter = GeoPoint(lat: 1.3050, lng: 103.8327);
const GeoPoint kBotanicCenter = GeoPoint(lat: 1.3138, lng: 103.8159);
const GeoPoint kLittleIndiaCenter = GeoPoint(lat: 1.3066, lng: 103.8520);
const GeoPoint kKampongGlamCenter = GeoPoint(lat: 1.3019, lng: 103.8590);

// ─── Helper compact pour fabriquer un TemplateCandidate ──────────────

TemplateCandidate tc({
  required String placeKey,
  required String title,
  required String category,
  required double score,
  String? anchorKey,
  String? complexKey,
  double? rating,
  int? userRatingCount,
  double? lat,
  double? lng,
  int? estimatedDurationMinutes,
}) {
  return TemplateCandidate(
    placeKey: placeKey,
    title: title,
    category: category,
    score: score,
    anchorKey: anchorKey,
    complexKey: complexKey,
    rating: rating,
    userRatingCount: userRatingCount,
    lat: lat,
    lng: lng,
    estimatedDurationMinutes: estimatedDurationMinutes,
  );
}

// ─── Pools par zone (TemplateCandidate, input direct du builder) ──────

/// 5 bons candidats Marina Bay. `anchorKey` aligné sur les noms
/// présents dans `recommendedAnchorKeys` du template
/// `marina_bay_day` quand pertinent.
List<TemplateCandidate> marinaBayPool() => [
      tc(
        placeKey: 'p_mbs',
        title: 'Marina Bay Sands',
        category: 'anchor',
        anchorKey: 'Marina Bay Sands',
        complexKey: 'marina_bay_sands',
        score: 95,
        rating: 4.7,
        userRatingCount: 80000,
        lat: 1.2834,
        lng: 103.8607,
        estimatedDurationMinutes: 180,
      ),
      tc(
        placeKey: 'p_gbb',
        title: 'Gardens by the Bay',
        category: 'anchor',
        anchorKey: 'Gardens by the Bay',
        complexKey: 'gardens_by_the_bay',
        score: 92,
        rating: 4.8,
        userRatingCount: 150000,
        lat: 1.2816,
        lng: 103.8636,
        estimatedDurationMinutes: 180,
      ),
      tc(
        placeKey: 'p_merlion',
        title: 'Merlion Park',
        category: 'visit',
        anchorKey: 'Merlion Park',
        score: 80,
        rating: 4.5,
        userRatingCount: 60000,
        lat: 1.2868,
        lng: 103.8545,
        estimatedDurationMinutes: 30,
      ),
      tc(
        placeKey: 'p_supertree',
        title: 'Supertree Grove',
        category: 'visit',
        complexKey: 'gardens_by_the_bay',
        score: 88,
        rating: 4.7,
        userRatingCount: 40000,
        lat: 1.2820,
        lng: 103.8636,
        estimatedDurationMinutes: 90,
      ),
      tc(
        placeKey: 'p_artscience',
        title: 'ArtScience Museum',
        category: 'visit',
        anchorKey: 'ArtScience Museum',
        complexKey: 'marina_bay_sands',
        score: 78,
        rating: 4.5,
        userRatingCount: 25000,
        lat: 1.2862,
        lng: 103.8593,
        estimatedDurationMinutes: 120,
      ),
    ];

/// Candidats Sentosa — à utiliser dans des scénarios « Marina Bay »
/// pour vérifier qu'ils sont rejetés / dépriorisés malgré un score
/// élevé. À l'inverse, dans un scénario `sentosa_day`, ils sont
/// les bons choix.
List<TemplateCandidate> sentosaPool() => [
      tc(
        placeKey: 'p_sentosa',
        title: 'Sentosa Island',
        category: 'anchor',
        anchorKey: 'Sentosa Island',
        complexKey: 'sentosa',
        score: 95,
        rating: 4.6,
        userRatingCount: 70000,
        lat: 1.2494,
        lng: 103.8303,
        estimatedDurationMinutes: 360,
      ),
      tc(
        placeKey: 'p_uss',
        title: 'Universal Studios Singapore',
        category: 'anchor',
        complexKey: 'sentosa',
        score: 99,
        rating: 4.6,
        userRatingCount: 80000,
        lat: 1.2540,
        lng: 103.8238,
        estimatedDurationMinutes: 360,
      ),
      tc(
        placeKey: 'p_oceanarium',
        title: 'Singapore Oceanarium',
        category: 'visit',
        complexKey: 'sentosa',
        score: 85,
        rating: 4.5,
        userRatingCount: 50000,
        lat: 1.2585,
        lng: 103.8221,
        estimatedDurationMinutes: 180,
      ),
    ];

/// Hawker centres / food centres. À bloquer en slot non-meal,
/// acceptables en slot meal.
List<TemplateCandidate> hawkerPool() => [
      tc(
        placeKey: 'p_lau_pa_sat',
        title: 'Lau Pa Sat',
        category: 'meal',
        anchorKey: 'Lau Pa Sat',
        score: 78,
        rating: 4.4,
        userRatingCount: 30000,
        lat: 1.2806,
        lng: 103.8503,
        estimatedDurationMinutes: 60,
      ),
      tc(
        placeKey: 'p_maxwell',
        title: 'Maxwell Food Centre',
        category: 'meal',
        anchorKey: 'Maxwell Food Centre',
        score: 82,
        rating: 4.6,
        userRatingCount: 30000,
        lat: 1.2807,
        lng: 103.8447,
        estimatedDurationMinutes: 60,
      ),
      tc(
        placeKey: 'p_hong_lim',
        title: 'Hong Lim Food Centre',
        category: 'meal',
        score: 75,
        rating: 4.3,
        userRatingCount: 8000,
        lat: 1.2849,
        lng: 103.8453,
        estimatedDurationMinutes: 60,
      ),
      tc(
        placeKey: 'p_tekka',
        title: 'Tekka Centre',
        category: 'meal',
        score: 72,
        rating: 4.2,
        userRatingCount: 6000,
        lat: 1.3060,
        lng: 103.8506,
        estimatedDurationMinutes: 60,
      ),
    ];

/// Variantes hawker volontairement étiquetées comme `visit` (catégorie
/// trompeuse — c'est exactement le cas observé en A/B 4.6, hawker
/// centre sorti par le pipeline avec `types: ['tourist_attraction']`).
List<TemplateCandidate> hawkerMislabeledAsVisit() => [
      tc(
        placeKey: 'p_lau_pa_sat_visit',
        title: 'Lau Pa Sat',
        category: 'visit', // catégorie trompeuse
        score: 95,
        rating: 4.4,
        userRatingCount: 30000,
        lat: 1.2806,
        lng: 103.8503,
      ),
      tc(
        placeKey: 'p_maxwell_visit',
        title: 'Maxwell Food Centre',
        category: 'visit',
        score: 90,
        rating: 4.6,
        userRatingCount: 30000,
        lat: 1.2807,
        lng: 103.8447,
      ),
      tc(
        placeKey: 'p_hong_lim_visit',
        title: 'Hong Lim Food Centre',
        category: 'visit',
        score: 80,
        rating: 4.3,
        userRatingCount: 8000,
        lat: 1.2849,
        lng: 103.8453,
      ),
    ];

/// Candidats faibles / cafés obscurs. Devraient être rejetés en
/// slot non-meal par le quality floor (rating < 4.0 OU reviews <
/// 50).
List<TemplateCandidate> weakPool() => [
      tc(
        placeKey: 'p_columbus_coffee',
        title: 'Columbus Coffee Co.',
        category: 'visit',
        score: 60,
        rating: 4.1,
        userRatingCount: 35, // reviews < 50 → rejet quality floor
        lat: 1.2825,
        lng: 103.8538,
      ),
      tc(
        placeKey: 'p_sod_cafe',
        title: 'SOD Cafe',
        category: 'visit',
        score: 55,
        rating: 3.7, // rating < 4.0 → rejet quality floor
        userRatingCount: 150,
        lat: 1.2806,
        lng: 103.8478,
      ),
      tc(
        placeKey: 'p_obscure_attraction',
        title: 'Obscure Random Place',
        category: 'visit',
        score: 50,
        rating: 3.5, // rating < 4.0 → rejet quality floor
        userRatingCount: 20, // reviews < 50 → rejet
        lat: 1.2840,
        lng: 103.8605,
      ),
    ];

/// Pool Orchard / Botanic — pour template `orchard_botanic_day`.
List<TemplateCandidate> orchardBotanicPool() => [
      tc(
        placeKey: 'p_botanic',
        title: 'Singapore Botanic Gardens',
        category: 'anchor',
        anchorKey: 'Singapore Botanic Gardens',
        score: 90,
        rating: 4.7,
        userRatingCount: 100000,
        lat: 1.3138,
        lng: 103.8159,
        estimatedDurationMinutes: 150,
      ),
      tc(
        placeKey: 'p_orchard_road',
        title: 'Orchard Road',
        category: 'shopping',
        anchorKey: 'Orchard Road',
        complexKey: 'orchard_shopping',
        score: 80,
        rating: 4.4,
        userRatingCount: 40000,
        lat: 1.3050,
        lng: 103.8327,
        estimatedDurationMinutes: 150,
      ),
    ];

/// Pool Chinatown — pour template `chinatown_civic_day`.
List<TemplateCandidate> chinatownPool() => [
      tc(
        placeKey: 'p_buddha',
        title: 'Buddha Tooth Relic Temple',
        category: 'anchor',
        anchorKey: 'Buddha Tooth Relic Temple',
        complexKey: 'chinatown_heritage',
        score: 88,
        rating: 4.7,
        userRatingCount: 30000,
        lat: 1.2814,
        lng: 103.8443,
        estimatedDurationMinutes: 120,
      ),
      tc(
        placeKey: 'p_chinatown',
        title: 'Chinatown',
        category: 'anchor',
        anchorKey: 'Chinatown',
        complexKey: 'chinatown_heritage',
        score: 75,
        rating: 4.4,
        userRatingCount: 25000,
        lat: 1.2814,
        lng: 103.8443,
        estimatedDurationMinutes: 120,
      ),
    ];

/// Pool Little India / Kampong Glam — pour template
/// `little_india_kampong_day`.
List<TemplateCandidate> kampongLittleIndiaPool() => [
      tc(
        placeKey: 'p_little_india',
        title: 'Little India',
        category: 'anchor',
        anchorKey: 'Little India',
        score: 80,
        rating: 4.4,
        userRatingCount: 20000,
        lat: 1.3066,
        lng: 103.8520,
        estimatedDurationMinutes: 120,
      ),
      tc(
        placeKey: 'p_kampong_glam',
        title: 'Kampong Glam / Arab Street',
        category: 'visit',
        anchorKey: 'Kampong Glam / Arab Street',
        score: 78,
        rating: 4.5,
        userRatingCount: 15000,
        lat: 1.3019,
        lng: 103.8590,
        estimatedDurationMinutes: 120,
      ),
    ];

/// Candidat à > 50 km de Marina Bay (équivalent Johor Bahru).
/// À utiliser pour tester le rejet > 10 km de l'Axe 1.
TemplateCandidate veryFarCandidate({
  required String placeKey,
  required String title,
  String category = 'visit',
  double score = 100,
}) =>
    tc(
      placeKey: placeKey,
      title: title,
      category: category,
      score: score,
      rating: 4.5,
      userRatingCount: 1000,
      lat: 1.7000, // ~50 km au nord de Singapour
      lng: 103.8600,
    );

// ─── Helpers `NearbyCandidate` (pour tests pipeline end-to-end) ───────

NearbyCandidate nc({
  required String placeId,
  required String name,
  required List<String> types,
  double lat = 1.283,
  double lng = 103.860,
  double rating = 4.5,
  int reviews = 1000,
}) {
  return NearbyCandidate(
    placeId: placeId,
    name: name,
    latitude: lat,
    longitude: lng,
    rating: rating,
    userRatingCount: reviews,
    types: types,
  );
}

DayCandidates dayCandsFor(
  DateTime day, {
  required Map<String, List<NearbyCandidate>> byInterest,
  double centerLat = 1.283,
  double centerLng = 103.860,
}) {
  return DayCandidates(
    day: day,
    center: DayCenter(
      latitude: centerLat,
      longitude: centerLng,
      source: 'destination',
    ),
    byInterest: byInterest,
  );
}

// ─── Helper rapport offline — métriques d'évaluation ─────────────────

/// Rapport offline calculé sur un `TemplateDayBuildResult` ou une
/// liste d'`ActivitySuggestion`. Sert à `template_first_offline_ab_test.dart`
/// pour formuler des assertions chiffrées sans dépendre de Google
/// Places.
///
/// Métriques :
/// - `filledSlotsCount` / `nonFreeSlotsCount` ;
/// - `transitionsBelowKm` / `transitionsAboveKm(threshold)` ;
/// - `hawkerCountInNonMealSlots` (régression A/B 4.6) ;
/// - `outOfZoneCount(zoneCenter, thresholdKm)`.
class OfflineAbReport {
  final int filledSlotsCount;
  final int nonFreeSlotsCount;
  final List<double> intraDayHopsKm;
  final int hawkerInNonMealSlotsCount;
  final int outOfZoneCount;

  const OfflineAbReport({
    required this.filledSlotsCount,
    required this.nonFreeSlotsCount,
    required this.intraDayHopsKm,
    required this.hawkerInNonMealSlotsCount,
    required this.outOfZoneCount,
  });

  int transitionsAboveKm(double thresholdKm) =>
      intraDayHopsKm.where((d) => d > thresholdKm).length;

  double get avgHopKm => intraDayHopsKm.isEmpty
      ? 0.0
      : intraDayHopsKm.reduce((a, b) => a + b) / intraDayHopsKm.length;

  double get maxHopKm =>
      intraDayHopsKm.isEmpty ? 0.0 : intraDayHopsKm.reduce((a, b) => a > b ? a : b);
}

/// Pré-calcule un `OfflineAbReport` à partir des assignments d'une
/// journée. `zoneCenter` peut être `null` (skip out-of-zone check).
/// `outOfZoneThresholdKm` par défaut 10 (cohérent avec l'Axe 1).
OfflineAbReport reportFor(
  TemplateDayBuildResult result, {
  GeoPoint? zoneCenter,
  double outOfZoneThresholdKm = 10.0,
}) {
  // Hops intra-jour entre slots remplis successifs.
  final filled = result.assignments
      .where((a) => a.candidate != null && a.candidate!.lat != null &&
          a.candidate!.lng != null)
      .toList();

  final hops = <double>[];
  for (var i = 1; i < filled.length; i++) {
    final a = filled[i - 1].candidate!;
    final b = filled[i].candidate!;
    hops.add(_haversineKm(a.lat!, a.lng!, b.lat!, b.lng!));
  }

  // Hawker count dans des slots non-meal.
  const hawkerPatterns = [
    'hawker centre',
    'hawker center',
    'food centre',
    'food center',
    'food court',
    'lau pa sat',
    'maxwell food centre',
    'hong lim food centre',
    'tekka centre',
  ];
  var hawkerInNonMeal = 0;
  for (final a in result.assignments) {
    final c = a.candidate;
    if (c == null) continue;
    if (a.slot.expectedType == ExpectedSlotType.meal) continue;
    final titleLower = c.title.toLowerCase();
    if (hawkerPatterns.any((p) => titleLower.contains(p))) {
      hawkerInNonMeal++;
    }
  }

  // Out-of-zone count.
  var outOfZone = 0;
  if (zoneCenter != null) {
    for (final a in result.assignments) {
      final c = a.candidate;
      if (c == null || c.lat == null || c.lng == null) continue;
      final d = _haversineKm(c.lat!, c.lng!, zoneCenter.lat, zoneCenter.lng);
      if (d > outOfZoneThresholdKm) outOfZone++;
    }
  }

  final nonFreeSlots = result.assignments
      .where((a) => a.slot.expectedType != ExpectedSlotType.freeTime)
      .length;
  final filledCount =
      result.assignments.where((a) => a.candidate != null).length;

  return OfflineAbReport(
    filledSlotsCount: filledCount,
    nonFreeSlotsCount: nonFreeSlots,
    intraDayHopsKm: hops,
    hawkerInNonMealSlotsCount: hawkerInNonMeal,
    outOfZoneCount: outOfZone,
  );
}

double _haversineKm(double lat1, double lng1, double lat2, double lng2) {
  const earthKm = 6371.0;
  final dLat = (lat2 - lat1) * math.pi / 180.0;
  final dLng = (lng2 - lng1) * math.pi / 180.0;
  final sLat = math.sin(dLat / 2);
  final sLng = math.sin(dLng / 2);
  final a = sLat * sLat +
      math.cos(lat1 * math.pi / 180.0) *
          math.cos(lat2 * math.pi / 180.0) *
          sLng *
          sLng;
  return earthKm * 2 * math.atan2(math.sqrt(a), math.sqrt(1 - a));
}
