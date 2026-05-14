import 'dart:developer' as developer;
import 'package:supabase_flutter/supabase_flutter.dart';

/// Signature de la fonction qui résout un `placeId` → coords + nom + pays
/// + ville via une source live (typiquement
/// `PlacesService.resolvePlaceCoords`). Définie ici sous forme de
/// `typedef` plutôt qu'un import direct pour découpler la couche cache
/// du code transport Google et permettre l'injection d'une fake en test
/// sans tirer les dépendances de `PlacesService` (clés API, `dart:io`,
/// etc.).
typedef PlaceCoordsFetcher = Future<({double lat, double lng, String name, String? countryCode, String? city})?>
    Function(String placeId, {String? sessionToken});

/// Cache partagé entre tous les utilisateurs qui résout un placeId Google
/// (aéroport / gare) en coordonnées + nom officiel, sans payer Place Details
/// à chaque save d'un doc Vol/Train. Les hubs de transport étant
/// quasi-statiques, le cache est permanent (pas de TTL).
///
/// **Cache-first strict (P0.5, 2026-05-14).** Par défaut (`allowLiveFallback:
/// false`), un miss de cache ou une erreur de lookup retourne `null` —
/// **aucun appel Google silencieux**. Le caller doit explicitement opter
/// pour la résolution live en passant `allowLiveFallback: true`, ce qui
/// reste lui-même gouverné par `LiveApiGuards.googlePlaces` côté
/// `PlacesService.resolvePlaceCoords()`. Cette défense en profondeur évite
/// que :
/// - une erreur Supabase RLS / réseau ne se traduise en appel Places
///   silencieux et payant ;
/// - un nouveau caller utilise la méthode sans réaliser qu'elle peut
///   escalader vers une API live ;
/// - une entrée legacy (sans `country_code` / `city`) déclenche un
///   re-fetch live à chaque save d'un doc vu en lecture seule.
///
/// Workflow :
/// 1. Lookup `place_lookup_cache` par `place_id` (PK).
/// 2. HIT complet → return les coords lues. Update soft `last_seen_at`.
/// 3. HIT partiel (legacy) + `allowLiveFallback=false` → return les
///    coords partielles disponibles, sans escalade Google.
/// 4. HIT partiel + `allowLiveFallback=true` → re-fetch Place Details
///    pour enrichir.
/// 5. MISS + `allowLiveFallback=false` → return `null`.
/// 6. MISS + `allowLiveFallback=true` → `PlacesService.resolvePlaceCoords()`
///    (lui-même guardé par `LiveApiGuards.googlePlaces`), puis upsert
///    dans le cache pour le prochain user.
/// 7. Erreur lookup + `allowLiveFallback=false` → return `null`. Pas de
///    fallback Google silencieux.
class PlaceLookupCacheService {
  final PlaceLookupCacheStore _store;
  final PlaceCoordsFetcher _fetchLive;

  PlaceLookupCacheService(this._store, this._fetchLive);

  /// Résout `placeId` → coords + nom + code pays ISO 2 + ville. `kind` doit
  /// valoir `'airport'` ou `'train_station'`. `sessionToken` est passé au
  /// Place Details si miss + opt-in (continuité tarif session avec
  /// l'autocomplete précédent).
  ///
  /// `countryCode` et `city` peuvent être null pour les entrées cachées
  /// avant l'ajout des colonnes correspondantes (entrées legacy) — on
  /// retourne alors les coords partielles disponibles sans appeler Google
  /// sauf opt-in explicite.
  ///
  /// **`allowLiveFallback`** : opt-in explicite du caller pour autoriser
  /// l'escalade vers `PlacesService.resolvePlaceCoords()` en cas de miss /
  /// entrée legacy / erreur de cache. Par défaut `false` — strict
  /// cache-first. Les appels live restent **en plus** gouvernés par
  /// `LiveApiGuards.googlePlaces` côté `PlacesService`.
  Future<({double lat, double lng, String name, String? countryCode, String? city})?> resolveCoords({
    required String placeId,
    required String kind,
    String? sessionToken,
    bool allowLiveFallback = false,
  }) async {
    if (placeId.isEmpty) return null;

    // 1. Cache lookup. Trois issues : hit / miss / erreur.
    Map<String, dynamic>? cached;
    var lookupFailed = false;
    try {
      cached = await _store.readByPlaceId(placeId);
    } catch (e) {
      developer.log('[place_lookup_cache] lookup error : $e', name: 'place_lookup');
      lookupFailed = true;
    }

    // 2. Hit (complet ou partiel).
    if (cached != null) {
      final lat = (cached['latitude'] as num?)?.toDouble();
      final lng = (cached['longitude'] as num?)?.toDouble();
      final name = (cached['name'] as String?)?.trim() ?? '';
      final cachedCountry = (cached['country_code'] as String?)?.trim();
      final cachedCity = (cached['city'] as String?)?.trim();
      final hasCountry = cachedCountry != null && cachedCountry.isNotEmpty;
      final hasCity = cachedCity != null && cachedCity.isNotEmpty;
      final hasCoords = lat != null && lng != null && name.isNotEmpty;

      if (hasCoords && hasCountry && hasCity) {
        developer.log('[place_lookup_cache] HIT $placeId', name: 'place_lookup');
        _store.touch(placeId);
        return (
          lat: lat,
          lng: lng,
          name: name,
          countryCode: cachedCountry,
          city: cachedCity,
        );
      }

      // Entrée legacy : coords présentes mais country/city manquants.
      if (!allowLiveFallback) {
        if (hasCoords) {
          developer.log(
            '[place_lookup_cache] HIT (partial, no live escalation) $placeId',
            name: 'place_lookup',
          );
          _store.touch(placeId);
          return (
            lat: lat,
            lng: lng,
            name: name,
            countryCode: hasCountry ? cachedCountry : null,
            city: hasCity ? cachedCity : null,
          );
        }
        // Hit corrompu / sans coords : pas d'appel live silencieux.
        return null;
      }
      developer.log('[place_lookup_cache] HIT (enrichment) $placeId', name: 'place_lookup');
    } else if (lookupFailed) {
      // Le cache est en erreur (RLS, réseau, etc.). Sans opt-in explicite
      // on ne déclenche pas Google : sinon une panne Supabase devient un
      // appel Places payant silencieux.
      if (!allowLiveFallback) return null;
    } else {
      developer.log('[place_lookup_cache] MISS $placeId', name: 'place_lookup');
      if (!allowLiveFallback) return null;
    }

    // 3. Escalade live opt-in. `PlacesService.resolvePlaceCoords()` est
    //    elle-même guardée par `LiveApiGuards.googlePlaces` — le call
    //    throw `LiveApiBlockedException` si le runtime n'autorise pas
    //    Places.
    final fresh = await _fetchLive(placeId, sessionToken: sessionToken);
    if (fresh == null) return null;

    // 4. Upsert (best-effort, n'interrompt pas le caller si fail).
    try {
      await _store.upsert(
        placeId: placeId,
        name: fresh.name,
        latitude: fresh.lat,
        longitude: fresh.lng,
        kind: kind,
        countryCode: fresh.countryCode,
        city: fresh.city,
      );
    } catch (e) {
      developer.log('[place_lookup_cache] upsert error : $e', name: 'place_lookup');
    }
    return fresh;
  }
}

/// Abstraction des I/O Supabase pour `place_lookup_cache`. Permet
/// d'injecter une fake en test sans dépendre de `SupabaseClient`.
abstract class PlaceLookupCacheStore {
  Future<Map<String, dynamic>?> readByPlaceId(String placeId);
  Future<void> upsert({
    required String placeId,
    required String name,
    required double latitude,
    required double longitude,
    required String kind,
    String? countryCode,
    String? city,
  });
  Future<void> touch(String placeId);
}

class SupabasePlaceLookupCacheStore implements PlaceLookupCacheStore {
  final SupabaseClient _client;

  SupabasePlaceLookupCacheStore(this._client);

  @override
  Future<Map<String, dynamic>?> readByPlaceId(String placeId) {
    return _client
        .from('place_lookup_cache')
        .select('latitude,longitude,name,country_code,city')
        .eq('place_id', placeId)
        .maybeSingle();
  }

  @override
  Future<void> upsert({
    required String placeId,
    required String name,
    required double latitude,
    required double longitude,
    required String kind,
    String? countryCode,
    String? city,
  }) async {
    await _client.from('place_lookup_cache').upsert({
      'place_id': placeId,
      'name': name,
      'latitude': latitude,
      'longitude': longitude,
      'kind': kind,
      'country_code': ?countryCode,
      'city': ?city,
      'last_seen_at': DateTime.now().toUtc().toIso8601String(),
    }, onConflict: 'place_id');
  }

  @override
  Future<void> touch(String placeId) async {
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
