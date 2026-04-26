import 'dart:convert';
import 'dart:developer' as developer;
import 'package:http/http.dart' as http;
import 'package:voyage/core/constants/ai_constants.dart';
import 'package:voyage/features/planning/models/trip_transport_model.dart';
import 'package:voyage/features/planning/services/gemini_cache_service.dart';

/// Service Google Routes API v2 — calcule des durées de trajet réelles entre
/// deux lieux pour 4 modes de transport (walk, drive=taxi, transit, bicycle).
///
/// Remplace les durées générées par Gemini, qui hallucinaient régulièrement
/// (ex: "20 min à pied" pour 8 km réels). Routes API utilise le réseau routier
/// + les horaires de transport en commun + les pistes cyclables Google Maps.
///
/// Fallback : si l'appel échoue (clé invalide, quota, lieu inconnu, réseau),
/// retourne `null` et le caller devra fallback sur les durées Gemini ou des
/// estimations heuristiques.
///
/// Cache : table `gemini_cache` avec action `routes_pair`. Une paire de
/// place_id donne le même résultat tant que les routes ne changent pas, donc
/// TTL long (30j par défaut). Les hits sont gratuits pour tous les voyageurs.
class RoutesService {
  final GeminiCacheService? _cache;

  RoutesService({GeminiCacheService? cache}) : _cache = cache;

  /// Calcule les options de transport réalistes pour une paire (origin, destination).
  /// Retourne `null` si tout a échoué (réseau, clé, place_ids invalides).
  ///
  /// `travelerType` influence le `default_mode` retourné dans le bundle :
  /// Grand luxe / Voyage pro → taxi, Backpack / Meilleur prix → walk ou transit,
  /// En famille → taxi (avec enfants), Road-trip → car. Le default_mode n'est
  /// PAS retourné par cette méthode — c'est au caller de le calculer à partir
  /// du profil et des options retournées (ex: la 1ère option valide).
  Future<List<TransportOption>?> computeOptions({
    required String fromPlaceId,
    required String toPlaceId,
  }) async {
    final key = AiConstants.googleMapsApiKey;
    if (key.isEmpty || key == 'COLLE_TA_CLE_MAPS_ICI') return null;
    if (fromPlaceId.isEmpty || toPlaceId.isEmpty) return null;
    if (fromPlaceId == toPlaceId) return null;

    // Lookup cache (clé = paire ordonnée — A→B et B→A peuvent différer en transit).
    final cacheKey = GeminiCacheService.hashKey([
      (k: 'from', v: fromPlaceId),
      (k: 'to', v: toPlaceId),
    ]);
    final cached = await _cache?.get('routes_pair', cacheKey);
    if (cached != null) {
      final list = cached['options'] as List?;
      if (list != null && list.isNotEmpty) {
        final cachedOpts = list
            .whereType<Map<String, dynamic>>()
            .map(TransportOption.fromJson)
            .toList();
        // CRITIQUE : on filtre les options absurdes même au retour cache.
        // Sans ça, un cache pré-fix (avec WALK 600min) sert toujours la mauvaise
        // valeur. Bug signalé par Lalith : "10h à pied" persistait après le fix
        // côté _computeOne car les options venaient du cache, pas d'un call frais.
        return _filterAbsurdOptions(cachedOpts);
      }
    }

    // 4 appels en parallèle (1 par mode). Chaque échec individuel renvoie null
    // et est filtré du résultat — on garde le best-effort partiel.
    // TRANSIT a son propre code (_computeTransit) car on parse les transitDetails
    // pour extraire le vehicle réel (bus/tram/metro/train) et les instructions
    // de guidage (numéro de ligne, arrêt de montée/descente, direction). C'est
    // critique pour le guide-par-la-main : "Tram 1, arrêt Place Stanislas, dir.
    // Vandœuvre" ≠ "Bus 4, arrêt République, dir. Centre".
    final results = await Future.wait([
      _computeOne(fromPlaceId, toPlaceId, 'WALK', 'walk', key),
      _computeOne(fromPlaceId, toPlaceId, 'DRIVE', 'taxi', key),
      _computeTransit(fromPlaceId, toPlaceId, key),
      _computeOne(fromPlaceId, toPlaceId, 'BICYCLE', 'bike', key),
    ]);
    final options = results.whereType<TransportOption>().toList();
    if (options.isEmpty) return null;

    // Cache (best-effort) — on cache AVANT filtrage : si la logique de filtre
    // évolue, on n'invalide pas tout le cache. Le filtre est appliqué à chaque
    // lecture (cache ou fresh) côté `computeOptions`.
    await _cache?.put('routes_pair', cacheKey, {
      'options': options.map((o) => o.toJson()).toList(),
    });
    return _filterAbsurdOptions(options);
  }

  /// Filtre post-hoc des options absurdes : appelé à chaque retour de
  /// `computeOptions`, que les options viennent du cache ou d'un call frais.
  /// Permet au filtre d'évoluer sans invalider le cache et de couvrir les
  /// caches pré-fix qui contenaient déjà des valeurs aberrantes.
  /// Règles :
  /// - WALK : >180 min OU >15 km → on enlève (10h à pied, c'est non-sens UX)
  /// - BIKE : >80 km → on enlève
  /// - DRIVE / TRANSIT / autres : on garde tel quel
  List<TransportOption> _filterAbsurdOptions(List<TransportOption> options) {
    final kept = <TransportOption>[];
    for (final o in options) {
      // Extrait la distance depuis `detail` ("X.Y km") quand présent.
      double? distanceKm;
      if (o.detail != null) {
        final m = RegExp(r'(\d+(?:\.\d+)?)\s*km').firstMatch(o.detail!);
        if (m != null) distanceKm = double.tryParse(m.group(1)!);
      }
      if (o.mode == 'walk' && (o.durationMinutes > 180 || (distanceKm != null && distanceKm > 15))) {
        developer.log(
          'Routes filter: WALK rejeté (${o.durationMinutes}min, ${distanceKm?.toStringAsFixed(1) ?? "?"}km) — aberrant pour la marche',
          name: 'routes',
        );
        continue;
      }
      if (o.mode == 'bike' && distanceKm != null && distanceKm > 80) {
        developer.log(
          'Routes filter: BIKE rejeté (${distanceKm.toStringAsFixed(1)}km) — trop long pour le vélo',
          name: 'routes',
        );
        continue;
      }
      kept.add(o);
    }
    return kept;
  }

  /// Appelle Routes API pour UN seul mode. Renvoie `null` en cas d'échec
  /// (mode pas adapté entre A et B, par ex. transit dans une zone non desservie).
  Future<TransportOption?> _computeOne(
    String fromPlaceId,
    String toPlaceId,
    String googleMode,
    String voyageMode,
    String key,
  ) async {
    try {
      final uri = Uri.https('routes.googleapis.com', '/directions/v2:computeRoutes');
      final body = jsonEncode({
        'origin': {'placeId': fromPlaceId},
        'destination': {'placeId': toPlaceId},
        'travelMode': googleMode,
        // routingPreference n'est valide que pour DRIVE — Google rejette le request
        // (400) si on l'envoie pour les autres modes.
        if (googleMode == 'DRIVE') 'routingPreference': 'TRAFFIC_AWARE',
      });
      final resp = await http.post(
        uri,
        headers: {
          'Content-Type': 'application/json',
          'X-Goog-Api-Key': key,
          'X-Goog-FieldMask': 'routes.duration,routes.distanceMeters',
        },
        body: body,
      );
      if (resp.statusCode != 200) {
        developer.log('Routes HTTP ${resp.statusCode} ($googleMode): ${resp.body}', name: 'routes');
        return null;
      }
      final data = jsonDecode(resp.body) as Map<String, dynamic>;
      final routes = data['routes'] as List?;
      if (routes == null || routes.isEmpty) {
        developer.log('Routes: aucun itinéraire $googleMode', name: 'routes');
        return null;
      }
      final route = routes.first as Map<String, dynamic>;
      // duration au format ISO-8601 court ("1234s")
      final durationStr = route['duration'] as String?;
      final seconds = _parseDurationSeconds(durationStr);
      if (seconds == null || seconds <= 0) return null;
      final minutes = (seconds / 60).round().clamp(1, 600);
      final distanceM = (route['distance_meters'] as num?)?.toInt() ??
          (route['distanceMeters'] as num?)?.toInt() ??
          0;

      // Filtre les options absurdes : WALK >15km ou >3h, BIKE >80km. Au-delà,
      // proposer ces modes n'a pas de sens UX (cas réel : "10h à pied" à Épinal
      // quand le suggesteur place 2 activités à 50km l'une de l'autre par erreur).
      // DRIVE et TRANSIT restent autorisés à toute distance — le caller peut
      // décider d'afficher un avertissement en amont.
      if (voyageMode == 'walk' && (distanceM > 15000 || minutes > 180)) {
        developer.log(
          'Routes: WALK filtré ($fromPlaceId → $toPlaceId) — ${(distanceM / 1000).toStringAsFixed(1)}km, ${minutes}min aberrants pour la marche',
          name: 'routes',
        );
        return null;
      }
      if (voyageMode == 'bike' && distanceM > 80000) {
        developer.log(
          'Routes: BIKE filtré ($fromPlaceId → $toPlaceId) — ${(distanceM / 1000).toStringAsFixed(1)}km trop long pour le vélo',
          name: 'routes',
        );
        return null;
      }
      // Logging défensif : si DRIVE >50km entre 2 activités, c'est suspect (probable
      // bug suggesteur ayant placé 2 activités lointaines sur la même journée, ex:
      // Marrakech→Fès = 256km/388€). Aide à diagnostiquer en amont.
      if (voyageMode == 'taxi' && distanceM > 50000) {
        developer.log(
          'Routes: DRIVE longue distance ($fromPlaceId → $toPlaceId) — ${(distanceM / 1000).toStringAsFixed(1)}km. Vérifier que le suggesteur ne place pas 2 activités lointaines sur le même jour.',
          name: 'routes',
        );
      }

      return TransportOption(
        mode: voyageMode,
        durationMinutes: minutes,
        priceEstimate: _estimatePrice(voyageMode, distanceM),
        detail: distanceM > 0 ? '${(distanceM / 1000).toStringAsFixed(1)} km' : null,
      );
    } catch (e) {
      developer.log('Routes exception $googleMode: $e', name: 'routes');
      return null;
    }
  }

  /// Spécifique TRANSIT : appelle Routes API avec un field mask étendu pour
  /// récupérer les détails de chaque step (vehicle.type, numéro de ligne,
  /// arrêts, direction). Construit une TransportOption "guidée" avec :
  /// - `mode` = vehicle type réel (bus, tram, metro, train, boat, transit fallback)
  /// - `detail` = ligne de guidage humaine type "Tram 1 (Pl. Stanislas → Vandœuvre,
  ///   dir. Vandœuvre, 5 arrêts)" — coeur de la promesse "guide par la main".
  ///
  /// Si plusieurs segments TRANSIT (ex: bus + tram), `mode` = celui dont la
  /// durée est la plus longue, et `detail` enchaîne les instructions avec "puis".
  Future<TransportOption?> _computeTransit(String fromPlaceId, String toPlaceId, String key) async {
    try {
      final uri = Uri.https('routes.googleapis.com', '/directions/v2:computeRoutes');
      final body = jsonEncode({
        'origin': {'placeId': fromPlaceId},
        'destination': {'placeId': toPlaceId},
        'travelMode': 'TRANSIT',
      });
      final resp = await http.post(
        uri,
        headers: {
          'Content-Type': 'application/json',
          'X-Goog-Api-Key': key,
          'X-Goog-FieldMask':
              'routes.duration,routes.distanceMeters,routes.legs.steps.travelMode,routes.legs.steps.duration,routes.legs.steps.transitDetails',
        },
        body: body,
      );
      if (resp.statusCode != 200) {
        developer.log('Routes HTTP ${resp.statusCode} (TRANSIT) $fromPlaceId→$toPlaceId: ${resp.body}', name: 'routes');
        return null;
      }
      final data = jsonDecode(resp.body) as Map<String, dynamic>;
      final routes = data['routes'] as List?;
      if (routes == null || routes.isEmpty) {
        developer.log('Routes TRANSIT: aucune route renvoyée pour $fromPlaceId→$toPlaceId (probablement trop proche ou pas de réseau)', name: 'routes');
        return null;
      }
      final route = routes.first as Map<String, dynamic>;

      final seconds = _parseDurationSeconds(route['duration'] as String?);
      if (seconds == null || seconds <= 0) {
        developer.log('Routes TRANSIT: durée nulle/invalide $fromPlaceId→$toPlaceId', name: 'routes');
        return null;
      }
      final minutes = (seconds / 60).round().clamp(1, 600);
      final distanceM = (route['distanceMeters'] as num?)?.toInt() ?? 0;

      // Parse les steps TRANSIT — chaque step est un segment "bus 5" ou "tram 1".
      // Les steps WALK intercalés (marche jusqu'à l'arrêt) sont ignorés ici, car
      // le caller affiche déjà les transferts dans une UI dédiée.
      final transitSteps = <Map<String, dynamic>>[];
      for (final leg in (route['legs'] as List? ?? const [])) {
        if (leg is! Map) continue;
        for (final step in (leg['steps'] as List? ?? const [])) {
          if (step is Map && step['travelMode'] == 'TRANSIT') {
            transitSteps.add(step.cast<String, dynamic>());
          }
        }
      }

      if (transitSteps.isEmpty) {
        // Pas de step TRANSIT identifié (peut-être un trajet 100% marche que Google
        // a mis en TRANSIT par défaut). On renvoie une option transit générique.
        developer.log(
          'Routes TRANSIT: aucun segment transit dans la route $fromPlaceId→$toPlaceId '
          '(${minutes}min, ${(distanceM / 1000).toStringAsFixed(1)}km) — fallback générique',
          name: 'routes',
        );
        return TransportOption(
          mode: 'transit',
          durationMinutes: minutes,
          priceEstimate: _estimatePrice('transit', distanceM),
          detail: distanceM > 0 ? '${(distanceM / 1000).toStringAsFixed(1)} km' : null,
        );
      }

      String? primaryMode;
      var primaryDurationS = -1;
      final descriptions = <String>[];
      for (final step in transitSteps) {
        final transit = step['transitDetails'] as Map<String, dynamic>?;
        if (transit == null) continue;
        final stepDurS = _parseDurationSeconds(step['duration'] as String?) ?? 0;

        final line = transit['transitLine'] as Map<String, dynamic>?;
        // Numéro/court : `nameShort` souvent "1", "T2", "B5". Sinon `name` long.
        final lineLabel = (line?['nameShort'] as String?)?.trim() ??
            (line?['name'] as String?)?.trim() ??
            '';
        final vehicle = line?['vehicle'] as Map<String, dynamic>?;
        final mappedMode = _mapVehicleType(vehicle?['type'] as String?);

        final stops = transit['stopDetails'] as Map<String, dynamic>?;
        final fromStop = (stops?['departureStop'] as Map?)?['name'] as String?;
        final toStop = (stops?['arrivalStop'] as Map?)?['name'] as String?;
        final headsign = (transit['headsign'] as String?)?.trim();
        final stopCount = (transit['stopCount'] as num?)?.toInt();

        // Format guidé : "Tram 1 (Place Stanislas → Vandœuvre, dir. Vandœuvre, 5 arrêts)"
        final modeLabel = transportModeLabels[mappedMode] ?? mappedMode;
        final head = lineLabel.isEmpty ? modeLabel : '$modeLabel $lineLabel';
        final parts = <String>[];
        if (fromStop != null && toStop != null) {
          parts.add('$fromStop → $toStop');
        } else if (toStop != null) {
          parts.add('arrivée: $toStop');
        }
        if (headsign != null && headsign.isNotEmpty) parts.add('dir. $headsign');
        if (stopCount != null && stopCount > 0) {
          parts.add('$stopCount arrêt${stopCount > 1 ? 's' : ''}');
        }
        descriptions.add(parts.isEmpty ? head : '$head (${parts.join(', ')})');

        if (stepDurS > primaryDurationS) {
          primaryDurationS = stepDurS;
          primaryMode = mappedMode;
        }
      }

      if (descriptions.isEmpty || primaryMode == null) return null;

      return TransportOption(
        mode: primaryMode,
        durationMinutes: minutes,
        priceEstimate: _estimatePrice(primaryMode, distanceM),
        detail: descriptions.join(' puis '),
      );
    } catch (e) {
      developer.log('Routes exception TRANSIT: $e', name: 'routes');
      return null;
    }
  }

  /// Mappe l'enum `vehicle.type` de Routes API vers un mode Voyage.
  /// Liste source : https://developers.google.com/maps/documentation/routes
  /// (Google maintient ~25 types — on regroupe les plus fins, ex: ICE/maglev/etc → train).
  String _mapVehicleType(String? type) {
    if (type == null) return 'transit';
    switch (type) {
      case 'BUS':
      case 'INTERCITY_BUS':
      case 'TROLLEYBUS':
      case 'SHARE_TAXI':
        return 'bus';
      case 'TRAM':
      case 'LIGHT_RAIL':
        return 'tram';
      case 'METRO_RAIL':
      case 'SUBWAY':
      case 'MONORAIL':
        return 'metro';
      case 'HEAVY_RAIL':
      case 'COMMUTER_TRAIN':
      case 'HIGH_SPEED_TRAIN':
      case 'LONG_DISTANCE_TRAIN':
      case 'RAIL':
        return 'train';
      case 'FERRY':
        return 'boat';
      default:
        return 'transit';
    }
  }

  /// Estimation grossière du prix par mode. Routes API ne donne pas de prix,
  /// donc on heuristise. Volontairement simple — sera affiné quand on aura
  /// les vrais tarifs locaux par destination (post-beta).
  String _estimatePrice(String voyageMode, int distanceMeters) {
    switch (voyageMode) {
      case 'walk':
      case 'bike':
        return 'Gratuit';
      case 'transit':
      case 'metro':
      case 'tram':
      case 'bus':
        // Ticket unitaire dans la majorité des villes européennes : 1.50€-2.50€
        return '~2€';
      case 'taxi':
        // Forfait + ~1.5€/km — ordre de grandeur FR. Variera selon le pays.
        if (distanceMeters <= 0) return '~10€';
        final km = distanceMeters / 1000;
        final price = (3 + 1.5 * km).round();
        return '~$price€';
      default:
        return '~5€';
    }
  }

  /// Parse "1234s" → 1234. Tolérant : accepte aussi "1234.5s".
  int? _parseDurationSeconds(String? s) {
    if (s == null || s.isEmpty) return null;
    final trimmed = s.endsWith('s') ? s.substring(0, s.length - 1) : s;
    final n = num.tryParse(trimmed);
    return n?.toInt();
  }
}
