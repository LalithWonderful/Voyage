# API-0.1 — Inventaire des appels live

Scope: inventaire documentaire des points du code capables de consommer une API live. Aucun code de production, test, kill switch ou script n'a ete modifie.

## Synthese

Familles d'appels live identifiees:

- Google Places API legacy: Find Place, Autocomplete, Place Details, Place Photo.
- Google Places API New: `places:searchNearby`, `places:searchText`.
- Google Geocoding API.
- Google Routes API v2: `directions/v2:computeRoutes`.
- Gemini API via `google_generative_ai`.
- Supabase: Auth, PostgREST, RPC, Storage.
- Google Maps SDK / Maps URLs: affichage carte et ouverture de Google Maps.
- Geolocator: localisation appareil.
- Frankfurter: taux de change.

## Google Places API legacy

Wrapper principal: `lib/features/planning/services/places_service.dart`.

Endpoints live:

- `findInfo()` appelle `https://maps.googleapis.com/maps/api/place/findplacefromtext/json` pour photos, `place_id`, nom, rating, prix et adresse. Le meme appel construit aussi des URLs `place/photo`; ces URLs peuvent ensuite etre chargees par l'UI via `CachedNetworkImage`.
- `autocompleteCities()` lance 3 appels Autocomplete en parallele (`types=(cities)`, `geocode`, `establishment`).
- `autocompleteDestinations()` lance 1 appel Autocomplete `types=geocode`.
- `autocompleteTransport()` lance 1 appel Autocomplete `types=airport` ou `train_station`, avec session token optionnel.
- `resolvePlaceCoords()` appelle Place Details pour `geometry/location,name,address_components`.
- `getCountryCodeFromPlaceId()` appelle Place Details pour `address_component`.
- `findCityCoords()` appelle Find Place From Text pour resoudre une ville.
- `getDetails()` appelle Place Details pour `reviews,opening_hours`.

Caches/indirections:

- `lib/features/planning/services/places_cache_service.dart` lit/ecrit Supabase `places_cache`; sur miss ou cache expire, appelle `PlacesService.findInfo()` ou `PlacesService.getDetails()`.
- `lib/features/planning/services/place_lookup_cache_service.dart` lit/ecrit Supabase `place_lookup_cache`; sur miss ou entree legacy incomplete, appelle `PlacesService.resolvePlaceCoords()`.

Call sites utilisateur:

- `lib/core/widgets/city_autocomplete_field.dart` appelle `autocompleteDestinations()` et `autocompleteCities()`.
- `lib/core/widgets/transport_autocomplete_field.dart` appelle `autocompleteTransport()`.
- `lib/features/onboarding/screens/destination_screen.dart` appelle `getCountryCodeFromPlaceId()` apres selection de destination.
- `lib/features/trips/screens/trip_detail_screen.dart` appelle `autocompleteDestinations()` au boot de detection destination.
- `lib/features/trips/widgets/trip_edit_sheet.dart` appelle `autocompleteDestinations()`, `getCountryCodeFromPlaceId()` et `findCityCoords()`.
- `lib/features/planning/providers/planning_provider.dart` appelle `places_cache.findInfo()` et `places_cache.getDetails()` pour enrichir activites, photos, avis, horaires.
- `lib/features/planning/screens/planning_screen.dart` appelle `autocompleteDestinations()`, `findInfo()`, `places_cache.findInfo()`.
- `lib/features/planning/widgets/suggestion_detail_sheet.dart` appelle `places_cache.findInfo()`.
- `lib/features/planning/widgets/alternatives_sheet.dart` appelle `places_cache.findInfo()`.
- `lib/features/wallet/widgets/document_form_sheet.dart` appelle `autocompleteTransport()` et, via `PlaceLookupCacheService`, Place Details pour resoudre aeroports/gares.

## Google Places API New

Wrapper: `lib/features/planning/services/places_nearby_service.dart`.

Endpoints live:

- `searchNearby()` appelle `https://places.googleapis.com/v1/places:searchNearby`.
- `searchText()` appelle `https://places.googleapis.com/v1/places:searchText`.

Cache/guard existant:

- Lit/ecrit `gemini_cache` avec action `places_search`.
- Utilise `PlacesBudget` pour dedup, cap et detection de rate limit pendant une run, mais le service reste capable d'appeler l'API en live sur cache miss.

Call sites:

- `lib/features/planning/services/places_first_pipeline.dart` appelle `searchNearby()` et `searchText()` pendant le gather Places-first, les blueprints, le fanout metro anchors, les guards segment city et les repas deterministes.
- `test/dev/places_first_harness.dart` instancie `GeocodingService` + `PlacesNearbyService` et lance le pipeline sur de vrais appels Google Places.
- `test/snapshots/generate_baseline.dart` instancie `GeocodingService` + `PlacesNearbyService`; le header indique explicitement que le script hit la vraie API Google Places.

## Google Geocoding API

Wrapper: `lib/features/planning/services/geocoding_service.dart`.

Endpoint live:

- `geocode()` appelle `https://maps.googleapis.com/maps/api/geocode/json`.

Call sites:

- `lib/features/map/screens/trip_map_screen.dart` geocode une adresse d'activite avant update Supabase de coordonnees.
- `lib/features/wallet/widgets/document_form_sheet.dart` geocode adresses d'hotel et endpoints de transport en fallback texte.
- `lib/features/planning/services/day_center_service.dart` geocode destination, segment city et hints region.
- `lib/features/planning/services/places_first_pipeline.dart` consomme `DayCenterService`/`GeocodingService` pendant `gatherCandidatesForTrip`.
- `test/dev/places_first_harness.dart` et `test/snapshots/generate_baseline.dart` creent un `GeocodingService`.

## Google Routes API

Wrapper: `lib/features/planning/services/routes_service.dart`.

Endpoint live:

- `_computeOne()` et `_computeTransit()` appellent `https://routes.googleapis.com/directions/v2:computeRoutes`.

Caracteristique de cout:

- `computeOptionsFromEndpoints()` lance jusqu'a 4 appels en parallele par paire: `WALK`, `DRIVE`, `TRANSIT`, `BICYCLE`.
- Cache Supabase `gemini_cache` action `routes_pair`; cache hit evite Routes API.

Call sites:

- `lib/features/planning/screens/planning_screen.dart` appelle `routesService.computeOptionsFromEndpoints()` pour calculer les options de transport entre activites/hotel.

## Gemini API

Wrappers:

- `lib/features/planning/services/ai_suggestions_service.dart`.
- `lib/features/assistant/services/assistant_service.dart`.

Appels live:

- `AiSuggestionsService.suggestRegionalItinerary()` via `_generateWithRetry()`.
- `AiSuggestionsService.generateRaw()` pour prompts custom, notamment Places-first CoPilot et restaurants legacy.
- `AiSuggestionsService.suggestAlternatives()`.
- `AiSuggestionsService.describeActivitiesBatch()`.
- `AiSuggestionsService.generateTransportBetween()`.
- `AiSuggestionsService.describeActivity()`.
- `AiSuggestionsService.extractDocumentFromText()`.
- `AiSuggestionsService.extractDocumentFromImage()`.
- `AssistantService.sendMessage()`.

Caches/limites:

- Plusieurs actions passent par `GeminiCacheService` (`gemini_cache`) avant appel live: `regional_itinerary`, `raw`, `describe_activity`, `transport_pair`, `places_first_copilot`, `places_first_auto`.
- `_rateLimitEnabled` est actuellement `false` dans `AiSuggestionsService`; le RPC `check_and_log_ai_usage` existe dans le code mais ne protege pas les appels tant que ce flag reste desactive.

Call sites:

- `lib/features/trips/widgets/regional_loop_sheet.dart` appelle `suggestRegionalItinerary()`.
- `lib/features/planning/widgets/alternatives_sheet.dart` appelle `suggestAlternatives()`.
- `lib/features/planning/widgets/suggestion_detail_sheet.dart` et `lib/features/planning/providers/planning_provider.dart` appellent `describeActivity()`.
- `lib/features/planning/screens/planning_screen.dart` appelle `describeActivitiesBatch()`, `generateTransportBetween()` et, via Places-first, `generateRaw()`.
- `lib/features/planning/services/places_first_pipeline.dart` appelle `generateRaw()` pour CoPilot et le chemin `category=restaurants` legacy.
- `lib/features/wallet/widgets/document_form_sheet.dart` appelle `extractDocumentFromText()` et `extractDocumentFromImage()`.
- `lib/features/assistant/providers/assistant_provider.dart` appelle `AssistantService.sendMessage()`.

## Supabase

Initialisation/client:

- `lib/main.dart` appelle `Supabase.initialize()`.
- `lib/features/auth/providers/auth_provider.dart` expose `supabaseProvider`.

Auth live:

- `auth.onAuthStateChange`, `signUp`, `signInWithPassword`, `signOut`, `resetPasswordForEmail`, `updateUser`.
- `lib/core/services/deep_link_service.dart` appelle `verifyOTP()` et `exchangeCodeForSession()`.
- `lib/features/auth/screens/reset_password_screen.dart` appelle `updateUser()` et `signOut()`.
- `lib/features/profile/screens/profile_screen.dart` appelle `auth.updateUser()`.

PostgREST tables touchees:

- `user_profiles`: auth/onboarding/profile updates and reads.
- `user_interests`: onboarding insert/delete/read.
- `trips`: creation, selection, updates, delete cascade, destination/region persistence.
- `trip_activities`: planning reads/inserts/updates/deletes, generated activity lifecycle, cache enrichment.
- `trip_transports`: planning reads/inserts/updates/deletes.
- `trip_documents`: wallet reads/inserts/updates/deletes and trip detach.
- `country_regions`: remote regions source.
- `places_cache`: Places cache.
- `place_lookup_cache`: Place Details cache.
- `gemini_cache`: Gemini/Places/Routes cache.

RPC:

- `AiSuggestionsService._checkRateLimit()` peut appeler `check_and_log_ai_usage`, mais le flag `_rateLimitEnabled` est `false`.

Storage:

- `lib/features/profile/screens/profile_screen.dart` appelle `storage.from('avatars').uploadBinary()` et `getPublicUrl()`.

Principaux fichiers Supabase:

- `lib/features/auth/providers/auth_provider.dart`
- `lib/features/onboarding/screens/interests_screen.dart`
- `lib/features/onboarding/screens/destination_screen.dart`
- `lib/features/onboarding/screens/traveler_type_screen.dart`
- `lib/features/trips/providers/trips_provider.dart`
- `lib/features/trips/screens/trip_detail_screen.dart`
- `lib/features/trips/widgets/trip_edit_sheet.dart`
- `lib/features/trips/services/trip_segment_sync_service.dart`
- `lib/features/planning/providers/planning_provider.dart`
- `lib/features/planning/screens/planning_screen.dart`
- `lib/features/planning/widgets/activity_create_sheet.dart`
- `lib/features/planning/widgets/activity_edit_sheet.dart`
- `lib/features/planning/widgets/alternatives_sheet.dart`
- `lib/features/map/screens/trip_map_screen.dart`
- `lib/features/wallet/providers/wallet_provider.dart`
- `lib/features/wallet/widgets/document_form_sheet.dart`
- `lib/features/wallet/widgets/overlap_nights_sheet.dart`
- `lib/features/regions/services/country_regions_repository.dart`
- `lib/features/planning/services/activity_staleness_service.dart`
- `lib/features/planning/services/gemini_cache_service.dart`
- `lib/features/planning/services/places_cache_service.dart`
- `lib/features/planning/services/place_lookup_cache_service.dart`

## Google Maps SDK et URLs externes

SDK:

- `lib/features/map/screens/trip_map_screen.dart` utilise `GoogleMap` depuis `google_maps_flutter`. L'affichage carte peut consommer des services Google Maps SDK/tuiles selon le billing Google.

Ouverture Google Maps:

- `lib/features/map/screens/trip_map_screen.dart` ouvre `https://www.google.com/maps/dir/` et `/search/`.
- `lib/features/planning/widgets/suggestion_detail_sheet.dart` ouvre `https://www.google.com/maps/search/`.
- `lib/features/planning/widgets/activity_detail_sheet.dart` ouvre `https://www.google.com/maps/search/` et `/dir/`.
- `lib/features/planning/screens/planning_screen.dart` ouvre `https://www.google.com/maps/dir/`.

Ces URLs sortent de l'app via `launchUrl()`. Elles ne sont pas des appels serveur Places/Routes du code Dart, mais restent des sorties live vers Google.

## Geolocator / GPS appareil

Wrapper: `lib/core/services/location_service.dart`.

Appels live/systeme:

- `Geolocator.isLocationServiceEnabled()`
- `Geolocator.checkPermission()`
- `Geolocator.requestPermission()`
- `Geolocator.getCurrentPosition()`

Call site:

- `lib/features/planning/screens/planning_screen.dart` appelle `LocationService.instance.getCurrentLocation()` pour certains trajets/itineraire Maps avec origine courante.

## Frankfurter currency API

Wrapper: `lib/core/services/currency_service.dart`.

Endpoint live:

- `getRate()` appelle `https://api.frankfurter.app/latest?from=...&to=...`.

Call sites:

- `lib/core/providers/currency_provider.dart`.
- `lib/features/planning/providers/planning_provider.dart` dans le calcul budget.

## Images reseau

Sources identifiees:

- `CachedNetworkImage` dans `suggestion_detail_sheet.dart`, `activity_detail_sheet.dart`, `alternatives_sheet.dart`, `planning_screen.dart`.
- `NetworkImage` pour avatar profil dans `profile_screen.dart`.

Impact:

- Les images de lieux proviennent souvent des URLs Place Photo construites par `PlacesService.findInfo()`; le chargement UI peut donc declencher des requetes live d'image Google.
- Les avatars peuvent pointer vers Supabase Storage public URL.

## Scripts a ne pas lancer pour API-0

Ces fichiers sont des points d'appel live s'ils sont lances explicitement, mais ils n'ont pas ete executes pendant cet inventaire:

- `test/dev/places_first_harness.dart`
- `test/snapshots/generate_baseline.dart`

