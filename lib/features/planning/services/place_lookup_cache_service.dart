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

  /// Résout `placeId` → coords + nom + code pays ISO 2 + ville. `kind` doit
  /// valoir 'airport' ou 'train_station'. `sessionToken` est passé au Place
  /// Details si miss (continuité tarif session avec l'autocomplete précédent).
  ///
  /// `countryCode` et `city` peuvent être null pour les entrées cachées avant
  /// l'ajout des colonnes correspondantes — pas de regression, le code force
  /// alors un re-fetch pour enrichir.
  Future<({double lat, double lng, String name, String? countryCode, String? city})?> resolveCoords({
    required String placeId,
    required String kind,
    String? sessionToken,
  }) async {
    if (placeId.isEmpty) return null;

    // 1. Lookup cache. Si HIT MAIS country_code OU city manque (entrée écrite
    // avant l'ajout des colonnes), on bypasse pour re-fetch et enrichir.
    // Bénéfice unique par entrée : après une fois, le hit devient gratuit.
    try {
      final cached = await _client
          .from('place_lookup_cache')
          .select('latitude,longitude,name,country_code,city')
          .eq('place_id', placeId)
          .maybeSingle();
      if (cached != null) {
        final lat = (cached['latitude'] as num?)?.toDouble();
        final lng = (cached['longitude'] as num?)?.toDouble();
        final name = (cached['name'] as String?)?.trim() ?? '';
        final cachedCountry = (cached['country_code'] as String?)?.trim();
        final cachedCity = (cached['city'] as String?)?.trim();
        final hasCountry = cachedCountry != null && cachedCountry.isNotEmpty;
        final hasCity = cachedCity != null && cachedCity.isNotEmpty;
        if (lat != null && lng != null && name.isNotEmpty && hasCountry && hasCity) {
          developer.log('[place_lookup_cache] HIT $placeId', name: 'place_lookup');
          _touchLastSeen(placeId);
          return (lat: lat, lng: lng, name: name, countryCode: cachedCountry, city: cachedCity);
        }
        if (lat != null && lng != null && name.isNotEmpty) {
          developer.log('[place_lookup_cache] HIT (enrichment) $placeId', name: 'place_lookup');
        }
      } else {
        developer.log('[place_lookup_cache] MISS $placeId', name: 'place_lookup');
      }
    } catch (e) {
      developer.log('[place_lookup_cache] lookup error : $e', name: 'place_lookup');
    }

    // 2. Miss OU enrichissement (entrée legacy sans country_code/city) → Place Details API
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
        if (fresh.countryCode != null) 'country_code': fresh.countryCode,
        if (fresh.city != null) 'city': fresh.city,
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
