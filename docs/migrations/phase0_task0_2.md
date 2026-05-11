# Phase 0 / Tâche 0.2 — Module métriques qualité planning

## Objectif de la tâche

Créer un module pur de calcul des métriques qualité d'un planning
généré, indépendant du pipeline et sans dépendance réseau. Servira
de base aux phases ultérieures pour mesurer **objectivement** les
régressions / améliorations de toute refonte (comparaison contre
baseline Tâche 0.1).

## Fichiers lus avant de coder

- `lib/features/planning/models/activity_suggestion_model.dart` —
  modèle des slots produits par le pipeline. Champs disponibles :
  `dayDate`, `startTime`, `title`, `tag`, `kind`, `latitude`,
  `longitude`. **Pas de `placeId`**, **pas de discriminant
  visite/repas** sur `kind` (les deux sont `ActivityKind.main`).
- `lib/features/planning/models/trip_activity_model.dart` —
  `ActivityKind` = `{ main, logistic }`. Pas de `meal` kind.
- `lib/quality/` — dossier inexistant avant cette tâche (créé).
- `test/quality/` — dossier inexistant avant cette tâche (créé).
- `test/snapshots/generate_baseline.dart` — pour intégrer les
  scores au JSON baseline existant.
- Mémoire feedback `no_parallel_models` — vérifié, création de
  `PlanningQualityReport` / `DayQualityDetail` justifiée
  (sémantiquement distincts, aucun modèle équivalent existant).

## Fichiers créés / modifiés

- **`lib/quality/planning_metrics.dart`** *(créé, ~360 lignes)* —
  module métriques pur. Public API : `computePlanningMetrics`,
  `PlanningQualityReport`, `DayQualityDetail`.
- **`test/quality/planning_metrics_test.dart`** *(créé, ~290
  lignes)* — 24 tests unitaires sans dépendance réseau, 3 scénarios
  fictifs (bon/moyen/mauvais planning) + edge cases.
- **`test/snapshots/generate_baseline.dart`** *(modifié)* — ajoute
  l'appel à `computePlanningMetrics` et inclut le rapport dans le
  JSON baseline. Aucune logique pipeline modifiée.
- **`test/snapshots/singapore_baseline.json`** *(régénéré)* —
  inclut désormais `quality_report` en plus du contenu original.
- **`docs/migrations/phase0_task0_2.md`** *(ce document)*.

## Définition exacte des 5 scores

Tous dans `[0, 100]`, plus haut = mieux. Peuvent être `null` si la
donnée d'entrée ne permet pas le calcul (ex: pas de hops avec
coords → `transitionScore = null`).

### `coherenceScore`

Cohérence géographique **par jour**, moyenne sur les jours
non-vides ayant au moins un hop calculable.

Formule par jour :
```
dayScore = clamp(0, 100, 100 - 10 * longHopsCount - 4 * maxTransitionKm)
```

Avec :
- `longHopsCount` = nombre de hops > 5 km dans la journée
- `maxTransitionKm` = transition la plus longue de la journée (km)

`coherenceScore` = moyenne des `dayScore` sur tous les jours
qualifiables (≥1 hop avec coords).

**Intuition** :
- Journée compacte (max 1.5 km, 0 long hop) → 94
- Journée avec 1 long hop à 8 km → 100 - 10 - 32 = 58
- Journée chaos (2 long hops, 12 km max) → 100 - 20 - 48 = 32

Volontairement plus sévère que `transitionScore` (moyenne flat) car
**un seul long hop ruine une journée** du point de vue voyageur.

### `diversityScore`

Variété des `tag` des **visites** (les repas exclus — tous tag
"Gastronomie" fausseraient la mesure). Mesurée via **entropie de
Shannon normalisée**.

```
H = -Σ pi * log2(pi)
Hmax = log2(N)  où N = nb visites
diversityScore = (H / Hmax) * 100
```

**Intuition** :
- 9 visites avec 9 tags différents → 100
- 9 visites avec 5 tags distribution (3/3/1/1/1) → ~67
- 9 visites avec 1 seul tag → 0
- 1 seule visite → 100 (pas pénalisable)

Capture mieux la distribution qu'un simple ratio
`unique_tags / total`. Une distribution déséquilibrée (1 tag
dominant) est plus pénalisée qu'un nombre fixe de tags équiréparti.

### `repetitionScore`

Anti-répétitions des **visites** (les repas répétés sont OK par
design `insertDeterministicMeals` cap, donc exclus).

```
repetitions = Σ (count - 1) pour chaque titre normalisé répété
repetitionScore = max(0, 100 - 100 * repetitions / totalVisits)
```

**Intuition** :
- 0 répétition → 100
- 1 lieu picked 2× sur 10 visites → 100 - 10 = 90
- 1 lieu picked 3× sur 4 visites → 100 - 50 = 50
- Tout répété → 0

**Limite documentée (spec)** : ne détecte PAS les complexes
sémantiques type *Sentosa Island* vs *Sentosa* (différents
placeIds, titres différents après normalisation). Traité en
**Phase 2 via `SameComplexGroup`** (hors scope Tâche 0.2).

### `transitionScore`

Distances raisonnables entre slots consécutifs (tous jours
confondus). Moyenne des scores par hop.

Score par hop selon distance km :
- ≤ 2 km → 100
- 2 - 5 km → 100 → 80 (linéaire)
- 5 - 10 km → 80 → 40 (linéaire)
- 10 - 20 km → 40 → 0 (linéaire)
- ≥ 20 km → 0

**Linéaire entre bornes** pour éviter les sauts brutaux (un hop à
5.001 km ne doit pas passer brusquement de 80 à 40).

### `coverageScore`

Pourcentage de journées du voyage ayant au moins une activité.

```
coverageScore = 100 * daysWithActivity / totalExpectedDays
```

- `totalExpectedDays` = `expectedTripDays` si fourni, sinon
  `(maxDayDate - minDayDate + 1)`.
- "Remplie" = ≥ 1 slot (visite OU repas).

**Intuition** :
- 8 jours / 8 → 100
- 6 jours / 8 (2 jours libres) → 75
- Tout vide → 0

## Heuristique visite vs repas

Le pipeline retourne `List<ActivitySuggestion>` sans discriminant
explicite (les deux sont `ActivityKind.main`). Heuristique
appliquée :
```
_isMealSlot(s) = s.startTime == '12:30' || s.startTime == '19:30'
```

Cohérent avec `insertDeterministicMeals` qui produit ces slots
fixes (déjeuner 12:30, dîner 19:30). **Pragmatique, à mettre à
jour si le pipeline change ces conventions.** Documenté en
commentaire dans le code.

## Warnings par jour

5 codes stables, consommables par baseline / dashboards / dashboards
futurs :

| Code | Déclenchement |
|------|---------------|
| `empty_day` | Aucune activité ce jour. |
| `missing_coordinates` | ≥1 slot sans `lat`/`lng` → hops dégradés. |
| `long_transition` | ≥1 hop > 5 km dans la journée. |
| `low_activity_count` | Journée non vide mais < 2 slots. |
| `repeated_place` | Au moins 1 slot de la journée a un titre normalisé déjà vu un autre jour (inclut visites ET repas — le score `repetitionScore` ne pénalise que les visites, mais le warning est conservateur). |

## Seuils utilisés (constants dans `planning_metrics.dart`)

```dart
const double _kTransitionExcellentKm = 2.0;   // hop "compact"
const double _kTransitionAcceptableKm = 5.0;  // hop "long" (warning)
const double _kTransitionPenalizedKm = 10.0;  // hop "fortement pénalisé"
```

Ces seuils sont **alignés** sur les caps déjà actifs dans le
pipeline :
- 5 km = `_kMaxTransitionMegaCityKm` (V8.28d-fix Day Builder cap)
- 5 km = coherence guard slot picker (V8.23)
- 10 km = `_kMaxTransitionPerPackKm` (Day Builder default cap)

## Impact sur `singapore_baseline.json`

Le JSON baseline produit en Tâche 0.1 est **régénéré** par cette
tâche pour inclure le bloc `quality_report`. Le contenu pipeline
(`visits`, `meals`, `captured_logs`) est aussi re-produit
puisque le run hit la vraie API.

**Conséquence du non-déterminisme Google Places** (limite déjà
documentée Tâche 0.1) : le 2e run a vu un pool légèrement
différent du 1er :

| Métrique | 1er run (Tâche 0.1) | 2e run (Tâche 0.2) |
|----------|---------------------:|--------------------:|
| Total visites | 19 | 22 |
| Total repas | 4 | 4 |
| Jours actifs | 7 | 8 |
| Jours libres | 1 | 0 |
| Distance inter-slot moyenne | 1615.8 m | 1529.2 m |

Le 2e run a vu 3 visites de plus + jour 22/05 rempli. Probable
explication : cache Supabase peuplé par le 1er run → 2e run sert
un pool plus riche. Cette dérive **EST attendue** (cf. limite
"baseline immuable par engagement humain").

**Décision** : la baseline JSON est à jour avec les scores. Si un
besoin futur de revenir au 1er run apparaît, le commit `eb57677`
(Tâche 0.1) le contient.

## Scores obtenus sur Singapour (2e run, 2026-05-11)

```
Overall score : 81.1 / 100
├─ coherence  : 73.8   compacité jour par jour
├─ diversity  : 42.5   entropie Shannon des tags visites
├─ repetition : 100.0  haut = peu de répétitions
├─ transition : 89.1   distances inter-slot
└─ coverage   : 100.0  % journées remplies

Totaux : 26 slots (22 visites + 4 repas)
Jours actifs : 8/8
Titres répétés (warning per-day uniquement, pas score) :
  - nummun thai kitchen (repas × 2)
  - sod cafe (repas × 2)
Jours avec warnings : 20/05, 23/05, 24/05, 25/05
  (long_transition + repeated_place pour chaque)
```

**Lecture** :
- `repetition=100` confirme **0 visite répétée** (V8.28b1.4 fix
  trip-level iconic dedup tient en pratique).
- `coverage=100` : aucune journée libre involontaire ce run.
- `coherence=73.8` correct mais pas excellent : 4 jours ont des
  long transitions. Cohérent avec la structure géo distribuée de
  Singapour (Marina Bay / Sentosa / Botanic / Chinatown sont à
  5-10 km entre zones).
- `diversity=42.5` est **faible**. Probable cause : beaucoup de
  visites taggées "Activité" générique au lieu de Culture / Nature
  / Shopping. Ouvre un sujet pour Phase 1+ : améliorer la
  granularité du `tag` derived from `primary type`.
- `transition=89.1` très bon : la majorité des hops sont compacts
  (V8.28d-fix cap 5 km efficace), seulement quelques jours avec
  des hops 5-7 km dépassent le seuil acceptable.

## Limites connues

1. **Heuristique meal slots fragile** — fondée sur startTime exact
   `12:30` / `19:30`. Si `insertDeterministicMeals` change ses
   conventions horaires, l'heuristique se désynchronise. Mitigation
   future : exposer un champ `ActivitySuggestion.isMeal` ou ajouter
   un `ActivityKind.meal` dans une phase ultérieure (Tâche
   non-scope 0.2).

2. **Pas de détection complexes sémantiques** — Sentosa Island vs
   Sentosa, Tokyo Skytree vs Skytree Tower passent à travers
   `repetitionScore`. Traité **Phase 2 via `SameComplexGroup`**
   (mentionné dans la spec Tâche 0.2).

3. **`diversityScore` dépend fortement de la qualité du `tag`**
   produit par le pipeline. Tag "Activité" générique → diversity
   sous-évaluée. Pas un bug du module métriques, mais un signal
   pour les phases d'amélioration scoring du pipeline.

4. **`coherenceScore` ignore les jours sans hops calculables**
   (slot seul ou tous slots sans coords). Comportement
   conservateur : ne pénalise pas, mais ne récompense pas non plus.
   Le warning `low_activity_count` ou `missing_coordinates` signale
   ces cas séparément.

5. **Warning `repeated_place` mélange visites + repas** — le
   warning per-day se déclenche sur n'importe quel titre normalisé
   répété cross-day, incluant les repas (autorisés par design). Le
   score global `repetitionScore` exclut correctement les repas.
   Choix : warning conservateur (visibilité), score strict
   (sémantique correcte).

6. **Aucun pondération inter-scores** — `overallScore` = moyenne
   arithmétique simple des 5. Pas de poids spécifique (ex:
   `coverage` plus important que `diversity`). Pondération à
   définir en phase ultérieure si nécessaire.

## Tests unitaires

24 tests dans `test/quality/planning_metrics_test.dart`, 3 groupes
+ edge cases :

1. **Bon planning** (9 visites compactes Singapour, 5 tags, 3 jours)
   - overallScore ≥ 80
   - transitionScore = 100 (tous hops < 2 km)
   - repetitionScore = 100 (0 répétition)
   - diversityScore > 60 (entropie ~67 sur 5 tags)
   - coverageScore = 100
   - aucun warning per-day

2. **Planning moyen** (4 jours attendus, 3 remplis, hop 5.5 km, 2 tags)
   - overallScore ∈ [35, 80]
   - coverageScore = 75
   - warning `long_transition` sur le jour avec le hop 5.5 km
   - warning `low_activity_count` sur le jour avec 1 seule visite
   - transitionScore ∈ [50, 100[
   - diversityScore < 90

3. **Mauvais planning** (8 jours, 2 remplis, 3× même lieu, hop 12 km, 1 tag)
   - overallScore < 50
   - repetitionScore < 60 (2 répétitions / 4 visites)
   - transitionScore < 50
   - coverageScore = 25
   - diversityScore = 0 (1 seul tag)
   - warnings `repeated_place` + `long_transition`

4. **Edge cases** (5 tests)
   - liste vide → scores `null` sauf `coverage` si `expectedTripDays`
   - slot sans coords → warning `missing_coordinates`
   - slots 12:30 / 19:30 = repas (vs visites)
   - `expectedTripDays` null → déduit du min/max `dayDate`
   - repas répétés ne pénalisent PAS `repetitionScore`

Aucune dépendance réseau / Google Places / Supabase.

## Confirmation : pipeline production NON modifié

- `lib/features/planning/services/places_first_pipeline.dart` :
  **aucune modification**.
- `lib/features/planning/data/` : **aucune modification**.
- `lib/features/planning/services/day_builder.dart` : **aucune
  modification**.
- `lib/features/planning/models/activity_suggestion_model.dart` :
  **aucune modification**.
- Aucun feature flag introduit.
- Aucun modèle `Planning` créé (cf. règle feedback
  `no_parallel_models`).
- Aucun `DestinationIntelligence` ni `DayTemplate` créé.
- Le module est strictement consommateur de `ActivitySuggestion`
  (modèle existant), produit `PlanningQualityReport` /
  `DayQualityDetail` qui sont des modèles purement liés aux
  métriques (sémantiquement distincts, non parallèles à un modèle
  pipeline).

## Validation

- `flutter analyze` : 35 info préexistants (inchangés depuis Tâche
  0.1), 0 warning, 0 error.
- `flutter test` : 455 tests verts (431 V8.28c + 24 nouveaux
  Tâche 0.2).
- `flutter test test/snapshots/generate_baseline.dart` : 1 test
  passé, JSON baseline régénéré ~57 KB, scores Singapour affichés
  console.

## Commande

```bash
flutter test test/quality/planning_metrics_test.dart   # tests purs
flutter test test/snapshots/generate_baseline.dart      # baseline + scores
```

## Hors scope (n'est PAS dans cette tâche)

- Détection complexes sémantiques (Sentosa Island / Sentosa) →
  Phase 2 `SameComplexGroup`.
- Pondération des scores → phase future si besoin.
- Modifier `ActivityKind` pour ajouter `meal` → phase future,
  nécessite migration DB.
- Dashboard / visualisation des scores → hors plan refonte.

## Note pour Tâche 0.3

Le module `planning_metrics.dart` peut être consommé tel quel par
toute prochaine tâche (comparaison de plannings, assertions de
qualité dans des tests d'intégration, etc.). Le JSON baseline est
maintenant enrichi avec `quality_report` exploitable pour la
comparaison.
