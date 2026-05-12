# API-0.4a — Spec Places New + Geocoding guards

## Objectif

Brancher `LiveApiGuards` sur les deux familles live les plus critiques sans elargir le scope:

- `PlacesNearbyService` pour Google Places API New (`places:searchNearby`, `places:searchText`);
- `GeocodingService` pour Google Geocoding API.

Design retenu a valider avant code:

> cache hit autorise, cache miss live bloque sans opt-in live.

Les services bas niveau doivent throw `LiveApiBlockedException` quand un appel live serait necessaire mais non autorise. Les call sites decideront plus tard s'ils veulent afficher un message, fallback vide, ou degrader l'UX.

## 1. Fichiers a lire

Avant implementation API-0.4a:

- `lib/config/live_api_guards.dart`
- `lib/features/planning/services/places_nearby_service.dart`
- `lib/features/planning/services/geocoding_service.dart`
- `lib/features/planning/providers/planning_provider.dart`
- `lib/features/planning/services/day_center_service.dart`
- `lib/features/planning/services/places_first_pipeline.dart`
- `test/dev/places_first_harness.dart`
- `test/snapshots/generate_baseline.dart`
- `test/helpers/live_api_script_guards.dart`
- `test/config/live_api_guards_test.dart`

## 2. Fichiers a modifier plus tard

Implementation cible API-0.4a:

- `lib/features/planning/services/places_nearby_service.dart`
- `lib/features/planning/services/geocoding_service.dart`
- `lib/features/planning/providers/planning_provider.dart`
- `test/dev/places_first_harness.dart`
- `test/snapshots/generate_baseline.dart`
- tests offline nouveaux, probablement:
  - `test/features/planning/services/places_nearby_service_guard_test.dart`
  - `test/features/planning/services/geocoding_service_guard_test.dart`

Fichiers a ne pas modifier dans API-0.4a:

- `lib/features/planning/services/routes_service.dart`
- `lib/features/planning/services/ai_suggestions_service.dart`
- `lib/features/planning/services/places_service.dart`
- `lib/config/feature_flags.dart`
- snapshots JSON
- fichiers Phase 4.8

## 3. Comportement exact de `PlacesNearbyService`

### Injection

Ajouter un champ immutable optionnel:

```dart
final LiveApiGuards _guards;
```

Constructeur propose:

```dart
PlacesNearbyService({
  GeminiCacheService? cache,
  LiveApiGuards? guards,
})  : _cache = cache,
      _guards = guards ?? LiveApiGuards.fromEnvironment();
```

Le default `fromEnvironment()` permet aux scripts/dev runs de rester pilotes par `--dart-define`. Les tests peuvent injecter `LiveApiGuards.defaults()` ou une instance autorisee.

### `searchNearby()`

Ordre de decision:

1. Si API key absente ou placeholder: retour `[]` comme aujourd'hui.
2. Si `includedTypes` vide: retour `[]` comme aujourd'hui.
3. Calculer `cacheKey` et `dedupKey`.
4. Lire `_cache?.get('places_search', cacheKey)`.
5. Si cache hit valide: retourner les candidats, meme si `allowGooglePlaces=false`.
6. Appliquer le budget existant `_budget?.shouldSkip(...)`; si skip: retour `[]`.
7. Avant `http.post(...)`, appeler:

```dart
_guards.assertAllowed(
  LiveApiFamily.googlePlaces,
  operation: 'PlacesNearbyService.searchNearby',
);
```

8. Si autorise: effectuer l'appel live comme aujourd'hui, puis cache put.
9. Si bloque: laisser remonter `LiveApiBlockedException`.

### `searchText()`

Meme ordre:

1. API key/placeholder: `[]`.
2. Query vide: `[]`.
3. Cache lookup.
4. Cache hit: OK sans live.
5. Budget skip: `[]`.
6. Avant `http.post(...)`, `assertAllowed(googlePlaces, operation: 'PlacesNearbyService.searchText')`.
7. Autorise: live call + cache put.
8. Bloque: throw `LiveApiBlockedException`.

### Pourquoi throw et pas `[]`

Retourner `[]` masquerait la difference entre:

- vrai zero resultat Google;
- cache miss bloque par politique cout;
- erreur reseau ou quota.

Pour API cost, cette distinction est importante. Les call sites pourront transformer l'exception plus haut, mais le service bas niveau doit rester explicite.

## 4. Comportement exact de `GeocodingService`

`GeocodingService` n'a pas de cache aujourd'hui. Dans API-0.4a, il faut donc considerer tout appel `geocode()` non vide avec API key valide comme un potentiel live miss.

Ordre de decision propose:

1. Si API key absente ou placeholder: retour `null` comme aujourd'hui.
2. Trim query; si vide: retour `null`.
3. Avant de construire/lancer `http.get(...)`, appeler:

```dart
_guards.assertAllowed(
  LiveApiFamily.googleGeocoding,
  operation: 'GeocodingService.geocode',
);
```

4. Si autorise: comportement actuel.
5. Si bloque: throw `LiveApiBlockedException`.

### Cache hit / miss pour Geocoding

Etat actuel:

- pas de cache dans `GeocodingService`;
- quelques donnees resolues peuvent etre persistees ailleurs apres coup (ex: docs wallet metadata, trip coords), mais ce n'est pas un cache generique du service.

Donc pour API-0.4a:

- pas de live sans `ALLOW_LIVE_GOOGLE_GEOCODING=true`;
- pas de fallback silencieux `null` sur blocage;
- pas de nouveau cache a introduire dans cette sous-phase, sauf decision produit separee.

Une future API-0.4b/0.5 pourrait ajouter un cache de geocoding partage, mais ce serait un chantier different.

## 5. Strategie d'injection de `LiveApiGuards`

### Providers app

Dans `planning_provider.dart`, ajouter probablement:

```dart
final liveApiGuardsProvider = Provider<LiveApiGuards>((ref) {
  return LiveApiGuards.fromEnvironment();
});
```

Puis:

```dart
final placesNearbyServiceProvider = Provider<PlacesNearbyService>((ref) {
  return PlacesNearbyService(
    cache: ref.watch(geminiCacheServiceProvider),
    guards: ref.watch(liveApiGuardsProvider),
  );
});

final geocodingServiceProvider = Provider<GeocodingService>((ref) {
  return GeocodingService(guards: ref.watch(liveApiGuardsProvider));
});
```

### Scripts deja gardes

`generate_baseline.dart` et `places_first_harness.dart` devront instancier les services avec guards explicites pour eviter un double comportement ambigu:

```dart
final guards = LiveApiGuards.fromEnvironment();
assertLiveApisAllowedForGenerateBaseline(guards: guards);
final geocoder = GeocodingService(guards: guards);
final nearbyService = PlacesNearbyService(guards: guards);
```

Les guards de script restent utiles pour echouer avec un message plus pedagogique. Les guards de service deviennent la protection defense-in-depth.

## 6. Comportement cache hit / cache miss

`PlacesNearbyService`:

- cache hit `gemini_cache/action=places_search`: autorise sans live;
- cache miss + `allowGooglePlaces=false`: throw `LiveApiBlockedException`;
- cache miss + `allowGooglePlaces=true`: appel Google, puis cache put best-effort.

`GeocodingService`:

- cache hit: non applicable en API-0.4a;
- query vide ou key absente: retour `null`;
- live necessaire + `allowGoogleGeocoding=false`: throw `LiveApiBlockedException`;
- live necessaire + `allowGoogleGeocoding=true`: appel Google.

## 7. Type d'erreur ou fallback recommande

Recommandation:

- Services bas niveau: throw `LiveApiBlockedException`.
- Call sites UI/pipeline: ne pas modifier dans API-0.4a sauf necessaire pour tests compile.
- Scripts dangereux: gardent leur erreur pedagogique via `LiveApiScriptGuardException` avant d'atteindre les services.

Ne pas retourner silencieusement `[]` ou `null` sur blocage live dans les services critiques.

Si un call site existant casse fortement l'UX apres API-0.4a, traiter dans une phase dediee avec fallback explicite et logs visibles.

## 8. Tests offline a creer

### `PlacesNearbyService`

Tests proposes sans reseau:

1. cache hit `searchNearby()` retourne les candidats meme avec `LiveApiGuards.defaults()`.
2. cache hit `searchText()` retourne les candidats meme avec `LiveApiGuards.defaults()`.
3. cache miss `searchNearby()` avec guards default throw `LiveApiBlockedException` avant HTTP.
4. cache miss `searchText()` avec guards default throw `LiveApiBlockedException` avant HTTP.
5. cache miss avec `allowGooglePlaces=true` ne doit pas etre teste avec vrai HTTP; si besoin, introduire une injection de client HTTP fake ou limiter API-0.4a aux tests de blocage/cache hit.
6. budget skip avant live guard conserve retour `[]` si `_budget.shouldSkip` est actif.

Point technique: le service utilise `http.post` statique. Pour tester le chemin autorise sans reseau, il faudrait injecter un client HTTP. Ce serait du scope supplementaire. API-0.4a peut se limiter aux chemins cache hit et blocked miss.

### `GeocodingService`

Tests proposes sans reseau:

1. query vide retourne `null` sans guard.
2. API key placeholder/empty retourne `null` sans guard si testable.
3. query non vide + guards default throw `LiveApiBlockedException`.
4. query non vide + `allowGoogleGeocoding=true` ne doit pas faire de vrai HTTP; ne pas tester ce chemin sans client fake.

Point technique: `AiConstants.googleMapsApiKey` est statique. Si la cle de dev est non-placeholder, le test de blocage suffit car il throw avant `http.get`.

## 9. Impacts attendus sur `generate_baseline.dart` apres API-0.4a

Avec API-0.3 seul:

- le script est bloque par le guard de script avant service creation.

Avec API-0.4a:

- le script reste bloque par le guard de script par defaut;
- si quelqu'un contourne le guard de script ou instancie les services ailleurs, `PlacesNearbyService` et `GeocodingService` bloquent quand meme;
- en run controle avec les deux flags requis, le script continue a fonctionner:

```bash
flutter test \
  --dart-define=ALLOW_LIVE_GOOGLE_PLACES=true \
  --dart-define=ALLOW_LIVE_GOOGLE_GEOCODING=true \
  test/snapshots/generate_baseline.dart
```

Aucun changement attendu sur les snapshots JSON dans API-0.4a.

## 10. Limites et risques

### Limites

- `PlacesService` legacy n'est pas protege en API-0.4a.
- `RoutesService` n'est pas protege en API-0.4a.
- `AiSuggestionsService` / Gemini n'est pas protege en API-0.4a.
- Network images, device location, currency API restent hors scope.
- `GeocodingService` n'a pas de cache hit possible tant qu'un cache dedie n'existe pas.

### Risques

- Certaines UI/dev flows qui appellent `GeocodingService` sans flags peuvent commencer a throw au lieu de retourner `null`.
- Certains pipelines peuvent devoir catcher `LiveApiBlockedException` plus haut pour afficher un etat "live disabled" lisible.
- Les tests existants qui instancient ces services avec une vraie query peuvent devoir injecter `LiveApiGuards` autorises ou eviter le chemin live.
- `PlacesNearbyService` catch actuellement toutes les exceptions autour du `http.post`. Le `assertAllowed()` doit etre place avant le `try` ou rethrow explicitement, sinon il serait swallow et redeviendrait un `[]` silencieux.

## Decision recommandee

Implementation API-0.4a devrait:

1. Injecter `LiveApiGuards` dans `PlacesNearbyService` et `GeocodingService`.
2. Autoriser les cache hits Places sans live flag.
3. Throw `LiveApiBlockedException` sur cache miss Places sans `ALLOW_LIVE_GOOGLE_PLACES=true`.
4. Throw `LiveApiBlockedException` sur Geocoding live sans `ALLOW_LIVE_GOOGLE_GEOCODING=true`.
5. Mettre a jour les providers et scripts pour passer la meme instance de guards.
6. Ajouter uniquement des tests offline de cache hit et blocage.

