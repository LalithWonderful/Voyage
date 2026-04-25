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
        return list
            .whereType<Map<String, dynamic>>()
            .map(TransportOption.fromJson)
            .toList();
      }
    }

    // 4 appels en parallèle (1 par mode). Chaque échec individuel renvoie null
    // et est filtré du résultat — on garde le best-effort partiel.
    final results = await Future.wait([
      _computeOne(fromPlaceId, toPlaceId, 'WALK', 'walk', key),
      _computeOne(fromPlaceId, toPlaceId, 'DRIVE', 'taxi', key),
      // TRANSIT = générique (métro / tram / bus / train selon la ville). On ne
      // sait pas à l'avance et Routes API n'expose pas le réseau précis dans la
      // réponse minimale. Étiqueté 'transit' = "Transports en commun" pour ne
      // pas mentir au voyageur (ex: pas de métro à Nancy, juste tram + bus).
      _computeOne(fromPlaceId, toPlaceId, 'TRANSIT', 'transit', key),
      _computeOne(fromPlaceId, toPlaceId, 'BICYCLE', 'bike', key),
    ]);
    final options = results.whereType<TransportOption>().toList();
    if (options.isEmpty) return null;

    // Cache (best-effort)
    await _cache?.put('routes_pair', cacheKey, {
      'options': options.map((o) => o.toJson()).toList(),
    });
    return options;
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
