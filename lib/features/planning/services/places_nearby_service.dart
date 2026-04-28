import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:voyage/core/constants/ai_constants.dart';
import 'package:voyage/core/services/location_service.dart';
import 'package:voyage/features/planning/services/gemini_cache_service.dart';

/// Un candidat retourné par Places Nearby Search ou Text Search v1.
/// Contient tout ce dont on a besoin pour le filtrage post-fetch (rating,
/// userRatingCount, priceLevel, types) ET les coords pour le filtrage
/// distance / clustering géographique.
///
/// Distinct du `PlaceInfo` historique (qui sert pour les fiches et le cache
/// `places_cache` keyed par titre+destination) : ici on travaille avec une
/// liste de lieux RÉELS retournée par une recherche, pas un lookup par nom.
class NearbyCandidate {
  final String placeId;
  final String name;
  final String? address;
  final double? rating;
  final int? userRatingCount;
  /// 0 = gratuit, 1 = inexpensive, 2 = moderate, 3 = expensive, 4 = very expensive.
  /// Null si non renseigné par Places.
  final int? priceLevel;
  final List<String> types;
  final double latitude;
  final double longitude;

  const NearbyCandidate({
    required this.placeId,
    required this.name,
    required this.latitude,
    required this.longitude,
    this.address,
    this.rating,
    this.userRatingCount,
    this.priceLevel,
    this.types = const [],
  });

  factory NearbyCandidate.fromPlacesV1(Map<String, dynamic> json) {
    final loc = json['location'] as Map<String, dynamic>? ?? const {};
    final lat = (loc['latitude'] as num?)?.toDouble();
    final lng = (loc['longitude'] as num?)?.toDouble();
    return NearbyCandidate(
      placeId: json['id'] as String? ?? '',
      name: ((json['displayName'] as Map?)?['text'] as String?)?.trim() ?? '',
      address: (json['formattedAddress'] as String?)?.trim(),
      rating: (json['rating'] as num?)?.toDouble(),
      userRatingCount: (json['userRatingCount'] as num?)?.toInt(),
      priceLevel: _decodePriceLevel(json['priceLevel'] as String?),
      types: ((json['types'] as List?) ?? const []).map((e) => e.toString()).toList(),
      latitude: lat ?? 0,
      longitude: lng ?? 0,
    );
  }

  Map<String, dynamic> toCacheJson() => {
        'placeId': placeId,
        'name': name,
        'address': address,
        'rating': rating,
        'userRatingCount': userRatingCount,
        'priceLevel': priceLevel,
        'types': types,
        'latitude': latitude,
        'longitude': longitude,
      };

  factory NearbyCandidate.fromCacheJson(Map<String, dynamic> json) => NearbyCandidate(
        placeId: json['placeId'] as String? ?? '',
        name: json['name'] as String? ?? '',
        address: json['address'] as String?,
        rating: (json['rating'] as num?)?.toDouble(),
        userRatingCount: (json['userRatingCount'] as num?)?.toInt(),
        priceLevel: (json['priceLevel'] as num?)?.toInt(),
        types: ((json['types'] as List?) ?? const []).map((e) => e.toString()).toList(),
        latitude: (json['latitude'] as num?)?.toDouble() ?? 0,
        longitude: (json['longitude'] as num?)?.toDouble() ?? 0,
      );

  static int? _decodePriceLevel(String? raw) {
    switch (raw) {
      case 'PRICE_LEVEL_FREE':
        return 0;
      case 'PRICE_LEVEL_INEXPENSIVE':
        return 1;
      case 'PRICE_LEVEL_MODERATE':
        return 2;
      case 'PRICE_LEVEL_EXPENSIVE':
        return 3;
      case 'PRICE_LEVEL_VERY_EXPENSIVE':
        return 4;
      default:
        return null;
    }
  }
}

/// Wrapper sur Places API (New) v1 — endpoints `places:searchNearby` et
/// `places:searchText`. Brique de base de la refonte "Places-first" du
/// suggesteur : on récupère une liste de VRAIS lieux dans un quartier, puis
/// Gemini choisit/ordonne parmi cette liste (zéro hallucination par construction).
///
/// Les filtres rating / userRatingCount / priceLevel sont appliqués CÔTÉ DART
/// (post-fetch) car l'API n'accepte que `priceLevels` en paramètre serveur.
/// Voir `interests_to_places_mapping.dart` pour les requêtes par intérêt.
///
/// Cache : table `gemini_cache` (action `places_search`). Clé = hash
/// (mode + types/textQuery + lat/lng arrondis + radius). TTL long (les lieux
/// d'une ville changent peu). Le hit est gratuit pour tous les voyageurs.
class PlacesNearbyService {
  final GeminiCacheService? _cache;

  PlacesNearbyService({GeminiCacheService? cache}) : _cache = cache;

  static const _fieldMask =
      'places.id,places.displayName,places.formattedAddress,'
      'places.rating,places.userRatingCount,places.priceLevel,'
      'places.types,places.location';

  /// Recherche par types Places (`includedTypes`). Restreinte à un cercle
  /// (lat/lng + radius en mètres).
  ///
  /// `languageCode` : code BCP-47 (ex: "fr", "en", "fr-FR"). Critique pour les
  /// destinations non-anglophones — sans ça, Places retourne les noms en
  /// langue locale (arabe au Maroc, thaï à Bangkok). Default null = langue
  /// par défaut Places (généralement anglais).
  Future<List<NearbyCandidate>> searchNearby({
    required double latitude,
    required double longitude,
    required List<String> includedTypes,
    int radius = 1500,
    int maxResults = 20,
    String? languageCode,
  }) async {
    final key = AiConstants.googleMapsApiKey;
    if (key.isEmpty || key == 'COLLE_TA_CLE_MAPS_ICI') return [];
    if (includedTypes.isEmpty) return [];

    final cacheKey = _cacheKeyForNearby(
      types: includedTypes,
      lat: latitude,
      lng: longitude,
      radius: radius,
      maxResults: maxResults,
      languageCode: languageCode,
    );
    final cached = await _cache?.get('places_search', cacheKey);
    if (cached != null) {
      final list = cached['places'] as List?;
      if (list != null) {
        final results = list
            .whereType<Map<String, dynamic>>()
            .map(NearbyCandidate.fromCacheJson)
            .toList();
        debugPrint(
          '[places_nearby] cache HIT searchNearby types=$includedTypes '
          'r=${radius}m → ${results.length} candidats',
        );
        return results;
      }
    }

    try {
      final uri = Uri.https('places.googleapis.com', '/v1/places:searchNearby');
      final body = jsonEncode({
        'includedTypes': includedTypes,
        'maxResultCount': maxResults.clamp(1, 20),
        'locationRestriction': {
          'circle': {
            'center': {'latitude': latitude, 'longitude': longitude},
            'radius': radius,
          },
        },
        if (languageCode != null && languageCode.isNotEmpty) 'languageCode': languageCode,
      });
      final resp = await http.post(
        uri,
        headers: {
          'Content-Type': 'application/json',
          'X-Goog-Api-Key': key,
          'X-Goog-FieldMask': _fieldMask,
        },
        body: body,
      );
      if (resp.statusCode != 200) {
        debugPrint(
          '[places_nearby] HTTP ${resp.statusCode} searchNearby types=$includedTypes '
          'body="${resp.body}"',
        );
        return [];
      }
      final data = jsonDecode(resp.body) as Map<String, dynamic>;
      final places = (data['places'] as List?) ?? const [];
      final results = places
          .whereType<Map<String, dynamic>>()
          .map(NearbyCandidate.fromPlacesV1)
          .where((c) => c.placeId.isNotEmpty && c.name.isNotEmpty)
          .toList();
      debugPrint(
        '[places_nearby] API searchNearby types=$includedTypes '
        '(${latitude.toStringAsFixed(3)},${longitude.toStringAsFixed(3)}) r=${radius}m '
        '→ ${results.length} candidats',
      );

      await _cache?.put('places_search', cacheKey, {
        'places': results.map((c) => c.toCacheJson()).toList(),
      });
      return results;
    } catch (e) {
      debugPrint('[places_nearby] EXCEPTION searchNearby types=$includedTypes error="$e"');
      return [];
    }
  }

  /// Recherche par mot-clé en langage naturel. **Restreinte strictement** au
  /// cercle (lat/lng + radius) : on utilise `locationRestriction` et pas
  /// `locationBias` car ce dernier laissait passer des lieux hors zone (ex:
  /// "USA Guided Tours" à NYC remonté pour un voyage Nancy avec textQuery
  /// "guided tour"). Utile pour les concepts qui n'ont pas de type officiel
  /// Places ("hiking", "outlet", "facial").
  Future<List<NearbyCandidate>> searchText({
    required String textQuery,
    required double latitude,
    required double longitude,
    int radius = 5000,
    int maxResults = 20,
    String? languageCode,
  }) async {
    final key = AiConstants.googleMapsApiKey;
    if (key.isEmpty || key == 'COLLE_TA_CLE_MAPS_ICI') return [];
    final query = textQuery.trim();
    if (query.isEmpty) return [];

    final cacheKey = _cacheKeyForText(
      query: query,
      lat: latitude,
      lng: longitude,
      radius: radius,
      maxResults: maxResults,
      languageCode: languageCode,
    );
    final cached = await _cache?.get('places_search', cacheKey);
    if (cached != null) {
      final list = cached['places'] as List?;
      if (list != null) {
        final results = list
            .whereType<Map<String, dynamic>>()
            .map(NearbyCandidate.fromCacheJson)
            .toList();
        debugPrint(
          '[places_nearby] cache HIT searchText q="$query" r=${radius}m '
          '→ ${results.length} candidats',
        );
        return results;
      }
    }

    try {
      final uri = Uri.https('places.googleapis.com', '/v1/places:searchText');
      // searchText n'accepte PAS `locationRestriction.circle` (réservé à
      // searchNearby) — utiliser ce format renvoyait HTTP 400 silencieusement
      // → toutes les queries retournaient 0 résultats. Bug observé 2026-04-28.
      // On utilise `locationBias.circle` (le seul format circle supporté pour
      // searchText) PUIS on filtre côté code par Haversine pour respecter le
      // radius strict — sans ce filtre, des textQueries génériques type
      // "guided tour" remontent des résultats à l'autre bout du monde
      // (ex: "USA Guided Tours" à NYC pour un voyage Nancy).
      final body = jsonEncode({
        'textQuery': query,
        'maxResultCount': maxResults.clamp(1, 20),
        'locationBias': {
          'circle': {
            'center': {'latitude': latitude, 'longitude': longitude},
            'radius': radius,
          },
        },
        if (languageCode != null && languageCode.isNotEmpty) 'languageCode': languageCode,
      });
      final resp = await http.post(
        uri,
        headers: {
          'Content-Type': 'application/json',
          'X-Goog-Api-Key': key,
          'X-Goog-FieldMask': _fieldMask,
        },
        body: body,
      );
      if (resp.statusCode != 200) {
        debugPrint(
          '[places_nearby] HTTP ${resp.statusCode} searchText q="$query" '
          'body="${resp.body}"',
        );
        return [];
      }
      final data = jsonDecode(resp.body) as Map<String, dynamic>;
      final places = (data['places'] as List?) ?? const [];
      final raw = places
          .whereType<Map<String, dynamic>>()
          .map(NearbyCandidate.fromPlacesV1)
          .where((c) => c.placeId.isNotEmpty && c.name.isNotEmpty)
          .toList();
      // Filtre dur par distance — corollaire de l'usage de locationBias (soft).
      final radiusKm = radius / 1000.0;
      final results = raw.where((c) {
        final d = haversineKm(latitude, longitude, c.latitude, c.longitude);
        return d <= radiusKm;
      }).toList();
      final droppedFar = raw.length - results.length;
      // Diagnostic : on log même quand 0 résultats pour distinguer cache hit vs
      // API call qui retourne réellement 0 (Google n'a aucun match dans la zone).
      debugPrint(
        '[places_nearby] API searchText q="$query" '
        '(${latitude.toStringAsFixed(3)},${longitude.toStringAsFixed(3)}) r=${radius}m '
        'lang=${languageCode ?? "default"} → ${results.length} candidats'
        '${droppedFar > 0 ? " (-$droppedFar hors radius)" : ""}'
        '${results.isEmpty && raw.isEmpty ? " (0 brut Google)" : ""}',
      );

      await _cache?.put('places_search', cacheKey, {
        'places': results.map((c) => c.toCacheJson()).toList(),
      });
      return results;
    } catch (e) {
      debugPrint('[places_nearby] EXCEPTION searchText q="$query" error="$e"');
      return [];
    }
  }

  // Lat/lng arrondis à 3 décimales (~110m) pour favoriser les hits cache sur
  // des centres très proches. Au-delà, des centres distants donneront des
  // résultats sensiblement différents donc autant les considérer distincts.
  // `languageCode` inclus dans la clé : un même centre/types en arabe vs
  // français doit donner 2 entrées distinctes en cache, sinon on servirait
  // de l'arabe à un voyageur francophone (régression bug Maroc 26/04).
  String _cacheKeyForNearby({
    required List<String> types,
    required double lat,
    required double lng,
    required int radius,
    required int maxResults,
    String? languageCode,
  }) {
    final sortedTypes = [...types]..sort();
    return GeminiCacheService.hashKey([
      (k: 'mode', v: 'nearby'),
      (k: 'types', v: sortedTypes),
      (k: 'lat', v: lat.toStringAsFixed(3)),
      (k: 'lng', v: lng.toStringAsFixed(3)),
      (k: 'radius', v: radius),
      (k: 'max', v: maxResults),
      (k: 'lang', v: languageCode ?? ''),
    ]);
  }

  String _cacheKeyForText({
    required String query,
    required double lat,
    required double lng,
    required int radius,
    required int maxResults,
    String? languageCode,
  }) {
    return GeminiCacheService.hashKey([
      (k: 'mode', v: 'text'),
      (k: 'q', v: GeminiCacheService.normKey(query)),
      (k: 'lat', v: lat.toStringAsFixed(3)),
      (k: 'lng', v: lng.toStringAsFixed(3)),
      (k: 'radius', v: radius),
      (k: 'max', v: maxResults),
      (k: 'lang', v: languageCode ?? ''),
    ]);
  }
}
