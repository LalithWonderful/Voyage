# POI-2.0 — Minimal POI-First Candidate Provider

## Objectif

Injecter les POIs curatés Supabase dans le pool de candidats du planning **sans modifier les modèles, le schéma, ni l'UI**.

## Fichiers livrés

| Fichier | Type | Description |
|---------|------|-------------|
| `lib/features/planning/data/destination_key_mapper.dart` | Nouveau | Mapping `Trip.destination` → `destination_key` POI (Lisbonne uniquement pour le pilote). |
| `lib/features/planning/services/poi_candidate_adapter.dart` | Nouveau | Adapte `List<Poi>` → `List<NearbyCandidate>`. Gère synthetic IDs, skip coordonnées invalides, déduplication. |
| `lib/features/planning/services/places_first_pipeline.dart` | Patch | `gatherCandidatesForTrip` accepte un `PoiRepository?` optionnel. Insertion POI après le segment pool guard, avant l'assemblage `DayCandidates`. |
| `test/planning/poi_candidate_adapter_test.dart` | Nouveau | 12 tests offline : mapping, conversion, skip, déduplication, scoring. |
| `docs/poi/poi_2_0_poi_first_candidate_provider.md` | Nouveau | Ce document. |

## Architecture

```
Trip.destination
    ↓
DestinationKeyMapper.map() → destinationKey (ex: "lisbon") ou null
    ↓
gatherCandidatesForTrip()
    ├── Google Places gather (existant)
    ├── Blueprint injection (existant)
    ├── Metro anchor injection (existant)
    ├── Segment pool guard (existant)
    └── POI-2.0 insertion ← NOUVEAU
            │
            ├── PoiCandidateAdapter(repo).adaptForDestination(destinationKey)
            │       → List<NearbyCandidate> (synthetic IDs, coords validées)
            │
            └── Merge dans poolBySig (chaque intérêt de chaque pool)
                    → Remplace si googlePlaceId match
                    → Ajoute si ID synthétique (pas de match Google)
    ↓
Assemblage DayCandidates → pipeline existant inchangé
```

## Règles de merge

1. **Match par `placeId`** : si un POI a le même `googlePlaceId` qu'un candidat Google, le POI curaté remplace le candidat Google.
2. **ID synthétique** : si un POI n'a pas de `googlePlaceId`, il reçoit `poi:<poiId>` et est ajouté comme candidat nouveau.
3. **Skip sans coords** : POI avec `lat` ou `lng` null/NaN est ignoré silencieusement.
4. **Déduplication** : deux POIs avec le même `googlePlaceId` ne produisent qu'un seul candidat.

## Fallback 100% préservé

| Condition | Comportement |
|-----------|-------------|
| Destination non mappée | `DestinationKeyMapper.map()` → null → skip POI |
| `poiRepository` non fourni | Paramètre optionnel null → skip POI |
| Aucun POI en base | `listPoisByDestination` → [] → merge no-op |
| POI sans coordonnées | Skip dans l'adapter → jamais injecté |

## Activation progressive

`gatherCandidatesForTrip` prend un paramètre optionnel `PoiRepository? poiRepository`. Aucun appelant existant n'a été modifié. Pour activer les POIs en production, passer le repo :

```dart
final pool = await gatherCandidatesForTrip(
  trip: trip,
  hotels: hotels,
  geocoder: geocoder,
  nearbyService: nearbyService,
  poiRepository: ref.read(poiRepositoryProvider), // ← activer ici
);
```

## Tests

```bash
flutter test test/planning/poi_candidate_adapter_test.dart
```

12 tests offline, aucun appel réseau.
