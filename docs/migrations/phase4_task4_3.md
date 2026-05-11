# Phase 4 / Tâche 4.3 — `DayThemeAssigner`

## Objectif

Service **pur** qui assigne un `DayTemplate` à chaque jour d'un
voyage, **sans construire les activités**, **sans appeler
Google Places**, **sans toucher au pipeline**.

Sa responsabilité unique : produire une séquence
`jour → template` **déterministe**, prête à être consommée par
le futur `DayBuilder template-first` (Tâche 4.4+) derrière le
flag `useDayTemplates`.

**Tâche purement service + tests + doc.** 0 fichier de
production planning modifié. Le flag `useDayTemplates` reste
OFF par défaut et n'est consommé nulle part.

Conforme aux règles d'or :
- **1 — Ne JAMAIS casser le pipeline existant** : 0 fichier de
  production planning modifié.
- **3 — Une tâche, un commit, une PR**.
- **5 — Tests dans le même commit que la production**.
- **7 — Étendre l'existant** : adapter local `TripSkeleton`
  (pas de couplage au `Trip` lourd du projet), réutilise
  `DayTemplate` et `DestinationIntelligence` existants.

## Fichiers créés

- **`lib/services/day_theme_assigner.dart`** *(~330 lignes)* —
  `TripSkeleton` + `DayTemplateAssignment` + `DayAssignmentReason`
  enum + fonction publique `assignThemesToDays`.
- **`test/services/day_theme_assigner_test.dart`** *(~470 lignes)*
  — **39 tests** en 10 groupes.
- **`docs/migrations/phase4_task4_3.md`** *(ce document)*.

## Fichiers de production NON modifiés

- `lib/models/day_template.dart` intact (Tâche 4.1)
- `lib/data/day_templates/singapore_templates.dart` intact (Tâche 4.2)
- `lib/models/destination_intelligence.dart` intact (consommé en
  lecture seule)
- `lib/data/destinations/singapore.dart` intact
- `lib/features/planning/services/places_first_pipeline.dart` intact
- `lib/features/planning/services/day_builder.dart` intact
- `lib/config/feature_flags.dart` intact (`useDayTemplates` OFF,
  non consommé)

## Modèles créés

### `TripSkeleton` (adapter local)

```dart
class TripSkeleton {
  final String destinationKey;
  final DateTime startDate;
  final DateTime endDate;
  final List<String> interests;
  final String? travelerType;
}
```

Pourquoi un adapter local plutôt que `Trip` (modèle riche du
projet) :
- Évite le couplage à 30+ champs non pertinents (accommodation,
  budget, segments, hôtels, etc.)
- Le caller construit `TripSkeleton` à partir de son `Trip`
  réel via une simple projection
- Cohérent avec règle d'or 7

### `DayTemplateAssignment`

```dart
class DayTemplateAssignment {
  final DateTime date;          // trip.startDate + dayIndex days
  final int dayIndex;           // 0-based
  final DayTemplate template;
  final DayAssignmentReason reason;
}
```

### `DayAssignmentReason`

```dart
enum DayAssignmentReason {
  arrival,           // 1er jour, arrival_day retenu
  departure,         // dernier jour, departure_day retenu
  iconicPriority,    // template iconique (anchors non vides)
  interestMatch,     // (réservé Tâche 4.3+, non émis en 4.3)
  restBalance,       // free_day inséré pour rythme repos
  defaultRotation,   // fallback pas de rôle spécifique
}
```

## Logique arrival / departure

- **Day 0** = `arrival_day` si présent, sinon **le template le
  plus light** disponible (priorité : light > medium > intense,
  stable par templateKey).
- **Dernier jour** = `departure_day` si présent, sinon template
  light parmi ceux non utilisés (ne réutilise pas `day0`).

| Cas | Day 0 | Dernier jour | Reason day 0 | Reason dernier |
|-----|-------|--------------|--------------|----------------|
| Standard | arrival_day | departure_day | arrival | departure |
| Sans arrival_day | light fallback | departure_day | defaultRotation | departure |
| Sans departure_day | arrival_day | light fallback | arrival | defaultRotation |

## Logique jours du milieu

### Queue iconique (déterministe)

`_buildMiddleQueue(eligible)` filtre arrival/departure/free_day
et trie le reste par :

1. `recommendedAnchorKeys.length` DESC (iconic = plus d'anchors)
2. `intensity` (medium > intense > light)
3. `templateKey` ASC (alphabétique stable)

Pour les 8 templates Singapour, la queue middle est :
```
marina_bay_day            (3 anchors, medium)
chinatown_civic_day       (2 anchors, medium)
little_india_kampong_day  (2 anchors, medium)
orchard_botanic_day       (2 anchors, medium)
sentosa_day               (1 anchor,  intense)
```

### Walker

À chaque jour middle `i` ∈ [1, numDays-2] :

1. **Si `free_day` dispo ET `activeDaysSinceLastFree >= threshold`**
   → insère `free_day`, reset compteur, reason `restBalance`.
2. **Sinon** → pioche dans la queue iconique en partant de
   `middleQueueIndex` (round-robin), en sautant :
   - les déjà-utilisés si `numDays <= 10`
   - les `intense` si le précédent était `intense`

Si rien ne passe les filtres, relaxe le filtre `intense` (cap
répétition reste prioritaire).

### Seuil free_day

```dart
final freeThreshold = numDays > 10 ? 4 : 5;
```

Pour un voyage 8 jours : free_day après 5 actifs → 1 free_day.
Pour un voyage 12 jours : free_day après 4 actifs → 2 free_days
(satisfait spec "≥ 2 free_day si dispo").

### Anti-duplication

- `numDays <= 10` : aucun templateKey ne peut apparaître 2× dans
  le voyage (sauf jour 0 / dernier qui restent uniques par
  construction du rôle).
- `numDays > 10` : répétitions autorisées via round-robin sur la
  queue iconique.

### Anti-intense consécutifs

Le walker skip un template `intense` si le précédent jour était
aussi `intense`. Pour les 8 templates Singapour, le seul
`intense` est `sentosa_day` — la règle empêche donc une 2ᵉ
journée intense adjacente sur les voyages longs avec
répétitions.

## Exemples d'assignation

### Voyage 8 jours Singapour (vérifié par test)

```
Day 0 (2026-05-18) : arrival_day              — arrival
Day 1 (2026-05-19) : marina_bay_day           — iconicPriority
Day 2 (2026-05-20) : chinatown_civic_day      — iconicPriority
Day 3 (2026-05-21) : little_india_kampong_day — iconicPriority
Day 4 (2026-05-22) : orchard_botanic_day      — iconicPriority
Day 5 (2026-05-23) : sentosa_day              — iconicPriority
Day 6 (2026-05-24) : free_day                 — restBalance
Day 7 (2026-05-25) : departure_day            — departure
```

Invariants vérifiés :
- ✅ arrival_day jour 0
- ✅ departure_day jour 7
- ✅ contient free_day
- ✅ contient marina_bay_day
- ✅ contient sentosa_day
- ✅ aucun template dupliqué
- ✅ pas deux jours intense consécutifs (sentosa à day 5
  entre orchard medium et free light)
- ✅ sentosa pas en bord (ni day 0 ni day 7)

### Voyage 3 jours Singapour

```
Day 0 : arrival_day
Day 1 : marina_bay_day (iconique, anchors non vides, pas intense)
Day 2 : departure_day
```

### Voyage 12 jours Singapour (long, > 10)

```
Day  0 : arrival_day
Day  1 : marina_bay_day
Day  2 : chinatown_civic_day
Day  3 : little_india_kampong_day
Day  4 : orchard_botanic_day
Day  5 : free_day                 (1ʳᵉ)
Day  6 : sentosa_day
Day  7 : marina_bay_day           (répétition autorisée)
Day  8 : chinatown_civic_day      (répétition)
Day  9 : little_india_kampong_day (répétition)
Day 10 : free_day                 (2ᵉ, ≥ 2 OK)
Day 11 : departure_day
```

### Voyage 1 jour

```
Day 0 : arrival_day (ou template light fallback)
```

### Voyage 2 jours

```
Day 0 : arrival_day
Day 1 : departure_day
```

## Stratégie free_day

Spec : *"insérer au moins un free_day par tranche de 5 jours si
disponible"*.

- Court séjour (≤ 10 jours) : seuil 5 jours actifs entre 2
  free_day. Pour 8 jours → 1 free_day inséré en fin de séquence
  iconique (juste avant departure).
- Long séjour (> 10 jours) : seuil resserré à 4 → 2 free_days
  pour un voyage 12j.

Garantit aussi que `free_day` n'est jamais le premier ni le
dernier jour (sauf voyages 1-jour fallback).

## Stratégie intensité

- `intense` jamais consécutif. Pour 8 templates Singapour : sentosa
  est le seul intense, donc règle automatiquement satisfaite.
- Jour de milieu strict (court séjour 3-jours) : préférer
  non-intense. Vérifié par test ("jour du milieu ne doit pas
  être intense").
- Pas de logique "sentosa pas trop tôt après arrival" explicite
  — l'ordre par iconic-score place naturellement sentosa après
  les autres iconiques.

## Stratégie anti-duplication

| numDays | Politique |
|---------|-----------|
| 1 | 1 template, pas de problème |
| 2 | arrival + departure, uniques par rôle |
| 3-10 | Aucun templateKey 2× (vérifié) |
| > 10 | Répétitions autorisées via round-robin sur la queue iconique |

## Confirmation déterminisme

3 tests dédiés vérifient :
- Deux appels avec mêmes inputs → même séquence de `templateKey`
- Deux appels avec mêmes inputs → même séquence de `reason`
- **L'ordre des `templates` en input ne change pas la séquence**
  (le tri interne stable rend l'algo indépendant de l'ordre)

Pas de hasard, pas de Gemini, pas d'appel réseau.

## Limites connues

1. **`interests` accepté mais non utilisé en 4.3** : la
   signature accepte une liste d'intérêts pour cohérence future
   (Tâche 4.3+), mais aucune logique d'interest-matching n'est
   active. La raison `DayAssignmentReason.interestMatch` existe
   dans l'enum mais n'est jamais émise par le code actuel —
   réservée pour une extension future.
2. **`travelerType` accepté mais non utilisé** : idem.
3. **Pas de cross-validation contre `forbiddenComplexKeys`** :
   la cohérence des templates avec les `SameComplexGroup`
   relève des tests Tâche 4.2, pas de l'assigner.
4. **Fallback ultime simple** : en voyage très court (3-4
   jours) avec très peu de templates, l'algo peut, en dernier
   recours, retourner un template déjà utilisé (cf. helper
   `_fallbackPick`). Cas rare, documenté.
5. **Pas de scoring par intérêt** : volontaire, garde l'algo
   strictement déterministe et facile à vérifier.

## Tests — 39 tests / 10 groupes

### 1. Voyage 8 jours Singapour (11 tests)
- 8 assignments
- Day 0 = arrival_day, reason arrival
- Day 7 = departure_day, reason departure
- Contient free_day
- Contient marina_bay_day
- Contient sentosa_day
- Aucun template dupliqué
- Pas deux jours intense consécutifs
- Chaque template valide vs DI
- Dates calendaires correctes (séquence)
- sentosa_day n'est ni day 0 ni dernier

### 2. Voyage 3 jours (4 tests)
- 3 assignments
- arrival / departure aux bornes
- Jour du milieu iconique, pas intense

### 3. Voyage 1 jour (3 tests)
- 1 assignment, pas de crash
- arrival_day retourné
- Fallback light sans arrival_day

### 4. Voyage 2 jours (2 tests)
- 2 assignments
- arrival puis departure

### 5. Voyage 12 jours (5 tests)
- 12 assignments
- ≥ 2 free_day
- Pas intense consécutifs
- Day 0 arrival, day 11 departure
- Répétitions autorisées

### 6. Templates manquants (3 tests)
- Sans arrival_day → fallback light day 0
- Sans departure_day → fallback light dernier
- Sans free_day → pas de crash, pas d'insertion repos

### 7. Liste vide (2 tests)
- Liste vide → `ArgumentError`
- destinationKey non matché → `ArgumentError`

### 8. Dates invalides (2 tests)
- `endDate < startDate` → `ArgumentError`
- `endDate == startDate` → OK (1 jour)

### 9. Déterminisme (3 tests)
- Même séquence templateKey sur 2 appels
- Même séquence reason sur 2 appels
- **Ordre des inputs ne change pas la séquence**

### 10. Reasons (4 tests)
- arrival_day → reason arrival
- departure_day → reason departure
- free_day → reason restBalance
- Iconiques → reason iconicPriority

## Ce qui n'est volontairement PAS fait

- ❌ Création de `DayBuilder template-first` / `template_first_pipeline.dart` — Tâche 4.4+
- ❌ Sélection de lieux / candidats Google Places
- ❌ Construction d'`ActivitySuggestion`
- ❌ Insertion de repas
- ❌ Consommation du flag `useDayTemplates`
- ❌ Modification de `places_first_pipeline.dart`
- ❌ Scoring par intérêts (signature acceptée mais inactive)
- ❌ Appel réseau / Supabase / Gemini

## Confirmation aucun branchement runtime

- ✅ `grep -rn "day_theme_assigner\|assignThemesToDays" lib/features/`
  → **aucune référence** dans les fichiers de production planning.
- ✅ `grep -rn "useDayTemplates" lib/` → seule occurrence dans
  `lib/config/feature_flags.dart` (déclaration, pas de
  consommation).
- ✅ Le test 4.3 importe uniquement :
  - `package:flutter_test/flutter_test.dart`
  - `package:voyage/data/day_templates/singapore_templates.dart`
  - `package:voyage/data/destinations/singapore.dart`
  - `package:voyage/models/day_template.dart`
  - `package:voyage/services/day_theme_assigner.dart`

## Résultats validation

```
flutter analyze
  35 issues info préexistants (Tâche 0.1, inchangés)
  → lib/services/day_theme_assigner.dart       : No issues found
  → test/services/day_theme_assigner_test.dart : No issues found
  0 warning, 0 error sur les nouveaux fichiers

flutter test
  985 tests verts (946 Tâche 4.2 + 39 nouveaux Tâche 4.3)

flutter test test/snapshots/generate_baseline.dart
  1 test passé, baseline JSON régénéré
  Overall score : 82.78 / 18 visites / coverage 100%
  Variation Google Places attendue — aucun rapport avec cette
  tâche, qui ne branche rien au pipeline.

flutter test test/snapshots/compare_snapshot.dart
  16 tests passés (1 self-check + 15 fixtures)
  Verdict self-check Singapour : PASS
```

## Commande

```bash
# Test service uniquement
flutter test test/services/day_theme_assigner_test.dart

# Suite complète
flutter test
flutter test test/snapshots/generate_baseline.dart
flutter test test/snapshots/compare_snapshot.dart
```

## Prochaine étape : Tâche 4.4

`DayBuilder template-first` — service qui consomme une
`DayTemplateAssignment` et construit la journée concrète
(`ActivitySuggestion` slots remplis depuis le pool de candidats
Google Places). C'est le **premier composant runtime** de la
Phase 4 qui touchera réellement la sélection de lieux.

À partir de la Tâche 4.4, on revient dans la zone sensible
(modification potentielle du comportement). Comme Tâche 2.4
et 3.2, l'intégration sera **derrière le flag
`useDayTemplates`** (OFF par défaut, court-circuité quand
inactif).
