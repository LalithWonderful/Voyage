# Refactor API-Cost / POI-first - Checklist P0

Decision pilotage 2026-05-14 : fin des audits isolés, passage en mode
exécution. Chaque entrée doit avoir un fichier concerné, un comportement
attendu, et un commit quand corrigée.

## Règles de fond

- Aucun appel Google Places / Geocoding / Routes silencieux
  (déclenché sans action utilisateur explicite).
- POI Lunao / Supabase-first : la base offline est toujours essayée en premier.
- Google reste autorisé uniquement pour :
  - autocomplete sur action utilisateur (frappe dans un champ) ;
  - détails ciblés (placeId existant) ;
  - fallback qualité explicite ;
  - enrichissement sur POI déjà sélectionné.
- Tout appel Google autorisé passe par cache/store Supabase
  (`places_cache`, `place_lookup_cache`, `gemini_cache`).
- Tests offline uniquement. Pas de live opt-in.

## P0.2 Resolver `train_station` Lunao-First

- [x] Créer la base éditoriale offline des hubs transport pour les sept villes
  POI pilot : London, Amsterdam, Paris, Rome, Barcelona, Lisbon, Marrakech.
- [x] Inclure uniquement les hubs majeurs utiles aux voyageurs : railway, bus,
  airport-link, intermodal. Ce n'est volontairement pas une base exhaustive de
  stations métro/bus.
- [x] Ajouter un resolver offline qui recherche par ville plus nom de hub,
  alias, code IATA quand pertinent, et retourne `null` si non résolu.
- [x] Ajouter les tests offline : exact lookup, alias lookup, unknown city,
  unknown hub, priority, type filtering, airport-link codes, absence de Google
  IDs.
- [ ] Brancher la résolution runtime train-station / bus-station sur le
  resolver offline avant tout fallback Google Places ou Geocoding.
- [ ] Remonter proprement les hubs train/bus non résolus au lieu d'appeler
  Google silencieusement.

## P0 - Appels Google silencieux dans les flows utilisateur

| Statut | Item | Fichier | Comportement attendu | Commit |
| --- | --- | --- | --- | --- |
| [x] | `TripDetailScreen.initState` ne doit plus appeler `places.autocompleteDestinations()` juste pour calculer le badge "À compléter" | `lib/features/trips/screens/trip_detail_screen.dart` + `lib/features/trips/services/destination_kind_resolver.dart` | Résolution offline via `destinationKindFromTrip(trip)` : `trip.destinationKind` persisté -> country_code/segments -> `unknown`. Zéro appel Google. | _ce commit_ |
| [x] | Base offline + resolver `train_station` Lunao-first disponibles | `lib/features/transport/data/transport_hubs_seed.dart` + `lib/features/transport/services/offline_transport_hub_resolver.dart` + `test/features/transport/offline_transport_hub_resolver_test.dart` | 37 hubs éditoriaux offline pour les 7 villes actives, lookup par nom/alias/type/code, aucun ID Google, aucun appel réseau. | `169aec5` |
| [ ] | `_resolveTransportEndpoint(kind: 'train_station')` n'a pas encore de Chemin 0 Lunao-first runtime | `lib/features/wallet/widgets/document_form_sheet.dart` | Brancher `OfflineTransportHubResolver` dans `_resolveTransportEndpoint` quand `kind == 'train_station'`. Pas de fallback Google silencieux si pas de match. | - |
| [ ] | `_geocodeHotelAddress` appelle systématiquement `geocoder.geocode(address)` au SAVE d'un doc Hôtel | `lib/features/wallet/widgets/document_form_sheet.dart` | Tenter d'abord un resolver POI hôtel Lunao (bloqué par POI-0.1+, dépend de la base hôtels). Geocoding live uniquement si POI absent ET guard `googleGeocoding` actif. | - |
| [ ] | `getCountryCodeFromPlaceId` appelé en background dans `trip_edit_sheet` après pick : vérifier cache `place_lookup_cache` | `lib/features/trips/widgets/trip_edit_sheet.dart:197`, `:1683` | Confirmer cache-first ; si miss, action utilisateur déjà explicite (pick), donc OK. Audit ligne par ligne avant cocher. | - |
| [x] | `_geocodeTransportDocument` Chemin 1 sur miss cache -> Place Details live | `lib/features/planning/services/place_lookup_cache_service.dart` + `lib/features/wallet/widgets/document_form_sheet.dart:770-810` | `resolveCoords()` strict cache-first par défaut : miss / erreur lookup / entrée legacy -> retour `null` ou coords partielles, jamais d'appel `PlacesService` silencieux. Le fallback live est désormais derrière un opt-in caller explicite `allowLiveFallback: true` (le wallet SAVE l'active car c'est une action utilisateur). `PlacesService.resolvePlaceCoords()` reste guard par `LiveApiGuards.googlePlaces` (defense en profondeur). Découplage via `PlaceCoordsFetcher` typedef + `PlaceLookupCacheStore` abstrait pour tests offline. 8 tests verts. | `826a1b0` |

## P1 - Caches obligatoires sur appels Google autorisés

| Statut | Item | Fichier | Comportement attendu | Commit |
| --- | --- | --- | --- | --- |
| [ ] | `findCityCoords` appelé dans `trip_edit_sheet._reorderSegments` doit toujours passer par `place_lookup_cache` | `lib/features/trips/widgets/trip_edit_sheet.dart:1110`, `:1128` | Ajouter wrapper cache-first. Auditer cache miss rate. | - |
| [ ] | `places.findInfo` dans `planning_provider` enrichit en background : confirmer cache-first et batch dedup | `lib/features/planning/providers/planning_provider.dart` | Vérifier que toutes les entrées passent par `placesCacheService`. | - |

## P2 - Surfaces non-flow utilisateur

Reportées au backlog audit (`docs/api_cost/remaining_live_api_audit_2026_05_13.md`) :

- Overpass CLI (`tool/poi/extract_osm_pois.dart`) : guards manquants.
- Supabase scripts (`verify_schema.dart`, `verify_import.dart`) : guards manquants.
- Currency API : pas de guard malgré `LiveApiFamily.currencyApi`.
- Network images Google Photo : pas de guard runtime.

Ces points ne touchent pas le flow utilisateur quotidien et restent hors P0.

## Notes Transport Hubs

The transport seed is hand-curated editorial data inspired by stable public
transport concepts such as `railway=station`, `public_transport=station`,
`amenity=bus_station`, and major airport rail/bus transfer hubs. This task made
no live API calls and did not automate calls to Google, Supabase, Overpass, OSM,
or any external HTTP source.
