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
///
/// TODO (V8.28-future) — same-complex deduplication. Simu Tokyo
/// 2026-05-11 a montré des packs Roppongi avec « Roppongi Hills
/// Mori Tower » + « Roppongi Hills - Tokyo City View » (= même
/// bâtiment, observation deck dans la tour). Idem Skytree avec
/// « Tokyo Skytree » + « SKYTREE GALLERY » + « Tokyo Skytree Town ».
/// Pas catastrophique mais ressemble à du remplissage artificiel.
/// Fix proposé : règle « parent complex » détectée via prefix nominal
/// (« Roppongi Hills », « Tokyo Skytree ») → garder 1 entrée par
/// complexe, préférer le sous-lieu le plus iconique (observation deck
/// > parent). À implémenter dans le slot picker (post-pack) ou
/// directement dans la composition Day Builder.
library;

import 'dart:math' as math;

import 'package:flutter/foundation.dart' show debugPrint;
import 'package:voyage/features/planning/data/destination_blueprints.dart';
import 'package:voyage/features/planning/data/metro_profile.dart';
import 'package:voyage/features/planning/services/places_nearby_service.dart';
import 'package:voyage/features/trips/models/trip_model.dart';

/// Archétype thématique d'un day pack. Un pack regroupe des candidats
/// cohérents géographiquement ET thématiquement.
///
/// V8.24 (Lalith 2026-05-10) — `market_day` éclaté en 3 zones pour
/// Bangkok (`market_old_city_day`, `market_chatuchak_day`,
/// `market_srinagarindra_day`). Évite de forcer Chatuchak (nord),
/// Chinatown (Old City), Train Night Market (est) dans le même pack
/// thématique alors qu'ils sont à 7-16 km l'un de l'autre. Le générique
/// `market_day` reste pour les villes sans split (Paris).
enum DayPackType {
  oldCityDay('old_city_day'),
  riversideDay('riverside_day'),
  marketDay('market_day'),
  marketOldCityDay('market_old_city_day'),
  marketChatuchakDay('market_chatuchak_day'),
  marketSrinagarindraDay('market_srinagarindra_day'),
  modernDay('modern_day'),
  // V8.28d2 (Lalith 2026-05-11) — split `modernDay` Tokyo en 2 zones
  // géo distinctes. Simu Tokyo 2026-05-11 a montré que Shibuya
  // Crossing + Shinjuku Gyoen + Tokyo Tower passait avec
  // maxTransitionKm=4.4 (sous cap 5 km) mais ce n'est pas un vrai
  // pack compact. Tokyo Tower appartient à Roppongi/Minato, pas à
  // l'axe Shibuya/Harajuku/Shinjuku. Précédent : Bangkok marketDay
  // splitté en marketOldCity/Chatuchak/Srinagarindra.
  modernWestDay('modern_west_day'),
  roppongiMinatoDay('roppongi_minato_day'),
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
  final double maxTransitionKm;
  final int longTransitions;
  final double score;

  const DayPack({
    required this.type,
    required this.places,
    required this.totalDistanceKm,
    required this.maxTransitionKm,
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

// V8.27 — `_BuilderCity` / `_MarketZone` / `_bangkok` / `_paris`
// retirés. Configurations migrées vers `MetroProfile` /
// `MetroZone` dans `data/metro_profile.dart`. Lookup via
// `getMetroProfileForCluster()`. Ajout de nouvelles métropoles
// = ajouter un MetroProfile au registre `metroProfiles`.

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

/// Hard cap maxTransition (km) pour un pack non-arrival. Au-delà, le
/// pack est rejeté quel que soit le nombre de long transitions
/// (Chatuchak↔Srinagarindra à 16km déclenche).
const double _kMaxTransitionPerPackKm = 10.0;

/// V8.28d-fix (Lalith 2026-05-11) — cap durci pour les mégalopoles
/// (`MetroProfile.isMegaCity=true`). Simu Tokyo 2026-05-11 a montré
/// des packs acceptés avec `maxTransitionKm=9.7` (Meiji-jingū →
/// Sanctuaire Asakusa dans la même matinée). Pour les mégalopoles
/// type Tokyo / NYC / London, une journée 3-4 visites doit rester
/// dans une zone (≤ 5 km inter-pick). 5 km est cohérent avec le
/// coherence guard V8.23 et le second-pick guard V8.26.
const double _kMaxTransitionMegaCityKm = 5.0;

/// Hard cap maxTransition (km) pour un pack arrival_light_day. Plus
/// strict (5km) car jour d'arrivée doit rester compact autour du
/// hôtel/cluster, pas d'enchaînement type Asiatique→Bang Na (9.6km).
const double _kMaxTransitionArrivalLightKm = 5.0;

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
  // V8.28d3 — macrons japonais (ō/ū/ā/ē/ī) ajoutés. Sans cette
  // normalisation, "Meiji-jingū", "Zōjō-ji", "Hachikō",
  // "Takeshita-dōri" rataient les patterns Tokyo (rédigés en
  // romaji stripped) et tombaient en fallback `modernDay`.
  const r = <String, String>{
    'á': 'a', 'à': 'a', 'â': 'a', 'ä': 'a', 'ã': 'a', 'å': 'a',
    'ā': 'a',
    'é': 'e', 'è': 'e', 'ê': 'e', 'ë': 'e', 'ē': 'e',
    'í': 'i', 'ì': 'i', 'î': 'i', 'ï': 'i', 'ī': 'i',
    'ó': 'o', 'ò': 'o', 'ô': 'o', 'ö': 'o', 'õ': 'o', 'ō': 'o',
    'ú': 'u', 'ù': 'u', 'û': 'u', 'ü': 'u', 'ū': 'u',
    'ç': 'c', 'đ': 'd', 'ñ': 'n', 'ý': 'y',
  };
  r.forEach((k, v) {
    n = n.replaceAll(k, v);
  });
  return n;
}

class _ArchetypeMatch {
  final Set<DayPackType> archetypes;
  /// True si au moins un archétype vient d'un pattern nominal curated.
  /// False si TOUS les archétypes proviennent du fallback type Google
  /// (ex: Wat Bang Na Nok tagué old_city via `place_of_worship`).
  /// arrival_light_day n'accepte que `fromPattern=true` pour éviter
  /// les enchaînements de temples Bang Na locaux non-iconiques.
  final bool fromPattern;
  const _ArchetypeMatch(this.archetypes, this.fromPattern);
}

/// V8.27 — classifie un candidat en 0..N archétypes selon le
/// MetroProfile de la ville. Itère `profile.zones` (chaque zone =
/// patterns + DayPackType). Pattern match priorité absolue, puis
/// fallback type Google Places. Un place peut matcher plusieurs
/// archétypes (ex: ICONSIAM = riverside ET modern via patterns).
_ArchetypeMatch _archetypesForCandidate(
    NearbyCandidate cand, MetroProfile profile) {
  final out = <DayPackType>{};
  final n = _normName(cand.name);
  bool matchAny(List<String> patterns) =>
      patterns.any((p) => n.contains(p));
  for (final zone in profile.zones) {
    if (matchAny(zone.patterns)) out.add(zone.type);
  }
  // V8.28d3 — filtre les archétypes désactivés pour cette ville
  // (Tokyo désactive `modernDay` au profit des 2 zones géo W +
  // Roppongi). Sans ce filtre, un place qui matcherait à la fois
  // une zone explicite ET un legacy (peu probable mais possible
  // via patterns trop larges) garderait le legacy.
  final disabled = profile.disabledArchetypes;
  if (disabled.isNotEmpty) {
    out.removeWhere(disabled.contains);
  }
  if (out.isNotEmpty) return _ArchetypeMatch(out, true);
  // Fallback type-based pour les candidats sans match nom.
  final types = cand.types.toSet();
  if ((types.contains('hindu_temple') ||
          types.contains('place_of_worship') ||
          types.contains('church') ||
          types.contains('mosque')) &&
      !disabled.contains(DayPackType.oldCityDay)) {
    out.add(DayPackType.oldCityDay);
  }
  // V8.24 — fallback `market` désactivé pour les villes avec
  // `disableMarketTypeFallback=true` (Bangkok = 3 zones marché ;
  // sinon Indy Market / Trok Mor / Imperial World tomberaient
  // à tort dans une zone arbitraire et casseraient la cohérence).
  // Pour Paris (1 zone marketDay), fallback actif.
  if (types.contains('market') &&
      !profile.disableMarketTypeFallback &&
      !disabled.contains(DayPackType.marketDay)) {
    // Ajout au seul DayPackType de type marketDay générique présent
    // dans les zones de la ville (s'il existe).
    for (final zone in profile.zones) {
      if (zone.type == DayPackType.marketDay) {
        out.add(DayPackType.marketDay);
        break;
      }
    }
  }
  // `shopping_mall` retiré du fallback : un mall générique (Imperial
  // World Bang Na, Cloud 11, Mega Bangna) n'est PAS Bangkok-iconique,
  // les malls iconiques (IconSiam, Centralworld, Terminal 21) sont
  // déjà capturés par patterns nominaux.
  //
  // V8.28d3 — `modernDay` fallback bloqué pour Tokyo (`disabled`
  // contient modernDay). Évite Hibiya Park + Mitsubishi Ichigokan
  // Museum + Parc d'Ueno (FR non-matched) de retomber dans modernDay.
  // Les candidats sans pattern match deviennent unassigned → skip.
  if ((types.contains('park') ||
          types.contains('national_park') ||
          types.contains('botanical_garden') ||
          types.contains('art_gallery')) &&
      !disabled.contains(DayPackType.modernDay)) {
    out.add(DayPackType.modernDay);
  }
  return _ArchetypeMatch(out, false);
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
  final bool fromPattern;
  final double baseScore;

  _Tagged(this.placeId, this.candidate, this.matchedInterests,
      this.archetypes, this.fromPattern, this.baseScore);

  bool get isMustSee => _hasMustSeeMarker(matchedInterests);
}

class _PackMetrics {
  final double totalDistanceKm;
  final int longTransitions;
  final double maxTransitionKm;
  const _PackMetrics(this.totalDistanceKm, this.longTransitions, this.maxTransitionKm);
}

_PackMetrics _packMetrics(
    List<_Tagged> ordered, double anchorLat, double anchorLng) {
  if (ordered.isEmpty) return const _PackMetrics(0, 0, 0);
  // V8.22 — `longTransitions` et `maxTransitionKm` ne comptent QUE les
  // hops INTER-place, pas le hop initial centre_cluster → 1ʳᵉ place.
  // Ce hop initial représente le commute matinal hôtel → 1ʳᵉ activité,
  // qui n'est pas un « zigzag intra-jour » au sens utilisateur. Sans
  // cette exclusion, le cluster Bang Na (hôtel 13.67/100.60 à 12 km de
  // Old City) rejetait à tort le pack old_city compact Grand Palace +
  // Wat Pho + Wat Arun (inter-pick 0.4 + 0.5 km).
  //
  // `totalDistanceKm` inclut le hop initial pour info (distance totale
  // parcourue, utile à l'affichage).
  double total = 0;
  int longs = 0;
  double maxHop = 0;
  // Premier hop : centre cluster → 1ʳᵉ place. Compté dans total mais
  // pas dans longs/maxHop.
  final firstHop = _haversineKm(
      anchorLat, anchorLng,
      ordered.first.candidate.latitude, ordered.first.candidate.longitude);
  total += firstHop;
  double prevLat = ordered.first.candidate.latitude;
  double prevLng = ordered.first.candidate.longitude;
  for (var i = 1; i < ordered.length; i++) {
    final t = ordered[i];
    final d = _haversineKm(
        prevLat, prevLng, t.candidate.latitude, t.candidate.longitude);
    total += d;
    if (d > _kLongTransitionKm) longs += 1;
    if (d > maxHop) maxHop = d;
    prevLat = t.candidate.latitude;
    prevLng = t.candidate.longitude;
  }
  return _PackMetrics(total, longs, maxHop);
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
    maxTransitionKm: m.maxTransitionKm,
    longTransitions: m.longTransitions,
    score: score,
  );
}

bool _packMetricsAcceptable(_PackMetrics m, {
  required int maxLongTransitions,
  required double maxTransitionKmCap,
}) {
  return m.longTransitions <= maxLongTransitions &&
      m.maxTransitionKm <= maxTransitionKmCap;
}

DayPack? _buildPackForType({
  required DayPackType type,
  required List<_Tagged> available,
  required double centerLat,
  required double centerLng,
  required int maxPlaces,
  required int maxLongTransitions,
  required double maxTransitionKmCap,
}) {
  if (available.length < _kMinPackSize) return null;
  final sorted = [...available]
    ..sort((a, b) => b.baseScore.compareTo(a.baseScore));
  // Première tentative : top-K par score.
  var picked = sorted.take(maxPlaces).toList();
  var ordered = _nearestNeighborOrder(picked, centerLat, centerLng);
  var metrics = _packMetrics(ordered, centerLat, centerLng);
  if (_packMetricsAcceptable(metrics,
      maxLongTransitions: maxLongTransitions,
      maxTransitionKmCap: maxTransitionKmCap)) {
    return _buildDayPack(type, ordered, metrics);
  }
  // Shrink retry : drop la place la plus éloignée du centre, retest.
  while (picked.length > _kMinPackSize &&
      !_packMetricsAcceptable(metrics,
          maxLongTransitions: maxLongTransitions,
          maxTransitionKmCap: maxTransitionKmCap)) {
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
  if (!_packMetricsAcceptable(metrics,
      maxLongTransitions: maxLongTransitions,
      maxTransitionKmCap: maxTransitionKmCap)) {
    return null;
  }
  if (ordered.length < _kMinPackSize) return null;
  return _buildDayPack(type, ordered, metrics);
}

DayPack? _buildArrivalLightPack({
  required Map<DayPackType, List<_Tagged>> available,
  required double centerLat,
  required double centerLng,
  required int maxPlaces,
}) {
  // Strict pattern-only : exclut les fallbacks type Google Places
  // (place_of_worship, market type sans pattern). Évite les
  // enchaînements Wat Bang Na Nok / Wat Bang Nam Phueng Nok = temples
  // Bang Na locaux non-iconiques. Doit ressembler à du curated, pas
  // à du proximité brute.
  //
  // Exclut aussi les must-sees iconiques (préservés pour les vrais
  // packs thématiques) — la journée d'arrivée doit rester compacte
  // autour du hôtel/cluster, pas faire de 9 km pour un must-see.
  //
  // Si le pool insuffisant (< 3), arrival_light est rejeté → fall
  // through vers old_city/modern/market dans le caller. Mieux vaut
  // une journée Old City compacte qu'un arrival_light mal composé.
  final pool = <_Tagged>[];
  final seen = <String>{};
  for (final type in [
    DayPackType.modernDay,
    // V8.28d2 — arrival pool inclut aussi les modern zones Tokyo
    // splittées. Garde le caractère « pattern non-must-see proche »
    // pour le J1 compact autour de l'hôtel.
    DayPackType.modernWestDay,
    DayPackType.roppongiMinatoDay,
    DayPackType.riversideDay,
    DayPackType.oldCityDay,
  ]) {
    for (final t in available[type] ?? const <_Tagged>[]) {
      if (!t.fromPattern) continue;
      if (t.isMustSee) continue;
      if (seen.contains(t.placeId)) continue;
      seen.add(t.placeId);
      pool.add(t);
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
  // Hard cap 5 km maxTransition pour arrival_light_day (spec user :
  // « low distance, no >5km transition »). Cap aussi longTransitions
  // ≤ 1 (hôtel → 1ʳᵉ activité tolère 1 long hop modéré).
  if (!_packMetricsAcceptable(metrics,
      maxLongTransitions: 1,
      maxTransitionKmCap: _kMaxTransitionArrivalLightKm)) {
    return null;
  }
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

  final profile = getMetroProfileForCluster(
      clusterCenterLat, clusterCenterLng);
  if (profile == null) return DayBuilderResult.disabled;
  final blueprint = getBlueprintForDestination(profile.cityKey);
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
    final match = _archetypesForCandidate(c, profile);
    if (match.archetypes.isEmpty) continue;
    tagged.add(_Tagged(entry.key, c, mi, match.archetypes,
        match.fromPattern, _candidateBaseScore(c, mi)));
  }

  if (tagged.length < _kMinPoolForBuilder) {
    debugPrint('[day_builder] city=${profile.cityKey} days=${clusterDays.length} '
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
  // V8.28d-fix — cap maxTransition durci pour les mégalopoles. Évite
  // Meiji-jingū → Asakusa (9.7 km) acceptés dans la même matinée
  // Tokyo. Cf. simu 2026-05-11.
  final maxTransitionKmCap = profile.isMegaCity
      ? _kMaxTransitionMegaCityKm
      : _kMaxTransitionPerPackKm;

  // V8.24 — log condensé : ne montre que les counts non-nuls.
  final countsParts = <String>[];
  for (final t in DayPackType.values) {
    final n = byType[t]!.length;
    if (n > 0) countsParts.add('${t.label}:$n');
  }
  debugPrint(
    '[day_builder] city=${profile.cityKey} days=${clusterDays.length} '
    'pool=${clusterPool.length} enabled=true '
    'taggedPool=${tagged.length} '
    'counts={${countsParts.join(",")}}',
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
      } else {
        debugPrint(
          '[day_pack_reject] date=${_iso(day)} type=arrival_light_day '
          'reason=insufficient_pattern_pool_or_maxTransition_over_5km',
        );
      }
    }

    if (pack == null) {
      // Score chaque archétype : pool size + must-sees disponibles -
      // pénalité si déjà utilisé. Tri descendant pour diversité.
      final scores = <DayPackType, double>{};
      final av = available();
      // V8.22 — sur jour d'arrivée, fallback restreint à old_city_day
      // uniquement (pas modern/market/riverside). Préserve l'intention
      // produit « J1 = arrivée légère, idéalement Old City compact ».
      // Évite Jim Thompson + Lumpini + Mahanakhon le 1er jour vs Old
      // City iconique réservé pour plus tard.
      final candidateTypes = isArrival
          ? const [DayPackType.oldCityDay]
          : const [
              DayPackType.oldCityDay,
              DayPackType.marketDay,
              DayPackType.marketOldCityDay,
              DayPackType.marketChatuchakDay,
              DayPackType.marketSrinagarindraDay,
              DayPackType.riversideDay,
              DayPackType.modernDay,
              // V8.28d2 — zones modernes Tokyo (split géo).
              DayPackType.modernWestDay,
              DayPackType.roppongiMinatoDay,
            ];
      for (final type in candidateTypes) {
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
          maxTransitionKmCap: maxTransitionKmCap,
        );
        if (attempt != null) {
          debugPrint(
            '[day_pack_candidate] date=${_iso(day)} type=${t.label} '
            'places=[${attempt.places.map((c) => '"${c.name}"').join(",")}] '
            'totalDistKm=${attempt.totalDistanceKm.toStringAsFixed(1)} '
            'maxTransitionKm=${attempt.maxTransitionKm.toStringAsFixed(1)} '
            'longTransitions=${attempt.longTransitions} '
            'score=${attempt.score.toStringAsFixed(0)}',
          );
          pack = attempt;
          attemptedType = t;
          break;
        } else {
          debugPrint(
            '[day_pack_reject] date=${_iso(day)} type=${t.label} '
            'reason=pool_too_small_or_maxTransition_over_${maxTransitionKmCap.toStringAsFixed(0)}km_or_too_many_long_hops '
            'poolSize=${pool.length} isMegaCity=${profile.isMegaCity}',
          );
        }
      }
    }

    if (pack != null && attemptedType != null) {
      result[day] = pack;
      usedPlaceIds.addAll(pack.placeIds);
      typeUseCount[attemptedType] = (typeUseCount[attemptedType] ?? 0) + 1;
      debugPrint(
        '[day_pack_selected] date=${_iso(day)} type=${pack.type.label} '
        'places=[${pack.places.map((c) => '"${c.name}"').join(",")}] '
        'totalDistKm=${pack.totalDistanceKm.toStringAsFixed(1)} '
        'maxTransitionKm=${pack.maxTransitionKm.toStringAsFixed(1)} '
        'longTransitions=${pack.longTransitions} '
        'score=${pack.score.toStringAsFixed(0)}',
      );
    } else {
      debugPrint('[day_pack_reject] date=${_iso(day)} '
          'reason=no_archetype_pool_sufficient');
    }
  }

  return DayBuilderResult(
    enabled: true,
    cityKey: profile.cityKey,
    dayPackByDate: result,
  );
}
