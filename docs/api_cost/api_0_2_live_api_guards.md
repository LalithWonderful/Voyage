# API-0.2 — Live API guardrails

## Objectif

API-0.2 ajoute un module central, pur et testable pour representer les permissions d'appels live API dans Lunao:

- fichier: `lib/config/live_api_guards.dart`
- tests: `test/config/live_api_guards_test.dart`

Le module ne fait aucun appel reseau, n'importe pas Supabase, et ne garde aucun etat global mutable. Il expose seulement une classe immutable `LiveApiGuards`, l'enum `LiveApiFamily`, et l'exception `LiveApiBlockedException`.

## Flags disponibles

Tous les flags sont lus via `--dart-define`.

| Flag | Famille |
| --- | --- |
| `ALLOW_LIVE_APIS` | Global |
| `ALLOW_LIVE_GOOGLE_PLACES` | Google Places legacy + Places New |
| `ALLOW_LIVE_GOOGLE_ROUTES` | Google Routes API |
| `ALLOW_LIVE_GOOGLE_GEOCODING` | Google Geocoding API |
| `ALLOW_LIVE_GEMINI` | Gemini API |
| `ALLOW_LIVE_SUPABASE` | Supabase Auth/PostgREST/RPC/Storage |
| `ALLOW_LIVE_NETWORK_IMAGES` | Images reseau |
| `ALLOW_LIVE_DEVICE_LOCATION` | Geolocator / position appareil |
| `ALLOW_LIVE_CURRENCY_API` | Frankfurter currency API |

## Defaults

Tous les flags sont `false` par defaut.

```dart
final guards = LiveApiGuards.defaults();
guards.allowsAnyLiveApi; // false
```

Parsing bool accepte:

- true: `true`, `TRUE`, `1`, `yes`, `YES`
- false: `false`, `FALSE`, `0`, `no`, `NO`
- absent, vide ou inconnu: false

## Comportement `ALLOW_LIVE_APIS`

Regle retenue pour API-0.2:

- `ALLOW_LIVE_APIS=true` active toutes les familles.
- sinon, seuls les flags specifiques activent leur famille.

Un flag specifique `false` ne desactive pas une famille si `ALLOW_LIVE_APIS=true`. Ce choix est volontaire pour eviter l'ambiguite entre "absent" et "force false" avec `String.fromEnvironment`, qui renvoie une string vide quand une cle compile-time n'est pas definie.

## Exemples

Autoriser seulement Gemini pendant un test cible:

```bash
flutter test test/config/live_api_guards_test.dart \
  --dart-define=ALLOW_LIVE_GEMINI=true
```

Autoriser Places et Geocoding pour un script controle:

```bash
flutter test test/dev/some_guarded_script.dart \
  --dart-define=ALLOW_LIVE_GOOGLE_PLACES=true \
  --dart-define=ALLOW_LIVE_GOOGLE_GEOCODING=true
```

Autoriser toutes les familles:

```bash
flutter test test/dev/some_guarded_script.dart \
  --dart-define=ALLOW_LIVE_APIS=true
```

## Exemple d'utilisation future

API-0.2 ne branche pas encore les guards dans les services live. L'usage prevu pour API-0.3/API-0.4 ressemble a ceci:

```dart
final guards = LiveApiGuards.fromEnvironment();

guards.assertAllowed(
  LiveApiFamily.googlePlaces,
  operation: 'generate_baseline.dart gather candidates',
);

// Appel Places live seulement apres la verification.
```

Si la famille est bloquee, `assertAllowed()` throw `LiveApiBlockedException` avant tout appel live.

## Pas encore branche

API-0.2 cree seulement le module central. Rien n'est encore branche dans:

- `test/snapshots/generate_baseline.dart`
- `test/dev/places_first_harness.dart`
- `PlacesNearbyService`
- `PlacesService`
- `RoutesService`
- `GeocodingService`
- `AiSuggestionsService`
- chargement d'images reseau
- Supabase providers/services

## Suite logique

API-0.3 doit brancher `LiveApiGuards.assertAllowed()` sur les scripts dangereux:

- `test/snapshots/generate_baseline.dart`
- `test/dev/places_first_harness.dart`

La premiere protection concrete anti-facture devrait verifier au minimum les familles `googlePlaces` et `googleGeocoding` avant de lancer ces scripts.

