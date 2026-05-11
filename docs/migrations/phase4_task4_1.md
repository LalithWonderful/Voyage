# Phase 4 / Tâche 4.1 — Modèle `DayTemplate`

## Objectif

Poser la **structure de données** des gabarits de journées
thématiques (DayTemplate) : un template décrit une journée
structurée autour d'un thème + zone primaire + intensité +
anchors recommandés + complexes interdits + stratégie repas +
slots attendus + flexibilité.

**Tâche purement de schéma + enums + validation + sérialisation
+ tests + migration SQL.** Aucune donnée Singapour (→ Tâche
4.2), aucun assigner, aucun day builder template-first, aucun
branchement runtime. Le flag `useDayTemplates` reste OFF et
n'est consommé nulle part.

Conforme aux règles d'or :
- **1 — Ne JAMAIS casser le pipeline existant** : 0 fichier de
  production modifié.
- **3 — Une tâche, un commit, une PR**.
- **5 — Tests dans le même commit que la production**.
- **7 — Étendre l'existant** : conventions strictement
  alignées sur `DestinationIntelligence` (Tâche 1.1) et
  `SameComplexGroup` (Tâche 2.1) — `snake_case` JSON, validate
  agrégée, enums strict-by-default, PK SQL composite.

## Fichiers créés

- **`lib/models/day_template.dart`** *(~430 lignes)* — classes
  immutables `DayTemplate` et `SlotSpec` + 3 enums (`DayIntensity`,
  `MealStrategy`, `ExpectedSlotType`) + validation simple +
  validation croisée DI + JSON snake_case.
- **`supabase/sql/day_templates.sql`** *(~105 lignes)* — table
  avec PK composite + 4 indexes (3 B-tree + 1 GIN) + RLS read-all
  + trigger `updated_at`. **Aucun seed.**
- **`test/models/day_template_test.dart`** *(~535 lignes)* —
  **56 tests** en 9 groupes. Aucune dépendance réseau /
  Supabase / framework de mock.
- **`docs/migrations/phase4_task4_1.md`** *(ce document)*.

## Fichiers de production NON modifiés

- `lib/features/planning/services/places_first_pipeline.dart` intact
- `lib/features/planning/services/day_builder.dart` intact (Day
  Builder greedy V8.20+ continue inchangé)
- `lib/models/destination_intelligence.dart` intact (consommé
  par `validateAgainstDestination` mais pas modifié)
- `lib/config/feature_flags.dart` intact (`useDayTemplates`
  reste OFF, non consommé)

## Modèles créés

### `DayTemplate`

| Champ | Type | Default | Validation |
|-------|------|---------|------------|
| `templateKey` | String | — | non vide, pas de whitespace |
| `destinationKey` | String | — | non vide |
| `theme` | String | — | non vide |
| `primaryZoneName` | String | — | non vide ; cross-checked DI séparé |
| `intensity` | `DayIntensity` | — | enum strict |
| `recommendedAnchorKeys` | `List<String>` | — | pas d'entrée vide, pas de doublon |
| `forbiddenComplexKeys` | `List<String>` | — | pas d'entrée vide, pas de doublon |
| `mealStrategy` | `MealStrategy` | — | enum strict |
| `slots` | `List<SlotSpec>` | — | ≥ 1, chaque slot valide, pas de doublon `slotKey` |
| `flexibility` | int | `50` | ∈ [0, 100] |

### `SlotSpec`

| Champ | Type | Validation |
|-------|------|------------|
| `slotKey` | String | non vide, pas de whitespace |
| `startTime` | String | **`HH:mm` 24h strict avec leading zero** |
| `typicalDurationMinutes` | int | `> 0 && <= 720` |
| `expectedType` | `ExpectedSlotType` | enum strict |

### Enums

```dart
enum DayIntensity { light, medium, intense }

enum MealStrategy {
  zoneRestaurants,
  hawkerCenters,
  fineDining,
  mixed,
}

enum ExpectedSlotType {
  anchor,
  visit,
  meal,
  rest,
  transfer,
  shopping,
  viewpoint,
  show,
  freeTime,
}
```

Sérialisation : `.name` (camelCase Dart). Désérialisation :
strict-by-default (FormatException sur valeur inconnue, cohérent
avec `BorderSensitivity` / `TripMode` Tâche 1.1).

## Validation simple

`DayTemplate.validate() → List<String>` agrège **toutes** les
erreurs en un seul appel (cf. style `DestinationIntelligence`).
Contrôles minimum :

- `template_key` non vide, sans whitespace
- `destination_key` non vide
- `theme` non vide
- `primary_zone_name` non vide
- `flexibility` ∈ [0, 100]
- `slots` ≥ 1 entrée
- chaque slot passe `SlotSpec.validate()`
- pas de doublon `recommended_anchor_keys` après normalisation
- pas de doublon `forbidden_complex_keys` après normalisation
- pas d'entrée vide dans ces listes
- pas de doublon `slot_key` après normalisation

Test "agrégation" : template massivement invalide → ≥ 5 erreurs
remontées en une fois.

## Validation croisée avec `DestinationIntelligence`

Méthode **séparée** :

```dart
List<String> validateAgainstDestination(DestinationIntelligence di)
```

Vérifie :
- `destination_key` matche `di.destinationKey` (trim insensible
  à la casse implicite)
- `primary_zone_name` existe dans `di.zones.name` (case-insensitive
  + trim)
- chaque `recommendedAnchorKeys` matche un
  `DestinationAnchor.name` (case-insensitive + trim) — autorise
  les références "lisibles"

**Ne vérifie PAS `forbiddenComplexKeys`** : `SameComplexGroup`
n'est pas dans la DI et n'est pas forcément disponible au site
d'appel. Le validateur de complexes pourra être ajouté plus
tard quand un caller fournit aussi la liste de groupes.

Test : template `forbiddenComplexKeys` aux valeurs inconnues
reste valide côté DI (`validateAgainstDestination` retourne
vide).

## Convention JSON

`snake_case`, cohérent avec `DestinationIntelligence` et
`SameComplexGroup` :

```json
{
  "template_key": "marina_bay_day",
  "destination_key": "singapore",
  "theme": "Marina Bay & waterfront icons",
  "primary_zone_name": "Marina Bay",
  "intensity": "medium",
  "recommended_anchor_keys": ["Gardens by the Bay", "Marina Bay Sands"],
  "forbidden_complex_keys": ["sentosa"],
  "meal_strategy": "mixed",
  "slots": [
    {
      "slot_key": "morning_anchor",
      "start_time": "09:30",
      "typical_duration_minutes": 180,
      "expected_type": "anchor"
    }
  ],
  "flexibility": 70
}
```

Backward-compat sur `fromJson()` :
- `flexibility` absent → default `50`
- `recommended_anchor_keys` / `forbidden_complex_keys` absents
  → fallback `[]`

## Migration SQL

`supabase/sql/day_templates.sql` :
- PK composite `(destination_key, template_key)` cohérent avec
  `same_complex_groups`
- Colonnes top-level (`theme`, `primary_zone_name`,
  `intensity`, `meal_strategy`, `flexibility`) pour filtrage
  rapide sans parser le payload
- 4 indexes (3 B-tree + 1 GIN payload)
- RLS `read-all`, pas de policy write → service_role uniquement
- Trigger `updated_at` automatique idempotent
- **Aucun seed.** Données Singapour → Tâche 4.2.

## Tests — 56 tests / 9 groupes

### 1. Modèle valide (3 tests)
- Template complet passe `validate()`
- Defaults exposés (`defaultFlexibility=50`, `minFlexibility=0`,
  `maxFlexibility=100`)
- Default flexibility via constructor

### 2. Round-trip JSON (5 tests)
- toJson + fromJson conserve toutes les valeurs
- JSON utilise snake_case (clés top-level + sous-clés
  SlotSpec)
- SlotSpec round-trip JSON
- Default flexibility appliqué si absent
- Listes optionnelles → `[]` si absentes

### 3. Enums parsing strict-by-default (9 tests)
- `DayIntensity` light/medium/intense + round-trip + inconnu →
  FormatException
- `MealStrategy` 4 valeurs + inconnu → FormatException
- `ExpectedSlotType` 9 valeurs + round-trip + inconnu →
  FormatException
- DayTemplate JSON avec intensity inconnue → FormatException

### 4. Validation champs obligatoires (6 tests)
- `templateKey` vide, avec whitespace
- `destinationKey` vide
- `theme` vide
- `primaryZoneName` vide
- `slots` vide

### 5. Validation flexibility (4 tests)
- -1, 101 rejetés
- 0, 100 acceptés (bornes)

### 6. Validation SlotSpec (14 tests)
- `slotKey` vide, avec whitespace
- `startTime` vide
- `09:00`, `13:30`, `19:45`, `00:00`, `23:59` acceptés
- `9:00` (manque leading zero), `25:00`, `12:99` rejetés
- `typicalDurationMinutes` à 0, négatif, > 720 rejetés
- `720` accepté (limite max)

### 7. Doublons (5 tests)
- `recommendedAnchorKeys` doublon casse différente
- entrée vide dans `recommendedAnchorKeys`
- `forbiddenComplexKeys` doublon
- entrée vide dans `forbiddenComplexKeys`
- `slotKey` doublon

### 8. validateAgainstDestination (8 tests)
- Template valide + anchors connus → 0 erreur croisée
- `destinationKey` différente rejetée
- `primaryZoneName` inconnu rejeté
- `primaryZoneName` match insensible à la casse
- `recommendedAnchorKey` inconnu rejeté
- `recommendedAnchorKey` match case/trim insensible
- `forbiddenComplexKeys` NON vérifié contre DI (hors scope 4.1)
- Sentosa zone connue → primaryZoneName Sentosa accepté

### 9. Agrégation d'erreurs (1 test)
- Template massivement invalide → ≥ 5 erreurs en une fois

## Ce qui n'est volontairement PAS fait

- ❌ Création des templates Singapour
  (`lib/data/day_templates/singapore_templates.dart`) — Tâche 4.2
- ❌ Création de `DayThemeAssigner`
- ❌ Création de `DayBuilder template-first` /
  `template_first_pipeline.dart`
- ❌ Consommation du flag `FeatureFlags.useDayTemplates`
- ❌ Modification de `places_first_pipeline.dart`
- ❌ Modification du Day Builder greedy V8.20+ existant
- ❌ Validation des `forbiddenComplexKeys` contre
  `SameComplexGroup` (le caller pourra cumuler les deux quand
  une registry combinée existera)
- ❌ Seed SQL Singapour
- ❌ Appel réseau / Supabase

## Confirmation aucun branchement runtime

- ✅ `grep -rn "DayTemplate\|day_template" lib/features/` →
  **aucune référence** dans les fichiers de production.
- ✅ `grep -rn "useDayTemplates" lib/` → seule occurrence dans
  `lib/config/feature_flags.dart` (déclaration, pas de
  consommation).
- ✅ Le test 4.1 importe uniquement :
  - `package:flutter_test/flutter_test.dart`
  - `package:voyage/models/day_template.dart`
  - `package:voyage/models/destination_intelligence.dart`

## Résultats validation

```
flutter analyze
  35 issues info préexistants (Tâche 0.1, inchangés)
  → lib/models/day_template.dart       : No issues found
  → test/models/day_template_test.dart : No issues found
  0 warning, 0 error sur les nouveaux fichiers

flutter test
  915 tests verts (859 Phase 3 + 56 nouveaux Tâche 4.1)

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
# Test modèle uniquement
flutter test test/models/day_template_test.dart

# Suite complète
flutter test
flutter test test/snapshots/generate_baseline.dart
flutter test test/snapshots/compare_snapshot.dart
```

## Prochaine étape : Tâche 4.2

La suite logique est **Tâche 4.2 — Données Singapour day
templates** : créer `lib/data/day_templates/singapore_templates.dart`
exposant une fonction `buildSingaporeDayTemplates()` retournant
la liste des templates Singapour (Marina Bay day, Sentosa day,
Chinatown civic day, Orchard botanic day, Arrival day,
Departure day, etc.). Par analogie avec
`buildSingaporeDestinationIntelligence()` (Tâche 1.2) et
`buildSingaporeSameComplexGroups()` (Tâche 2.2).

Ces données seront ensuite consommées par le `DayThemeAssigner`
(Tâche 4.3+) puis le `DayBuilder template-first` (Tâche 4.4+)
derrière le flag `useDayTemplates`. La Tâche 4.1 a posé la
**forme** des données ; les Tâches suivantes poseront le
**runtime**.
