# POI-2.1 — Activate POI Candidates in Planning Flow

## Contexte

POI-2.0 a livré l'infrastructure :
- `DestinationKeyMapper` (mapping destination → `destination_key`)
- `PoiCandidateAdapter` (conversion `Poi` → `NearbyCandidate`)
- `gatherCandidatesForTrip` avec paramètre optionnel `PoiRepository?`

POI-2.1 active cette infrastructure dans les vrais flux de suggestion.

## Changements

### 1. `places_first_pipeline.dart` — Paramètres optionnels propagés

Les fonctions publiques d'entrée du pipeline reco ont reçu un paramètre optionnel `PoiRepository? poiRepository` :

| Fonction | Paramètre ajouté | Propagation |
|----------|-----------------|-------------|
| `runCoPilotPlacesFirst` | `PoiRepository? poiRepository` | → `_runCoPilotPlacesFirstBody` → `gatherCandidatesForTrip` |
| `runAutoPlacesFirst` | `PoiRepository? poiRepository` | → `_runAutoPlacesFirstBody` → `gatherCandidatesForTrip` |

- **Valeur par défaut :** `null`. Aucun appelant existant n'a été cassé.
- **Pas de changement de logique :** si `null`, le pipeline reste 100% Google Places.

### 2. `planning_screen.dart` — Injection dans le flux "Suggérer"

Deux call sites mis à jour :

- **CoPilot Places-first** (ligne ~694) : `poiRepository: ref.read(poiRepositoryProvider)`
- **Auto Places-first** (ligne ~753) : `poiRepository: ref.read(poiRepositoryProvider)`

### 3. `trip_detail_screen.dart` — Injection dans le flux turnkey

- **Auto Places-first** (ligne ~439) : `poiRepository: ref.read(poiRepositoryProvider)`

## Comportement attendu

| Destination | `DestinationKeyMapper` | `PoiRepository` | Résultat |
|-------------|----------------------|-----------------|----------|
| Lisbon / Lisbonne / Lisboa | → `lisbon` | `FakePoiRepository` (offline) / `SupabasePoiRepository` (live) | POIs curatés mergés dans le pool |
| Tokyo | → `null` | quelconque | Skip POI, fallback Google Places inchangé |
| Paris | → `null` | quelconque | Skip POI, fallback Google Places inchangé |
| Destination inconnue | → `null` | quelconque | Skip POI, fallback Google Places inchangé |

## Tests

Aucun test existant n'a été modifié (paramètres optionnels). Tous les tests passent :

```bash
flutter test test/planning/poi_candidate_adapter_test.dart
flutter test test/features/planning/services/places_first_pipeline_test.dart
flutter test test/poi/
```

**Résultat :** 405 passés, 5 live skipped, 0 échec.

## Activation progressive

L'activation est **transparente et sans risque** :
- Si la base POI est vide pour une destination → `listPoisByDestination` retourne `[]` → merge no-op.
- Si le `PoiRepository` retourne des POIs sans coordonnées → skip silencieux.
- Si la destination n'est pas mappée → `DestinationKeyMapper.map()` → `null` → bloc POI skip.

## Fichiers modifiés

| Fichier | Lignes | Type |
|---------|--------|------|
| `lib/features/planning/services/places_first_pipeline.dart` | ~20 | Paramètres optionnels ajoutés |
| `lib/features/planning/screens/planning_screen.dart` | ~4 | `poiRepository` passé aux 2 calls |
| `lib/features/trips/screens/trip_detail_screen.dart` | ~2 | `poiRepository` passé au call |
| `docs/poi/poi_2_1_lisbon_planning_activation.md` | ~60 | Ce document |
