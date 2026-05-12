# API-0.4d — Spec Places Legacy Guards

## Objectif

Proteger `PlacesService` legacy contre les appels Google Places non autorises,
sans modifier les services deja traites dans API-0.4a/0.4b/0.4c.

Service cible:

- `lib/features/planning/services/places_service.dart`

Design retenu a valider avant code:

> cache hit autorise, cache miss Places legacy bloque sans opt-in live.

Les appels live Places legacy doivent throw `LiveApiBlockedException` au niveau
`PlacesService` avant tout `http.get`. Les call sites UI decideront plus tard
comment transformer cette erreur en fallback UX.

## 1. Fichiers a lire

Avant implementation API-0.4d:

- `lib/config/live_api_guards.dart`
- `lib/features/planning/services/places_service.dart`
- `lib/features/planning/services/places_cache_service.dart`
- `lib/features/planning/services/place_lookup_cache_service.dart`
- `lib/features/planning/providers/planning_provider.dart`
- `lib/core/widgets/city_autocomplete_field.dart`
- `lib/core/widgets/transport_autocomplete_field.dart`
- `lib/features/onboarding/screens/destination_screen.dart`
- `lib/features/trips/widgets/trip_edit_sheet.dart`
- `lib/features/trips/screens/trip_detail_screen.dart`
- `lib/features/planning/widgets/suggestion_detail_sheet.dart`
- `lib/features/planning/widgets/activity_detail_sheet.dart`
- `lib/features/planning/widgets/alternatives_sheet.dart`
- `docs/api_cost/api_live_call_inventory.md`

Fichiers a ne pas modifier pendant la spec:

- services Places New / Routes / Geocoding / Gemini;
- fichiers Phase 4.8;
- snapshots JSON.

## 2. Fichiers a modifier plus tard

Implementation cible API-0.4d:

- `lib/features/planning/services/places_service.dart`
- `lib/features/planning/providers/planning_provider.dart` si injection provider
  explicite retenue
- tests offline nouveaux, probablement:
  - `test/features/planning/services/places_service_guard_test.dart`
  - `test/features/planning/services/places_cache_service_guard_test.dart`
  - `test/features/planning/services/place_lookup_cache_service_guard_test.dart`

Fichiers a eviter en API-0.4d sauf necessite compile ou test:

- `lib/features/planning/services/places_nearby_service.dart`
- `lib/features/planning/services/geocoding_service.dart`
- `lib/features/planning/services/routes_service.dart`
- `lib/features/planning/services/ai_suggestions_service.dart`
- `lib/features/assistant/services/assistant_service.dart`
- `lib/features/planning/services/places_first_pipeline.dart`

## 3. Surface live legacy a proteger

`PlacesService` appelle directement Google Places legacy dans:

- `findInfo()`:
  - endpoint `place/findplacefromtext/json`;
  - construit aussi des URLs `place/photo`;
- `autocompleteCities()`:
  - lance 3 appels autocomplete en parallele: `(cities)`, `geocode`,
    `establishment`;
- `_autocompleteEtape()`:
  - helper prive utilise par `autocompleteCities()`;
- `autocompleteDestinations()`:
  - 1 appel autocomplete `types=geocode`;
- `autocompleteTransport()`:
  - 1 appel autocomplete `types=airport` ou `train_station`;
- `resolvePlaceCoords()`:
  - 1 appel Place Details `geometry/location,name,address_components`;
- `getCountryCodeFromPlaceId()`:
  - 1 appel Place Details `address_component`;
- `findCityCoords()`:
  - 1 appel Find Place From Text pour ville/pays;
- `getDetails()`:
  - 1 appel Place Details `reviews,opening_hours`.

## 4. Injection de `LiveApiGuards`

Ajouter un champ immutable:

```dart
final LiveApiGuards _guards;
```

Constructeur propose:

```dart
PlacesService({
  LiveApiGuards? guards,
  http.Client? httpClient,
})  : _guards = guards ?? LiveApiGuards.fromEnvironment(),
      _httpClient = httpClient;
```

Le `httpClient` est recommande pour tests offline. Il permet de verifier qu'un
blocage arrive avant tout `GET` et qu'un chemin autorise atteint seulement un
fake client.

Ajouter un helper interne:

```dart
void _assertGooglePlacesAllowed(String operation) {
  _guards.assertAllowed(
    LiveApiFamily.googlePlaces,
    operation: operation,
  );
}
```

Ordre general:

1. Conserver les retours rapides actuels pour inputs invalides.
2. Conserver les retours rapides actuels pour cle API absente/placeholder.
3. Juste avant le premier `http.get`, appeler `_assertGooglePlacesAllowed(...)`.
4. Ne pas attraper `LiveApiBlockedException` dans un `catch` qui retournerait
   silencieusement `[]`, `null` ou `PlaceInfo.empty`.

Point important: placer le guard hors des `try/catch` qui enveloppent les appels
HTTP, ou rethrow explicitement `LiveApiBlockedException`.

## 5. Comportement exact par methode

### `findInfo()`

Ordre propose:

1. Si cle absente/placeholder: `PlaceInfo.empty` comme aujourd'hui.
2. Query vide: `PlaceInfo.empty`.
3. `_assertGooglePlacesAllowed('PlacesService.findInfo')`.
4. Appel Find Place From Text.
5. Construction des `PlacePhoto.url` comme aujourd'hui.

Blocage:

- cache miss direct ou appel direct sans flag -> `LiveApiBlockedException`;
- ne pas convertir en `PlaceInfo.empty`.

### `autocompleteCities()`

Ordre propose:

1. Query trimmee `< 2`: `[]` comme aujourd'hui.
2. Cle absente/placeholder: `[]` comme aujourd'hui.
3. `_assertGooglePlacesAllowed('PlacesService.autocompleteCities')`.
4. Lancer les 3 appels autocomplete.

Alternative possible:

- guarder dans `_autocompleteEtape()` aussi, mais cela donnerait 3 checks pour
  une seule intention UI. Le guard au niveau public est plus lisible.

### `_autocompleteEtape()`

Si `autocompleteCities()` est le seul caller, ne pas ajouter un deuxieme guard
obligatoire. Si un futur caller direct apparait, il faudra soit rendre le helper
public/protege avec guard, soit ajouter le guard interne.

### `autocompleteDestinations()`

Ordre propose:

1. Query trimmee `< 2`: `[]`.
2. Cle absente/placeholder: `[]`.
3. `_assertGooglePlacesAllowed('PlacesService.autocompleteDestinations')`.
4. Appel autocomplete `types=geocode`.

### `autocompleteTransport()`

Ordre propose:

1. Query trimmee `< 2`: `[]`.
2. Cle absente/placeholder: `[]`.
3. Type invalide: `[]`.
4. `_assertGooglePlacesAllowed('PlacesService.autocompleteTransport')`.
5. Appel autocomplete avec `sessiontoken` si fourni.

### `resolvePlaceCoords()`

Ordre propose:

1. `placeId` vide: `null`.
2. Cle absente/placeholder: `null`.
3. `_assertGooglePlacesAllowed('PlacesService.resolvePlaceCoords')`.
4. Appel Place Details.

### `getCountryCodeFromPlaceId()`

Ordre propose:

1. `placeId` vide: `null`.
2. Cle absente/placeholder: `null`.
3. `_assertGooglePlacesAllowed('PlacesService.getCountryCodeFromPlaceId')`.
4. Appel Place Details.

### `findCityCoords()`

Ordre propose:

1. Cle absente/placeholder: `null`.
2. Optionnellement, si `city.trim().isEmpty`: `null` pour eviter un appel
   absurde.
3. `_assertGooglePlacesAllowed('PlacesService.findCityCoords')`.
4. Appel Find Place From Text.

### `getDetails()`

Ordre propose:

1. Cle absente/placeholder: `(reviews: [], openingHours: null)` comme
   aujourd'hui.
2. `placeId` vide: meme retour vide, a ajouter si absent.
3. `_assertGooglePlacesAllowed('PlacesService.getDetails')`.
4. Appel Place Details.

## 6. Cache hit / cache miss

### `PlacesCacheService.findInfo()`

Etat actuel:

1. lit Supabase `places_cache`;
2. cache hit frais -> retourne `PlaceInfo`;
3. cache miss / expire / lookup error -> appelle `PlacesService.findInfo()`.

Comportement API-0.4d:

- cache hit frais autorise sans `ALLOW_LIVE_GOOGLE_PLACES`;
- cache miss ou expire atteint `PlacesService.findInfo()`;
- si `ALLOW_LIVE_GOOGLE_PLACES` absent, `PlacesService.findInfo()` throw
  `LiveApiBlockedException`;
- `PlacesCacheService` ne doit pas swallow cette exception en `PlaceInfo.empty`.

La ligne actuelle `catch (e) { ... on passe en live }` sur lookup cache ne doit
pas attraper un blocage Places, car le blocage arrive apres le lookup. Si une
future refactor de cache englobe aussi le call Places dans un try, rethrow
explicitement `LiveApiBlockedException`.

### `PlacesCacheService.getDetails()`

Etat actuel:

1. lit `reviews`, `opening_hours`, `place_id`;
2. hit strict si reviews et opening_hours non null -> retourne cache;
3. sinon cherche un `placeId` via `findInfo()` si necessaire;
4. appelle `PlacesService.getDetails()`.

Comportement API-0.4d:

- hit strict autorise sans flag;
- miss details sans flag bloque au niveau `PlacesService.getDetails()`;
- si `placeId` manque et `findInfo()` doit etre appele, il bloque aussi sans
  flag;
- ne pas convertir le blocage en details vides.

### `PlaceLookupCacheService.resolveCoords()`

Etat actuel:

1. lit Supabase `place_lookup_cache`;
2. hit complet avec lat/lng/name/country/city -> retourne cache;
3. hit legacy incomplet ou miss -> appelle `PlacesService.resolvePlaceCoords()`.

Comportement API-0.4d:

- hit complet autorise sans flag;
- hit legacy incomplet necessitant enrichissement = cache miss live;
- miss sans `ALLOW_LIVE_GOOGLE_PLACES` bloque au niveau
  `PlacesService.resolvePlaceCoords()`;
- ne pas swallow `LiveApiBlockedException` en `null`.

## 7. Autocomplete UI quand live bloque

Les champs UI appellent directement `PlacesService`:

- `CityAutocompleteField` -> `autocompleteDestinations()` et
  `autocompleteCities()`;
- `TransportAutocompleteField` -> `autocompleteTransport()`;
- `trip_edit_sheet.dart` / `trip_detail_screen.dart` ont aussi des calls directs
  selon les flows.

Recommandation API-0.4d:

- `PlacesService` throw explicitement;
- les widgets ne sont pas modifies dans le meme commit sauf si necessaire pour
  compiler ou pour eviter une erreur non geree en test;
- une phase UX separee pourra transformer `LiveApiBlockedException` en liste
  vide avec message dev visible, ou en etat "recherche live desactivee".

Pourquoi ne pas retourner `[]` dans le service:

- `[]` est indistinguable d'un vrai `ZERO_RESULTS`;
- le but API cost est de rendre le blocage visible en dev/test.

## 8. Details / Find Place quand live bloque

`findInfo()`, `findCityCoords()`, `resolvePlaceCoords()`,
`getCountryCodeFromPlaceId()` et `getDetails()` doivent throw
`LiveApiBlockedException` sur live necessaire non autorise.

Ne pas retourner silencieusement:

- `PlaceInfo.empty`;
- `null`;
- `(reviews: [], openingHours: null)`.

Ces valeurs doivent rester reservees aux cas historiques:

- input invalide;
- cle absente/placeholder;
- reponse Google sans resultat;
- erreur reseau Google quand live etait explicitement autorise.

## 9. Place Photo URLs et images reseau

`PlacesService.findInfo()` ne telecharge pas les photos. Il construit des URLs:

```text
https://maps.googleapis.com/maps/api/place/photo?...&key=...
```

Ces URLs sont ensuite chargees par l'UI via `CachedNetworkImage` dans plusieurs
widgets (`suggestion_detail_sheet`, `activity_detail_sheet`,
`alternatives_sheet`, `planning_screen`).

Decision API-0.4d:

- proteger la generation de nouvelles URLs Place Photo via le guard
  `googlePlaces`, car elles sont creees uniquement apres un appel Find Place;
- ne pas encore brancher `ALLOW_LIVE_NETWORK_IMAGES` dans les widgets;
- documenter que les URLs deja stockees en DB ou cache peuvent encore declencher
  des requetes image Google quand l'UI les affiche;
- traiter le blocage runtime des images reseau dans une phase separee si le
  budget image devient prioritaire.

Option future:

- filtrer les `photoUrls` Google si `allowNetworkImages=false`;
- proxy/cache image cote backend;
- remplacer par placeholder local en dev/test.

## 10. Tests offline a creer

`places_service_guard_test.dart`:

- `findInfo()` sans flag throw `LiveApiBlockedException` avant fake HTTP;
- `findInfo()` avec `allowGooglePlaces=true` atteint fake HTTP;
- `autocompleteDestinations()` sans flag throw avant fake HTTP;
- `autocompleteCities()` sans flag throw une seule fois avant les 3 requetes;
- `autocompleteTransport()` sans flag throw avant fake HTTP;
- `resolvePlaceCoords()` sans flag throw avant fake HTTP;
- `getCountryCodeFromPlaceId()` sans flag throw avant fake HTTP;
- `findCityCoords()` sans flag throw avant fake HTTP;
- `getDetails()` sans flag throw avant fake HTTP;
- `ALLOW_LIVE_APIS=true` autorise au moins un chemin.

`places_cache_service_guard_test.dart`:

- `findInfo()` cache hit retourne sans flag et sans Places fake HTTP;
- `findInfo()` cache miss sans flag propage `LiveApiBlockedException`;
- `getDetails()` hit strict retourne sans flag;
- `getDetails()` miss sans flag propage `LiveApiBlockedException`.

`place_lookup_cache_service_guard_test.dart`:

- hit complet retourne sans flag;
- miss sans flag propage `LiveApiBlockedException`;
- hit legacy incomplet sans flag propage `LiveApiBlockedException`.

Tous les tests doivent utiliser:

- fake `http.Client`;
- fake cache/Supabase ou services doubles offline;
- aucun vrai appel Google;
- aucun vrai appel Supabase;
- aucun `generate_baseline.dart`;
- aucun `places_first_harness.dart`.

## 11. Risques UX

- Autocomplete peut throw en dev/test si l'UI ne gere pas encore
  `LiveApiBlockedException`.
- Les flows onboarding/trip edit peuvent ne plus suggerer de destination sans
  flag live.
- Les details photos/avis/horaires peuvent apparaitre absents si les call sites
  choisissent plus tard de degrader l'exception en fallback.
- Des URLs photos deja en DB peuvent continuer a charger des images Google tant
  que `ALLOW_LIVE_NETWORK_IMAGES` n'est pas branche dans l'UI.

## 12. Limites

API-0.4d ne couvre pas:

- Places API New deja traitee par `PlacesNearbyService`;
- Geocoding API deja traitee par `GeocodingService`;
- Routes API deja traitee par `RoutesService`;
- Gemini deja traite par API-0.4c;
- Supabase cache policy globale;
- network images runtime;
- device location;
- currency API.

## 13. Validation cible implementation

Commandes cible pour l'implementation future:

```bash
flutter analyze lib/features/planning/services/places_service.dart \
  test/features/planning/services/places_service_guard_test.dart \
  test/features/planning/services/places_cache_service_guard_test.dart \
  test/features/planning/services/place_lookup_cache_service_guard_test.dart

flutter test test/features/planning/services/places_service_guard_test.dart
flutter test test/features/planning/services/places_cache_service_guard_test.dart
flutter test test/features/planning/services/place_lookup_cache_service_guard_test.dart
flutter test test/config/live_api_guards_test.dart
```

Ne pas lancer de scripts live pendant cette phase.
