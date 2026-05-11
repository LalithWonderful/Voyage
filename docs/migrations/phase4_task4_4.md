# Phase 4 / Tâche 4.4 — `TemplateFirstDayBuilder`

## Objectif

**Premier composant runtime Phase 4** capable de construire une
journée à partir d'un `DayTemplate` assigné + un pool de
candidats, derrière feature flag (à venir Tâche 4.5+), sans
remplacer ni brancher le pipeline actuel.

Le service répond à **une seule question** :
> *Peut-on transformer `(DayTemplate, candidates)` en
> `TemplateDayBuildResult` cohérent et déterministe ?*

**Tâche purement service + tests + doc.** 0 fichier de
production planning modifié. Le flag `useDayTemplates` reste
OFF et n'est consommé nulle part. Aucun branchement.

Conforme aux règles d'or :
- **1 — Ne JAMAIS casser le pipeline existant** : 0 fichier de
  production planning modifié, `day_builder.dart` legacy intact.
- **3 — Une tâche, un commit, une PR**.
- **5 — Tests dans le même commit que la production**.
- **7 — Étendre l'existant** : adapter local `TemplateCandidate`
  pour éviter le couplage à `NearbyCandidate` / `PlaceInfo`.

## Choix de nommage

`template_first_day_builder.dart` / `TemplateFirstDayBuilder`
**explicitement distinct** de `day_builder.dart` legacy
(V8.20+, slot-first, branché au pipeline). Évite toute
confusion sémantique pendant la coexistence.

## Fichiers créés

- **`lib/services/template_first_day_builder.dart`**
  *(~430 lignes)* — `TemplateCandidate` (adapter local) +
  `TemplateDayBuildInput` + `TemplateSlotAssignment` +
  `TemplateDayBuildResult` + enum
  `TemplateDayBuildWarning` + fonction publique
  `buildTemplateFirstDay`.
- **`test/services/template_first_day_builder_test.dart`**
  *(~600 lignes)* — **39 tests** en 8 groupes.
- **`docs/migrations/phase4_task4_4.md`** *(ce document)*.

## Fichiers de production NON modifiés

- `lib/features/planning/services/places_first_pipeline.dart` intact
- `lib/features/planning/services/day_builder.dart` intact (legacy V8.20+)
- `lib/models/day_template.dart` intact (Tâche 4.1)
- `lib/data/day_templates/singapore_templates.dart` intact (Tâche 4.2)
- `lib/services/day_theme_assigner.dart` intact (Tâche 4.3)
- `lib/config/feature_flags.dart` intact (`useDayTemplates` OFF)

## Modèles créés

### `TemplateCandidate` (adapter local)

| Champ | Type | Required |
|-------|------|----------|
| `placeKey` | String | ✅ — dédup key |
| `title` | String | ✅ — debug + tri |
| `category` | String | ✅ |
| `score` | double | ✅ — tri principal |
| `anchorKey` | String? | matching anchor recommandé |
| `complexKey` | String? | matching forbidden complex |
| `rating` | double? | tri tiebreaker (nulls last) |
| `userRatingCount` | int? | tri tiebreaker (nulls last) |
| `lat` / `lng` | double? | réservé futur (distance) |
| `estimatedDurationMinutes` | int? | override slot duration |

Pas de couplage à `NearbyCandidate` (`places_nearby_service.dart`)
ni à `PlaceInfo` (`places_service.dart`). Le caller futur (Tâche
4.5+) projettera depuis son modèle.

### `TemplateDayBuildInput`

```dart
class TemplateDayBuildInput {
  final DayTemplate template;
  final DateTime date;
  final int dayIndex;
  final List<TemplateCandidate> candidates;
  final String? destinationKey;
  final Set<String> alreadyUsedPlaceKeys;
  final Set<String> alreadyUsedAnchorKeys;
}
```

### `TemplateDayBuildResult`

```dart
class TemplateDayBuildResult {
  final DateTime date;
  final int dayIndex;
  final String templateKey;
  final List<TemplateSlotAssignment> assignments;
  final List<TemplateDayBuildWarning> warnings;  // day-level
  final bool isFallback;

  List<String> validate();          // détecte duplicate placeKey
  int get filledSlotsCount;
}
```

### `TemplateSlotAssignment`

```dart
class TemplateSlotAssignment {
  final SlotSpec slot;
  final TemplateCandidate? candidate;        // null = slot vide
  final int effectiveDurationMinutes;        // candidate ?? slot
  final List<TemplateDayBuildWarning> warnings;  // per-slot
  bool get isEmpty;
}
```

### `TemplateDayBuildWarning` (enum)

```dart
enum TemplateDayBuildWarning {
  emptyCandidatePool,             // day-level
  forbiddenComplexFiltered,       // day-level
  missingCandidateForSlot,        // per-slot
  missingRecommendedAnchor,       // per-slot
  reusedPlaceDueToNoAlternative,  // per-slot
  reusedAnchorDueToNoAlternative, // per-slot
}
```

## Algorithme

```
1. Filtrage day-level : exclure candidats dont complexKey ∈
   template.forbiddenComplexKeys.
   Si réduction → warning forbiddenComplexFiltered.
   Si pool vide après filtrage → emptyCandidatePool + résultat
   isFallback=true avec tous slots vides.

2. Pour chaque slot in template.slots (ordre du template) :
   a. eligible = candidats non-utilisés-dans-jour
   b. Cascading tier filter :
      Tier 1 : category matches + non-utilisé-place + non-utilisé-anchor
      Tier 2 : category matches + non-utilisé-place           (relâche anchor)
      Tier 3 : non-utilisé-place                              (relâche cat)
      Tier 4 : tout eligible (réutilisation autorisée)
   c. Tri déterministe stable + pick.first.
   d. Émettre warnings :
      - reusedPlaceDueToNoAlternative si pick ∈ alreadyUsedPlace
      - reusedAnchorDueToNoAlternative si pick.anchor ∈ alreadyUsedAnchor
      - missingRecommendedAnchor si slot=anchor ET pick.anchor ∉ recommended

3. isFallback = (filledSlotsCount < assignments.length / 2) OU
                (warnings contient emptyCandidatePool)
```

## Tri déterministe (cf. spec)

Comparator stable avec **tiebreaker ultime sur `placeKey`** —
garantit que deux runs identiques + l'ordre des inputs shuffled
produisent **exactement le même résultat** :

1. anchor match recommandé (rang 0 si match, 1 sinon)
2. `score` DESC
3. `rating` DESC nulls last (`null` traité comme `-∞`)
4. `userRatingCount` DESC nulls last (`null` traité comme `-1`)
5. `title` ASC
6. `placeKey` ASC (tiebreaker final ultime)

Test dédié `Candidates shuffled → même résultat` vérifie
l'insensibilité à l'ordre des inputs.

## Catégories — matching slot ↔ candidate

Helper `_categoryMatchesSlot(category, expectedType)` :

1. **`freeTime`** matche toute catégorie (slot flexible).
2. **Match exact** : `category == expectedType.name` (`'anchor'`,
   `'meal'`, etc.).
3. **Synonymes** Google Places-style (table interne) :
   - `anchor` ← `tourist_attraction`, `landmark`, `monument`,
     `point_of_interest`
   - `visit` ← `tourist_attraction`, `museum`, `park`,
     `point_of_interest`, `landmark`
   - `meal` ← `restaurant`, `cafe`, `food`, `food_court`
   - `rest` ← `park`, `cafe`
   - `shopping` ← `shopping_mall`, `market`, `store`
   - `viewpoint` ← `observation_deck`, `tower`
   - `show` ← `performance`, `event`, `theater`
   - `transfer` ← `transport`

Table étendable au besoin (Tâche 4.5+).

## Logique des warnings — résumé

| Cas | Warning émis | Niveau |
|-----|--------------|--------|
| Pool initial vide ou intégralement filtré | `emptyCandidatePool` | day |
| ≥ 1 candidat exclu par forbidden complex | `forbiddenComplexFiltered` | day |
| Slot sans candidat assigné | `missingCandidateForSlot` | slot |
| Slot anchor + pick.anchor ∉ recommended | `missingRecommendedAnchor` | slot |
| Pick ∈ alreadyUsedPlaceKeys | `reusedPlaceDueToNoAlternative` | slot |
| Pick.anchor ∈ alreadyUsedAnchorKeys | `reusedAnchorDueToNoAlternative` | slot |

## Durées effectives

```dart
effectiveDurationMinutes = candidate.estimatedDurationMinutes
    ?? slot.typicalDurationMinutes;
```

Test dédié vérifie l'override quand le candidat fournit une
durée, et le fallback quand `null`.

## Garanties

| Garantie | Vérification |
|----------|--------------|
| Déterministe | ✅ test `Deux appels identiques → même résultat` |
| Insensible à l'ordre des inputs | ✅ test `Candidates shuffled → même résultat` |
| Jamais throw | ✅ test `candidates vide → résultat avec warnings` |
| Pas d'appel réseau | ✅ aucun import network / Google Places / Supabase |
| Pas de couplage Trip lourd | ✅ adapter local `TemplateCandidate` |
| Pas de duplicate intra-jour | ✅ `selectedThisDay` set + `validate()` |

## Cas testés — 39 tests / 8 groupes

### A. Cas nominal (10 tests)
- 4 slots template, 5 candidats matchant tous les types
- Tous les slots remplis
- `isFallback = false`, `warnings = []`
- Slot anchor matin priorisé sur match anchor + score
- Slots meal / visit / viewpoint remplis correctement
- `templateKey` préservé
- `validate()` vide

### B. forbiddenComplexKeys (3 tests)
- `sentosa` exclu pour marina_bay_day
- Tous filtrés → pool vide → isFallback
- `complexKey = null` n'est pas filtré

### C. recommendedAnchorKeys (4 tests)
- Anchor recommandé prioritaire même si autre a meilleur score
- Si absent : warning `missingRecommendedAnchor` + fallback
- Match case-insensitive + trim
- `anchorKey = null` → ne match pas (warning émis)

### D. Anti-duplication (5 tests)
- Pas deux fois le même `placeKey` dans une journée
- `alreadyUsedPlaceKeys` évité si alternative
- Reuse autorisée en dernier recours avec warning
- `alreadyUsedAnchorKeys` évité si alternative
- Reuse anchor seulement si forcé + warning

### E. Déterminisme (3 tests)
- Deux appels identiques → mêmes assignments
- Candidates shuffled → même résultat
- Tiebreaker `placeKey ASC` stable sur scores/ratings identiques

### F. Edge cases (7 tests)
- `candidates` vide → warnings, pas crash
- Tous filtrés par forbidden → pool vide
- `rating` / `userRatingCount` null gérés (nulls last)
- Template `free_day` avec listes vides
- `estimatedDurationMinutes` null → fallback slot.typical
- 1 seul candidate pour plusieurs slots
- `estimatedDurationMinutes` override slot duration

### G. Intégration légère avec Singapore templates (3 tests)
- `chinatown_civic_day` avec fake candidates Chinatown
- `arrival_day` avec candidates minimalistes
- `marina_bay_day` avec sentosa filtré

### H. Warnings & isFallback (4 tests)
- `isFallback = false` quand tous remplis
- `isFallback = true` quand > 50% vides
- Warnings codes stables (enum)
- `validate()` détecte duplicate placeKey (invariant)

## Ce qui n'est volontairement PAS fait

- ❌ Branchement au pipeline production
- ❌ `template_first_pipeline.dart` (Tâche 4.5+)
- ❌ Consommation du flag `useDayTemplates`
- ❌ Appel Google Places / Gemini / Supabase
- ❌ Modification de `places_first_pipeline.dart`
- ❌ Modification de `day_builder.dart` legacy
- ❌ Optimisation d'itinéraire (transitions géographiques)
- ❌ Insertion automatique de repas extra hors slots
- ❌ Interest-matching scoring
- ❌ Couplage à `Trip` / `NearbyCandidate` / `PlaceInfo`

## Confirmation aucun branchement runtime

- ✅ `grep -rn "template_first_day_builder\|buildTemplateFirstDay"
  lib/features/` → **aucune référence** dans les fichiers de
  production planning.
- ✅ `grep -rn "useDayTemplates" lib/` → seule occurrence dans
  `lib/config/feature_flags.dart` (déclaration, pas de
  consommation).
- ✅ Le test 4.4 importe uniquement :
  - `package:flutter_test/flutter_test.dart`
  - `package:voyage/data/day_templates/singapore_templates.dart`
  - `package:voyage/models/day_template.dart`
  - `package:voyage/services/template_first_day_builder.dart`

## Résultats validation

```
flutter analyze
  35 issues info préexistants (Tâche 0.1, inchangés)
  → lib/services/template_first_day_builder.dart       : No issues found
  → test/services/template_first_day_builder_test.dart : No issues found
  0 warning, 0 error sur les nouveaux fichiers

flutter test
  1024 tests verts (985 Tâche 4.3 + 39 nouveaux Tâche 4.4)

flutter test test/snapshots/generate_baseline.dart
  1 test passé, baseline JSON régénéré
  Overall score : 81.07 / 18 visites / coverage 100%
  Variation Google Places attendue — aucun rapport avec cette
  tâche, qui ne branche rien au pipeline.

flutter test test/snapshots/compare_snapshot.dart
  16 tests passés (1 self-check + 15 fixtures)
  Verdict self-check Singapour : PASS
```

## Commande

```bash
# Test builder uniquement
flutter test test/services/template_first_day_builder_test.dart

# Suite complète
flutter test
flutter test test/snapshots/generate_baseline.dart
flutter test test/snapshots/compare_snapshot.dart
```

## Conclusion Phase 4 partielle

Avec la Tâche 4.4, la **brique centrale runtime** Phase 4 est
disponible :

| Tâche | Commit | Apport |
|-------|--------|--------|
| 4.1 | `e5ab97d` + `bf54187` | Modèle `DayTemplate` + contrat listes vides |
| 4.2 | `157ca49` | 8 templates Singapour |
| 4.3 | `b2f1658` | `DayThemeAssigner` (jour → template) |
| 4.4 | (this) | `TemplateFirstDayBuilder` (template + candidats → journée) |

La chaîne suivante est maintenant **complète côté
abstractions/services** :

```
DestinationIntelligence + SameComplexGroups + DayTemplates
  → DayThemeAssigner (Tâche 4.3) → assignations jour-par-jour
  → TemplateFirstDayBuilder (Tâche 4.4) → journées structurées
```

Manque pour la phase 4 fonctionnelle complète :
- **Tâche 4.5+** : `template_first_pipeline.dart` qui orchestre
  l'ensemble, charge les candidats Google Places réels,
  consomme le flag `useDayTemplates`, et substitue le legacy
  Day Builder quand le flag est ON.
- **Validation A/B** : flag OFF vs ON sur le baseline Singapour
  (analogue Tâche 2.5 et 3.2).

## Prochaine étape : Tâche 4.5

`template_first_pipeline.dart` orchestrera :
1. Charge `DestinationIntelligence` + `DayTemplate` list pour
   la destination.
2. Appelle `DayThemeAssigner` → mapping jour → template.
3. Pour chaque jour :
   - Charge le pool de candidats (réutilise `gatherCandidatesForTrip`
     ou équivalent du pipeline existant).
   - Appelle `buildTemplateFirstDay(template, candidates)`.
   - Convertit `TemplateDayBuildResult` en `ActivitySuggestion`.
4. Branchement derrière `useDayTemplates`, court-circuit total
   quand flag OFF.

À partir de 4.5, on revient en zone sensible (modification
runtime). Comme Tâches 2.4 et 3.2, l'intégration sera derrière
flag (OFF par défaut) avec tests Flag OFF / Flag ON.
