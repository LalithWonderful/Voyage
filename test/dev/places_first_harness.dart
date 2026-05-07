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

/// Sélection volontairement courte pour la 1re version. Étendra ensuite à
/// Backpack / En famille / Couple / Voyage pro / Chill / Fun / Road-trip.
const _scenarios = <_Scenario>[
  _Scenario(
    label: 'Meilleur prix',
    travelerType: 'Meilleur prix',
    budgetPerPersonEur: 350,
    interests: ['Culture', 'Plage', 'Bons plans', 'Hors circuit', 'Gastronomie'],
    localTransportMode: 'walk',
  ),
  _Scenario(
    label: 'Grand luxe',
    travelerType: 'Grand luxe',
    budgetPerPersonEur: 2400,
    interests: ['Culture', 'Plage', 'Wellness', 'Gastronomie', 'Événements'],
    localTransportMode: 'taxi',
  ),
  _Scenario(
    label: 'Senior',
    travelerType: 'Senior',
    budgetPerPersonEur: 900,
    interests: ['Culture', 'Plage', 'Nature', 'Spots populaires', 'Gastronomie'],
    localTransportMode: 'walk',
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
const _beachPrimaryTypes = <String>{
  'beach', 'water_park',
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

/// True si la visite tombe dans le segment Marrakech (ville intérieure, pas
/// de plage). Heuristique : Marrakech est centrée ~31.63N, 7.99W ; Essaouira
/// ~31.51N, 9.77W. Une visite à plus de 100km d'Essaouira (i.e. < 9°W) est
/// considérée Marrakech-side.
bool _isInMarrakechSegment(ActivitySuggestion v) {
  if (v.longitude == null) return false;
  return v.longitude! > -9.0;
}

class _Kpi {
  final int totalVisits;
  final int totalMeals;
  final int duplicatePlaces;
  final int hotelInVisits;
  final int foodInVisits;
  final int beachInMarrakech;
  final int maxWellnessPerDay;
  final int skippedSlots;
  /// `dayKey (yyyy-MM-dd) → list de titres pickés ce jour-là (visits + meals
  /// triés par startTime)`.
  final Map<String, List<String>> picksByDay;
  /// Détails des violations pour reporting (visite → raison).
  final List<String> hotelOffenders;
  final List<String> foodOffenders;
  final List<String> beachOffenders;

  const _Kpi({
    required this.totalVisits,
    required this.totalMeals,
    required this.duplicatePlaces,
    required this.hotelInVisits,
    required this.foodInVisits,
    required this.beachInMarrakech,
    required this.maxWellnessPerDay,
    required this.skippedSlots,
    required this.picksByDay,
    required this.hotelOffenders,
    required this.foodOffenders,
    required this.beachOffenders,
  });
}

_Kpi _computeKpi(_RunOutput out, _Scenario s) {
  final visits = out.visits;
  final meals = out.meals;
  final pool = out.pool;

  // Doublons globaux : clé = primary type/coord arrondie / titre normalisé.
  // On utilise (name normalisé + coord arrondie 4 décimales) qui couvre les
  // doublons réels même quand placeId n'est pas exposé via ActivitySuggestion.
  final seen = <String>{};
  var duplicates = 0;
  String dedupKey(ActivitySuggestion a) {
    final n = a.title.toLowerCase().trim();
    final lat = (a.latitude ?? 0).toStringAsFixed(4);
    final lng = (a.longitude ?? 0).toStringAsFixed(4);
    return '$n@$lat,$lng';
  }
  for (final v in [...visits, ...meals]) {
    final k = dedupKey(v);
    if (!seen.add(k)) duplicates++;
  }

  final hotelOffenders = <String>[];
  final foodOffenders = <String>[];
  final beachOffenders = <String>[];

  for (final v in visits) {
    final pt = _primaryTypeForVisit(v, pool);
    final dayKey = v.dayDate.toIso8601String().split('T').first;
    if (pt != null && _lodgingPrimaryTypes.contains(pt)) {
      hotelOffenders.add('$dayKey ${v.startTime} "${v.title}" type=$pt');
    }
    if (pt != null && _foodPrimaryTypes.contains(pt)) {
      foodOffenders.add('$dayKey ${v.startTime} "${v.title}" type=$pt');
    }
    if (pt != null &&
        _beachPrimaryTypes.contains(pt) &&
        _isInMarrakechSegment(v)) {
      beachOffenders.add('$dayKey ${v.startTime} "${v.title}" type=$pt');
    }
  }

  // Densité Wellness max sur un seul jour.
  final wellnessByDay = <String, int>{};
  for (final v in visits) {
    final pt = _primaryTypeForVisit(v, pool);
    if (pt == null) continue;
    if (!_wellnessPrimaryTypes.contains(pt)) continue;
    final key = v.dayDate.toIso8601String().split('T').first;
    wellnessByDay[key] = (wellnessByDay[key] ?? 0) + 1;
  }
  final maxWellnessPerDay =
      wellnessByDay.values.fold<int>(0, (a, b) => a > b ? a : b);

  // Slots manqués : (jours × max_visits/jour + jours × 2 repas) - pickés
  final profile = travelerPlacesProfiles[s.travelerType];
  final maxPerDay = profile?.maxActivitiesPerDay ?? 4;
  // 6 jours fixés par la fixture
  const tripDays = 6;
  final expectedVisits = tripDays * maxPerDay;
  final expectedMeals = tripDays * 2;
  final skipped =
      math.max<int>(0, expectedVisits - visits.length) +
      math.max<int>(0, expectedMeals - meals.length);

  // Picks par jour (visits + meals, triés par startTime).
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
    duplicatePlaces: duplicates,
    hotelInVisits: hotelOffenders.length,
    foodInVisits: foodOffenders.length,
    beachInMarrakech: beachOffenders.length,
    maxWellnessPerDay: maxWellnessPerDay,
    skippedSlots: skipped,
    picksByDay: picksByDay,
    hotelOffenders: hotelOffenders,
    foodOffenders: foodOffenders,
    beachOffenders: beachOffenders,
  );
}

// ─── Assertions ───────────────────────────────────────────────────────────

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

List<_AssertionFailure> _runAssertions(_Scenario s, _Kpi k) {
  final failures = <_AssertionFailure>[];

  if (k.duplicatePlaces > 0) {
    failures.add(_AssertionFailure(
      scenarioLabel: s.label,
      rule: 'duplicate_places == 0',
      detail: '${k.duplicatePlaces} doublon(s) détecté(s) sur le voyage',
    ));
  }

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

// ─── Console renderer ─────────────────────────────────────────────────────

String _renderTable(List<({_Scenario scenario, _Kpi kpi})> results) {
  final buf = StringBuffer();
  buf.writeln();
  buf.writeln('═══ KPI Places-first — Marrakech + Essaouira (6 jours) ═══');
  buf.writeln();
  // Header
  const colLabel = 18;
  const colNum = 8;
  String pad(String v, int w) => v.padRight(w);
  String padR(String v, int w) => v.padLeft(w);
  buf.write(pad('KPI', colLabel));
  for (final r in results) {
    buf.write(' │ ${padR(r.scenario.label, colNum + 5)}');
  }
  buf.writeln();
  buf.write('─' * colLabel);
  for (var i = 0; i < results.length; i++) {
    buf.write('─┼─');
    buf.write('─' * (colNum + 5));
  }
  buf.writeln();

  void row(String name, num Function(_Kpi) extract) {
    buf.write(pad(name, colLabel));
    for (final r in results) {
      buf.write(' │ ${padR(extract(r.kpi).toString(), colNum + 5)}');
    }
    buf.writeln();
  }
  row('total visits', (k) => k.totalVisits);
  row('total meals', (k) => k.totalMeals);
  row('duplicates', (k) => k.duplicatePlaces);
  row('hotel in visits', (k) => k.hotelInVisits);
  row('food in visits', (k) => k.foodInVisits);
  row('beach in MRK', (k) => k.beachInMarrakech);
  row('max wellness/d', (k) => k.maxWellnessPerDay);
  row('skipped slots', (k) => k.skippedSlots);

  buf.writeln();
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
  test('Places-first harness — Marrakech + Essaouira (3 profils)', () async {
    final results = <({_Scenario scenario, _Kpi kpi})>[];

    for (final s in _scenarios) {
      // ignore: avoid_print
      print('▶ Run ${s.label}…');
      final out = await _runPipeline(s);
      final kpi = _computeKpi(out, s);
      results.add((scenario: s, kpi: kpi));
    }

    // ignore: avoid_print
    print(_renderTable(results));

    final allFailures = <_AssertionFailure>[];
    for (final r in results) {
      allFailures.addAll(_runAssertions(r.scenario, r.kpi));
    }

    if (allFailures.isNotEmpty) {
      // ignore: avoid_print
      print('═══ Assertions échouées (${allFailures.length}) ═══');
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
  }, timeout: const Timeout(Duration(minutes: 5)));
}
