# Phase 2 / Tâche 2.2 — Données initiales Singapour `SameComplexGroup`

## Objectif

Lister les principaux complexes touristiques de Singapour sous
forme de données Dart locales — par analogie avec la Tâche 1.2
(`buildSingaporeDestinationIntelligence()`). Ces données
serviront ensuite au matcher (Tâche 2.3) puis au sélecteur
déterministe (Tâche 2.4).

**Tâche purement de données + tests.** 0 fichier de production
planning modifié. Le flag `useSameComplexDedup` reste OFF et
n'est consommé nulle part.

Conforme aux règles d'or :
- **1 — Ne JAMAIS casser le pipeline existant** : 0 fichier de
  production modifié.
- **3 — Une tâche, un commit, une PR**.
- **5 — Tests dans le même commit que la production**.
- **7 — Étendre l'existant** : le builder utilise uniquement le
  modèle `SameComplexGroup` (Tâche 2.1) sans créer de structure
  parallèle.

## Fichiers créés

- **`lib/data/complexes/singapore_complexes.dart`** *(~140 lignes)*
  — fonction `buildSingaporeSameComplexGroups()` retournant la
  liste const des 6 groupes Singapour.
- **`test/data/complexes/singapore_complexes_test.dart`** *(~280 lignes)*
  — **31 tests** en 7 groupes. Aucune dépendance réseau / Supabase
  / framework de mock.
- **`docs/migrations/phase2_task2_2.md`** *(ce document)*.

## Fichiers de production non modifiés

- `lib/features/planning/services/places_first_pipeline.dart` intact
- `lib/features/planning/services/day_builder.dart` intact
- `lib/models/same_complex_group.dart` intact (Tâche 2.1)
- `lib/config/feature_flags.dart` intact (`useSameComplexDedup`
  reste OFF, non consommé)
- `supabase/sql/same_complex_groups.sql` intact (pas de seed SQL
  ajouté en Tâche 2.2 — cf. section "Seed SQL" ci-dessous)

## 6 groupes créés

| complex_key | aliases | maxPerDay | maxPerTrip | priority |
|-------------|---------|-----------|------------|----------|
| `sentosa` | 9 | 1 | 2 | 5 |
| `gardens_by_the_bay` | 6 | 1 | 2 | 5 |
| `marina_bay_sands` | 5 | 1 | 2 | 5 |
| `chinatown_heritage` | 5 | **2** | **3** | 4 |
| `clarke_quay_riverside` | 3 | 1 | 2 | 3 |
| `orchard_shopping` | 5 | 1 | 2 | 3 |

Total : **6 groupes / 33 aliases / 0 placeIds**.

### Aliases par groupe

**`sentosa`** (île-resort iconique) :
- Sentosa Island
- Universal Studios Singapore
- Resorts World Sentosa
- Madame Tussauds Singapore
- Singapore Oceanarium
- SkyLine Luge Sentosa
- Wings of Time
- Adventure Cove Waterpark
- S.E.A. Aquarium

**`gardens_by_the_bay`** (complexe horticole/architectural) :
- Gardens by the Bay
- Supertree Grove
- Flower Dome
- Cloud Forest
- OCBC Skyway
- Floral Fantasy

**`marina_bay_sands`** (complexe hôtel/casino/observation) :
- Marina Bay Sands
- SkyPark Observation Deck
- ArtScience Museum
- Spectra Light Show
- The Shoppes at Marina Bay Sands

**`chinatown_heritage`** (quartier patrimonial) :
- Buddha Tooth Relic Temple
- Chinatown Heritage Centre
- Sri Mariamman Temple
- Pagoda Street
- Chinatown Street Market

**`clarke_quay_riverside`** (vie nocturne / quais) :
- Clarke Quay
- Boat Quay
- Robertson Quay

**`orchard_shopping`** (corridor commercial) :
- Orchard Road
- ION Orchard
- Ngee Ann City
- Takashimaya
- Paragon

## Choix `max_per_day` / `max_per_trip` / `priority`

Trois clusters de paramètres produit, justifiés par la sémantique
du complexe :

1. **Iconiques absolus** (`sentosa`, `gardens_by_the_bay`,
   `marina_bay_sands`) — `1/2/priority 5`. Un seul slot par
   journée pour ne pas saturer ; retour autorisé sur le voyage
   (ex: Sentosa peut mériter 2 visites distantes pour
   `Universal Studios` puis `Wings of Time`).
2. **Quartier patrimonial** (`chinatown_heritage`) —
   `2/3/priority 4`. Assouplissement : Chinatown peut
   légitimement accueillir plusieurs petits lieux dans la même
   journée (temple + heritage centre + street market sont
   contigus à pied). Sans ce relâchement, le sélecteur perdrait
   de la richesse là où elle est attendue.
3. **Thèmes secondaires** (`clarke_quay_riverside`,
   `orchard_shopping`) — `1/2/priority 3`. Pas iconiques mais
   structurants ; cap conservateur, priority basse pour ne pas
   éclipser les iconiques quand l'algorithme aura un choix.

## Pourquoi `placeIds` est vide ?

Spec Tâche 2.2 :
> *"Pour cette tâche, placeIds peut rester vide. Ne cherche pas
> les Google Place IDs maintenant. Ne fais aucun appel réseau.
> La Tâche 2.3 utilisera d'abord le matching par alias."*

Raisons :
- Aucun appel réseau autorisé dans cette tâche.
- Le matcher Tâche 2.3 fonctionnera d'abord par alias normalisés
  (qui couvrent déjà les variantes Google Places fréquentes :
  ex. `Universal Studios Singapore` est le nom Google standard).
- Une enrichissement futur des `placeIds` pourra être effectué
  une fois en production via un script offline, sans changer la
  structure du modèle.

## Seed SQL

**Pas de seed SQL ajouté dans cette tâche.**

Justification :
- La spec autorise explicitement : *"Option préférée : fichier
  Dart local uniquement ; seed SQL éventuel plus tard quand le
  loader des complexes existera."*
- Aucun loader Supabase de complexes n'existe encore (relèvera
  de Tâche 2.3 + et probablement plus tard que la version Dart).
- Ajouter un seed SQL maintenant complexifierait inutilement la
  tâche et risquerait de désynchroniser avec la liste Dart.

Le fichier `supabase/sql/same_complex_groups.sql` (Tâche 2.1)
reste la migration de référence pour la création de la table.

## Tests — 31 tests / 7 groupes

### 1. Validation globale (6 tests)
- Liste non vide
- Chaque groupe passe `validate()` sans erreur
- `destinationKey == 'singapore'` sur tous les groupes
- Caps cohérents (maxPerDay ≥ 1, maxPerTrip ≥ maxPerDay,
  priority ∈ [1, 5])
- `aliases` non vide pour chaque groupe
- `placeIds` vides en Tâche 2.2 (conformité spec)

### 2. Présence des 6 complex_keys (2 tests)
- Au minimum les 6 complex_keys obligatoires
- Aucun complexKey dupliqué

### 3. Aliases obligatoires par groupe (6 tests)
- Un test par groupe vérifiant 2-3 aliases minimaux requis
- Utilise `matchesAlias` pour valider la normalisation conjointe

### 4. Caps recommandés par groupe (6 tests)
- Vérifie `maxPerDay/maxPerTrip/priority` pour chaque groupe
- Sentinel particulier sur `chinatown_heritage` (2/3/4)

### 5. matchesAlias — robustesse (8 tests)
- UPPERCASE / lowercase
- Ponctuation différente (`Sentosa-Island`)
- Whitespace multiple (`  S.E.A.   Aquarium  `)
- Alias inconnu (`Eiffel Tower`) ne matche aucun groupe
- Alias d'un autre groupe ne matche pas (cross-group check)

### 6. Pas de doublons d'aliases (2 tests)
- Aucun alias normalisé dupliqué intra-groupe (déjà couvert par
  `validate()` Tâche 2.1, mais répliqué ici par robustesse)
- Aucun alias normalisé partagé entre groupes (invariant fort de
  la base : un même `Cloud Forest` ne peut pas appartenir à 2
  groupes simultanément)

### 7. Round-trip JSON par groupe (1 test)
- Pour chaque groupe : `toJson()` → `fromJson()` préserve tous
  les champs et `validate()` reste vide.

## Ce qui n'est volontairement PAS fait

- ❌ Matcher (`complex_matcher.dart`) — Tâche 2.3
- ❌ Branchement sélecteur déterministe — Tâche 2.4
- ❌ Consommation du flag `useSameComplexDedup`
- ❌ Modification de `places_first_pipeline.dart`
- ❌ Modification de `same_complex_group.dart`
- ❌ Enrichissement `placeIds` via appel Google Places
- ❌ Seed SQL Supabase
- ❌ Migration `DayTemplate` (Phase 4)
- ❌ Suppression d'ancien code

## Confirmation aucun branchement runtime

- ✅ `grep -rn "singapore_complexes\|buildSingaporeSameComplexGroups"
  lib/features/` → **aucune référence** dans les fichiers de
  production planning.
- ✅ `grep -rn "useSameComplexDedup" lib/` → seule occurrence
  dans `lib/config/feature_flags.dart` (déclaration de la
  constante, pas de consommation).
- ✅ Le test 2.2 importe uniquement :
  - `package:flutter_test/flutter_test.dart`
  - `package:voyage/data/complexes/singapore_complexes.dart`
  - `package:voyage/models/same_complex_group.dart`

## Résultats validation

```
flutter analyze
  35 issues found (info préexistants Tâche 0.1, inchangés)
  → lib/data/complexes/singapore_complexes.dart     : No issues found
  → test/data/complexes/singapore_complexes_test.dart : No issues found
  0 warning, 0 error sur les nouveaux fichiers

flutter test
  684 tests verts (653 Tâche 2.1 + 31 nouveaux Tâche 2.2)

flutter test test/snapshots/generate_baseline.dart
  1 test passé, baseline JSON régénéré
  Overall score : 81.07 / 19 visites / coverage 100%
  Variation Google Places attendue (cf. Tâche 0.1) — pas due à
  cette tâche, qui ne branche rien au pipeline.

flutter test test/snapshots/compare_snapshot.dart
  16 tests passés (1 self-check + 15 fixtures)
  Verdict self-check Singapour : PASS
```

## Commande

```bash
# Test données uniquement
flutter test test/data/complexes/singapore_complexes_test.dart

# Suite complète
flutter test
flutter test test/snapshots/generate_baseline.dart
flutter test test/snapshots/compare_snapshot.dart
```

## Prochaine étape : Tâche 2.3 — Complex matcher

La suite logique est **Tâche 2.3 — `complex_matcher.dart`** : la
logique de matching d'un candidat (place_id, nom) contre la
liste des `SameComplexGroup`. Stratégie de matching attendue :

1. **placeId exact** (case-sensitive après trim) ;
2. **alias exact normalisé** (utilise `normalizeComplexText` de
   Tâche 2.1) ;
3. **alias fuzzy** (similarité > 0.85 via Levenshtein ou
   équivalent) — c'est le vrai morceau intéressant de Tâche 2.3.

Le matcher restera dormant jusqu'en Tâche 2.4 où il sera branché
au sélecteur déterministe derrière le flag `useSameComplexDedup`.
