# Phase 4 / Tâche 4.2 — Données Singapour `DayTemplate`

## Objectif

Poser les **données locales** des 8 templates de journée pour
Singapour. Par analogie avec :
- `buildSingaporeDestinationIntelligence()` (Tâche 1.2)
- `buildSingaporeSameComplexGroups()` (Tâche 2.2)

**Tâche purement de données + tests.** 0 fichier de production
planning modifié. Aucun matcher, aucun day builder template-first,
aucun branchement pipeline. Le flag `useDayTemplates` reste OFF et
n'est consommé nulle part. Les templates restent **données
dormantes** jusqu'aux tâches suivantes (4.3+ : assigner / builder).

Conforme aux règles d'or :
- **1 — Ne JAMAIS casser le pipeline existant** : 0 fichier de
  production planning modifié.
- **3 — Une tâche, un commit, une PR**.
- **5 — Tests dans le même commit que la production**.
- **7 — Étendre l'existant** : aucune nouvelle abstraction. Le
  fichier utilise exclusivement `DayTemplate` / `SlotSpec` /
  enums livrés en Tâche 4.1. Aucun import de
  `DestinationBlueprint` / `MetroProfile`.

## Confirmation du contrat listes vides (bf54187)

Le commit de renforcement `bf54187` (post-Tâche 4.1) verrouille
explicitement :
- `recommendedAnchorKeys` peut être vide
- `forbiddenComplexKeys` peut être vide
- les deux peuvent être vides simultanément
- round-trip JSON préserve les listes vides

**Templates Singapour qui exercent ce contrat** :
- `free_day` — `recommendedAnchorKeys: []`, `forbiddenComplexKeys: []`
- `arrival_day` — `forbiddenComplexKeys: []`

Tests dédiés vérifient que ces templates passent `validate()` ET
`validateAgainstDestination(buildSingaporeDestinationIntelligence())`.

## Fichiers créés

- **`lib/data/day_templates/singapore_templates.dart`**
  *(~290 lignes)* — `buildSingaporeDayTemplates()` retournant
  une liste `const` de 8 templates.
- **`test/data/day_templates/singapore_templates_test.dart`**
  *(~300 lignes)* — **27 tests** en 10 groupes.
- **`docs/migrations/phase4_task4_2.md`** *(ce document)*.

## Fichiers de production NON modifiés

- `lib/models/day_template.dart` intact (Tâche 4.1)
- `lib/data/destinations/singapore.dart` intact (Tâche 1.2 / 3.2)
- `lib/data/complexes/singapore_complexes.dart` intact (Tâche 2.2)
- `lib/features/planning/services/places_first_pipeline.dart` intact
- `lib/config/feature_flags.dart` intact (`useDayTemplates` OFF,
  non consommé)

## Les 8 templates créés

| # | templateKey | Zone | Intensité | Strategy repas | Anchors recom. | Complexes interdits | Slots | Flex |
|---|-------------|------|-----------|----------------|----------------|---------------------|-------|------|
| 1 | `arrival_day` | Orchard | light | mixed | 1 (Orchard Road) | — (vide) | 3 | 80 |
| 2 | `marina_bay_day` | Marina Bay | medium | mixed | 3 (Gardens by the Bay, Marina Bay Sands, Merlion Park) | sentosa | 4 | 60 |
| 3 | `chinatown_civic_day` | Chinatown | medium | **hawkerCenters** | 2 (Buddha Tooth Relic Temple, Chinatown) | sentosa, orchard_shopping | 4 | 65 |
| 4 | `sentosa_day` | Sentosa | **intense** | mixed | 1 (Sentosa Island) | gardens_by_the_bay, marina_bay_sands, orchard_shopping | 4 | 50 |
| 5 | `orchard_botanic_day` | Botanic Gardens | medium | mixed | 2 (Singapore Botanic Gardens, Orchard Road) | sentosa, marina_bay_sands | 4 | 65 |
| 6 | `little_india_kampong_day` | Kampong Glam | medium | **hawkerCenters** | 2 (Little India, Kampong Glam / Arab Street) | sentosa, marina_bay_sands | 4 | 70 |
| 7 | `free_day` | Marina Bay | light | mixed | **— (vide)** | **— (vide)** | 3 | **100** |
| 8 | `departure_day` | Orchard | light | mixed | 1 (Orchard Road) | sentosa | 3 | 90 |

**Total** : 8 templates / 29 slots / 12 anchors recommandés / 12
forbidden complex slots.

## Choix de zones

Toutes les zones primaires existent dans `buildSingaporeDestinationIntelligence().zones` :
- **Orchard** : arrival_day, departure_day — quartier transit /
  shopping, idéal pour journées allégées encadrant le voyage.
- **Marina Bay** : marina_bay_day, free_day — cœur waterfront
  iconique ; choisi pour free_day car le voyageur a accès à
  beaucoup de spots sans devoir s'engager.
- **Chinatown** : chinatown_civic_day — quartier patrimonial.
- **Sentosa** : sentosa_day — île resort.
- **Botanic Gardens** : orchard_botanic_day.
- **Kampong Glam** : little_india_kampong_day.

Cohérent avec les 10 zones Tâche 1.2.

## Choix d'intensité

Trois clusters :

1. **Light** (3 templates) : `arrival_day`, `free_day`,
   `departure_day`. Journées de transition / repos volontaire.
2. **Medium** (4 templates) : `marina_bay_day`,
   `chinatown_civic_day`, `orchard_botanic_day`,
   `little_india_kampong_day`. Default raisonnable pour la
   plupart des journées.
3. **Intense** (1 template) : `sentosa_day`. Journée chargée
   (anchor matin 3h + show soir) — alignée avec spec Tâche 4.1
   ("~5-6 slots, peu de temps tampon").

## Choix de mealStrategy

- **mixed** (6 templates) : default. Couvre l'absence de
  préférence forte.
- **hawkerCenters** (2 templates) : `chinatown_civic_day` et
  `little_india_kampong_day`. Justification : Singapour offre
  des hawker centres iconiques dans ces quartiers (Maxwell Food
  Centre, Tekka Centre, Lau Pa Sat) qui sont culturellement
  fondamentaux à l'expérience. Aligné avec les `experience
  Queries` du blueprint Singapour qui incluent ces hawker
  centres.

Pas de **fineDining** ni **zoneRestaurants** en Tâche 4.2 — ces
stratégies sont disponibles dans le modèle mais ne s'imposent
pas pour un voyage Singapour standard "Couple 800 €".

## Choix de forbiddenComplexKeys

Stratégie : empêcher l'intrusion d'un complexe iconique d'une
zone géographique distante quand le template cible une autre
zone.

| Template | forbidden | Justification |
|----------|-----------|---------------|
| arrival_day | — (vide) | Pas de zone iconique encore visitée à exclure |
| marina_bay_day | `sentosa` | Sentosa = autre île, 30+ min métro/taxi |
| chinatown_civic_day | `sentosa`, `orchard_shopping` | Compactage quartier patrimonial |
| sentosa_day | `gardens_by_the_bay`, `marina_bay_sands`, `orchard_shopping` | Journée dédiée à l'île |
| orchard_botanic_day | `sentosa`, `marina_bay_sands` | Recentrage parc + shopping |
| little_india_kampong_day | `sentosa`, `marina_bay_sands` | Compactage quartiers ethniques |
| free_day | — (vide) | Voyageur libre d'aller où il veut |
| departure_day | `sentosa` | Pas le temps pour Sentosa avant le vol |

Tous les `forbiddenComplexKeys` non-vides référencent des
`complexKey` qui existent dans `buildSingaporeSameComplexGroups()`
(Tâche 2.2). Vérifié par test.

## Slots — invariants

- Chaque template : **3 à 5 slots** (vérifié par test).
- Chaque slot a `slotKey` unique dans son template (vérifié).
- Au moins un template contient `ExpectedSlotType.anchor` :
  marina_bay_day, chinatown_civic_day, sentosa_day,
  orchard_botanic_day, little_india_kampong_day (5 templates).
- Au moins un template contient `ExpectedSlotType.meal` :
  tous sauf… en fait tous les 8 templates ont un slot meal.
- Au moins un template contient `ExpectedSlotType.freeTime` :
  arrival_day, orchard_botanic_day, free_day (3 templates).
- Heures au format **`HH:mm` 24h strict** (testé par
  `SlotSpec.validate`).

## Tests — 27 tests / 10 groupes

### 1. Liste globale (4 tests)
- Exactement 8 templates
- Tous ont `destinationKey == 'singapore'`
- Tous passent `validate()`
- Tous passent `validateAgainstDestination(buildSingaporeDI)`

### 2. Présence des 8 templateKey (2 tests)
- 8 keys obligatoires présents
- Aucun doublon

### 3. Références zones (1 test)
- Chaque `primaryZoneName` existe dans DI Singapour

### 4. Références anchors (2 tests)
- Chaque `recommendedAnchorKey` existe dans DI Singapour
- Listes vides acceptées (`free_day`)

### 5. Références complexes (2 tests)
- Chaque `forbiddenComplexKey` existe dans Singapour complexes
- Listes vides acceptées (`arrival_day`, `free_day`)

### 6. Slots invariants (6 tests)
- 3-5 slots par template
- Chaque slot valide (`SlotSpec.validate()`)
- `slotKey` uniques par template
- ≥ 1 template avec `ExpectedSlotType.anchor`
- ≥ 1 template avec `ExpectedSlotType.meal`
- ≥ 1 template avec `ExpectedSlotType.freeTime`

### 7. Intensité (3 tests)
- `sentosa_day` est intense
- Les 4 templates "medium" sont medium
- Les 3 templates "light" sont light

### 8. Round-trip JSON par template (1 test)
- Chaque template `toJson() → fromJson()` préserve les valeurs
  et reste valide vs DI

### 9. No duplicate templateKey (2 tests)
- Aucun doublon en exact match
- Aucun doublon après normalisation lowercase

### 10. Contrat listes vides bf54187 (4 tests)
- `free_day.recommendedAnchorKeys` vide
- `free_day.forbiddenComplexKeys` vide
- `free_day` reste valide (modèle + croisé DI)
- `free_day` round-trip JSON préserve la vacuité

## Ce qui n'est volontairement PAS fait

- ❌ Création de `DayThemeAssigner` (Tâche 4.3+)
- ❌ Création de `DayBuilder template-first` /
  `template_first_pipeline.dart` (Tâche 4.4+)
- ❌ Consommation du flag `FeatureFlags.useDayTemplates`
- ❌ Modification de `places_first_pipeline.dart`
- ❌ Modification du Day Builder greedy V8.20+ existant
- ❌ Seed SQL Singapour (option Dart-only, cohérent avec
  Tâche 2.2 / 4.1)
- ❌ Appel réseau / Supabase
- ❌ Extension à d'autres destinations (Bangkok, Tokyo, etc.)
- ❌ `mealStrategy: fineDining` ou `zoneRestaurants` (réservés
  pour profils Premium futurs)

## Confirmation aucun branchement runtime

- ✅ `grep -rn "singapore_templates\|buildSingaporeDayTemplates"
  lib/features/` → **aucune référence** dans les fichiers de
  production planning.
- ✅ `grep -rn "useDayTemplates" lib/` → seule occurrence dans
  `lib/config/feature_flags.dart` (déclaration, pas de
  consommation).
- ✅ Le test 4.2 importe uniquement :
  - `package:flutter_test/flutter_test.dart`
  - `package:voyage/data/complexes/singapore_complexes.dart`
  - `package:voyage/data/day_templates/singapore_templates.dart`
  - `package:voyage/data/destinations/singapore.dart`
  - `package:voyage/models/day_template.dart`

## Limites connues

1. **Granularité éditoriale fixe** : 8 templates pour un voyage
   8j classique. Pour un voyage plus long (15j+), il faudrait
   ajouter des variantes (`marina_bay_evening_only_day`,
   `sentosa_lite_day`, etc.).
2. **Anchors recommandés référencés par nom** (pas par clé
   technique). Ex : `'Singapore Botanic Gardens'` plutôt que
   `botanic_gardens_anchor`. Cohérent avec la doc Tâche 4.1 qui
   autorise les "références lisibles". Une migration future
   pourra introduire des clés techniques si besoin.
3. **Singapour-specific** : aucun template générique
   réutilisable cross-destinations. Bangkok / Tokyo / Paris
   nécessiteront leurs propres builders dédiés.
4. **Pas de slot `transfer` dans la majorité des templates** :
   uniquement dans `departure_day` (transfer_buffer). Les
   transferts intra-jour sont gérés par le futur day builder via
   les coords des candidats, pas par un slot explicite.

## Résultats validation

```
flutter analyze
  35 issues info préexistants (Tâche 0.1, inchangés)
  → lib/data/day_templates/singapore_templates.dart       : No issues found
  → test/data/day_templates/singapore_templates_test.dart : No issues found
  0 warning, 0 error sur les nouveaux fichiers

flutter test
  946 tests verts (919 Tâche 4.1 bf54187 + 27 nouveaux Tâche 4.2)

flutter test test/snapshots/generate_baseline.dart
  1 test passé, baseline JSON régénéré
  Overall score : 81.46 / 18 visites / coverage 100%
  Variation Google Places attendue — aucun rapport avec cette
  tâche, qui ne branche rien au pipeline.

flutter test test/snapshots/compare_snapshot.dart
  16 tests passés (1 self-check + 15 fixtures)
  Verdict self-check Singapour : PASS
```

## Commande

```bash
# Tests données uniquement
flutter test test/data/day_templates/singapore_templates_test.dart

# Suite complète
flutter test
flutter test test/snapshots/generate_baseline.dart
flutter test test/snapshots/compare_snapshot.dart
```

## Prochaine étape : Tâche 4.3

`DayThemeAssigner` — service pur qui assigne un `templateKey` à
chaque jour d'un voyage selon des règles (intensity du voyage,
nombre de jours, jour d'arrivée/départ, séquence de variétés
thématiques, complexité voyageur). Service **dormant** : posera
la logique d'attribution sans encore brancher de runtime.

À partir de la Tâche 4.4+, le `DayBuilder template-first`
consommera les templates assignés via le flag
`useDayTemplates`. Le vrai changement comportemental commencera
uniquement à ce moment.
