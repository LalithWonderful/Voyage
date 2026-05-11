# Phase 2 / Tâche 2.3 — Détecteur de complexe `ComplexMatcher`

## Objectif

Poser le **service de matching** d'un lieu candidat (par `placeId`
et/ou `name`) contre la liste des `SameComplexGroup` connus.
Service **pur, dormant**, sans dépendance réseau, sans
modification du modèle existant. Sera consommé en Tâche 2.4 par
le sélecteur déterministe derrière le flag `useSameComplexDedup`.

**Tâche purement service + tests.** 0 fichier de production
planning modifié. Le flag `useSameComplexDedup` reste OFF et
n'est consommé nulle part.

Conforme aux règles d'or :
- **1 — Ne JAMAIS casser le pipeline existant** : 0 fichier de
  production modifié.
- **3 — Une tâche, un commit, une PR**.
- **5 — Tests dans le même commit que la production**.
- **7 — Étendre l'existant** : signature à paramètres nommés au
  lieu de wrapper `Place` artificiel ; aucune dépendance externe.

## Fichiers créés

- **`lib/services/complex_matcher.dart`** *(~280 lignes)* —
  `matchComplex` + `matchComplexDetailed` + `normalizedStringSimilarity` +
  enum `ComplexMatchStrategy` + classe `ComplexMatchResult`.
- **`test/services/complex_matcher_test.dart`** *(~430 lignes)* —
  **45 tests** en 7 groupes. Aucune dépendance réseau / Supabase /
  framework de mock.
- **`docs/migrations/phase2_task2_3.md`** *(ce document)*.

## Fichiers de production non modifiés

- `lib/features/planning/services/places_first_pipeline.dart` intact
- `lib/features/planning/services/day_builder.dart` intact
- `lib/models/same_complex_group.dart` intact (Tâche 2.1)
- `lib/data/complexes/singapore_complexes.dart` intact (Tâche 2.2)
- `lib/config/feature_flags.dart` intact (`useSameComplexDedup`
  reste OFF, non consommé)
- `lib/features/planning/services/places_service.dart` intact
  (notamment `PlaceInfo` — pas de couplage introduit)

## Signature retenue

```dart
String? matchComplex({
  String? name,
  String? placeId,
  required List<SameComplexGroup> groups,
});

ComplexMatchResult? matchComplexDetailed({
  String? name,
  String? placeId,
  required List<SameComplexGroup> groups,
});
```

### Pourquoi ce design

La spec autorisait explicitement plusieurs variantes
(`Place place`, wrapper `ComplexMatchPlace`, paramètres nommés).
**Choix : paramètres nommés** — le plus simple et le moins
intrusif :

- Le projet possède `PlaceInfo`
  (`lib/features/planning/services/places_service.dart`) mais
  c'est un modèle riche (photos, reviews, opening hours…).
  Coupler le matcher à `PlaceInfo` introduirait une dépendance
  lourde pour 2 champs (`name`, `placeId`).
- Pas de wrapper `ComplexMatchPlace` créé non plus : un wrapper
  ad hoc ajouterait une indirection pour aucun gain.
- Le caller (Tâche 2.4) appellera trivialement
  `matchComplex(name: candidate.name, placeId: candidate.placeId,
  groups: …)` depuis n'importe quel modèle.

Cohérent avec règle d'or 7 (*"Étendre l'existant plutôt que
dupliquer"*) — on ne crée pas un faux `Place` global.

### Variante `matchComplexDetailed`

Retourne un `ComplexMatchResult` enrichi :
- `complexKey` — clé du groupe matché
- `strategy` — `placeId` / `exactName` / `fuzzyAlias`
- `matchedAlias` — alias normalisé qui a matché (`''` pour
  `placeId`)
- `similarity` — score réel (∈ [0, 1], `1.0` pour `placeId` et
  `exactName`)
- `priority` — priorité du groupe matché (snapshot)

Utile en Tâche 2.4 pour logger les rejets `same_complex_cap`
avec la raison exacte sans recalcul. `matchComplex` y délègue
puis ne renvoie que `complexKey`.

## Ordre de matching

```
1. placeId exact          (case-sensitive après trim)
2. name exact normalisé   (via normalizeComplexText)
3. fuzzy alias            (Levenshtein normalisée > 0.85)
```

Comportement :
- Dès qu'une étape produit un résultat, on retourne.
- `placeId` null/vide → étape 1 sautée, fall-through au `name`.
- `name` null/vide/ponctuation pure → étapes 2 et 3 sautées.
- Si `placeId` n'est pas vide mais sans match → on tente toujours
  le `name` (fall-through). Spec : *"Dès qu'un match est trouvé,
  retourner complexKey"* — implique fall-through si pas de match.

## Tie-break commun

Si plusieurs candidats valides à la même étape :

| Étape | Tri primaire | Tri secondaire | Tri tertiaire |
|-------|--------------|----------------|---------------|
| placeId | priority desc | complexKey asc | — |
| exactName | priority desc | complexKey asc | — |
| fuzzyAlias | **similarité desc** | priority desc | complexKey asc |

L'ordre lexicographique sur `complexKey` (asc) garantit la
**stabilité** : pour un même input, le matcher renvoie toujours
le même résultat indépendamment de l'ordre des `groups` passés.

## Seuil fuzzy

`> 0.85` **strict** (pas `>= 0.85`). Spec explicite. Validé par un
test dédié :
- `'aaaaaa'` (6) vs `'aaaaab'` (6) → distance 1, sim = 0.833 → **null** (< 0.85)
- `'aaaaaaa'` (7) vs `'aaaaaab'` (7) → distance 1, sim ≈ 0.857 → **match** (> 0.85)

Calibré pour :
- accepter une coquille / un `s` manquant (sim ≈ 0.94-0.96)
- rejeter un substring permissif (`Bay` → `Marina Bay Sands`,
  sim ≈ 0.19)

## Stratégie de fuzzy

`normalizedStringSimilarity(a, b)` exposée publiquement et
testée directement.

```
sim = 1 - levenshteinDistance(a, b) / max(len(a), len(b))
```

Plage `[0, 1]`. Implémentation Levenshtein **DP 2-lignes** (O(n
× m) temps, O(min(n, m)) mémoire). Aucune dépendance externe.

Conventions sur les vides :
- `('', '')` → `1.0` (deux vides identiques)
- `('', 'x')` ou `('x', '')` → `0.0`

Le matcher applique `normalizeComplexText` (Tâche 2.1) **avant**
d'appeler la similarité, donc les comparaisons sont
case-insensitive, sans accents et sans ponctuation.

## Exemples Singapour validés

| Input `name` | Résultat | Stratégie |
|--------------|----------|-----------|
| `Buddha Tooth Relic Temple` | `chinatown_heritage` | exactName |
| `Universal Studios Singapore` | `sentosa` | exactName |
| `sentosa island` | `sentosa` | exactName |
| `SENTOSA ISLAND` | `sentosa` | exactName |
| `Cloud Forest` | `gardens_by_the_bay` | exactName |
| `ArtScience Museum` | `marina_bay_sands` | exactName |
| `S.E.A. Aquarium` | `sentosa` | exactName |
| `Skyline Luge Sentosa` | `sentosa` | exactName (norm = `SkyLine`) |
| `Universal Studio Singapore` | `sentosa` | **fuzzyAlias** (≈ 0.96) |
| `Garden by the Bay` | `gardens_by_the_bay` | **fuzzyAlias** (≈ 0.94) |
| `Resort World Sentosa` | `sentosa` | **fuzzyAlias** (≈ 0.95) |
| `Eiffel Tower` | `null` | aucun |
| `Random Museum` | `null` | aucun |
| `Bay` | `null` | aucun (sim ≈ 0.19, rejeté) |

## Tests — 45 tests / 7 groupes

### 1. Match exact alias — Singapour (9 tests)
- Buddha Tooth Relic Temple → chinatown_heritage
- Universal Studios Singapore → sentosa
- Casse mixte (sentosa island / SENTOSA ISLAND)
- Cloud Forest → gardens_by_the_bay
- ArtScience Museum → marina_bay_sands
- S.E.A. Aquarium (ponctuation) → sentosa
- Eiffel Tower / Random Museum → null
- Stratégie reportée = exactName

### 2. Match placeId — groupes fictifs (9 tests)
- placeId exact → bon complexKey
- Whitespace avant/après accepté
- placeId inconnu → null
- Case-sensitive (chij_alpha_001 ≠ ChIJ_alpha_001)
- placeId partagé entre 2 groupes → priority la plus haute gagne
- Stratégie reportée = placeId
- placeId vide après trim → fall-through au name
- placeId fourni sans match + name non fourni → null
- placeId sans match + name avec match → fall-through OK

### 3. Fuzzy matching > 0.85 (8 tests)
- Universal Studio Singapore → sentosa (sim ≈ 0.96)
- Garden by the Bay → gardens_by_the_bay
- Resort World Sentosa → sentosa
- Skyline Luge Sentosa → exactName (pas fuzzy après normalisation)
- Random Museum → null
- Bay → null (substring permissif rejeté)
- Stratégie reportée = fuzzyAlias avec similarity > 0.85 et < 1.0
- **Seuil strict > 0.85** (vérifié avec aliases artisanaux)

### 4. Tie-break — priorité puis complexKey (4 tests)
- Exact match : priority desc gagne
- Exact match : priorités égales → complexKey asc (stable)
- Fuzzy match : meilleure similarité gagne quel que soit
  priority
- Fuzzy match : similarités égales → priority gagne, puis
  complexKey

### 5. Entrées null / vides (6 tests)
- name et placeId tous deux null → null
- name vide → null (sans placeId)
- name whitespace uniquement → null
- name uniquement ponctuation (normalisation vide) → null
- groups vide → null
- placeId vide + name matchant → fall-through OK

### 6. `normalizedStringSimilarity` (7 tests)
- Même string → 1.0
- Strings très proches (diff 1 char) → > 0.85
- Strings différentes → < 0.85
- Vide vs vide → 1.0 (convention)
- Vide vs non-vide → 0.0
- Symétrie : `sim(a, b) == sim(b, a)`
- Plage [0, 1] strictement respectée

### 7. Ordre des stratégies (2 tests)
- placeId match préempte tout match name
- exact match préempte fuzzy match (même priority moins haute)

## Ce qui n'est volontairement PAS fait

- ❌ Branchement matcher → `places_first_pipeline.dart` —
  Tâche 2.4
- ❌ Consommation du flag `useSameComplexDedup`
- ❌ Branchement sélecteur déterministe
- ❌ Caps `max_per_day` / `max_per_trip` (le matcher détecte
  l'appartenance ; appliquer les caps relève du sélecteur)
- ❌ Logging `same_complex_cap` rejections — Tâche 2.4
- ❌ Modification du modèle `SameComplexGroup`
- ❌ Modification des données Singapour
- ❌ Création de `DayTemplate` / `DestinationScope`
- ❌ Ajout de dépendance externe (Levenshtein implémentée
  en interne)
- ❌ Suppression d'ancien code

## Confirmation aucun branchement runtime

- ✅ `grep -rn "complex_matcher\|matchComplex" lib/features/` →
  **aucune référence** dans les fichiers de production planning.
- ✅ `grep -rn "useSameComplexDedup" lib/` → seule occurrence
  dans `lib/config/feature_flags.dart` (déclaration, pas de
  consommation).
- ✅ Le test 2.3 importe uniquement :
  - `package:flutter_test/flutter_test.dart`
  - `package:voyage/data/complexes/singapore_complexes.dart`
  - `package:voyage/models/same_complex_group.dart`
  - `package:voyage/services/complex_matcher.dart`

## Résultats validation

```
flutter analyze
  35 issues found (info préexistants Tâche 0.1, inchangés)
  → lib/services/complex_matcher.dart       : No issues found
  → test/services/complex_matcher_test.dart : No issues found
  0 warning, 0 error sur les nouveaux fichiers

flutter test
  729 tests verts (684 Tâche 2.2 + 45 nouveaux Tâche 2.3)

flutter test test/snapshots/generate_baseline.dart
  1 test passé, baseline JSON régénéré
  Overall score : 82.78 / 19 visites / coverage 100%
  Variation Google Places attendue (cf. Tâche 0.1) — pas due à
  cette tâche, qui ne branche rien au pipeline.

flutter test test/snapshots/compare_snapshot.dart
  16 tests passés (1 self-check + 15 fixtures)
  Verdict self-check Singapour : PASS
```

## Commande

```bash
# Test service uniquement
flutter test test/services/complex_matcher_test.dart

# Suite complète
flutter test
flutter test test/snapshots/generate_baseline.dart
flutter test test/snapshots/compare_snapshot.dart
```

## Prochaine étape : Tâche 2.4

La Tâche 2.4 sera l'**intégration au sélecteur déterministe**
derrière `useSameComplexDedup = true` :

- consommer `FeatureFlags.useSameComplexDedup` ;
- charger la liste des `SameComplexGroup` pour la destination
  courante (probablement `buildSingaporeSameComplexGroups()` en
  premier — extensible par destination via Tâche ultérieure ou
  loader Supabase) ;
- appeler `matchComplexDetailed` sur chaque candidat ;
- appliquer les caps `max_per_day` / `max_per_trip` du groupe
  matché ;
- journaliser les rejets via `same_complex_cap` (utiliser le
  `ComplexMatchResult.strategy` pour le diagnostic).

Le sélecteur déterministe (`places_first_pipeline.dart`) sera la
seule cible runtime modifiée en Tâche 2.4. Le matcher et les
données restent intacts.
