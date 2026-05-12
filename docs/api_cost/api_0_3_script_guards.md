# API-0.3 — Script live API guards

## Objectif

API-0.3 protege les scripts de test/dev capables de declencher beaucoup d'appels live Google Places et Geocoding.

Scripts proteges:

- `test/snapshots/generate_baseline.dart`
- `test/dev/places_first_harness.dart`

Ces scripts refusent maintenant de demarrer leurs runs live sans opt-in explicite via `LiveApiGuards`.

## Comportement avant/apres

Avant API-0.3:

- lancer `flutter test test/snapshots/generate_baseline.dart` pouvait appeler directement Google Places/Geocoding;
- lancer `flutter test test/dev/places_first_harness.dart` pouvait lancer plusieurs profils et consommer des centaines de RPC Places.

Apres API-0.3:

- par defaut, les scripts echouent rapidement avec un message explicite;
- le check est fait avant creation de `GeocodingService`, `PlacesNearbyService`, ou appel au pipeline;
- aucun service de production n'est encore modifie.

## Commandes bloquees par defaut

```bash
flutter test test/snapshots/generate_baseline.dart
```

```bash
flutter test test/dev/places_first_harness.dart
```

Message attendu, sous une forme equivalente:

```text
Live API calls are disabled for this script: ...
Missing live API permissions: googlePlaces, googleGeocoding.
Use --dart-define=ALLOW_LIVE_GOOGLE_PLACES=true --dart-define=ALLOW_LIVE_GOOGLE_GEOCODING=true only for controlled runs.
```

## Commandes live autorisees explicitement

Baseline snapshot:

```bash
flutter test \
  --dart-define=ALLOW_LIVE_GOOGLE_PLACES=true \
  --dart-define=ALLOW_LIVE_GOOGLE_GEOCODING=true \
  test/snapshots/generate_baseline.dart
```

Harness Places-first:

```bash
flutter test \
  --dart-define=ALLOW_LIVE_GOOGLE_PLACES=true \
  --dart-define=ALLOW_LIVE_GOOGLE_GEOCODING=true \
  test/dev/places_first_harness.dart
```

Le flag global `ALLOW_LIVE_APIS=true` fonctionne aussi par design API-0.2, mais les flags specifiques ci-dessus sont preferes pour eviter d'ouvrir toutes les familles.

## Flags requis

Pour `generate_baseline.dart`:

- `ALLOW_LIVE_GOOGLE_PLACES=true`
- `ALLOW_LIVE_GOOGLE_GEOCODING=true`

Pour `places_first_harness.dart`:

- `ALLOW_LIVE_GOOGLE_PLACES=true`
- `ALLOW_LIVE_GOOGLE_GEOCODING=true`

Gemini n'est pas requis dans API-0.3 pour ces deux scripts: leurs chemins actuels utilisent le pipeline deterministe (`gatherCandidatesForTrip`, `selectVisitsDeterministic`, `insertDeterministicMeals`) et n'instancient pas `AiSuggestionsService`.

Supabase n'est pas requis dans API-0.3: ces scripts instancient `PlacesNearbyService()` sans cache Supabase et ne passent pas par les providers app.

## Cout potentiel

Rappel de l'inventaire API-0.1:

- `generate_baseline.dart`: environ 50-100 RPC Google Places par run selon cache/resultats.
- `places_first_harness.dart`: environ 50-100 RPC par profil, avec 10 profils dans le harness actuel.

Ces chiffres justifient le blocage par defaut.

## Implementation

Le helper test-only `test/helpers/live_api_script_guards.dart` expose:

- `missingLiveApiFamiliesForGenerateBaseline(guards)`
- `missingLiveApiFamiliesForPlacesFirstHarness(guards)`
- `assertLiveApisAllowedForGenerateBaseline()`
- `assertLiveApisAllowedForPlacesFirstHarness()`

Les tests offline sont dans:

- `test/snapshots/generate_baseline_guard_test.dart`

Ils ne lancent pas les scripts live et n'appellent aucune API Google/Gemini/Supabase.

## Limites connues

API-0.3 protege uniquement les deux scripts dangereux. Les services de production ne sont pas encore branches:

- `PlacesNearbyService`
- `PlacesService`
- `RoutesService`
- `GeocodingService`
- `AiSuggestionsService`

Le branchement progressif des services est reserve a API-0.4.

