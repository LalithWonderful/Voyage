import 'dart:developer' as developer;
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:voyage/features/planning/services/places_service.dart';

/// Cache partagé entre tous les utilisateurs qui résout un placeId Google
/// (aéroport / gare) en coordonnées + nom officiel, sans payer Place Details
/// à chaque save d'un doc Vol/Train. Les hubs de transport étant
/// quasi-statiques, le cache est permanent (pas de TTL).
///
/// Workflow :
/// 1. Lookup `place_lookup_cache` par `place_id` (PK)
/// 2. Hit → return les coords lues. Update soft `last_seen_at` (best-effort).
/// 3. Miss → appelle `PlacesService.resolvePlaceCoords()` (Place Details API)
///    puis upsert dans le cache pour le prochain user.
///
/// Les erreurs réseau / RLS / lookup tombent sur l'appel Places direct (pas
/// d'exception remontée — le caller continue avec coords null si Places fail
/// aussi, et un flag `geocoding_failed` est posé en metadata côté form).
class PlaceLookupCacheService {
  final SupabaseClient _client;
  final PlacesService _places;

  PlaceLookupCacheService(this._client, this._places);

  /// Résout `placeId` → coords + nom. `kind` doit valoir 'airport' ou
  /// 'train_station'. `sessionToken` est passé au Place Details si miss
  /// (continuité tarif session avec l'autocomplete précédent).
  Future<({double lat, double lng, String name})?> resolveCoords({
    required String placeId,
    required String kind,
    String? sessionToken,
  }) async {
    if (placeId.isEmpty) return null;

    // 1. Lookup cache
    try {
      final cached = await _client
          .from('place_lookup_cache')
          .select('latitude,longitude,name')
          .eq('place_id', placeId)
          .maybeSingle();
      if (cached != null) {
        final lat = (cached['latitude'] as num?)?.toDouble();
        final lng = (cached['longitude'] as num?)?.toDouble();
        final name = (cached['name'] as String?)?.trim() ?? '';
        if (lat != null && lng != null && name.isNotEmpty) {
          developer.log('[place_lookup_cache] HIT $placeId', name: 'place_lookup');
          // Refresh soft de last_seen_at (fire-and-forget, on ignore les erreurs)
          _touchLastSeen(placeId);
          return (lat: lat, lng: lng, name: name);
        }
      }
      developer.log('[place_lookup_cache] MISS $placeId', name: 'place_lookup');
    } catch (e) {
      developer.log('[place_lookup_cache] lookup error : $e', name: 'place_lookup');
    }

    // 2. Miss → Place Details API
    final fresh = await _places.resolvePlaceCoords(placeId, sessionToken: sessionToken);
    if (fresh == null) return null;

    // 3. Upsert dans le cache (best-effort, on ne bloque pas le caller si fail)
    try {
      await _client.from('place_lookup_cache').upsert({
        'place_id': placeId,
        'name': fresh.name,
        'latitude': fresh.lat,
        'longitude': fresh.lng,
        'kind': kind,
        'last_seen_at': DateTime.now().toUtc().toIso8601String(),
      }, onConflict: 'place_id');
    } catch (e) {
      developer.log('[place_lookup_cache] upsert error : $e', name: 'place_lookup');
    }
    return fresh;
  }

  Future<void> _touchLastSeen(String placeId) async {
    try {
      await _client
          .from('place_lookup_cache')
          .update({'last_seen_at': DateTime.now().toUtc().toIso8601String()})
          .eq('place_id', placeId);
    } catch (_) {
      // Silent : c'est juste une stat, on ne bloque rien.
    }
  }
}
