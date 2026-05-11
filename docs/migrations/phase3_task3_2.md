# Phase 3 / Tâche 3.2 — Migration scope vers `DestinationIntelligence` + branchement pipeline (flag-gated)

## Objectif

Remplacer progressivement les `blockedAddressPatterns` hardcodés
de Singapour par une logique générique basée sur
`DestinationIntelligence.blockedNeighborRegions` + `ScopeValidator`,
derrière le feature flag `useDestinationScope` (OFF par défaut).

**Cette tâche introduit une modification du pipeline production**
(comme Tâche 2.4 l'a fait pour `SameComplexGroup`), mais
exclusivement derrière flag. Quand le flag est OFF, le
comportement est strictement identique au pré-3.2. Quand le flag
est ON, le validator s'applique **EN ADDITION** du legacy filter
(AND logique) — il ne le remplace pas (cf. spec : *"Ne pas
supprimer les anciens blockedAddressPatterns"*).

Conforme aux règles d'or :
- **1 — Ne JAMAIS casser le pipeline existant** : flag OFF =
  comportement identique. Legacy `blockedAddressPatterns`
  intact.
- **3 — Une tâche, un commit, une PR**.
- **5 — Tests dans le même commit que la production**.
- **7 — Étendre l'existant** : nouveau champ générique
  `blockedNeighborRegions` ajouté à DI (option 1 retenue par
  produit, cf. point ouvert Tâche 3.1). Aucun countryCode
  synthétique, aucune logique custom destination dans le
  pipeline.

## Décision architecture retenue

**Option 1 du point ouvert Tâche 3.1** :

```dart
class DestinationIntelligence {
  // ... champs existants
  final List<String> blockedNeighborRegions;
}
```

Champ générique, non-breaking (default `[]`). Renseigné par
destination dans les builders Dart (Tâche 1.2 pour Singapour,
futures destinations pour Bangkok/Tokyo/etc.). Aucune logique
custom Dubai/Singapour/HK dans le pipeline.

Pourquoi pas option 2 (`countryCode` synthétique `AE-DU` / `AE-AZ`) :
non standard ISO 3166, mélange pays/région, fragilise la
sémantique.

Pourquoi pas option 3 (co-existence indéfinie) : objectif Phase 3
est de sortir du hardcoding ville par ville. Co-existence ici =
**transitoire** (le legacy reste actif pour éviter régression,
mais le validator armed prendra le relais quand confiance
multi-destinations sera établie).

## Fichiers lus avant modification

- `lib/models/destination_intelligence.dart` (modèle Tâche 1.1)
- `lib/data/destinations/singapore.dart` (données Tâche 1.2)
- `lib/services/scope_validator.dart` (Tâche 3.1)
- `lib/services/destination_intelligence_loader.dart` (loader
  async Tâche 1.3)
- `lib/config/feature_flags.dart`
- `lib/features/planning/services/places_first_pipeline.dart`
  (signature `selectVisitsDeterministic`, filter
  `_isAllowedFinalVisitCandidate`, caller production line ~6336)
- `lib/features/planning/data/metro_profile.dart` (legacy
  `blockedAddressPatterns` Singapour pour migration)
- `test/snapshots/generate_baseline.dart` (intégration
  dart-define `USE_DESTINATION_SCOPE`)

## Fichiers créés

- **`lib/data/destinations/destination_intelligence_registry.dart`**
  *(~80 lignes)* — `lookupLocalDestinationIntelligence(String?)`
  resolver sync (registry par destinationKey, pas de hardcode
  Singapour dans le pipeline).
- **`lib/services/destination_scope_rejection.dart`**
  *(~75 lignes)* — class immutable `DestinationScopeRejection`
  (journal pour tests + log pipeline). Mirror du pattern Tâche
  2.4 `SameComplexRejection`.
- **`test/features/planning/services/destination_scope_dedup_test.dart`**
  *(~315 lignes)* — 11 tests d'intégration en 4 groupes.
- **`docs/migrations/phase3_task3_2.md`** *(ce document)*.

## Fichiers modifiés

- **`lib/models/destination_intelligence.dart`** —
    * nouveau champ `final List<String> blockedNeighborRegions`
      (default `const []` non-breaking)
    * `validate()` étendu : entrées non vides, pas de doublons
      après normalisation
    * `toJson()` ajoute `blocked_neighbor_regions`
    * `fromJson()` fallback `[]` si clé absente (backward-compat)
- **`lib/data/destinations/singapore.dart`** —
    * `blockedNeighborRegions: [johor bahru, johor, ksl city,
      komtar, jbcc, batam, bintan, lagoi, tanjung pinang, kepri]`
    * Migration directe depuis `_singaporeMetro.blockedAddressPatterns`
      (legacy), excluant les country names déjà couverts par
      `blockedCountryCodes` (`MY`, `ID`).
- **`lib/services/scope_validator.dart`** —
    * nouvelle étape 2 entre countryCode et country hints :
      check substring de `address`+`name` contre
      `di.blockedNeighborRegions`
    * reject `blockedNeighborRegion` MEDIUM
    * sauvegarde toute la logique précédente (countryCode HIGH,
      hints MEDIUM, default LOW)
- **`lib/features/planning/services/places_first_pipeline.dart`** —
    * 4 nouveaux imports (registry DI sync, modèle DI, rejection
      class, validator)
    * signature `selectVisitsDeterministic` : 3 paramètres
      optionnels (`useDestinationScope = false`,
      `destinationIntelligence`, `destinationScopeRejectionsOut`)
    * `destinationScopeActive` flag effectif court-circuité
    * bloc dans la boucle `filteredClusters.map` : après le
      `_isAllowedFinalVisitCandidate` legacy, appelle
      `validatePlaceInScope` si `destinationScopeActive`.
      Si reject : log `[places_destination_scope_reject]`,
      ajoute au journal, incrémente le finalGateCount avec
      `destination_scope_<reason>`.
    * caller production line ~6336 : appelle
      `lookupLocalDestinationIntelligence(trip.destination)` +
      passe les paramètres flag-aware.
- **`test/snapshots/generate_baseline.dart`** — pareil que le
  caller pipeline (flag-aware + registry lookup).
- Tests modèle DI / Singapour mis à jour avec sections dédiées
  `blockedNeighborRegions`.

## Point exact d'intégration pipeline

Dans `selectVisitsDeterministic`, à l'intérieur du loop
`filteredClusters.map((cluster) { ... for (final entry in
cluster.pool.entries) { ... } })` — **après** l'appel à
`_isAllowedFinalVisitCandidate` (filter legacy) et **avant**
l'insertion dans `newPool` :

```dart
final reason = _isAllowedFinalVisitCandidate(...);
if (reason == null) {
  // Phase 3 / Tâche 3.2 — scope validation (flag-gated)
  if (destinationScopeActive) {
    final scopeResult = validatePlaceInScope(
      ScopeValidationPlace(
        name: candidate.name,
        address: candidate.address,
        countryCode: null,  // NearbyCandidate n'a pas de field
        lat: candidate.latitude,
        lng: candidate.longitude,
      ),
      destinationIntelligence,
    );
    if (!scopeResult.isInScope) {
      // log + reject + continue
    }
  }
  newPool[entry.key] = entry.value;
  continue;
}
// ... reason != null → legacy reject
```

**Comportement** : un candidat doit passer **les deux** filtres
(legacy ET scope) pour entrer dans le pool. AND logique strict.
Le legacy reste la première ligne ; le scope est une couche
défensive supplémentaire pour les destinations sans
MetroProfile curé ou avec MetroProfile incomplet.

## Comportement flag OFF

Strictement identique au pré-3.2 :
- `destinationScopeActive = false` (court-circuit total)
- Aucun appel à `validatePlaceInScope`
- Aucun log `[places_destination_scope_reject]`
- Aucun entry dans `destinationScopeRejectionsOut`
- Legacy `blockedAddressPatterns` continue de filtrer comme
  avant (Singapour → Johor/Bintan/Batam etc. bloqués)
- Comportement strictement identique au commit pré-3.2

**Vérifié par 3 tests dédiés** (groupe "Flag OFF — comportement
strictement inchangé") :
- Explicit OFF + DI Singapour → aucun rejet scope
- Defaults (aucun param) → strict OFF
- Flag ON sans DI → court-circuit sécurité, no-op

## Comportement flag ON

Active la dédup scope uniquement quand `destinationIntelligence
!= null`. Pour les destinations non encore dans la registry
sync (Bangkok, Tokyo, Paris, etc.) → court-circuit, no-op
(comportement identique au flag OFF).

Logique :
1. Candidat passe le legacy `_isAllowedFinalVisitCandidate`
2. Le validator est appelé via `validatePlaceInScope`
3. Si validator reject :
    - **journal** : append à `destinationScopeRejectionsOut`
      (si non null)
    - **log** : `[places_destination_scope_reject]` avec
      name + address + reason + confidence + evidence
    - **counter** : `finalGateCounts['destination_scope_<reason>']++`
    - **continue** (candidat exclu du pool)
4. Si validator accept : candidat entre dans `newPool`.

## Caractéristique importante : convergence des 2 filtres

**Observation snapshot baseline** : en flag ON sur Singapour
baseline, **0 log `[places_destination_scope_reject]` observé**.
Pourquoi ?

Les coordonnées des clusters Singapour matchent le Singapore
MetroProfile (via `getMetroProfileForCluster`). Donc le legacy
`blockedAddressPatterns` est actif avec les patterns Singapour
complets. Tout candidat Johor/Bintan/Batam est rejeté par le
**legacy** avant que le scope ne soit invoqué.

Le résultat de flag ON sur Singapour = celui de flag OFF, à la
variation Google Places près.

**C'est le comportement souhaité pour cette tâche** :
- ✅ Aucune régression (legacy intact + scope additif)
- ✅ Scope **armed** mais dormant en pratique sur Singapour
  (legacy fait le job)
- ✅ Scope ACTIF sur destinations sans MetroProfile curé : si
  une destination future (Bangkok par exemple) renseigne
  `blockedNeighborRegions` mais n'a pas de
  `blockedAddressPatterns` dans son MetroProfile, le scope
  fait le travail seul

Migration progressive complète prévue plus tard :
1. Phase 3.3 : tests cross-destinations
2. Validation multi-destinations en production
3. Quand confiance établie : retirer le legacy
   `blockedAddressPatterns` (hors scope 3.2)

## Tests ajoutés — 40 tests / 7 fichiers

### Modèle DI (8 nouveaux tests dans `destination_intelligence_test.dart`)
- Default vide quand non renseigné
- Liste validée si entrées non vides + sans doublons
- Entrée vide après trim rejetée
- Doublon après normalisation lowercase rejeté
- Doublon via whitespace rejeté
- Round-trip JSON conserve les valeurs
- JSON sans la clé → fallback liste vide (backward-compat)
- JSON avec clé non-liste → fallback liste vide

### Données Singapour (8 nouveaux tests dans
`singapore_destination_intelligence_test.dart`)
- Liste non vide
- Contient indices MY side (johor bahru, ksl city, komtar, jbcc, johor)
- Contient indices ID side (batam, bintan, lagoi, tanjung pinang, kepri)
- Au moins 10 entrées
- Aucune entrée vide après trim
- Aucun doublon après normalisation
- Pas de country names (déjà dans blockedCountryCodes)
- DI reste valide avec le nouveau champ

### Scope validator (13 nouveaux tests dans `scope_validator_test.dart`)
- 7 tests `blockedNeighborRegions — DI driven`
  (Singapour avec regions explicites)
- 5 tests `Dubai DI avec blockedNeighborRegions
  (résolution 3.1)` (Abu Dhabi/Sharjah/Ajman rejetés sans
  logique custom)
- 1 test `countryCode explicite prime sur blockedNeighborRegions`

### Intégration pipeline (11 tests dans
`destination_scope_dedup_test.dart`)

**1. Flag OFF — comportement strictement inchangé** (3 tests)
- Flag OFF + DI Singapour → aucun rejet scope
- Defaults (sans aucun param) → strict OFF
- Flag ON sans DI → court-circuit sécurité, no-op

**2. Flag ON — Singapour bloque hors scope** (4 tests)
- Address "Johor Bahru, Malaysia" → rejet
- Address "Batam, Indonesia" → rejet
- Address "Tanjung Pinang, Kepri" → rejet
- Address "Marina Bay, Singapore" → accepté

**3. Flag ON — Dubai DI avec blockedNeighborRegions** (1 test)
- Address "Abu Dhabi" rejeté SANS logique custom pipeline

**4. Logging et reason structure** (3 tests)
- `pipelineReason` format `destination_scope_<reason_snake_case>`

## Snapshot Singapour

### A. Flag OFF (canonical state, commit final)

```
flutter test test/snapshots/generate_baseline.dart
  → overall 81.46 / 18 visites / coverage 100%
  → 0 log [places_destination_scope_reject]
  → comparator self-check : PASS
```

### B. Flag ON via dart-define

```
flutter test --dart-define=USE_DESTINATION_SCOPE=true \
  test/snapshots/generate_baseline.dart
  → overall 81.46 / 18 visites / coverage 100%
  → 0 log [places_destination_scope_reject]
    (legacy filter intercept déjà)
  → comparator self-check : PASS
```

**Différences observées** : aucune. Le legacy
`blockedAddressPatterns` filtre tous les candidats hors-scope
avant que le scope validator ne s'exécute (cf. section
"Convergence" ci-dessus).

C'est le résultat IDÉAL pour une migration progressive sans
régression :
- Scope wiring complet, testable, observable
- Aucun effet négatif sur le baseline
- Couche défensive prête pour destinations futures sans
  MetroProfile curé

## Limites connues

1. **Dépendance au cluster MetroProfile** : tant que le legacy
   `blockedAddressPatterns` reste actif via MetroProfile, le
   scope est dormant en pratique sur Singapour. Le retrait du
   legacy nécessitera validation multi-destinations (hors
   scope 3.2).
2. **Registry sync local** : ne couvre que Singapour. Bangkok,
   Tokyo, Paris, HK, Dubai, etc. ont `blockedNeighborRegions=[]`
   par défaut → scope inactif pour ces destinations. Extension
   future = ajouter ces destinations à la registry + renseigner
   leurs DI.
3. **Loader async non câblé** : le pipeline reste sync.
   `DestinationIntelligenceLoader` (Tâche 1.3) avec ses
   capacités async (Supabase remote, fallback graceful) n'est
   pas branché. Migration future possible quand un refactor
   async du pipeline sera fait.

## Ce qui n'est volontairement PAS fait

- ❌ Suppression des `blockedAddressPatterns` legacy
- ❌ Activation par défaut du flag `useDestinationScope`
- ❌ Extension de la registry à d'autres destinations
- ❌ Câblage du loader async
- ❌ Tests cross-destinations runtime (Tâche 3.3)
- ❌ Création de `DayTemplate` (Phase 4)
- ❌ Logique custom Singapour/Dubai/HK dans le pipeline

## Confirmation comportement par défaut inchangé

- ✅ `useDestinationScope` reste **OFF par défaut** dans
  `FeatureFlags` (aucune modification).
- ✅ Caller production lit `FeatureFlags.fromEnvironment()` →
  OFF sans `--dart-define`.
- ✅ Default `selectVisitsDeterministic` :
  `useDestinationScope = false`, `destinationIntelligence =
  null` → `destinationScopeActive == false` → court-circuit
  total.
- ✅ 171 tests pipeline pré-existants (places_first_pipeline +
  day_builder + same_complex_dedup) restent verts inchangés.
- ✅ Snapshot baseline OFF cohérent (overall 81.46, 18 visites,
  100% coverage).
- ✅ `grep -rn "places_destination_scope_reject" lib/` n'apparaît
  pas hors du fichier pipeline (où il est gardé par le flag).

## Résultats validation

```
flutter analyze
  35 issues info préexistants (Tâche 0.1, inchangés)
  0 nouveau warning/error.

flutter test
  818 tests verts (778 Tâche 3.1 + 40 nouveaux Tâche 3.2 :
    +8 modèle DI
    +8 données Singapour
    +13 scope_validator (regions + Dubai résolu)
    +11 intégration pipeline)

flutter test test/snapshots/generate_baseline.dart   (OFF)
  → overall 81.46 / 18 visites / coverage 100%
  → 0 log [places_destination_scope_reject]
  → comparator self-check : PASS

flutter test --dart-define=USE_DESTINATION_SCOPE=true \
  test/snapshots/generate_baseline.dart   (ON)
  → overall 81.46 / 18 visites / coverage 100%
  → 0 log [places_destination_scope_reject] (legacy intercept)
  → comparator self-check : PASS
```

## Commande

```bash
# Tests intégration uniquement
flutter test test/features/planning/services/destination_scope_dedup_test.dart

# Tests services + données
flutter test test/services/scope_validator_test.dart
flutter test test/data/destinations/singapore_destination_intelligence_test.dart
flutter test test/models/destination_intelligence_test.dart

# Suite complète
flutter test

# Snapshot baseline (flag OFF par défaut)
flutter test test/snapshots/generate_baseline.dart
flutter test test/snapshots/compare_snapshot.dart

# Snapshot baseline avec flag ON
flutter test --dart-define=USE_DESTINATION_SCOPE=true \
  test/snapshots/generate_baseline.dart
```

## Résolution du point ouvert Tâche 3.1

Le point ouvert "Dubai et régions internes AE" signalé en Tâche
3.1 est **résolu** par `blockedNeighborRegions` :

| Concern Tâche 3.1 | Status 3.2 |
|-------------------|------------|
| `AE` allowed, Abu Dhabi à bloquer | ✅ Bloquer via `blockedNeighborRegions: ['abu dhabi', ...]` |
| Pas de countryCode synthétique | ✅ Aucun code synthétique introduit |
| Pas de logique custom Dubai | ✅ Aucune logique custom dans pipeline / validator |
| Abstraction générique | ✅ Champ `blockedNeighborRegions` réutilisable pour Singapour, HK, etc. |

Test dédié `Dubai DI avec blockedNeighborRegions (résolution 3.1)`
vérifie ce comportement avec un DI Dubai fictif.

## Prochaine étape : Tâche 3.3

Tests cross-destinations. Étendre la registry à 2-3 destinations
supplémentaires (Bangkok / Tokyo / Hong Kong / Paris / Rome /
Dubai). Mesurer l'impact du scope ON sur chacune. Valider
qualitativement les substitutions.

Critère de release potentiel pour Tâche 3.4 (si elle existe) :
retrait du legacy `blockedAddressPatterns` après validation
multi-destinations sur ≥ 3 villes.
