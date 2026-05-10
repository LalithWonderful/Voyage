/// V8.20 (Lalith 2026-05-10 — Day Builder pré-slot) —
/// compose des « day packs » thématiques (old_city / riverside / market /
/// modern / arrival_light) AVANT le slot picker pour les grandes villes
/// (Bangkok V1, Paris V1). Ré sout les zigzags Bangkok observés sur les
/// runs simulés post-Q1D où le selector pickait Grand Palace + Jim Thompson
/// + ICONSIAM + Wat Arun dans la même journée (mix Old City / modern /
/// riverside / Old City sur 13-18km).
///
/// Architecture :
/// 1. `buildDayPacksForCluster` détecte si le cluster est dans une ville
///    Day-Builder enabled (haversine ≤ 35km du centre canonique). Sinon
///    `DayBuilderResult.disabled` → comportement legacy (slot par slot).
/// 2. Pour chaque candidat du pool, classification archétype (par patterns
///    de noms curated + fallback type Google Places). Un candidat peut
///    matcher plusieurs archétypes (ex: marché de nuit dans Old City).
/// 3. Pour chaque jour du cluster, sélection greedy : archétype avec le
///    plus de must-sees disponibles + moins déjà utilisé. Pack contient
///    3-4 places, ordonnées en nearest-neighbor depuis le centre cluster.
/// 4. Reject si > 1 transition long range (>5 km) après shrink. Cap dur
///    à 4 places/jour. Dédup placeId across days du même cluster.
///
/// Extension : ajouter une `_BuilderCity` à `_builderCities` + créer le
/// `DestinationBlueprint` correspondant (kind=majorCity) pour activer.
library;

import 'dart:math' as math;

import 'package:voyage/features/planning/data/destination_blueprints.dart';
import 'package:voyage/features/planning/services/places_nearby_service.dart';
import 'package:voyage/features/trips/models/trip_model.dart';

/// Archétype thématique d'un day pack. Un pack regroupe des candidats
/// cohérents géographiquement ET thématiquement.
enum DayPackType {
  oldCityDay('old_city_day'),
  riversideDay('riverside_day'),
  marketDay('market_day'),
  modernDay('modern_day'),
  arrivalLightDay('arrival_light_day');

  final String label;
  const DayPackType(this.label);
}

/// Pack composé pour un jour donné. `places` est ordonné en
/// nearest-neighbor depuis le centre du cluster → enchaînement compact.
/// `totalDistanceKm` somme l'itinéraire (centre → place 1 → place 2 …).
/// `longTransitions` compte les hops > 5 km (cible : ≤ 1 par pack).
class DayPack {
  final DayPackType type;
  final List<NearbyCandidate> places;
  final double totalDistanceKm;
  final int longTransitions;
  final double score;

  const DayPack({
    required this.type,
    required this.places,
    required this.totalDistanceKm,
    required this.longTransitions,
    required this.score,
  });

  Set<String> get placeIds => {for (final c in places) c.placeId};
}

class DayBuilderResult {
  final bool enabled;
  final String? cityKey;
  final Map<DateTime, DayPack> dayPackByDate;

  const DayBuilderResult({
    required this.enabled,
    required this.cityKey,
    required this.dayPackByDate,
  });

  static const disabled = DayBuilderResult(
    enabled: false,
    cityKey: null,
    dayPackByDate: <DateTime, DayPack>{},
  );
}

/// Description d'une ville Day-Builder enabled. Centre canonique +
/// patterns de noms curated par archétype. Patterns sont matchés
/// case-insensitive sur le nom du candidat (après strip diacritiques).
class _BuilderCity {
  final String key;
  final double lat;
  final double lng;
  final List<String> oldCityPatterns;
  final List<String> riversidePatterns;
  final List<String> marketPatterns;
  final List<String> modernPatterns;

  const _BuilderCity({
    required this.key,
    required this.lat,
    required this.lng,
    required this.oldCityPatterns,
    required this.riversidePatterns,
    required this.marketPatterns,
    required this.modernPatterns,
  });
}

const _bangkok = _BuilderCity(
  key: 'bangkok',
  lat: 13.7563,
  lng: 100.5018,
  oldCityPatterns: [
    'grand palace', 'wat pho', 'wat arun', 'temple of the emerald buddha',
    'emerald buddha', 'sanam luang', 'city pillar', 'museum siam',
    'national museum', 'khao san', 'khaosan',
    'wat phra', 'wat saket', 'wat traimit', 'wat suthat', 'wat ratchanatda',
    'wat benchamabophit', 'wat mahathat', 'phra nakhon',
  ],
  riversidePatterns: [
    'iconsiam', 'icon siam', 'chao phraya', 'asiatique', 'wang lang',
    'the riverfront', 'riverfront', 'river cruise', 'tha tien',
    'tha maharaj', 'phra athit', 'sathorn pier', 'saphan taksin',
  ],
  marketPatterns: [
    'chatuchak', 'jj market', 'chinatown', 'yaowarat', 'night market',
    'weekend market', 'floating market', 'damnoen saduak',
    'maeklong', 'pak khlong', 'flower market', 'rot fai',
    'train night market', 'sampeng',
  ],
  modernPatterns: [
    'jim thompson', 'mahanakhon', 'lumpini', 'lumphini', 'siam paragon',
    'siam center', 'siam discovery', 'centralworld', 'central world',
    'terminal 21', 'mbk', 'emquartier', 'em district', 'emporium',
    'sky walk', 'skywalk', 'benjasiri', 'benjakitti', 'kingpower',
    'king power', 'samyan mitrtown',
  ],
);

const _paris = _BuilderCity(
  key: 'paris',
  lat: 48.8566,
  lng: 2.3522,
  oldCityPatterns: [
    'notre-dame', 'notre dame', 'sainte-chapelle', 'sainte chapelle',
    'le marais', 'place des vosges', 'pantheon', 'panthéon',
    'sacre-coeur', 'sacré-cœur', 'sacre coeur', 'montmartre',
    'conciergerie', 'place de la bastille', 'ile de la cite',
    'île de la cité', 'saint-germain', 'saint germain',
  ],
  riversidePatterns: [
    'seine', 'pont alexandre', 'pont des arts', 'pont neuf', 'tuileries',
    'orsay', 'quai', 'bateaux', 'bateau-mouche', 'orangerie',
    'berges de seine',
  ],
  marketPatterns: [
    'rue mouffetard', 'marche bastille', 'marché bastille',
    'marche aligre', 'marché aligre', 'aligre',
    'marche des enfants', 'marché des enfants',
    'rue cler', 'marche monge', 'marché monge',
    'marche beauvau', 'marché beauvau',
    'marche saint-quentin', 'marché saint-quentin',
  ],
  modernPatterns: [
    'eiffel', 'tour eiffel', 'trocadero', 'trocadéro',
    'champs-elysees', 'champs-élysées', 'champs elysees',
    'arc de triomphe', 'galeries lafayette', 'centre pompidou',
    'pompidou', 'la defense', 'la défense',
    'orsay', 'musee d\'orsay', 'musée d\'orsay',
    'luxembourg garden', 'jardin du luxembourg', 'louvre',
  ],
);

const _builderCities = <_BuilderCity>[_bangkok, _paris];

/// Distance max entre `cluster.center` et le centre canonique d'une
/// ville pour activer Day Builder. 35 km couvre la métropole Bangkok
/// (Bang Na hotel ≈ 13.67, 100.60 → ~12 km du centre Sukhumvit).
const double _kClusterCityRadiusKm = 35.0;

/// Pack minimum viable : 3 places. Sous ce seuil un pack n'apporte pas
/// de valeur thématique vs le slot picker direct.
const int _kMinPackSize = 3;

/// Cap dur de places par pack (= visites/jour). Le profil voyageur peut
/// imposer moins (ex: Senior 3/jour) — on prend le min.
const int _kMaxPlacesPerPackHardCap = 4;

/// Seuil "long transition" en km. > 5 km = transport probable.
const double _kLongTransitionKm = 5.0;

/// Cap nombre de long transitions tolérées dans un pack non-arrival.
/// 1 long hop OK (ex: hôtel → Old City), 2+ rejette le pack.
const int _kMaxLongTransitionsPerPack = 1;

/// Days minimum pour activer Day Builder. À 1 jour, le slot picker
/// suffit (pas de re-distribution thématique nécessaire).
const int _kMinDaysForBuilder = 2;

/// Pool minimum pour activer Day Builder. Sous 8 candidats il n'y a
/// pas assez de variété pour composer plusieurs archétypes distincts.
const int _kMinPoolForBuilder = 8;

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

String _normName(String s) {
  var n = s.toLowerCase().trim();
  const r = <String, String>{
    'á': 'a', 'à': 'a', 'â': 'a', 'ä': 'a', 'ã': 'a', 'å': 'a',
    'é': 'e', 'è': 'e', 'ê': 'e', 'ë': 'e',
    'í': 'i', 'ì': 'i', 'î': 'i', 'ï': 'i',
    'ó': 'o', 'ò': 'o', 'ô': 'o', 'ö': 'o', 'õ': 'o',
    'ú': 'u', 'ù': 'u', 'û': 'u', 'ü': 'u',
    'ç': 'c', 'đ': 'd', 'ñ': 'n', 'ý': 'y',
  };
  r.forEach((k, v) {
    n = n.replaceAll(k, v);
  });
  return n;
}

_BuilderCity? _detectBuilderCity(double centerLat, double centerLng) {
  for (final c in _builderCities) {
    final d = _haversineKm(centerLat, centerLng, c.lat, c.lng);
    if (d <= _kClusterCityRadiusKm) return c;
  }
  return null;
}

/// Classifie un candidat en 0..N archétypes. Pattern match sur le nom
/// (priorité absolue), puis fallback type Google Places. Un place
/// peut matcher plusieurs archétypes (ex: market à proximité du fleuve)
/// — il sera disponible pour les deux types lors du build pack.
Set<DayPackType> _archetypesForCandidate(NearbyCandidate cand, _BuilderCity city) {
  final out = <DayPackType>{};
  final n = _normName(cand.name);
  bool matchAny(List<String> patterns) =>
      patterns.any((p) => n.contains(p));
  if (matchAny(city.oldCityPatterns)) out.add(DayPackType.oldCityDay);
  if (matchAny(city.riversidePatterns)) out.add(DayPackType.riversideDay);
  if (matchAny(city.marketPatterns)) out.add(DayPackType.marketDay);
  if (matchAny(city.modernPatterns)) out.add(DayPackType.modernDay);
  if (out.isNotEmpty) return out;
  // Fallback type-based pour les candidats sans match nom.
  final types = cand.types.toSet();
  if (types.contains('hindu_temple') ||
      types.contains('place_of_worship') ||
      types.contains('church') ||
      types.contains('mosque')) {
    out.add(DayPackType.oldCityDay);
  }
  if (types.contains('market')) {
    out.add(DayPackType.marketDay);
  }
  // `shopping_mall` retiré du fallback : un mall générique (Imperial
  // World Bang Na, Cloud 11, Mega Bangna) n'est PAS Bangkok-iconique,
  // les malls iconiques (IconSiam, Centralworld, Terminal 21) sont
  // déjà capturés par patterns nominaux.
  if (types.contains('park') ||
      types.contains('national_park') ||
      types.contains('botanical_garden') ||
      types.contains('art_gallery')) {
    out.add(DayPackType.modernDay);
  }
  return out;
}

bool _hasMustSeeMarker(List<String> matchedInterests) =>
    matchedInterests.contains(blueprintMustSeeMarker);
bool _hasExperienceMarker(List<String> matchedInterests) =>
    matchedInterests.contains(blueprintExperienceMarker);

/// Score de base d'un candidat dans le contexte Day Builder. Réutilise
/// la formule du slot picker (qualité × log reviews + blueprint boost)
/// pour cohérence : un must-see a +100 ici comme là, donc le ranking
/// intra-archétype est aligné avec le ranking final.
double _candidateBaseScore(NearbyCandidate c, List<String> matchedInterests) {
  final r = c.rating ?? 0;
  final reviews = c.userRatingCount ?? 0;
  final qualityScore = r * (reviews <= 1 ? 1 : math.log(reviews));
  final blueprintBonus = _hasMustSeeMarker(matchedInterests)
      ? 100.0
      : (_hasExperienceMarker(matchedInterests) ? 70.0 : 0.0);
  return qualityScore + blueprintBonus;
}

class _Tagged {
  final String placeId;
  final NearbyCandidate candidate;
  final List<String> matchedInterests;
  final Set<DayPackType> archetypes;
  final double baseScore;

  _Tagged(this.placeId, this.candidate, this.matchedInterests,
      this.archetypes, this.baseScore);

  bool get isMustSee => _hasMustSeeMarker(matchedInterests);
}

class _PackMetrics {
  final double totalDistanceKm;
  final int longTransitions;
  const _PackMetrics(this.totalDistanceKm, this.longTransitions);
}

_PackMetrics _packMetrics(
    List<_Tagged> ordered, double anchorLat, double anchorLng) {
  if (ordered.isEmpty) return const _PackMetrics(0, 0);
  double total = 0;
  int longs = 0;
  double prevLat = anchorLat;
  double prevLng = anchorLng;
  for (final t in ordered) {
    final d = _haversineKm(
        prevLat, prevLng, t.candidate.latitude, t.candidate.longitude);
    total += d;
    if (d > _kLongTransitionKm) longs += 1;
    prevLat = t.candidate.latitude;
    prevLng = t.candidate.longitude;
  }
  return _PackMetrics(total, longs);
}

List<_Tagged> _nearestNeighborOrder(
    List<_Tagged> input, double startLat, double startLng) {
  final remaining = [...input];
  final result = <_Tagged>[];
  double curLat = startLat;
  double curLng = startLng;
  while (remaining.isNotEmpty) {
    _Tagged? next;
    double bestD = double.infinity;
    for (final p in remaining) {
      final d = _haversineKm(
          curLat, curLng, p.candidate.latitude, p.candidate.longitude);
      if (d < bestD) {
        bestD = d;
        next = p;
      }
    }
    if (next == null) break;
    result.add(next);
    remaining.remove(next);
    curLat = next.candidate.latitude;
    curLng = next.candidate.longitude;
  }
  return result;
}

DayPack _buildDayPack(DayPackType type, List<_Tagged> ordered, _PackMetrics m) {
  final qualitySum = ordered.fold<double>(0, (s, t) => s + t.baseScore);
  // Penalty distance/transitions : -5 par km parcouru, -50 par long hop,
  // -100 hard penalty si > 1 long hop (cap déjà filtré mais defensive).
  final score = qualitySum -
      m.totalDistanceKm * 5.0 -
      m.longTransitions * 50.0 -
      (m.longTransitions > 1 ? 100.0 : 0.0);
  return DayPack(
    type: type,
    places: ordered.map((t) => t.candidate).toList(),
    totalDistanceKm: m.totalDistanceKm,
    longTransitions: m.longTransitions,
    score: score,
  );
}

DayPack? _buildPackForType({
  required DayPackType type,
  required List<_Tagged> available,
  required double centerLat,
  required double centerLng,
  required int maxPlaces,
  required int maxLongTransitions,
}) {
  if (available.length < _kMinPackSize) return null;
  final sorted = [...available]
    ..sort((a, b) => b.baseScore.compareTo(a.baseScore));
  // Première tentative : top-K par score.
  var picked = sorted.take(maxPlaces).toList();
  var ordered = _nearestNeighborOrder(picked, centerLat, centerLng);
  var metrics = _packMetrics(ordered, centerLat, centerLng);
  if (metrics.longTransitions <= maxLongTransitions) {
    return _buildDayPack(type, ordered, metrics);
  }
  // Shrink retry : drop la place la plus éloignée du centre, retest.
  while (picked.length > _kMinPackSize &&
      metrics.longTransitions > maxLongTransitions) {
    _Tagged? worst;
    double worstD = -1;
    for (final p in picked) {
      final d = _haversineKm(
          centerLat, centerLng, p.candidate.latitude, p.candidate.longitude);
      if (d > worstD) {
        worstD = d;
        worst = p;
      }
    }
    if (worst == null) break;
    picked = [...picked]..remove(worst);
    ordered = _nearestNeighborOrder(picked, centerLat, centerLng);
    metrics = _packMetrics(ordered, centerLat, centerLng);
  }
  if (metrics.longTransitions > maxLongTransitions) return null;
  if (ordered.length < _kMinPackSize) return null;
  return _buildDayPack(type, ordered, metrics);
}

DayPack? _buildArrivalLightPack({
  required Map<DayPackType, List<_Tagged>> available,
  required double centerLat,
  required double centerLng,
  required int maxPlaces,
}) {
  // Compose depuis modern + riverside + old_city, MAIS exclut les
  // must-sees iconiques (préservés pour les packs thématiques où ils
  // brilleront vraiment — un must-see sur jour d'arrivée gaspille un
  // highlight et tend à enchaîner des temples lourds = ce qu'on évite
  // par spec « no heavy temple chain »).
  final pool = <_Tagged>[];
  final seen = <String>{};
  for (final type in [
    DayPackType.modernDay,
    DayPackType.riversideDay,
    DayPackType.oldCityDay,
  ]) {
    for (final t in available[type] ?? const <_Tagged>[]) {
      if (t.isMustSee) continue;
      if (seen.contains(t.placeId)) continue;
      seen.add(t.placeId);
      pool.add(t);
    }
  }
  // Fallback : si le pool non-must-see est trop maigre, on ré-inclut
  // les must-sees modern + riverside (mais toujours pas le Old City
  // pour respecter l'esprit « no heavy temple chain »).
  if (pool.length < _kMinPackSize) {
    for (final type in [DayPackType.modernDay, DayPackType.riversideDay]) {
      for (final t in available[type] ?? const <_Tagged>[]) {
        if (seen.contains(t.placeId)) continue;
        seen.add(t.placeId);
        pool.add(t);
      }
    }
  }
  if (pool.length < _kMinPackSize) return null;
  // Tri par distance au centre cluster — arrival_light privilégie la
  // proximité plutôt que le rating brut.
  pool.sort((a, b) {
    final da = _haversineKm(
        centerLat, centerLng, a.candidate.latitude, a.candidate.longitude);
    final db = _haversineKm(
        centerLat, centerLng, b.candidate.latitude, b.candidate.longitude);
    return da.compareTo(db);
  });
  final picked = pool.take(maxPlaces).toList();
  if (picked.length < _kMinPackSize) return null;
  final ordered = _nearestNeighborOrder(picked, centerLat, centerLng);
  final metrics = _packMetrics(ordered, centerLat, centerLng);
  // arrival_light tolère 1 long hop max (hôtel → 1 spot iconique).
  if (metrics.longTransitions > 1) return null;
  return _buildDayPack(DayPackType.arrivalLightDay, ordered, metrics);
}

String _iso(DateTime d) => d.toIso8601String().split('T').first;

bool _isSameDate(DateTime a, DateTime b) =>
    a.year == b.year && a.month == b.month && a.day == b.day;

/// Construit les day packs pour un cluster donné, dans le contexte
/// d'un trip. Retourne `DayBuilderResult.disabled` si :
/// - le cluster.center n'est pas dans une ville Day-Builder enabled,
/// - le blueprint correspondant n'est pas `kind=majorCity`,
/// - cluster.days < 2 ou pool < 8 candidats.
///
/// `reservedPlaceIds` permet au caller de réserver des place_ids déjà
/// utilisés dans d'autres clusters du même segment (cas k-means split
/// Bangkok : sub-cluster A → must-sees pickés, sub-cluster B doit voir
/// que ces places sont prises pour ne pas les re-tagger).
DayBuilderResult buildDayPacksForCluster({
  required double clusterCenterLat,
  required double clusterCenterLng,
  required List<DateTime> clusterDays,
  required Map<String, ({NearbyCandidate candidate, List<String> matchedInterests})> clusterPool,
  required Trip trip,
  required int maxPerDay,
  Set<String> reservedPlaceIds = const <String>{},
}) {
  if (clusterDays.length < _kMinDaysForBuilder) return DayBuilderResult.disabled;
  if (clusterPool.length < _kMinPoolForBuilder) return DayBuilderResult.disabled;

  final city = _detectBuilderCity(clusterCenterLat, clusterCenterLng);
  if (city == null) return DayBuilderResult.disabled;
  final blueprint = getBlueprintForDestination(city.key);
  if (blueprint == null || blueprint.kind != DestinationKind.majorCity) {
    return DayBuilderResult.disabled;
  }

  // Tag candidats. Skip les placeIds réservés par d'autres sub-clusters
  // du même segment (évite double-pick across k-means partitions).
  final tagged = <_Tagged>[];
  for (final entry in clusterPool.entries) {
    if (reservedPlaceIds.contains(entry.key)) continue;
    final c = entry.value.candidate;
    final mi = entry.value.matchedInterests;
    final archs = _archetypesForCandidate(c, city);
    if (archs.isEmpty) continue;
    tagged.add(_Tagged(entry.key, c, mi, archs, _candidateBaseScore(c, mi)));
  }

  if (tagged.length < _kMinPoolForBuilder) {
    // ignore: avoid_print
    print('[day_builder] city=${city.key} days=${clusterDays.length} '
        'pool=${clusterPool.length} taggedPool=${tagged.length} '
        'enabled=false reason=not_enough_archetype_matches');
    return DayBuilderResult.disabled;
  }

  final byType = <DayPackType, List<_Tagged>>{
    for (final t in DayPackType.values) t: <_Tagged>[],
  };
  for (final t in tagged) {
    for (final arch in t.archetypes) {
      byType[arch]!.add(t);
    }
  }

  final maxPlacesPerDay = math.min(maxPerDay, _kMaxPlacesPerPackHardCap);

  // ignore: avoid_print
  print(
    '[day_builder] city=${city.key} days=${clusterDays.length} '
    'pool=${clusterPool.length} enabled=true '
    'taggedPool=${tagged.length} '
    'counts={old_city:${byType[DayPackType.oldCityDay]!.length},'
    'riverside:${byType[DayPackType.riversideDay]!.length},'
    'market:${byType[DayPackType.marketDay]!.length},'
    'modern:${byType[DayPackType.modernDay]!.length}}',
  );

  final usedPlaceIds = <String>{};
  final result = <DateTime, DayPack>{};
  final tripStart = DateTime(
      trip.startDate.year, trip.startDate.month, trip.startDate.day);
  final sortedDays = [...clusterDays]..sort();
  final typeUseCount = <DayPackType, int>{};

  Map<DayPackType, List<_Tagged>> available() => <DayPackType, List<_Tagged>>{
        for (final t in DayPackType.values)
          t: byType[t]!.where((x) => !usedPlaceIds.contains(x.placeId)).toList()
      };

  for (var i = 0; i < sortedDays.length; i++) {
    final day = sortedDays[i];
    final dayKey = DateTime(day.year, day.month, day.day);
    final isArrival = _isSameDate(dayKey, tripStart);

    DayPack? pack;
    DayPackType? attemptedType;

    if (isArrival) {
      pack = _buildArrivalLightPack(
        available: available(),
        centerLat: clusterCenterLat,
        centerLng: clusterCenterLng,
        maxPlaces: math.min(3, maxPlacesPerDay),
      );
      if (pack != null) {
        attemptedType = DayPackType.arrivalLightDay;
      }
    }

    if (pack == null) {
      // Score chaque archétype : pool size + must-sees disponibles -
      // pénalité si déjà utilisé. Tri descendant pour diversité.
      final scores = <DayPackType, double>{};
      final av = available();
      for (final type in [
        DayPackType.oldCityDay,
        DayPackType.marketDay,
        DayPackType.riversideDay,
        DayPackType.modernDay,
      ]) {
        final pool = av[type]!;
        if (pool.length < _kMinPackSize) continue;
        final mustSeeCount = pool.where((t) => t.isMustSee).length;
        final use = typeUseCount[type] ?? 0;
        scores[type] =
            pool.length.toDouble() + mustSeeCount * 5.0 - use * 10.0;
      }
      final ranked = scores.entries.toList()
        ..sort((a, b) => b.value.compareTo(a.value));
      for (final candType in ranked) {
        final t = candType.key;
        final pool = av[t]!;
        final attempt = _buildPackForType(
          type: t,
          available: pool,
          centerLat: clusterCenterLat,
          centerLng: clusterCenterLng,
          maxPlaces: maxPlacesPerDay,
          maxLongTransitions: _kMaxLongTransitionsPerPack,
        );
        if (attempt != null) {
          // ignore: avoid_print
          print(
            '[day_pack_candidate] date=${_iso(day)} type=${t.label} '
            'places=[${attempt.places.map((c) => '"${c.name}"').join(",")}] '
            'totalDistKm=${attempt.totalDistanceKm.toStringAsFixed(1)} '
            'longTransitions=${attempt.longTransitions} '
            'score=${attempt.score.toStringAsFixed(0)}',
          );
          pack = attempt;
          attemptedType = t;
          break;
        } else {
          // ignore: avoid_print
          print(
            '[day_pack_reject] date=${_iso(day)} type=${t.label} '
            'reason=too_many_long_transitions_or_pool_too_small '
            'poolSize=${pool.length}',
          );
        }
      }
    }

    if (pack != null && attemptedType != null) {
      result[day] = pack;
      usedPlaceIds.addAll(pack.placeIds);
      typeUseCount[attemptedType] = (typeUseCount[attemptedType] ?? 0) + 1;
      // ignore: avoid_print
      print(
        '[day_pack_selected] date=${_iso(day)} type=${pack.type.label} '
        'places=[${pack.places.map((c) => '"${c.name}"').join(",")}] '
        'totalDistKm=${pack.totalDistanceKm.toStringAsFixed(1)} '
        'longTransitions=${pack.longTransitions} '
        'score=${pack.score.toStringAsFixed(0)}',
      );
    } else {
      // ignore: avoid_print
      print('[day_pack_reject] date=${_iso(day)} '
          'reason=no_archetype_pool_sufficient');
    }
  }

  return DayBuilderResult(
    enabled: true,
    cityKey: city.key,
    dayPackByDate: result,
  );
}
