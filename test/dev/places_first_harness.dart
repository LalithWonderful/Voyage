// Harness Places-first — script DEV (pas un test CI).
//
// Lance le pipeline déterministe (gather → cluster → selectVisits → meals)
// pour 3 profils Lunao sur le même voyage Marrakech + Essaouira, puis
// imprime un tableau comparatif de KPIs et exécute les assertions fortes.
//
// Hits real Google Places API — clé via `AiConstants.googleMapsApiKey`.
// Quota approximatif : ~6 intérêts × 6 jours × 2-3 calls/jour ≈ 50-100 RPCs
// par profil. Lent (~30-60s par profil). Non déterministe au sens strict :
// Google peut renvoyer des lieux différents d'un run à l'autre.
//
// Run :
//   flutter test test/dev/places_first_harness.dart
//
// Le fichier est nommé sans `_test` pour ne PAS être picked up par
// `flutter test` sans args. Run explicite uniquement.
//
// Extensible :
// - Ajouter un profil → ajouter une entrée dans `_scenarios`.
// - Ajouter un KPI → ajouter un champ dans `_Kpi` + sa computation dans
//   `_computeKpi` + une colonne dans `_renderTable`.
// - Ajouter une assertion → ajouter un cas dans `_runAssertions`.

import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:voyage/features/planning/models/activity_suggestion_model.dart';
import 'package:voyage/features/planning/services/geocoding_service.dart';
import 'package:voyage/features/planning/services/places_first_pipeline.dart';
import 'package:voyage/features/planning/services/places_nearby_service.dart';
import 'package:voyage/features/planning/services/traveler_to_places_mapping.dart';
import 'package:voyage/features/trips/models/trip_model.dart';

// ─── Scénarios ────────────────────────────────────────────────────────────

class _Scenario {
  final String label;
  final String travelerType;
  final num? budgetPerPersonEur;
  final List<String> interests;
  final String? localTransportMode;
  const _Scenario({
    required this.label,
    required this.travelerType,
    required this.budgetPerPersonEur,
    required this.interests,
    required this.localTransportMode,
  });
}

/// Les 10 profils Lunao. Échelle budget calibrée sur le voyage 6 jours :
/// `priceLevelCapForBudget` cap à 2 sous 50€/d, à 3 sous 120€/d, illimité
/// au-dessus. Les budgets ci-dessous testent les 3 régimes.
const _scenarios = <_Scenario>[
  _Scenario(
    label: 'Meilleur prix',
    travelerType: 'Meilleur prix',
    budgetPerPersonEur: 350, // ~58€/d → cap 3
    interests: ['Culture', 'Plage', 'Bons plans', 'Hors circuit', 'Gastronomie'],
    localTransportMode: 'walk',
  ),
  _Scenario(
    label: 'Backpack',
    travelerType: 'Backpack',
    budgetPerPersonEur: 250, // ~42€/d → cap 2 (économique strict)
    interests: ['Hors circuit', 'Bons plans', 'Nature', 'Plage', 'Gastronomie'],
    localTransportMode: 'walk',
  ),
  _Scenario(
    label: 'Chill',
    travelerType: 'Chill',
    budgetPerPersonEur: 700, // ~117€/d → cap 3
    interests: ['Nature', 'Plage', 'Spots populaires', 'Gastronomie', 'Wellness'],
    localTransportMode: 'walk',
  ),
  _Scenario(
    label: 'En famille',
    travelerType: 'En famille',
    budgetPerPersonEur: 850, // ~142€/d → no cap
    interests: ['Spots populaires', 'Nature', 'Culture', 'Plage', 'Gastronomie'],
    localTransportMode: 'public_transport',
  ),
  _Scenario(
    label: 'Senior',
    travelerType: 'Senior',
    budgetPerPersonEur: 900,
    interests: ['Culture', 'Plage', 'Nature', 'Spots populaires', 'Gastronomie'],
    localTransportMode: 'walk',
  ),
  _Scenario(
    label: 'Voyage pro',
    travelerType: 'Voyage pro',
    budgetPerPersonEur: 1100, // ~183€/d → no cap, frais de mission
    interests: ['Gastronomie', 'Spots populaires', 'Wellness'],
    localTransportMode: 'public_transport',
  ),
  _Scenario(
    label: 'Fun',
    travelerType: 'Fun',
    budgetPerPersonEur: 1000, // ~167€/d → no cap
    interests: ['Nightlife', 'Événements', 'Spots populaires', 'Gastronomie', 'Plage'],
    localTransportMode: 'public_transport',
  ),
  _Scenario(
    label: 'Road-trip',
    travelerType: 'Road-trip',
    budgetPerPersonEur: 1200, // ~200€/d → no cap
    interests: ['Nature', 'Hors circuit', 'Spots populaires', 'Plage', 'Gastronomie'],
    localTransportMode: 'car',
  ),
  _Scenario(
    label: 'Couple',
    travelerType: 'Couple',
    budgetPerPersonEur: 1400, // ~233€/d → no cap. Wellness volontairement
    // hors interests pour ne pas saturer en spas (cf. spec Lalith 09/05).
    interests: ['Spots populaires', 'Gastronomie', 'Culture', 'Événements', 'Plage'],
    localTransportMode: 'public_transport',
  ),
  _Scenario(
    label: 'Grand luxe',
    travelerType: 'Grand luxe',
    budgetPerPersonEur: 2400, // ~400€/d → no cap, premium
    interests: ['Culture', 'Plage', 'Wellness', 'Gastronomie', 'Événements'],
    localTransportMode: 'taxi',
  ),
];

// ─── Trip fixture ─────────────────────────────────────────────────────────

/// Marrakech 4 jours + Essaouira 2 jours, du 2026-05-15 au 2026-05-20.
/// Marrakech reste la "destination" (intérieur des terres) ; Essaouira est
/// segment intermédiaire (côtière, doit accueillir Plage).
Trip _buildTrip(_Scenario s) {
  return Trip(
    id: 'harness-${s.label.toLowerCase().replaceAll(' ', '-')}',
    userId: 'harness-user',
    title: 'Marrakech + Essaouira',
    destination: 'Marrakech, Maroc',
    destinationCountryCode: 'ma',
    destinationCountryName: 'Maroc',
    destinationKind: 'city',
    startDate: DateTime.utc(2026, 5, 15),
    endDate: DateTime.utc(2026, 5, 20),
    coverEmoji: '🕌',
    travelerType: s.travelerType,
    interests: s.interests,
    localTransportMode: s.localTransportMode,
    budgetPerPersonEur: s.budgetPerPersonEur,
    itinerarySegments: const [
      TripSegment(city: 'Marrakech', days: 4, country: 'Maroc'),
      TripSegment(city: 'Essaouira', days: 2, country: 'Maroc'),
    ],
    createdAt: DateTime.utc(2026, 5, 1),
  );
}

// ─── Pipeline runner ──────────────────────────────────────────────────────

class _RunOutput {
  final List<ActivitySuggestion> visits;
  final List<ActivitySuggestion> meals;
  final List<DayCandidates> pool;
  const _RunOutput({
    required this.visits,
    required this.meals,
    required this.pool,
  });

  List<ActivitySuggestion> get all => [...visits, ...meals];
}

Future<_RunOutput> _runPipeline(_Scenario s) async {
  final trip = _buildTrip(s);
  final geocoder = GeocodingService();
  final nearbyService = PlacesNearbyService();

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

  final visits = selectVisitsDeterministic(
    clusters: clusters,
    trip: trip,
    travelerProfile: travelerProfile,
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

  return _RunOutput(visits: visits, meals: meals, pool: pool);
}

// ─── KPIs ─────────────────────────────────────────────────────────────────

/// Types Places considérés "food" pour la sanity check "food in visit slots".
/// Un visit slot ne devrait JAMAIS contenir un de ces primary types — le
/// sélecteur les filtre via `_isMealPrimaryType`. Si on en voit, c'est un bug.
const _foodPrimaryTypes = <String>{
  'restaurant', 'cafe', 'bakery', 'bar', 'pub', 'food_court',
  'meal_delivery', 'meal_takeaway', 'wine_bar', 'sports_bar',
  'fine_dining_restaurant', 'fast_food_restaurant',
  'pastry_shop', 'dessert_shop', 'cake_shop', 'confectionery',
  'donut_shop', 'chocolate_shop', 'candy_store', 'coffee_shop',
  'tea_house', 'ice_cream_shop', 'sandwich_shop', 'breakfast_restaurant',
  'brunch_restaurant', 'steak_house',
};

/// Types lodging — un visit slot ne devrait JAMAIS être un hôtel/hostel.
const _lodgingPrimaryTypes = <String>{
  'lodging', 'hotel', 'motel', 'guest_house', 'hostel',
  'extended_stay_hotel', 'campground', 'rv_park', 'resort_hotel',
  'bed_and_breakfast', 'private_guest_room',
};

/// Types Places considérés wellness — pour le KPI densité.
const _wellnessPrimaryTypes = <String>{
  'spa', 'massage_spa', 'wellness_center', 'sauna', 'hammam', 'thermal_bath',
};

/// Types Places considérés "plage" — pour le check "beach_in_marrakech".
/// `water_park` retiré : c'est une Activité (parc aquatique), pas une plage
/// littorale. Une water_park légitime peut exister à Marrakech.
const _beachPrimaryTypes = <String>{
  'beach',
};

/// Détermine le primary type d'une visite en cherchant le candidat
/// correspondant dans la pool (match name + proximité ≤ 50m). Retourne null
/// si pas de match — dans ce cas on ne peut pas trancher type-based.
String? _primaryTypeForVisit(ActivitySuggestion v, List<DayCandidates> pool) {
  if (v.latitude == null || v.longitude == null) return null;
  final vLat = v.latitude!;
  final vLng = v.longitude!;
  final vNameNorm = v.title.toLowerCase().trim();
  for (final day in pool) {
    for (final list in day.byInterest.values) {
      for (final c in list) {
        if (c.types.isEmpty) continue;
        if (c.name.toLowerCase().trim() != vNameNorm) continue;
        // Match coord à ~50m près (1° lat = 111km, 1° lng ≈ 73km à 32°N).
        final dLat = (c.latitude - vLat) * 111000;
        final dLng = (c.longitude - vLng) * 95000;
        final d = math.sqrt(dLat * dLat + dLng * dLng);
        if (d <= 50) return c.types.first;
      }
    }
  }
  return null;
}

class _Kpi {
  // ─── Hard assertion-related (zéro tolérance) ───────────────────────
  final int totalVisits;
  final int totalMeals;
  /// Doublons entre VISITES (selectVisitsDeterministic dédup globalement
  /// par placeId/coords). Doit valoir 0 : si >0 c'est un bug pipeline.
  final int duplicateVisits;
  /// Doublons entre REPAS (insertDeterministicMeals autorise
  /// `maxRestoUsesAcrossTrip = 2` par design, fallback pool pauvre).
  /// Soft observation : valeur >0 acceptable, valeur >N (uses cap) = bug.
  final int duplicateMeals;
  /// Pour le détail : restos utilisés ≥2× sur le voyage (soft).
  final List<String> mealReuseDetail;
  final int hotelInVisits;
  final int foodInVisits;
  final int beachInMarrakech;

  // ─── Densité & distribution (observation, soft warnings) ───────────
  final int maxWellnessPerDay;
  final int wellnessTotal;
  /// Nombre de Plages pickées par ville (sanity / observation).
  final Map<String, int> beachByCity;
  /// Nombre de food/pâtisseries dans les SLOTS REPAS (devrait ≈ totalMeals).
  /// Sanity check : si bas, c'est que des meal slots sont remplis avec
  /// autre chose (ne devrait pas arriver).
  final int foodInMealSlots;
  /// Max d'enchaînements consécutifs du même tag dans une journée
  /// (visits triés par heure). Ex: 3 = 3 picks Wellness consécutifs.
  final int maxConsecutiveSameTag;
  /// Nombre total de transitions visite→visite > 1500m (soft : on tolère
  /// si transport=taxi/car/public_transport ou profil Road-trip).
  final int longHopsCount;
  /// Jours avec >2 wellness (cap soft pour profils non-Wellness).
  final int daysWithExcessWellness;
  /// Jours dont ≥75% des slots sont wellness ou repas (= journée monotone
  /// sans culture/nature/visite).
  final int monotonousDays;
  /// Nb de jours sans aucun spot fort (Visite/Culture/Nature avec rating
  /// ≥4.5 + ≥500 avis). Indicatif uniquement.
  final int daysWithoutStrongSpot;
  /// Tag dominant par jour : `dayKey → tag` (le tag le plus représenté).
  final Map<String, String> topTagByDay;

  // ─── Capacité ───────────────────────────────────────────────────────
  final int skippedSlots;

  /// `dayKey (yyyy-MM-dd) → list de titres pickés ce jour-là (visits + meals
  /// triés par startTime)`.
  final Map<String, List<String>> picksByDay;
  /// Détails des violations pour reporting (visite → raison).
  final List<String> hotelOffenders;
  final List<String> foodOffenders;
  final List<String> beachOffenders;
  /// Détails des soft warnings calculés (à imprimer en mode warning).
  final List<String> wellnessExcessDetail;
  final List<String> consecutiveSameTagDetail;
  final List<String> consecutiveSpaDetail;
  final List<String> longHopsDetail;
  final List<String> monotonousDaysDetail;
  final List<String> daysWithoutStrongSpotDetail;

  const _Kpi({
    required this.totalVisits,
    required this.totalMeals,
    required this.duplicateVisits,
    required this.duplicateMeals,
    required this.mealReuseDetail,
    required this.hotelInVisits,
    required this.foodInVisits,
    required this.beachInMarrakech,
    required this.maxWellnessPerDay,
    required this.wellnessTotal,
    required this.beachByCity,
    required this.foodInMealSlots,
    required this.maxConsecutiveSameTag,
    required this.longHopsCount,
    required this.daysWithExcessWellness,
    required this.monotonousDays,
    required this.daysWithoutStrongSpot,
    required this.topTagByDay,
    required this.skippedSlots,
    required this.picksByDay,
    required this.hotelOffenders,
    required this.foodOffenders,
    required this.beachOffenders,
    required this.wellnessExcessDetail,
    required this.consecutiveSameTagDetail,
    required this.consecutiveSpaDetail,
    required this.longHopsDetail,
    required this.monotonousDaysDetail,
    required this.daysWithoutStrongSpotDetail,
  });
}

/// Renvoie la ville segment qui contient une visite. Heuristique simple :
/// longitude > -9° = Marrakech-side (intérieur des terres), sinon Essaouira
/// (côte Atlantique). Utilisé pour `beachByCity` + sanity beach_in_marrakech.
String _cityForVisit(ActivitySuggestion v) {
  if (v.longitude == null) return 'Inconnue';
  return v.longitude! > -9.0 ? 'Marrakech' : 'Essaouira';
}

/// Distance haversine simplifiée (équiplane à ces latitudes ~32°N).
int _distMeters(double lat1, double lng1, double lat2, double lng2) {
  final dLat = (lat1 - lat2) * 111000;
  final dLng = (lng1 - lng2) * 95000;
  return math.sqrt(dLat * dLat + dLng * dLng).round();
}

/// Cherche le `NearbyCandidate` correspondant à une visite (match name +
/// coords ≤ 50m) et renvoie `(rating, userRatingCount)`. Sert à détecter les
/// "vrais spots forts" (rating ≥4.5 + ≥500 avis) pour la métrique
/// `daysWithoutStrongSpot`.
({double? rating, int? userRatingCount}) _ratingForVisit(
  ActivitySuggestion v,
  List<DayCandidates> pool,
) {
  if (v.latitude == null || v.longitude == null) return (rating: null, userRatingCount: null);
  final vLat = v.latitude!;
  final vLng = v.longitude!;
  final vNameNorm = v.title.toLowerCase().trim();
  for (final day in pool) {
    for (final list in day.byInterest.values) {
      for (final c in list) {
        if (c.name.toLowerCase().trim() != vNameNorm) continue;
        final d = _distMeters(c.latitude, c.longitude, vLat, vLng);
        if (d <= 50) {
          return (rating: c.rating, userRatingCount: c.userRatingCount);
        }
      }
    }
  }
  return (rating: null, userRatingCount: null);
}

_Kpi _computeKpi(_RunOutput out, _Scenario s) {
  final visits = out.visits;
  final meals = out.meals;
  final pool = out.pool;

  // Doublons : on sépare visits et meals.
  // - VISITES : selectVisitsDeterministic dédup HARD globalement par
  //   placeId+coords. duplicateVisits doit valoir 0 sinon bug pipeline.
  // - REPAS : insertDeterministicMeals autorise jusqu'à 2× par resto sur
  //   le voyage (cf. `maxRestoUsesAcrossTrip`). C'est intentionnel
  //   (fallback pool pauvre). On compte le nombre de RÉPÉTITIONS au-delà
  //   de la 1re occurrence (pas une assertion bloquante).
  String dedupKey(ActivitySuggestion a) {
    final n = a.title.toLowerCase().trim();
    final lat = (a.latitude ?? 0).toStringAsFixed(4);
    final lng = (a.longitude ?? 0).toStringAsFixed(4);
    return '$n@$lat,$lng';
  }

  final visitSeen = <String>{};
  var duplicateVisits = 0;
  for (final v in visits) {
    final k = dedupKey(v);
    if (!visitSeen.add(k)) duplicateVisits++;
  }

  final mealCount = <String, int>{};
  for (final m in meals) {
    final k = dedupKey(m);
    mealCount[k] = (mealCount[k] ?? 0) + 1;
  }
  final mealReuseDetail = <String>[];
  var duplicateMeals = 0;
  mealCount.forEach((k, n) {
    if (n > 1) {
      duplicateMeals += n - 1;
      // Reprend le titre lisible depuis le 1er meal qui matche cette clé.
      final title = meals
          .firstWhere((m) => dedupKey(m) == k, orElse: () => meals.first)
          .title;
      mealReuseDetail.add('"$title" ×$n');
    }
  });

  final hotelOffenders = <String>[];
  final foodOffenders = <String>[];
  final beachOffenders = <String>[];
  final beachByCity = <String, int>{};

  for (final v in visits) {
    final pt = _primaryTypeForVisit(v, pool);
    final dayKey = v.dayDate.toIso8601String().split('T').first;
    if (pt != null && _lodgingPrimaryTypes.contains(pt)) {
      hotelOffenders.add('$dayKey ${v.startTime} "${v.title}" type=$pt');
    }
    if (pt != null && _foodPrimaryTypes.contains(pt)) {
      foodOffenders.add('$dayKey ${v.startTime} "${v.title}" type=$pt');
    }
    if (pt != null && _beachPrimaryTypes.contains(pt)) {
      final city = _cityForVisit(v);
      beachByCity[city] = (beachByCity[city] ?? 0) + 1;
      if (city == 'Marrakech') {
        beachOffenders.add('$dayKey ${v.startTime} "${v.title}" type=$pt');
      }
    }
  }

  // ─── Wellness density ──────────────────────────────────────────────
  final wellnessByDay = <String, int>{};
  var wellnessTotal = 0;
  for (final v in visits) {
    final pt = _primaryTypeForVisit(v, pool);
    if (pt == null) continue;
    if (!_wellnessPrimaryTypes.contains(pt)) continue;
    final key = v.dayDate.toIso8601String().split('T').first;
    wellnessByDay[key] = (wellnessByDay[key] ?? 0) + 1;
    wellnessTotal++;
  }
  final maxWellnessPerDay =
      wellnessByDay.values.fold<int>(0, (a, b) => a > b ? a : b);
  final wellnessExcessDetail = <String>[];
  var daysWithExcessWellness = 0;
  wellnessByDay.forEach((day, n) {
    if (n > 2) {
      daysWithExcessWellness++;
      wellnessExcessDetail.add('$day : $n wellness');
    }
  });

  // ─── foodInMealSlots (sanity : devrait ≈ totalMeals) ───────────────
  var foodInMealSlots = 0;
  for (final m in meals) {
    final pt = _primaryTypeForVisit(m, pool);
    if (pt != null && _foodPrimaryTypes.contains(pt)) foodInMealSlots++;
  }

  // ─── Per-day analyses : group visits par jour, sortés par heure ────
  final visitsByDay = <String, List<ActivitySuggestion>>{};
  for (final v in visits) {
    final key = v.dayDate.toIso8601String().split('T').first;
    visitsByDay.putIfAbsent(key, () => []).add(v);
  }
  for (final list in visitsByDay.values) {
    list.sort((a, b) => a.startTime.compareTo(b.startTime));
  }

  // maxConsecutiveSameTag + détails (seulement >2 = soft warning)
  var maxConsecutiveSameTag = 0;
  final consecutiveSameTagDetail = <String>[];
  // consecutiveSpa = enchaînement de wellness picks (≥2 dans la journée
  // contigus). Sépare le détail spa-spécifique.
  final consecutiveSpaDetail = <String>[];
  visitsByDay.forEach((day, list) {
    if (list.isEmpty) return;
    var run = 1;
    var runTag = list.first.tag;
    var runStartIdx = 0;
    for (var i = 1; i < list.length; i++) {
      if (list[i].tag == runTag) {
        run++;
      } else {
        if (run > maxConsecutiveSameTag) maxConsecutiveSameTag = run;
        if (run >= 3) {
          consecutiveSameTagDetail.add(
            '$day : $run× $runTag '
            '(${list.sublist(runStartIdx, runStartIdx + run).map((a) => a.title).join(" → ")})',
          );
        }
        if (runTag == 'Wellness' && run >= 2) {
          consecutiveSpaDetail.add(
            '$day : $run spa consécutifs '
            '(${list.sublist(runStartIdx, runStartIdx + run).map((a) => a.title).join(" → ")})',
          );
        }
        run = 1;
        runTag = list[i].tag;
        runStartIdx = i;
      }
    }
    if (run > maxConsecutiveSameTag) maxConsecutiveSameTag = run;
    if (run >= 3) {
      consecutiveSameTagDetail.add(
        '$day : $run× $runTag '
        '(${list.sublist(runStartIdx, runStartIdx + run).map((a) => a.title).join(" → ")})',
      );
    }
    if (runTag == 'Wellness' && run >= 2) {
      consecutiveSpaDetail.add(
        '$day : $run spa consécutifs '
        '(${list.sublist(runStartIdx, runStartIdx + run).map((a) => a.title).join(" → ")})',
      );
    }
  });

  // longHopsCount : transitions visit→visit > 1500m sur la même journée.
  var longHopsCount = 0;
  final longHopsDetail = <String>[];
  visitsByDay.forEach((day, list) {
    for (var i = 1; i < list.length; i++) {
      final a = list[i - 1];
      final b = list[i];
      if (a.latitude == null || a.longitude == null) continue;
      if (b.latitude == null || b.longitude == null) continue;
      final d = _distMeters(a.latitude!, a.longitude!, b.latitude!, b.longitude!);
      if (d > 1500) {
        longHopsCount++;
        longHopsDetail.add(
          '$day : ${d}m de "${a.title}" → "${b.title}"',
        );
      }
    }
  });

  // monotonousDays : jours dont ≥75% des slots (visits + meals) sont wellness
  // ou repas. C'est-à-dire pas assez de Culture/Nature/Visite/Activité.
  var monotonousDays = 0;
  final monotonousDaysDetail = <String>[];
  final mealsByDay = <String, int>{};
  for (final m in meals) {
    final key = m.dayDate.toIso8601String().split('T').first;
    mealsByDay[key] = (mealsByDay[key] ?? 0) + 1;
  }
  visitsByDay.forEach((day, list) {
    final wellnessInDay = wellnessByDay[day] ?? 0;
    final mealsInDay = mealsByDay[day] ?? 0;
    final totalSlots = list.length + mealsInDay;
    if (totalSlots == 0) return;
    final wellnessOrMeal = wellnessInDay + mealsInDay;
    if (wellnessOrMeal / totalSlots >= 0.75) {
      monotonousDays++;
      monotonousDaysDetail.add(
        '$day : $wellnessOrMeal/$totalSlots slots = wellness ou repas',
      );
    }
  });

  // daysWithoutStrongSpot : jours sans aucun pick Culture/Nature/Visite avec
  // rating ≥4.5 ET userRatingCount ≥500. Indicatif (non-warning bloquant).
  var daysWithoutStrongSpot = 0;
  final daysWithoutStrongSpotDetail = <String>[];
  visitsByDay.forEach((day, list) {
    bool hasStrongSpot = false;
    for (final v in list) {
      const strongTags = {'Culture', 'Nature', 'Visite'};
      if (!strongTags.contains(v.tag)) continue;
      final r = _ratingForVisit(v, pool);
      if ((r.rating ?? 0) >= 4.5 && (r.userRatingCount ?? 0) >= 500) {
        hasStrongSpot = true;
        break;
      }
    }
    if (!hasStrongSpot) {
      daysWithoutStrongSpot++;
      daysWithoutStrongSpotDetail.add(day);
    }
  });

  // topTagByDay : tag le plus représenté dans la journée (visites seules).
  final topTagByDay = <String, String>{};
  visitsByDay.forEach((day, list) {
    final counts = <String, int>{};
    for (final v in list) {
      counts[v.tag] = (counts[v.tag] ?? 0) + 1;
    }
    if (counts.isEmpty) return;
    final top = counts.entries.reduce((a, b) => a.value >= b.value ? a : b);
    topTagByDay[day] = top.key;
  });

  // ─── Slots manqués ─────────────────────────────────────────────────
  final profile = travelerPlacesProfiles[s.travelerType];
  final maxPerDay = profile?.maxActivitiesPerDay ?? 4;
  const tripDays = 6;
  final expectedVisits = tripDays * maxPerDay;
  final expectedMeals = tripDays * 2;
  final skipped =
      math.max<int>(0, expectedVisits - visits.length) +
      math.max<int>(0, expectedMeals - meals.length);

  // ─── Picks par jour pour l'affichage détaillé ──────────────────────
  final picksByDay = <String, List<String>>{};
  final all = [...visits, ...meals]
    ..sort((a, b) {
      final c = a.dayDate.compareTo(b.dayDate);
      if (c != 0) return c;
      return a.startTime.compareTo(b.startTime);
    });
  for (final a in all) {
    final key = a.dayDate.toIso8601String().split('T').first;
    picksByDay
        .putIfAbsent(key, () => <String>[])
        .add('${a.startTime} [${a.tag}] ${a.title}');
  }

  return _Kpi(
    totalVisits: visits.length,
    totalMeals: meals.length,
    duplicateVisits: duplicateVisits,
    duplicateMeals: duplicateMeals,
    mealReuseDetail: mealReuseDetail,
    hotelInVisits: hotelOffenders.length,
    foodInVisits: foodOffenders.length,
    beachInMarrakech: beachOffenders.length,
    maxWellnessPerDay: maxWellnessPerDay,
    wellnessTotal: wellnessTotal,
    beachByCity: beachByCity,
    foodInMealSlots: foodInMealSlots,
    maxConsecutiveSameTag: maxConsecutiveSameTag,
    longHopsCount: longHopsCount,
    daysWithExcessWellness: daysWithExcessWellness,
    monotonousDays: monotonousDays,
    daysWithoutStrongSpot: daysWithoutStrongSpot,
    topTagByDay: topTagByDay,
    skippedSlots: skipped,
    picksByDay: picksByDay,
    hotelOffenders: hotelOffenders,
    foodOffenders: foodOffenders,
    beachOffenders: beachOffenders,
    wellnessExcessDetail: wellnessExcessDetail,
    consecutiveSameTagDetail: consecutiveSameTagDetail,
    consecutiveSpaDetail: consecutiveSpaDetail,
    longHopsDetail: longHopsDetail,
    monotonousDaysDetail: monotonousDaysDetail,
    daysWithoutStrongSpotDetail: daysWithoutStrongSpotDetail,
  );
}

// ─── Hard assertions (bloquantes) ─────────────────────────────────────────

class _AssertionFailure {
  final String scenarioLabel;
  final String rule;
  final String detail;
  const _AssertionFailure({
    required this.scenarioLabel,
    required this.rule,
    required this.detail,
  });
  @override
  String toString() => '[$scenarioLabel] ✗ $rule\n    $detail';
}

List<_AssertionFailure> _runHardAssertions(_Scenario s, _Kpi k) {
  final failures = <_AssertionFailure>[];

  if (k.duplicateVisits > 0) {
    failures.add(_AssertionFailure(
      scenarioLabel: s.label,
      rule: 'duplicate_visits == 0',
      detail: '${k.duplicateVisits} visite(s) en doublon sur le voyage '
          '(selectVisitsDeterministic devrait dédup hard via placeId)',
    ));
  }
  // Meals duplication is intentionally allowed up to maxRestoUsesAcrossTrip
  // (=2) — pas une assertion bloquante. Soft warning ci-dessous.

  if (k.hotelInVisits > 0) {
    failures.add(_AssertionFailure(
      scenarioLabel: s.label,
      rule: 'hotel/lodging/hostel/private_guest_room in visit slots == 0',
      detail: 'Offenders :\n      ${k.hotelOffenders.join("\n      ")}',
    ));
  }

  if (k.foodInVisits > 0) {
    failures.add(_AssertionFailure(
      scenarioLabel: s.label,
      rule: 'food types in visit slots == 0',
      detail: 'Offenders :\n      ${k.foodOffenders.join("\n      ")}',
    ));
  }

  if (k.beachInMarrakech > 0) {
    failures.add(_AssertionFailure(
      scenarioLabel: s.label,
      rule: 'beach_in_marrakech == 0',
      detail: 'Offenders :\n      ${k.beachOffenders.join("\n      ")}',
    ));
  }

  return failures;
}

// ─── Soft warnings (non-bloquant, observation) ────────────────────────────

class _Warning {
  final String scenarioLabel;
  final String rule;
  final String detail;
  const _Warning({
    required this.scenarioLabel,
    required this.rule,
    required this.detail,
  });
  @override
  String toString() => '⚠ [$scenarioLabel] $rule\n    $detail';
}

/// Profils tolérants au Wellness — cap soft relâché à 3/jour (au lieu de 2).
/// Critères : Grand luxe ou tout profil ayant `Wellness` parmi ses interests
/// explicites.
bool _wellnessTolerant(_Scenario s) {
  if (s.travelerType == 'Grand luxe') return true;
  return s.interests.contains('Wellness');
}

/// Profils tolérants aux long hops > 1500m (transport motorisé).
bool _longHopTolerant(_Scenario s) {
  const motorized = {'taxi', 'car', 'public_transport'};
  if (motorized.contains(s.localTransportMode)) return true;
  if (s.travelerType == 'Road-trip') return true;
  return false;
}

List<_Warning> _runSoftWarnings(_Scenario s, _Kpi k) {
  final warnings = <_Warning>[];

  // 0. Réutilisation repas (≥2× même resto sur le voyage). Acceptable jusqu'à
  //    `maxRestoUsesAcrossTrip = 2` côté pipeline. Émis en observation.
  if (k.duplicateMeals > 0) {
    warnings.add(_Warning(
      scenarioLabel: s.label,
      rule: 'restos repas réutilisés sur le voyage (≤2× ok par design)',
      detail: k.mealReuseDetail.join(', '),
    ));
  }

  // 1. Wellness > 2/jour (3 si profil tolérant)
  final wellnessCap = _wellnessTolerant(s) ? 3 : 2;
  if (k.maxWellnessPerDay > wellnessCap) {
    warnings.add(_Warning(
      scenarioLabel: s.label,
      rule: 'max $wellnessCap Wellness/jour (profil ${_wellnessTolerant(s) ? "tolérant" : "standard"})',
      detail: k.wellnessExcessDetail.join('\n    '),
    ));
  }

  // 2. > 2 lieux du même tag par jour (≥3 consécutifs uniquement — capturé
  //    via consecutiveSameTagDetail). Émettre 1 warning agrégé si ≥1 entrée.
  if (k.consecutiveSameTagDetail.isNotEmpty) {
    warnings.add(_Warning(
      scenarioLabel: s.label,
      rule: 'max 2 lieux consécutifs du même tag par jour',
      detail: k.consecutiveSameTagDetail.join('\n    '),
    ));
  }

  // 3. > 1 spa consécutif sauf profil tolérant.
  if (!_wellnessTolerant(s) && k.consecutiveSpaDetail.isNotEmpty) {
    warnings.add(_Warning(
      scenarioLabel: s.label,
      rule: 'max 1 spa consécutif (profil non-tolérant)',
      detail: k.consecutiveSpaDetail.join('\n    '),
    ));
  }

  // 4. Distance consécutive > 1500m sauf transport motorisé / Road-trip.
  if (!_longHopTolerant(s) && k.longHopsCount > 0) {
    warnings.add(_Warning(
      scenarioLabel: s.label,
      rule: 'distance consécutive ≤ 1500m (transport=${s.localTransportMode})',
      detail: k.longHopsDetail.join('\n    '),
    ));
  }

  // 5. Au moins 1 spot fort par jour (rating ≥4.5 + ≥500 avis sur tag fort).
  //    Indicatif : si la pool n'en a pas, le harness ne peut pas savoir.
  //    Emis comme warning seulement si > moitié des jours sans spot.
  if (k.daysWithoutStrongSpot >= 4) {
    warnings.add(_Warning(
      scenarioLabel: s.label,
      rule: '≥1 spot fort/jour si pool le permet',
      detail: '${k.daysWithoutStrongSpot}/6 jours sans spot fort : '
          '${k.daysWithoutStrongSpotDetail.join(", ")}',
    ));
  }

  // 6. Jour trop monotone (≥75% des slots = wellness ou repas).
  if (k.monotonousDays > 0) {
    warnings.add(_Warning(
      scenarioLabel: s.label,
      rule: 'jour trop monotone (≥75% spa/repas)',
      detail: k.monotonousDaysDetail.join('\n    '),
    ));
  }

  return warnings;
}

// ─── Console renderer ─────────────────────────────────────────────────────

/// Catalogue des KPIs affichés en colonnes (transposed table). Chaque entrée
/// = (header court 4-5 chars, extracteur). Order = ordre d'affichage.
/// Garder les colonnes étroites pour tenir 10 profils sur ~150 chars.
final List<({String header, num Function(_Kpi) extract})> _kpiColumns = [
  (header: 'vis', extract: (k) => k.totalVisits),
  (header: 'mls', extract: (k) => k.totalMeals),
  (header: 'dpV', extract: (k) => k.duplicateVisits),
  (header: 'dpM', extract: (k) => k.duplicateMeals),
  (header: 'hot', extract: (k) => k.hotelInVisits),
  (header: 'fod', extract: (k) => k.foodInVisits),
  (header: 'bMK', extract: (k) => k.beachInMarrakech),
  (header: 'wlD', extract: (k) => k.maxWellnessPerDay),
  (header: 'wlT', extract: (k) => k.wellnessTotal),
  (header: 'fMs', extract: (k) => k.foodInMealSlots),
  (header: 'cTg', extract: (k) => k.maxConsecutiveSameTag),
  (header: 'lhp', extract: (k) => k.longHopsCount),
  (header: 'dxW', extract: (k) => k.daysWithExcessWellness),
  (header: 'dMo', extract: (k) => k.monotonousDays),
  (header: 'dNs', extract: (k) => k.daysWithoutStrongSpot),
  (header: 'skp', extract: (k) => k.skippedSlots),
];

String _renderTable(List<({_Scenario scenario, _Kpi kpi})> results) {
  final buf = StringBuffer();
  buf.writeln();
  buf.writeln('═══ KPI Places-first — Marrakech + Essaouira (6 jours, ${results.length} profils) ═══');
  buf.writeln();
  buf.writeln('Légende : vis=visits  mls=meals  dpV=dup-visits(hard)  dpM=dup-meals(soft, ≤2× ok)  hot=hotel-in-visits');
  buf.writeln('         fod=food-in-visits  bMK=beach-in-Marrakech');
  buf.writeln('         wlD=maxWellness/day  wlT=wellness-total  fMs=food-in-meal-slots');
  buf.writeln('         cTg=maxConsecSameTag  lhp=longHops>1500m');
  buf.writeln('         dxW=daysWithExcessWellness  dMo=monotonousDays');
  buf.writeln('         dNs=daysWithoutStrongSpot  skp=skippedSlots');
  buf.writeln();

  // Largeur dynamique label (longueur max des labels profils)
  final colLabel = math
      .max(15, results.map((r) => r.scenario.label.length).fold<int>(0, math.max));
  const colNum = 4;
  String padR(String v, int w) => v.padRight(w);
  String padL(String v, int w) => v.padLeft(w);

  // Header
  buf.write(padR('Profile', colLabel));
  for (final c in _kpiColumns) {
    buf.write('│${padL(c.header, colNum)}');
  }
  buf.writeln();
  buf.write('─' * colLabel);
  for (var i = 0; i < _kpiColumns.length; i++) {
    buf.write('┼${'─' * colNum}');
  }
  buf.writeln();

  // Rows : 1 ligne par profil
  for (final r in results) {
    buf.write(padR(r.scenario.label, colLabel));
    for (final c in _kpiColumns) {
      buf.write('│${padL(c.extract(r.kpi).toString(), colNum)}');
    }
    buf.writeln();
  }
  buf.writeln();

  // Beach par ville (tableau séparé — observation distribution Plage)
  buf.writeln('─── Plages pickées par ville ───');
  for (final r in results) {
    final byCity = r.kpi.beachByCity;
    if (byCity.isEmpty) {
      buf.writeln('  ${r.scenario.label.padRight(colLabel)} : —');
    } else {
      final parts = byCity.entries.map((e) => '${e.key}:${e.value}').join(', ');
      buf.writeln('  ${r.scenario.label.padRight(colLabel)} : $parts');
    }
  }
  buf.writeln();

  // Top tag par jour
  buf.writeln('─── Tag dominant par jour ───');
  for (final r in results) {
    buf.writeln('  ${r.scenario.label}');
    final keys = r.kpi.topTagByDay.keys.toList()..sort();
    for (final k in keys) {
      buf.writeln('    $k → ${r.kpi.topTagByDay[k]}');
    }
  }
  buf.writeln();

  // Détail picks par jour (inchangé)
  buf.writeln('─── Détail picks par jour ───');
  for (final r in results) {
    buf.writeln();
    buf.writeln('▸ ${r.scenario.label} (${r.scenario.travelerType}, '
        'budget=${r.scenario.budgetPerPersonEur}€, '
        'transport=${r.scenario.localTransportMode})');
    final keys = r.kpi.picksByDay.keys.toList()..sort();
    for (final k in keys) {
      buf.writeln('  $k :');
      for (final p in r.kpi.picksByDay[k]!) {
        buf.writeln('    · $p');
      }
    }
  }
  buf.writeln();
  return buf.toString();
}

// ─── Test entry point ─────────────────────────────────────────────────────

void main() {
  test('Places-first harness — Marrakech + Essaouira (10 profils Lunao)',
      () async {
    final results = <({_Scenario scenario, _Kpi kpi})>[];

    // ⚠ Effet d'ordre observé 2026-05-08 : le profil en DERNIÈRE position
    // tend à perdre 4-5 meals (~30% mls) à cause du rate-limiting / quota
    // dégradation Google Places après ~500-1000 RPCs cumulés. Tester un
    // profil en 1re position prouve qu'il atteint son score nominal. Si
    // un profil suspect apparaît dégradé, le bouger en 1re position pour
    // valider que le problème vient du quota et non du scoring.
    for (final s in _scenarios) {
      // ignore: avoid_print
      print('▶ Run ${s.label}…');
      final out = await _runPipeline(s);
      final kpi = _computeKpi(out, s);
      results.add((scenario: s, kpi: kpi));
    }

    // ignore: avoid_print
    print(_renderTable(results));

    // ─── Soft warnings (observation, non-bloquant) ───────────────────
    final allWarnings = <_Warning>[];
    for (final r in results) {
      allWarnings.addAll(_runSoftWarnings(r.scenario, r.kpi));
    }
    // ignore: avoid_print
    print('═══ Soft warnings (non-bloquant — calibrage produit) ═══');
    if (allWarnings.isEmpty) {
      // ignore: avoid_print
      print('  (aucun warning)');
    } else {
      for (final w in allWarnings) {
        // ignore: avoid_print
        print(w);
      }
    }
    // ignore: avoid_print
    print('');

    // ─── Hard assertions (bloquant) ───────────────────────────────────
    final allFailures = <_AssertionFailure>[];
    for (final r in results) {
      allFailures.addAll(_runHardAssertions(r.scenario, r.kpi));
    }

    // ignore: avoid_print
    print('═══ Hard assertions ═══');
    if (allFailures.isNotEmpty) {
      // ignore: avoid_print
      print('✗ ${allFailures.length} échec(s) :');
      for (final f in allFailures) {
        // ignore: avoid_print
        print(f);
      }
    } else {
      // ignore: avoid_print
      print('✓ Toutes les assertions fortes passent.');
    }

    expect(
      allFailures,
      isEmpty,
      reason: 'Cf. logs ci-dessus pour le détail des échecs.',
    );
  }, timeout: const Timeout(Duration(minutes: 15)));
}
