# Phase 1 / Tâche 1.4 — Tests d'intégration DestinationIntelligence

## Objectif

Tâche **purement de tests** : vérifier que les composants
`DestinationIntelligence` livrés en Phase 1 fonctionnent **ensemble**
(modèle 1.1 + données Singapour 1.2 + loader 1.3) sans introduire
aucune intégration runtime au pipeline.

**Pas d'intégration runtime, pas de branchement pipeline, pas de
SameComplexGroup, pas de DayTemplate, pas d'implémentation Supabase
concrète.** Le flag `useDestinationIntelligence` reste OFF par
défaut et **n'est consommé nulle part**.

## Fichiers créés

- **`test/destination_intelligence_test.dart`** *(créé, ~330 lignes)*
  — **18 tests** d'intégration, 7 groupes. Aucune dépendance
  réseau / Supabase / Google Places / mock framework.
- **`docs/migrations/phase1_task1_4.md`** *(ce document)*.

**Aucun fichier de production modifié** :
- `lib/models/destination_intelligence.dart` intact
- `lib/data/destinations/singapore.dart` intact
- `lib/services/destination_intelligence_loader.dart` intact
- `lib/features/planning/services/places_first_pipeline.dart` intact
- `lib/features/planning/data/destination_blueprints.dart` intact
- `lib/features/planning/data/metro_profile.dart` intact
- `lib/features/planning/data/segment_city_canonicals.dart` intact
- `lib/features/planning/services/day_builder.dart` intact
- `lib/config/feature_flags.dart` intact (flag toujours OFF, non
  consommé)

## Portée des tests d'intégration

Les tests unitaires existants (Tâches 1.1, 1.2, 1.3) restent en
place et continuent à valider chaque composant **isolément**. La
Tâche 1.4 vérifie la **collaboration** entre eux :

- 1.1 fournit le modèle + validate + JSON
- 1.2 fournit les données Singapour
- 1.3 fournit le loader + cache + fallback
- 1.4 vérifie que `loader.load("singapore")` → données 1.2 →
  modèle 1.1 → validate vide → round-trip JSON OK → cache OK

Helpers de comparaison utilisés :
- `_norm(s)` : `lowercase + trim + collapse whitespace`
- `_zoneNames(di)` / `_anchorNames(di)` : `Set<String>` de noms
  normalisés

Permet une **comparaison robuste à l'ordre** des zones / anchors
(spec Tâche 1.4 : *"Ne pas rendre le test fragile sur l'ordre"*).

## Ce qui est couvert — 18 tests en 7 groupes

### 1. Chargement Singapour via loader (2 tests)
- `load('singapore')` retourne objet valide
- `destinationKey == 'singapore'`, `countryCode == 'SG'`,
  `allowedCountryCodes` contient SG, `blockedCountryCodes`
  contient MY + ID
- `borderSensitivity == high`, `tripMode == megaCity`
- `transportRules.maxTransitionKm == 5.0`, `hasMetro == true`,
  `hasMetroAnchorLogic == true`
- `canonicalCenter` ≈ (1.3521, 103.8198)

### 2. Zones Singapour via loader (3 tests)
- **Minimum strict (spec 1.4)** : Marina Bay, Chinatown, Sentosa,
  Orchard présents
- **Idéal (cf. spec 1.2)** : les 10 zones définies en Tâche 1.2
  toutes présentes — Marina Bay, Chinatown, Civic District, Orchard,
  Sentosa, Little India, Kampong Glam, Botanic Gardens, **Bugis**,
  Clarke Quay
- `di.zones` contient exactement 10 zones
- Chaque zone validée individuellement (`zone.validate().isEmpty`)

### 3. Anchors Singapour via loader (3 tests)
- **Minimum strict (spec 1.4)** : Gardens by the Bay, Buddha Tooth
  Relic Temple, Sentosa (préfixe accepté car "Sentosa Island" dans
  les données)
- **Idéal (cf. spec 1.2)** : 15 anchors présents (10 mustSee +
  5 experience) — incluant Marina Bay Sands, Singapore Botanic
  Gardens, Merlion Park, Orchard Road, ArtScience Museum,
  Little India, Chinatown, Lau Pa Sat, Maxwell Food Centre,
  Clarke Quay, Singapore Flyer, Kampong Glam variants
- Chaque anchor : importance ∈ [1, 5], duration > 0

### 4. Sérialisation intégrée round-trip (1 test)
- loader → `toJson()` → `DestinationIntelligence.fromJson(json)`
- Objet reconstruit validate vide
- Champs essentiels conservés (destinationKey, countryCode,
  borderSensitivity, tripMode, canonicalCenter, allowed/blocked
  CountryCodes)
- Zones et anchors conservés en nombre + samples conservés
- `transportRules` (4 champs) conservés à l'identique

### 5. Fallback destination inconnue intégration (2 tests)
- `load('unknown_city')` retourne fallback valide
- `destinationKey == 'unknown_city'`, `tripMode == cityBreak`,
  `borderSensitivity == medium`, `blockedCountryCodes` vide
- Au moins 1 zone, au moins 1 anchor, `transportRules` valide
- **Fallback sérialisable round-trip** (toJson + fromJson + validate)

### 6. Cache intégré + normalisation clé (4 tests)
- `isCached('singapore')` faux avant load, vrai après
- Cache utilise la clé normalisée : `isCached('singapore')` est
  vrai après `load('SINGAPORE')` ou `load(' Singapore ')`
- Deux loads consécutifs avec keys normalisées différentes
  retournent des objets **valides et équivalents** (comportement
  testé, pas identité — conforme spec 1.4)
- `clearCache()` + reload reste fonctionnel et valide

### 7. Robustesse globale sanity (2 tests)
- Loader sans aucune source injectée fonctionne pour Singapour
  (data Dart) + fallback inconnu (centre neutre) sans crash
- Loader peut servir plusieurs destinations différentes en
  mémoire simultanément, `clearCache()` les vide toutes

## Ce qui n'est volontairement PAS couvert

Aucune intégration **runtime** n'est testée car aucune n'existe
encore. Hors scope Tâche 1.4 et Phase 1 complète :

- ❌ Branchement loader → `places_first_pipeline.dart`
- ❌ Consommation du flag `useDestinationIntelligence` par le
  pipeline
- ❌ Implémentation concrète `SupabaseDestinationIntelligenceRemoteSource`
- ❌ Implémentation concrète `GoogleGeocodingCenterResolver`
- ❌ Migration des autres destinations (Bangkok, Tokyo, Paris,
  Rome, etc.) vers `lib/data/destinations/*.dart` — Tâches
  ultérieures Phase 1 ou 2
- ❌ `SameComplexGroup` — Phase 2
- ❌ `DestinationScope` — Phase 3
- ❌ `DayTemplate` — Phase 4
- ❌ Comparaison sémantique avec les `MetroProfile` /
  `DestinationBlueprint` existants (pas dans la spec ; les
  données 1.2 ont déjà été validées par les tests 1.2)

## Confirmation : aucune intégration runtime

- ✅ `grep -rn "DestinationIntelligenceLoader\|buildSingaporeDestination
  Intelligence" lib/features/` → **aucune référence** dans les
  fichiers de production planning
- ✅ Le test 1.4 importe uniquement :
  - `package:flutter_test/flutter_test.dart`
  - `package:voyage/models/destination_intelligence.dart`
  - `package:voyage/services/destination_intelligence_loader.dart`
- ✅ Le test n'importe NI `places_first_pipeline.dart`, NI les
  modules data du pipeline existant (`destination_blueprints.dart`,
  `metro_profile.dart`, `segment_city_canonicals.dart`).

## Résultats validation

```
flutter analyze
  35 issues found (info préexistants Tâche 0.1, inchangés)
  → test/destination_intelligence_test.dart : No issues found
  0 warning, 0 error sur le nouveau fichier

flutter test
  599 tests verts (581 Tâche 1.3 + 18 nouveaux Tâche 1.4)

flutter test test/snapshots/generate_baseline.dart
  1 test passé, baseline JSON régénéré (variation Google Places
  attendue, cf. Tâche 0.1)

flutter test test/snapshots/compare_snapshot.dart
  16 tests passés (1 self-check + 15 fixtures)
  Verdict self-check : PASS
```

## Commande

```bash
# Test d'intégration uniquement
flutter test test/destination_intelligence_test.dart

# Suite complète
flutter test
flutter test test/snapshots/generate_baseline.dart
flutter test test/snapshots/compare_snapshot.dart
```

## Conclusion Phase 1

Avec la Tâche 1.4, la **Phase 1** est complète côté **structure
DestinationIntelligence** :

| Tâche | Commit | Statut | Apport |
|-------|--------|--------|--------|
| 1.1 | `f8465e0` | Validée | Modèle + validation + JSON + SQL (41 tests) |
| 1.2 | `6421169` | Validée | Données Singapour (35 tests, 10 zones, 15 anchors) |
| 1.3 | `8816ac4` | Validée | Loader + cache + fallback (22 tests) |
| 1.4 | (this) | À valider | Tests d'intégration (18 tests) |

**Total Phase 1 : 116 tests** unitaires + intégration, **0
modification de production**.

`DestinationIntelligence` est **disponible** comme abstraction
complète et testée, **mais dormante** :
- Le modèle existe, valide.
- Une destination (Singapour) est embarquée comme donnée.
- Un loader peut la charger avec cache + fallback.
- Les pièces fonctionnent ensemble (vérifié 1.4).

Et pourtant **rien n'a changé pour l'utilisateur** : le pipeline
production continue à utiliser exactement les `DestinationBlueprint`
/ `MetroProfile` / `segment_city_canonicals` actuels. Le flag
`useDestinationIntelligence` reste OFF et n'est branché nulle part.

C'est le résultat attendu d'une migration progressive bien
exécutée : **fondations solides posées sans risque pour le
comportement actuel**.

## Prochaine étape : Phase 2

La suite logique est **Phase 2 — `SameComplexGroup`**. Cette phase
devrait apporter le premier gain visible côté qualité du planning :

- Détecter les complexes sémantiques (Sentosa Island / Sentosa,
  Tokyo Skytree / Skytree Tower, Marina Bay Sands / SkyPark
  Observation Deck, Gardens by the Bay / Supertree Grove / Cloud
  Forest).
- Permettre la dédup cross-complex (signal déjà identifié dans
  les V8.28b1.x sur Singapour).
- Probablement consommer le flag `useSameComplexDedup` déjà
  défini en Tâche 0.3.

Cf. Tâche 0.2 limite explicitement documentée :
> *"Les complexes sémantiques type Sentosa / Universal / Resorts
> World ne sont pas encore détectés ici. Ils seront traités en
> Phase 2 via SameComplexGroup."*
