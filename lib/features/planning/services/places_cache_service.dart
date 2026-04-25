import 'dart:developer' as developer;
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:voyage/features/planning/services/places_service.dart';

class PlacesCacheService {
  final SupabaseClient _client;
  final PlacesService _places;
  final Duration _ttl;

  PlacesCacheService(this._client, this._places, {Duration? ttl})
      : _ttl = ttl ?? const Duration(days: 30);

  String _normKey(String s) => s.toLowerCase().trim().replaceAll(RegExp(r'\s+'), ' ');

  /// Retourne les infos Places en les lisant du cache Supabase partagé si disponible (et frais).
  /// Sinon appelle Google Places et upsert dans le cache pour les prochains users.
  Future<PlaceInfo> findInfo({
    required String title,
    required String destination,
    double? latitude,
    double? longitude,
  }) async {
    final titleKey = _normKey(title);
    final destKey = _normKey(destination);
    if (titleKey.isEmpty) return PlaceInfo.empty;

    // 1. Lookup dans le cache partagé
    try {
      final cached = await _client
          .from('places_cache')
          .select()
          .eq('title_key', titleKey)
          .eq('destination_key', destKey)
          .maybeSingle();
      if (cached != null) {
        final refreshedAt = DateTime.tryParse(cached['refreshed_at'] as String? ?? '');
        if (refreshedAt != null && DateTime.now().difference(refreshedAt) < _ttl) {
          developer.log('Cache HIT: $titleKey / $destKey', name: 'places_cache');
          return _infoFromRow(cached);
        }
        developer.log('Cache EXPIRED: $titleKey / $destKey', name: 'places_cache');
      } else {
        developer.log('Cache MISS: $titleKey / $destKey', name: 'places_cache');
      }
    } catch (e) {
      developer.log('Cache lookup error (on passe en live) : $e', name: 'places_cache');
    }

    // 2. Call Places API
    final query = destination.isEmpty ? title : '$title $destination';
    final info = await _places.findInfo(
      query: query,
      latitude: latitude,
      longitude: longitude,
    );

    // 3. Upsert cache (best-effort)
    if (info.rating != null ||
        info.photos.isNotEmpty ||
        info.priceLevel != null ||
        info.placeId != null ||
        info.address != null ||
        info.name != null) {
      try {
        await _client.from('places_cache').upsert({
          'title_key': titleKey,
          'destination_key': destKey,
          'place_id': info.placeId,
          'place_name': info.name,
          'photo_urls': info.photos.map((p) => p.url).toList(),
          'rating': info.rating,
          'ratings_count': info.ratingsCount,
          'price_level': info.priceLevel,
          'address': info.address,
          'refreshed_at': DateTime.now().toIso8601String(),
        }, onConflict: 'title_key,destination_key');
      } catch (e) {
        developer.log('Cache upsert error : $e', name: 'places_cache');
      }
    }

    return info;
  }

  PlaceInfo _infoFromRow(Map<String, dynamic> row) {
    final urls = (row['photo_urls'] as List?)?.map((e) => e.toString()).toList() ?? const [];
    final reviewsData = row['reviews'] as List?;
    final hoursData = row['opening_hours'] as Map<String, dynamic>?;
    return PlaceInfo(
      photos: urls.map((url) => PlacePhoto(url: url)).toList(),
      rating: (row['rating'] as num?)?.toDouble(),
      ratingsCount: (row['ratings_count'] as num?)?.toInt(),
      priceLevel: (row['price_level'] as num?)?.toInt(),
      placeId: row['place_id'] as String?,
      address: row['address'] as String?,
      name: row['place_name'] as String?,
      reviews: reviewsData
          ?.whereType<Map<String, dynamic>>()
          .map((r) => PlaceReview.fromJson(r))
          .toList(),
      openingHours: hoursData != null ? OpeningHours.fromJson(hoursData) : null,
    );
  }

  /// Récupère les avis + horaires pour un lieu : cache first, sinon fetch + upsert.
  /// Retourne les deux dans un bundle car un seul appel Places Details les récupère.
  Future<({List<PlaceReview> reviews, OpeningHours? openingHours})> getDetails({
    required String title,
    required String destination,
    String? placeId,
  }) async {
    final titleKey = _normKey(title);
    final destKey = _normKey(destination);
    if (titleKey.isEmpty) return (reviews: const <PlaceReview>[], openingHours: null);

    // 1. Cache — hit strict : il faut les DEUX champs pour considérer le cache valide.
    // Sinon on refetch (les 2 sont obtenus dans un seul appel Places Details).
    try {
      final cached = await _client
          .from('places_cache')
          .select('reviews, opening_hours, place_id, refreshed_at')
          .eq('title_key', titleKey)
          .eq('destination_key', destKey)
          .maybeSingle();
      if (cached != null) {
        final refreshedAt = DateTime.tryParse(cached['refreshed_at'] as String? ?? '');
        final fresh = refreshedAt != null && DateTime.now().difference(refreshedAt) < _ttl;
        final reviewsData = cached['reviews'] as List?;
        final hoursData = cached['opening_hours'] as Map<String, dynamic>?;
        // Cache hit uniquement si les DEUX champs ont été tentés (non null).
        // `hoursData == {}` (map vide) = sentinel "tenté mais Google n'a rien" → OK, on respecte.
        if (fresh && reviewsData != null && hoursData != null) {
          final reviews = reviewsData
                  .whereType<Map<String, dynamic>>()
                  .map((r) => PlaceReview.fromJson(r))
                  .toList();
          final openingHours = hoursData.isEmpty ? null : OpeningHours.fromJson(hoursData);
          return (reviews: reviews, openingHours: openingHours);
        }
        placeId ??= cached['place_id'] as String?;
      }
    } catch (_) {}

    // 2. Besoin du placeId pour appeler Places Details
    if (placeId == null || placeId.isEmpty) {
      final info = await findInfo(title: title, destination: destination);
      placeId = info.placeId;
      if (placeId == null) return (reviews: const <PlaceReview>[], openingHours: null);
    }

    // 3. Fetch reviews + horaires
    final details = await _places.getDetails(placeId);

    // 4. Upsert dans le cache — on upsert TOUJOURS les 2 champs (même vides) pour marquer
    // "tenté", sinon on re-ferait une call à chaque ouverture des lieux sans horaires Google.
    try {
      await _client.from('places_cache').update({
        'reviews': details.reviews.map((r) => r.toJson()).toList(),
        'opening_hours': details.openingHours?.toJson() ?? {},
        'refreshed_at': DateTime.now().toIso8601String(),
      }).eq('title_key', titleKey).eq('destination_key', destKey);
    } catch (_) {}
    return details;
  }
}
