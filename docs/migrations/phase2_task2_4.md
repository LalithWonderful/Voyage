# Phase 2 / Tâche 2.4 — Intégration `SameComplexGroup` dans le sélecteur déterministe (flag-gated)

## Objectif

Première tâche qui **touche au pipeline production**, mais
exclusivement derrière le flag `useSameComplexDedup` (OFF par
défaut). Quand le flag est OFF, le comportement est **strictement
identique** au pré-2.4. Quand le flag est ON, le sélecteur
déterministe limite le nombre de visites appartenant au même
complexe touristique par jour (`maxPerDay`) et par voyage
(`maxPerTrip`).

Conforme aux règles d'or :
- **1 — Ne JAMAIS casser le pipeline existant** : flag OFF =
  comportement identique. Tests dédiés vérifient.
- **3 — Une tâche, un commit, une PR**.
- **5 — Tests dans le même commit que la production**.
- **7 — Étendre l'existant** : pas de nouveau wrapper Place, pas
  de refactor du sélecteur — uniquement des paramètres optionnels
  + 1 bloc filter + 1 bloc mirror + 1 bloc incrément.

## Fichiers lus avant modification

- `lib/features/planning/services/places_first_pipeline.dart`
  (signature `selectVisitsDeterministic`, boucle slot, mirror
  diagnostic, caller production)
- `lib/features/planning/services/day_builder.dart`
  (`isMetroQualifiedCandidate` pour comprendre l'interaction
  avec le quality_floor V8.28f)
- `lib/features/planning/services/places_nearby_service.dart`
  (`NearbyCandidate`)
- `lib/features/planning/data/destination_blueprints.dart`
  (`blueprintMustSeeMarker`, `getBlueprintForDestination`,
  `_normalizeBlueprintKey`)
- `lib/features/trips/models/trip_model.dart` (`Trip` minimal pour
  les tests d'intégration)
- `lib/config/feature_flags.dart` (pattern flag-from-environment)
- `lib/models/same_complex_group.dart`
- `lib/data/complexes/singapore_complexes.dart`
- `lib/services/complex_matcher.dart` (`matchComplexDetailed`,
  `matchComplex`)
- `test/features/planning/services/day_builder_test.dart`
  (pattern fixture Trip + NearbyCandidate pour les tests)
- `test/snapshots/generate_baseline.dart` (intégration
  dart-define USE_SAME_COMPLEX_DEDUP)

## Fichiers créés

- **`lib/data/complexes/complex_registry.dart`** *(~55 lignes)* —
  resolver `loadLocalComplexGroupsForDestination(String? destination)`
  retournant la liste connue (aujourd'hui Singapour) ou `[]` pour
  toute autre destination.
- **`lib/services/same_complex_rejection.dart`** *(~70 lignes)* —
  classe immutable `SameComplexRejection` pour le journal de
  rejets, avec constantes `reasonCapDay` / `reasonCapTrip`.
- **`test/data/complexes/complex_registry_test.dart`** *(~60 lignes)*
  — 7 tests (aliases, casse, destinations inconnues, null/vide).
- **`test/features/planning/services/same_complex_dedup_test.dart`**
  *(~430 lignes)* — 10 tests d'intégration en 7 groupes.
- **`docs/migrations/phase2_task2_4.md`** *(ce document)*.

## Fichiers modifiés

- **`lib/features/planning/services/places_first_pipeline.dart`**
  — patch minimal :
    1. 4 nouveaux imports (registry, feature_flags, modèle,
       matcher, rejection).
    2. **Signature** `selectVisitsDeterministic` : 3 paramètres
       nommés optionnels ajoutés
       (`useSameComplexDedup = false`, `complexGroups = []`,
       `sameComplexRejectionsOut`). Default = comportement pré-2.4.
    3. **Flag effectif** `complexDedupActive = useSameComplexDedup
       && complexGroups.isNotEmpty` calculé une fois.
    4. **Compteurs** : `complexCountAcrossTrip` (trip-wide, init
       en haut), `complexCountThisDay` (init par jour, comme
       `wellnessCountThisDay`).
    5. **Filter** : nouveau bloc dans `baseCandidates.where` qui
       cap maxPerDay puis maxPerTrip, court-circuité quand
       `complexDedupActive == false`. Logge via `print` et
       remplit le journal optionnel.
    6. **Mirror diagnostic** : nouveau bloc symétrique dans la
       boucle de diagnostic (quand le slot n'a aucun candidat),
       incrémente `rejectSameComplexCap` qui apparaît dans la
       breakdown `[places_first_skip_visit]`.
    7. **Incrément** : après `out.add(...)`, incrémente les 2
       compteurs si le pick matche un groupe.
- **`lib/features/planning/services/places_first_pipeline.dart`**
  (caller line ~6336) — branche `FeatureFlags.fromEnvironment()`
  + registry au call site. Default OFF, activable via
  `--dart-define=USE_SAME_COMPLEX_DEDUP=true`.
- **`test/snapshots/generate_baseline.dart`** — pareil : lit
  `FeatureFlags.fromEnvironment()` + registry, pour exposer la
  variante flag ON.

## Point exact d'intégration

Dans `selectVisitsDeterministic`, **après** tous les caps
existants (wellness, events, iconic, …) et **avant** le `return
true` final du filter `baseCandidates`. Position choisie pour :
- ne pas affecter le scoring (qui s'applique sur `baseCandidates`
  après filter) ;
- court-circuiter les autres caps en cas de match complexe (un
  candidat qui aurait été iconic-capé l'est toujours en premier ;
  pas de chevauchement).

Le mirror diagnostique est dans la boucle de breakdown (utilisée
uniquement quand `baseCandidates.isEmpty`). N'a aucun effet
runtime — juste de la télémétrie.

## Comment le flag est passé

```dart
final featureFlags = FeatureFlags.fromEnvironment();
final complexGroupsForTrip =
    loadLocalComplexGroupsForDestination(trip.destination);
final visits = selectVisitsDeterministic(
  ...
  useSameComplexDedup: featureFlags.useSameComplexDedup,
  complexGroups: complexGroupsForTrip,
);
```

Le caller production lit l'environnement compile-time. Future
activation via override Supabase suit la même API (cf.
`FeatureFlags.applyOverrides`).

Tests d'intégration passent les paramètres directement (pas via
environment), pour isoler le comportement.

## Comportement flag OFF

Strictement identique au pré-2.4 :
- `complexDedupActive = false` (court-circuit total)
- aucun appel à `matchComplexDetailed` ni `matchComplex`
- aucune entrée dans `sameComplexRejectionsOut`
- aucun log `[places_complex_dedup_reject]`
- aucun incrément des compteurs same-complex
- breakdown `[places_first_skip_visit]` peut contenir
  `rejected_by_same_complex_cap:0` (toujours 0)

**Vérifié par 3 tests dédiés** (groupe "Flag OFF — comportement
inchangé") :
- explicit OFF + groupes présents → aucun rejet
- explicit OFF + groupes vides → aucun rejet
- defaults (aucun param flag) → aucun rejet

## Comportement flag ON

Active la dédup uniquement quand `complexGroups.isNotEmpty`.
Sinon court-circuit (cas destination sans groupes connus —
Bangkok, Tokyo, Paris, etc. en Phase 2).

Logique pour chaque candidat passant les caps existants :
1. Match via `matchComplexDetailed(name, placeId, groups)`.
2. Si match → lookup du `SameComplexGroup` correspondant.
3. Si `complexCountThisDay[key] >= group.maxPerDay` →
   `same_complex_cap_day`, return false.
4. Sinon si `complexCountAcrossTrip[key] >= group.maxPerTrip` →
   `same_complex_cap_trip`, return false.
5. Sinon → return true (candidat retenu pour scoring).

Après pick accepté :
6. Réutilise `matchComplex(name, placeId, groups)` pour obtenir
   le complexKey du pick.
7. `complexCountThisDay[key]++`, `complexCountAcrossTrip[key]++`.

## Compteurs jour/trip

| Compteur | Init | Reset | Scope |
|----------|------|-------|-------|
| `complexCountAcrossTrip` | top de fonction (1 fois) | jamais | tout le voyage |
| `complexCountThisDay` | dans `for (day in cluster.days)` | par nouveau jour | jour courant uniquement |

Cohérent avec le pattern existant `wellnessCountTripWide` /
`wellnessCountThisDay` (lignes 3725 et 3941 du pipeline).

## Raisons de rejet

| Constante | String | Cap source |
|-----------|--------|------------|
| `SameComplexRejection.reasonCapDay` | `same_complex_cap_day` | `maxPerDay` |
| `SameComplexRejection.reasonCapTrip` | `same_complex_cap_trip` | `maxPerTrip` |

Aussi visible dans la breakdown `[places_first_skip_visit]` via
`rejected_by_same_complex_cap` (compteur unique, pas séparé
day/trip — cohérent avec les autres caps comme
`rejected_by_wellness_cap`).

## Journal de rejet

`List<SameComplexRejection>? sameComplexRejectionsOut` — paramètre
**optionnel** passé par les tests ; production passe `null`.
Chaque rejet est appendé avec :
- `candidateTitle` (`NearbyCandidate.name`)
- `complexKey` (du groupe matché)
- `reason` (`reasonCapDay` ou `reasonCapTrip`)
- `dayDate` (jour courant)
- `currentCount` (avant rejet)
- `maxAllowed` (`maxPerDay` ou `maxPerTrip`)

Toujours doublé d'un `print` `[places_complex_dedup_reject]` pour
les observabilités runtime. Format :
```
[places_complex_dedup_reject] name="Singapore Oceanarium"
  complex=sentosa strategy=exactName reason=same_complex_cap_day
  day=2026-05-20 count=1/1
```

## Tests ajoutés — 17 tests / 2 fichiers

### `complex_registry_test.dart` (7 tests, 1 groupe)
- Singapore standard / avec country suffix / aliases
  (singapour/singapura/sg)
- Casse mixte (UPPERCASE, whitespace)
- Destinations inconnues → []
- Null / vide / whitespace → []
- Tous les groupes retournés passent `validate()`

### `same_complex_dedup_test.dart` (10 tests, 7 groupes)

**1. Flag OFF — comportement inchangé** (3 tests)
- Explicit OFF + groupes présents → aucun rejet, ≥ 2 picks
- Explicit OFF + groupes vides → aucun rejet
- Defaults (sans aucun param flag) → strict OFF

**2. Flag ON — limite maxPerDay** (1 test)
- sentosa.maxPerDay=1 : un seul pick Sentosa/jour, ≥ 1 rejet
  `cap_day` enregistré avec metadata complète

**3. Flag ON — limite maxPerTrip** (1 test)
- sentosa.maxPerTrip=2 : ≤ 2 picks Sentosa sur 3 jours, ≥ 1
  rejet `cap_trip` enregistré

**4. Flag ON — groupe relâché chinatown_heritage** (1 test)
- maxPerDay=2 accepté, 3e candidat rejeté `cap_day` avec
  `maxAllowed=2`

**5. Destination sans groupes connus** (1 test)
- complexGroups vide + flag ON → aucun crash, aucun rejet,
  picks normaux

**6. Candidats sans match complexe** (1 test)
- Lieux non reconnus (Random Museum, Eiffel Tower) ne sont
  jamais rejetés par la dédup

**7. Fuzzy + exact dans l'intégration** (2 tests)
- Cloud Forest + Flower Dome (vrais aliases Singapour) →
  rejet `gardens_by_the_bay` sur `cap_day`
- Sentosa Island + Universal Studio (typo, fuzzy) →
  rejet `sentosa` sur `cap_day`

## Snapshot Singapour

### A. Flag OFF (commit final, état canonique)

```
flutter test test/snapshots/generate_baseline.dart
  → overall 81.46 / 19 visites / coverage 100%
  → aucun log [places_complex_dedup_reject]
  → comparator self-check : PASS
```

Variation overall vs Tâche 2.3 (82.78) attribuable purement à
Google Places non-déterministe (cf. Tâche 0.1). Le code path
flag OFF est court-circuité, donc strictement inchangé.

### B. Flag ON via dart-define

```
flutter test --dart-define=USE_SAME_COMPLEX_DEDUP=true \
  test/snapshots/generate_baseline.dart
  → overall 79.15 / 19 visites / coverage 100%
  → log observable :
    [places_complex_dedup_reject] name="Singapore Oceanarium"
      complex=sentosa strategy=exactName
      reason=same_complex_cap_day day=2026-05-20 count=1/1
  → comparator self-check : PASS
```

**Différences observées** :
- 19 visites dans les deux cas → la dédup fait place à
  d'autres lieux (le sélecteur substitue automatiquement).
- Singapore Oceanarium (qui appartient au complexe `sentosa`,
  alias #5) bloquée car Sentosa déjà pris ce jour-là.
- Overall très proche (81.46 → 79.15, ~−2 pts) — variation
  dans la marge attendue de Google Places.

**Limite** : 1 seul rejet observé sur ce run baseline. Cela
montre que le pipeline Singapour pré-2.4 ne tombait que
rarement dans le cas "complexe sémantique cross-attractions".
Les bénéfices visibles dépendront des runs : sur certains
patterns Sentosa (Universal Studios + Resorts World + S.E.A.
Aquarium même jour), l'effet sera plus marqué.

## Confirmation comportement par défaut inchangé

- ✅ `useSameComplexDedup` reste OFF par défaut dans
  `FeatureFlags`.
- ✅ Caller production lit `FeatureFlags.fromEnvironment()` →
  par défaut OFF (aucun `--dart-define`).
- ✅ Default `selectVisitsDeterministic` : `useSameComplexDedup
  = false`, `complexGroups = const []` → `complexDedupActive ==
  false` → code path court-circuité.
- ✅ 161 tests pipeline pré-existants (places_first_pipeline_test
  + day_builder_test) restent verts inchangés.
- ✅ Snapshot baseline OFF reste cohérent (overall ~80, 19
  visites, 100% coverage).
- ✅ `grep -rn "places_complex_dedup_reject" lib/` n'apparaît
  jamais quand flag OFF.

## Ce qui n'est volontairement PAS fait

- ❌ Modification du scoring existant (qualité, distance,
  diversité, blueprint bonus) — strictement intact.
- ❌ Refactor du sélecteur — uniquement des ajouts isolés.
- ❌ Bypass d'autres caps (wellness, events, iconic) — la
  dédup complexe s'applique en plus, pas à la place.
- ❌ Activation par défaut du flag — reste OFF.
- ❌ Création de `DestinationScope` — Phase 3.
- ❌ Création de `DayTemplate` — Phase 4.
- ❌ Suppression d'ancien code.
- ❌ Ajout de dépendance externe.
- ❌ Modification de modèles UI / Trip / NearbyCandidate.

## Résultats validation

```
flutter analyze
  35 issues info préexistants (Tâche 0.1) — INCHANGÉ
  0 nouveau warning/error sur les nouveaux fichiers ou les
  patches du pipeline.

flutter test
  746 tests verts (729 Tâche 2.3 → +17 nouveaux : 7 registry
  + 10 integration)

flutter test test/snapshots/generate_baseline.dart
  Baseline OFF : overall 81.46 / 19 visites / coverage 100%
  Comparator self-check : PASS

flutter test --dart-define=USE_SAME_COMPLEX_DEDUP=true \
  test/snapshots/generate_baseline.dart
  Flag ON : overall 79.15 / 19 visites / coverage 100%
  Rejets observables [places_complex_dedup_reject]
  Comparator self-check : PASS
```

## Commande

```bash
# Tests intégration
flutter test test/features/planning/services/same_complex_dedup_test.dart
flutter test test/data/complexes/complex_registry_test.dart

# Suite complète
flutter test

# Snapshot baseline (flag OFF par défaut)
flutter test test/snapshots/generate_baseline.dart
flutter test test/snapshots/compare_snapshot.dart

# Snapshot baseline avec flag ON
flutter test --dart-define=USE_SAME_COMPLEX_DEDUP=true \
  test/snapshots/generate_baseline.dart
```

## Prochaine étape : Tâche 2.5

La Tâche 2.5 sera vraisemblablement la **validation finale Phase
2** ou l'extension des complexes à d'autres destinations
(Bangkok, Tokyo, Paris, …). À partir de Tâche 2.4, l'API est
stable : ajouter une destination consiste à :
1. créer `lib/data/complexes/<destination>_complexes.dart`
2. exposer `build<Destination>SameComplexGroups()`
3. enregistrer dans `complex_registry.dart`

Pas de modification du sélecteur nécessaire.
