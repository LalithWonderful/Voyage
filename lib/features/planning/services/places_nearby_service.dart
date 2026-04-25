import 'dart:convert';
import 'dart:developer' as developer;
import 'package:http/http.dart' as http;
import 'package:voyage/core/constants/ai_constants.dart';
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
  Future<List<NearbyCandidate>> searchNearby({
    required double latitude,
    required double longitude,
    required List<String> includedTypes,
    int radius = 1500,
    int maxResults = 20,
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
    );
    final cached = await _cache?.get('places_search', cacheKey);
    if (cached != null) {
      final list = cached['places'] as List?;
      if (list != null) {
        return list
            .whereType<Map<String, dynamic>>()
            .map(NearbyCandidate.fromCacheJson)
            .toList();
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
        developer.log(
          'Places searchNearby HTTP ${resp.statusCode} types=$includedTypes: ${resp.body}',
          name: 'places_nearby',
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
      developer.log(
        'searchNearby types=$includedTypes (${latitude.toStringAsFixed(3)},${longitude.toStringAsFixed(3)}) → ${results.length} candidats',
        name: 'places_nearby',
      );

      await _cache?.put('places_search', cacheKey, {
        'places': results.map((c) => c.toCacheJson()).toList(),
      });
      return results;
    } catch (e) {
      developer.log('Places searchNearby exception: $e', name: 'places_nearby');
      return [];
    }
  }

  /// Recherche par mot-clé en langage naturel. Biaisée vers une zone
  /// géographique (pas restreinte stricte — Places peut retourner des lieux
  /// proches mais hors du cercle si très pertinents). Utile pour les concepts
  /// qui n'ont pas de type officiel ("hiking", "outlet", "facial").
  Future<List<NearbyCandidate>> searchText({
    required String textQuery,
    required double latitude,
    required double longitude,
    int radius = 5000,
    int maxResults = 20,
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
    );
    final cached = await _cache?.get('places_search', cacheKey);
    if (cached != null) {
      final list = cached['places'] as List?;
      if (list != null) {
        return list
            .whereType<Map<String, dynamic>>()
            .map(NearbyCandidate.fromCacheJson)
            .toList();
      }
    }

    try {
      final uri = Uri.https('places.googleapis.com', '/v1/places:searchText');
      final body = jsonEncode({
        'textQuery': query,
        'maxResultCount': maxResults.clamp(1, 20),
        'locationBias': {
          'circle': {
            'center': {'latitude': latitude, 'longitude': longitude},
            'radius': radius,
          },
        },
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
        developer.log(
          'Places searchText HTTP ${resp.statusCode} q="$query": ${resp.body}',
          name: 'places_nearby',
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
      developer.log(
        'searchText "$query" (${latitude.toStringAsFixed(3)},${longitude.toStringAsFixed(3)}) → ${results.length} candidats',
        name: 'places_nearby',
      );

      await _cache?.put('places_search', cacheKey, {
        'places': results.map((c) => c.toCacheJson()).toList(),
      });
      return results;
    } catch (e) {
      developer.log('Places searchText exception: $e', name: 'places_nearby');
      return [];
    }
  }

  // Lat/lng arrondis à 3 décimales (~110m) pour favoriser les hits cache sur
  // des centres très proches. Au-delà, des centres distants donneront des
  // résultats sensiblement différents donc autant les considérer distincts.
  String _cacheKeyForNearby({
    required List<String> types,
    required double lat,
    required double lng,
    required int radius,
    required int maxResults,
  }) {
    final sortedTypes = [...types]..sort();
    return GeminiCacheService.hashKey([
      (k: 'mode', v: 'nearby'),
      (k: 'types', v: sortedTypes),
      (k: 'lat', v: lat.toStringAsFixed(3)),
      (k: 'lng', v: lng.toStringAsFixed(3)),
      (k: 'radius', v: radius),
      (k: 'max', v: maxResults),
    ]);
  }

  String _cacheKeyForText({
    required String query,
    required double lat,
    required double lng,
    required int radius,
    required int maxResults,
  }) {
    return GeminiCacheService.hashKey([
      (k: 'mode', v: 'text'),
      (k: 'q', v: GeminiCacheService.normKey(query)),
      (k: 'lat', v: lat.toStringAsFixed(3)),
      (k: 'lng', v: lng.toStringAsFixed(3)),
      (k: 'radius', v: radius),
      (k: 'max', v: maxResults),
    ]);
  }
}
