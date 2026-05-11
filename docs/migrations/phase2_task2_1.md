# Phase 2 / Tâche 2.1 — Modèle `SameComplexGroup`

## Objectif

Poser la **structure de données** des "complexes touristiques"
— groupes d'entrées Google Places différentes mais sémantiquement
le même complexe pour un voyageur (Sentosa Island / Universal
Studios / Resorts World Sentosa ; Gardens by the Bay / Supertree
Grove / Cloud Forest ; Marina Bay Sands / SkyPark / The Shoppes).

**Tâche purement de schéma + validation + sérialisation + tests
unitaires.** Aucune donnée Singapour (Tâche 2.2), aucun matcher
(Tâche 2.3), aucun branchement sélecteur (Tâche 2.4). Le flag
`useSameComplexDedup` reste OFF et n'est consommé nulle part.

Conforme aux règles d'or :
- **1 — Ne JAMAIS casser le pipeline existant** : 0 fichier de
  production modifié.
- **3 — Une seule tâche, un seul commit, une seule PR**.
- **5 — Tests dans le même commit que la production**.
- **7 — Étendre l'existant plutôt que dupliquer** : la
  normalisation n'utilise aucune dépendance externe et reste
  réutilisable dans Tâche 2.3.

## Fichiers créés

- **`lib/models/same_complex_group.dart`** *(créé, ~260 lignes)*
  — modèle immutable `SameComplexGroup` + fonction top-level
  `normalizeComplexText`.
- **`supabase/sql/same_complex_groups.sql`** *(créé, ~100 lignes)*
  — table + 5 indexes + RLS read-all + trigger updated_at.
  **Aucun seed.**
- **`test/models/same_complex_group_test.dart`** *(créé, ~400 lignes)*
  — **54 tests** en 7 groupes. Aucune dépendance réseau /
  Supabase / mock framework.
- **`docs/migrations/phase2_task2_1.md`** *(ce document)*.

## Fichiers de production non modifiés

- `lib/features/planning/services/places_first_pipeline.dart`
  intact.
- `lib/features/planning/services/day_builder.dart` intact.
- `lib/models/destination_intelligence.dart` intact.
- `lib/config/feature_flags.dart` intact (`useSameComplexDedup`
  reste OFF, non consommé).

## Conception

### Classe `SameComplexGroup`

| Champ | Type | Default | Validation |
|-------|------|---------|------------|
| `complexKey` | `String` | — | non vide, pas de whitespace |
| `destinationKey` | `String` | — | non vide |
| `aliases` | `List<String>` | — | ≥ 1 entrée non vide, pas de doublon après normalisation |
| `placeIds` | `List<String>` | `[]` | peut être vide ; pas de doublon après trim |
| `maxPerDay` | `int` | `1` | ≥ 1 |
| `maxPerTrip` | `int` | `2` | ≥ 1 et ≥ `maxPerDay` |
| `priority` | `int` | `3` | ∈ [1, 5] |

#### Choix de design

- **Identification** : `(destinationKey, complexKey)` est la clé
  fonctionnelle. Reflétée en SQL via la primary key composite.
  Permet un même `complexKey` partagé entre destinations distinctes
  (homonymie improbable mais légale).
- **`complexKey` snake_case strict** : interdiction des
  whitespaces dans la valeur (`"sentosa"`, pas `"Sentosa Island"`).
  Le champ est un identifiant technique, pas un libellé. La
  contrainte est testable mécaniquement.
- **`aliases` séparé de `placeIds`** : deux voies de matching
  (sémantique vs identifiant Google) volontairement disjointes.
  La Tâche 2.3 (matcher) les utilisera de façon complémentaire.
- **`maxPerDay = 1` / `maxPerTrip = 2` par défaut** : valeurs
  produit raisonnables (un complexe touristique mérite rarement
  plus d'un slot/jour, peut être visité 2× sur un voyage moyen).
  Surchargeables en data si nécessaire (Sentosa 6 jours peut
  passer à `maxPerTrip = 3`).
- **`priority ∈ [1, 5]`** : aligné sur
  `DestinationAnchor.importance` (Tâche 1.1) — même échelle pour
  éviter le bruit cognitif.
- **`validate()` agrégeant** : retour `List<String>` plutôt que
  `throw`, cohérent avec `DestinationIntelligence`. Permet à un
  futur seed Supabase de logger toutes les erreurs d'un coup.

### Fonction `normalizeComplexText`

Top-level (non méthode), publique, testable indépendamment et
réutilisable par le matcher Tâche 2.3 sans instancier un groupe.

Pipeline de normalisation :

1. `toLowerCase + trim`
2. Mapping accent → ASCII (table compacte couvrant fr/es/pt/de/it/
   scandinave) — pas de dépendance `package:characters` lourde
3. `[^a-z0-9]+ → ' '` (ponctuation/tirets/apostrophes → espace)
4. Collapse espaces multiples + `trim`

Propriétés vérifiées par tests :
- Case-insensitive (`SENTOSA ISLAND` ≡ `Sentosa Island`)
- Robuste aux espaces multiples
- Robuste à la ponctuation (`Gardens-by-the Bay!` ≡ `Gardens by the Bay`)
- Robuste aux accents courants (`Musée d'Orsay` → `musee d orsay`,
  `Café Niçois` → `cafe nicois`)
- Digrammes `æ → ae`, `œ → oe`, `ß → ss`
- **Idempotent** : `normalize(normalize(s)) == normalize(s)`
- Chiffres conservés (`Pier 39` → `pier 39`)
- Chaîne vide ou ponctuation pure → `''`

### Helpers de matching

#### `matchesAlias(String candidateName) → bool`
- Normalise candidate + chaque alias
- Compare égalité stricte
- **Pas de fuzzy / préfixe / Levenshtein** — relève de la
  Tâche 2.3 (matcher)

#### `containsPlaceId(String placeId) → bool`
- Trim des deux côtés
- Compare égalité **case-sensitive** (les `place_id` Google sont
  case-sensitive)

## Convention JSON

`snake_case` pour cohérence avec `DestinationIntelligence` et le
reste du projet :

```json
{
  "complex_key": "sentosa",
  "destination_key": "singapore",
  "aliases": [
    "Sentosa Island",
    "Universal Studios Singapore",
    "Resorts World Sentosa"
  ],
  "place_ids": [],
  "max_per_day": 1,
  "max_per_trip": 2,
  "priority": 5
}
```

`fromJson()` :
- Lève `FormatException` sur clés requises manquantes ou typées
  incorrectement (`complex_key`, `destination_key`, `aliases`)
- Applique les defaults sur clés optionnelles absentes
  (`place_ids`, `max_per_day`, `max_per_trip`, `priority`) —
  cohérent avec l'évolution future du schéma (rétro-compat).

## Validation — checks couverts par les tests

Cumulé en une seule liste agrégée par `validate()` :

- `complex_key` vide → erreur
- `complex_key` avec whitespace → erreur
- `destination_key` vide → erreur
- `aliases` vide → erreur
- `aliases[i]` vide après trim → erreur indexée
- `aliases[i]` doublon après normalisation → erreur indexée
- `place_ids[i]` vide après trim → erreur indexée
- `place_ids[i]` doublon après trim → erreur indexée
- `max_per_day < 1` → erreur
- `max_per_trip < 1` → erreur
- `max_per_trip < max_per_day` → erreur
- `priority` hors [1, 5] → erreur

Test "agrégation" : groupe maximalement invalide → ≥ 5 erreurs
remontées en une fois.

## Migration SQL

`supabase/sql/same_complex_groups.sql` reproduit la convention
établie en Tâche 1.1 (`destination_intelligence.sql`) :

- Table avec colonnes top-level pour requêtes filtrées rapides
  (`destination_key`, `complex_key`, `max_per_day`, `max_per_trip`,
  `priority`) + `payload jsonb` contenant l'objet complet
  sérialisé.
- Colonnes JSONB dédiées `aliases` et `place_ids` (plutôt que de
  les laisser dans le payload uniquement) pour pouvoir les
  indexer en GIN et exécuter des requêtes
  `where aliases @> '["..."]'` rapides à grande échelle.
- 5 indexes : 2 B-tree (`destination_key`, `complex_key`) + 3 GIN
  (`aliases`, `place_ids`, `payload`).
- RLS `read-all` (lecture publique anon + auth), pas de policy
  write → écriture réservée au service_role (admin / migrations).
- Trigger `updated_at` automatique, idempotent via `drop/create`.
- **Primary key composite** `(destination_key, complex_key)`.
- **Aucun seed.** Données Singapour → Tâche 2.2.

## Tests — 54 tests en 7 groupes

### 1. Modèle valide (3 tests)
- Sentosa fixture passe `validate()` sans erreur
- `place_ids` vide accepté
- `place_ids` non vides sans doublons acceptés

### 2. Round-trip JSON (5 tests)
- `toJson()` + `fromJson()` conserve toutes les valeurs
- JSON utilise bien `snake_case`
- `fromJson()` lève `FormatException` sur clé manquante
- `fromJson()` lève `FormatException` sur aliases non liste
- `fromJson()` applique les defaults sur clés optionnelles absentes

### 3. Defaults (4 tests)
- `maxPerDay = 1`, `maxPerTrip = 2`, `priority = 3`
- Constantes statiques exposées (`defaultMaxPerDay`,
  `defaultMaxPerTrip`, `defaultPriority`, `minPriority`,
  `maxPriority`)

### 4. Validation (17 tests)
- `complexKey` vide, avec whitespace, avec trailing space
- `destinationKey` vide
- `aliases` vide, alias individuel vide
- `placeId` individuel vide
- `maxPerDay` à 0, négatif
- `maxPerTrip` à 0, < `maxPerDay`
- `priority` à 0, 6, négatif
- Alias doublon après normalisation (case / ponctuation)
- `placeId` doublon (exact / whitespace)
- Agrégation : groupe maximalement invalide → ≥ 5 erreurs

### 5. `normalizeComplexText` (11 tests)
- lowercase, trim, collapse espaces
- Apostrophe (`Musée d'Orsay`)
- Ponctuation/tirets (`Gardens-by-the Bay!`)
- Accents fr/es/pt/de (`Café Niçois`, `São Paulo`, `Köln`,
  `München`)
- Digrammes (`Æther`, `Œuvre`, `Straße`)
- Chiffres conservés
- Chaîne vide / ponctuation pure → `''`
- **Idempotence** sur plusieurs entrées

### 6. `matchesAlias` (6 tests)
- Case-insensitive
- Whitespace/punctuation différents
- Alias hors liste ne matche pas
- Chaîne vide ne matche pas
- **Substring strict ne matche pas** (pas de fuzzy en 2.1)
- Accents côté candidat

### 7. `containsPlaceId` (6 tests)
- Match exact
- Whitespace avant/après accepté
- **Case-sensitive**
- `placeId` inconnu ne matche pas
- Chaîne vide ne matche pas
- Groupe sans `placeIds` → toujours false

## Ce qui n'est volontairement PAS fait

- ❌ Données Singapour complexes
  (`lib/data/complexes/singapore_complexes.dart`) — Tâche 2.2
- ❌ Loader des complexes — Tâche 2.2
- ❌ Matcher (fuzzy / préfixe / Levenshtein) — Tâche 2.3
- ❌ Branchement sélecteur déterministe — Tâche 2.4
- ❌ Consommation du flag `useSameComplexDedup` — Tâche 2.4
- ❌ Modification de `places_first_pipeline.dart`
- ❌ Modification de `DestinationIntelligence`
- ❌ Suppression d'ancien code

## Confirmation aucun branchement runtime

- ✅ `grep -rn "SameComplexGroup\|same_complex_group" lib/features/`
  → **aucune référence** dans les fichiers de production planning.
- ✅ `grep -rn "useSameComplexDedup" lib/` → seule occurrence dans
  `lib/config/feature_flags.dart` (déclaration de la constante,
  pas de consommation).
- ✅ Le test 2.1 importe uniquement :
  - `package:flutter_test/flutter_test.dart`
  - `package:voyage/models/same_complex_group.dart`

## Résultats validation

```
flutter analyze
  35 issues found (info préexistants Tâche 0.1, inchangés)
  → lib/models/same_complex_group.dart       : No issues found
  → test/models/same_complex_group_test.dart : No issues found
  0 warning, 0 error sur les nouveaux fichiers

flutter test
  653 tests verts (599 Tâche 1.4 + 54 nouveaux Tâche 2.1)

flutter test test/snapshots/generate_baseline.dart
  1 test passé, baseline JSON régénéré
  Overall score : 81.97 / 19 visites / coverage 100%
  Variation Google Places attendue (cf. Tâche 0.1)

flutter test test/snapshots/compare_snapshot.dart
  16 tests passés (1 self-check + 15 fixtures)
  Verdict self-check Singapour : PASS
```

Le snapshot baseline a légèrement varié vs Tâche 1.4 (overall
78.6 → 81.97) — variation purement attribuable à Google Places /
cache, **pas à SameComplexGroup** (qui n'est branché nulle part).
Le verdict comparator PASS confirme que la variation reste dans
les seuils.

## Commande

```bash
# Test unitaire uniquement
flutter test test/models/same_complex_group_test.dart

# Suite complète
flutter test
flutter test test/snapshots/generate_baseline.dart
flutter test test/snapshots/compare_snapshot.dart
```

## Prochaine étape : Tâche 2.2

La suite logique est **Tâche 2.2 — Données Singapour
complexes** : créer `lib/data/complexes/singapore_complexes.dart`
exposant une fonction `buildSingaporeComplexes()` retournant la
liste des complexes connus de Singapour (Sentosa, Gardens by the
Bay, Marina Bay Sands, Chinatown Heritage, etc.) — par analogie
avec `buildSingaporeDestinationIntelligence()` en Tâche 1.2.

Ces données seront ensuite consommées par le matcher (Tâche 2.3)
puis branchées au sélecteur déterministe (Tâche 2.4) derrière le
flag `useSameComplexDedup`.
