# Phase 0 / Tâche 0.4 — Comparateur de snapshots planning

## Objectif

Créer un outil de **comparaison tolérante** entre 2 snapshots
planning : un baseline officiel et un snapshot courant. Produit un
rapport console + Markdown + verdict **PASS / WARN / FAIL**.

## Pourquoi cette tâche a été ajoutée

Le snapshot Singapour dépend en partie de la Google Places API et
du cache Supabase. Les runs successifs peuvent varier (visites,
distances, scores) **sans modification du pipeline** — cf. limite
documentée Tâche 0.1, observée concrètement lors des Tâches 0.2 et
0.3 :

| Run | Visites | Distance avg | Overall score |
|-----|--------:|-------------:|--------------:|
| Tâche 0.1 | 19 | 1615.8 m | n/a |
| Tâche 0.2 | 22 | 1529.2 m | 81.1 |
| Tâche 0.3 | 19 | 1234.9 m | 78.6 |

Ces variations sont **acceptées** (cf. règle d'or 2 "baseline
immuable par engagement humain"), mais sans outillage, elles
rendent toute comparaison A/B inutilisable : impossible de
distinguer une régression réelle d'un simple bruit API.

**Objectif explicite (cf. spec)** : *"créer un outil de
comparaison tolérant, lisible et utile pour détecter les vraies
régressions"* — pas de rendre Google Places déterministe (hors
scope).

## Fichiers créés / modifiés

- **`lib/quality/snapshot_comparator.dart`** *(créé, ~720 lignes)* —
  module pur, déterministe, sans accès réseau. Models :
  `SnapshotComparison`, `ScoreDiff`, `SnapshotVolumeDiff`,
  `SnapshotPlacesDiff`, `SnapshotDistancesDiff`, `SnapshotDaysDiff`,
  `DayDiff`. Enum `SnapshotVerdict {pass, warn, fail}`. Fonction
  publique `compareSnapshots({baseline, current, baselinePath?,
  currentPath?})`. Méthodes `toConsoleString()` + `toMarkdown()`.

- **`test/snapshots/compare_snapshot.dart`** *(créé)* — 16 tests :
  - 1 self-check Singapour (lit `singapore_baseline.json` × 2,
    attend PASS, écrit le rapport Markdown)
  - 15 fixtures fictives (self-check identique, petite variation,
    WARN-zone, 6 cas FAIL, JSON partiel/vide, lieux
    added/removed, normalisation diacritiques, jour devenu vide,
    Markdown output)

- **`test/snapshots/singapore_diff_report.md`** *(généré au run)* —
  artefact Markdown produit par le self-check. Écrasé à chaque
  run. Ne pas modifier manuellement.

- **`docs/migrations/phase0_task0_4.md`** *(ce document)*.

**Pipeline de production NON modifié** :
- `lib/features/planning/services/places_first_pipeline.dart` : intact
- `lib/features/planning/data/*` : intacts
- `lib/features/planning/services/day_builder.dart` : intact
- `lib/config/feature_flags.dart` : intact (aucun flag consommé)

## Design retenu

**Module pur réutilisable** dans `lib/quality/` (cohérent avec
`planning_metrics.dart` Tâche 0.2). Le script test
`test/snapshots/compare_snapshot.dart` orchestre l'I/O (lecture
JSON, écriture Markdown) et appelle le module pur. Avantages :
- Logique pure testable avec fixtures en mémoire (16 tests sans I/O)
- Réutilisable si une phase future veut intégrer le comparateur
  dans un CI tool ou un dashboard
- Conforme règle feedback `no_parallel_models` : nouveaux models
  sémantiquement distincts (comparaison de snapshots, pas un
  planning ni un rapport métriques)

**API minimale et explicite** :
```dart
SnapshotComparison compareSnapshots({
  required Map<String, dynamic> baseline,
  required Map<String, dynamic> current,
  String baselinePath = '(baseline)',
  String currentPath = '(current)',
});
```

Entrée = `Map<String, dynamic>` (le JSON décodé). Aucun couplage à
`dart:io` côté logique pure. Le script test fait `File.readAsStringSync`
+ `jsonDecode` puis passe la map au comparateur.

**Robustesse JSON** : tous les accès sont défensifs via les helpers
`_readNum`/`_readInt`/`_readDouble`/`_readList` qui parcourent un
chemin et retournent `null` si à un moment le nœud n'est pas un
`Map`/`List`/`num`. Constante `kNotAvailable = 'not_available'`
propagée dans les rapports pour les champs manquants. **Jamais de
crash** sur JSON partiel.

## Champs comparés

Section par section :

### 1. Volumétrie
- `summary.total_visits` (delta + change %)
- `summary.total_meals`
- `summary.total_generated_days` (active days)
- `summary.free_days_count`
- slots = visits + meals (reconstruit)

### 2. Scores qualité (6)
- `quality_report.overall_score`
- `quality_report.scores.coherence`
- `quality_report.scores.diversity`
- `quality_report.scores.repetition`
- `quality_report.scores.transition`
- `quality_report.scores.coverage`

Pour chaque score : baseline, current, delta, status individuel
(`OK` / `WARN` / `FAIL`).

### 3. Lieux
Comparaison par **titre normalisé** :
- lowercase
- strip diacritiques (accents européens + macrons japonais)
- non-alphanumérique → espace
- whitespace collapsé

Sortie : liste ajoutés, liste retirés, répétitions baseline /
current, total uniques, ratio de churn.

### 4. Distances
- `summary.avg_inter_slot_distance_meters` (delta)
- Max inter-slot reconstruit depuis
  `quality_report.by_day[].max_inter_slot_meters` (max global)

### 5. Journées
Pour chaque date (union baseline + current, triée) :
- `quality_report.by_day[].total_slots / visits_count / meals_count`
- Flag `becameEmpty` : baseline ≥ 1 slot ET current = 0

Détection des dates qui basculent en vide (signal de régression).

## Seuils PASS / WARN / FAIL (Phase 0, provisoires)

Centralisés en constantes nommées en haut de
`lib/quality/snapshot_comparator.dart` pour modification facile.

### FAIL (régression bloquante)
| Critère | Seuil |
|---------|------:|
| Coverage delta ≤ -25 points | `_kFailCoverageDrop = 25.0` |
| Coverage absolue < 60 | `_kFailCoverageBelow = 60.0` |
| Repetition absolue < 70 | `_kFailRepetitionBelow = 70.0` |
| Overall delta ≤ -20 points | `_kFailOverallDrop = 20.0` |
| Visits drop > 40% | `_kFailVisitsDropPct = 40.0` |
| Baseline ≥ 5 visites ET current ≤ 1 | hard-coded |
| JSON illisible | `FormatException` levée par `jsonDecode` |

### WARN (à investiguer, non-bloquant)
| Critère | Seuil |
|---------|------:|
| Overall delta ≤ -10 (et > -20) | `_kWarnOverallDrop = 10.0` |
| Coherence delta ≤ -15 | `_kWarnCoherenceDrop = 15.0` |
| Transition delta ≤ -15 | `_kWarnTransitionDrop = 15.0` |
| Visits change ±20-40% | `_kWarnVisitsChangePct = 20.0` |
| Titles diff > 30% | `_kWarnTitlesDiffPct = 30.0` |
| ≥1 jour devient vide | hard-coded |

### PASS
Aucun seuil WARN/FAIL franchi.

**Note** : ces seuils sont **provisoires Phase 0**. Documenté dans
le code. À recalibrer dans les phases ultérieures quand on aura
collecté plus de données sur la stabilité réelle des runs.

## Limites connues

1. **Comparaison de lieux fuzzy par titre** — pas de matching par
   `placeId` (non présent dans `ActivitySuggestion`). Risque de
   faux positif si un même lieu apparaît avec un titre légèrement
   différent qui ne survit pas à la normalisation (ex: "Sentosa
   Island" vs "Sentosa"). Cf. limite documentée Tâche 0.2
   ("complexes sémantiques") — sera traité Phase 2 via
   `SameComplexGroup`.

2. **Seuils Phase 0 calibrés sur intuition** — pas sur des données
   statistiques. À refiner quand on aura plus d'historique de
   runs successifs.

3. **Pas d'I/O CLI native** — le test passe des chemins via
   constantes en haut de `test/snapshots/compare_snapshot.dart`,
   pas via arguments CLI (limitation `flutter test`). Pour
   comparer 2 fichiers différents : modifier les constantes
   `_kBaselinePath` / `_kCurrentPath` ou utiliser le module pur
   `compareSnapshots()` depuis un autre point d'entrée Dart.

4. **Détection journée vide se base sur `quality_report.by_day`** —
   si ce bloc est absent du JSON, la détection ne fonctionne pas.
   Acceptable car la baseline officielle l'inclut toujours (depuis
   Tâche 0.2).

5. **Rapport Markdown unique** — le self-check écrase
   `singapore_diff_report.md` à chaque run. Si plusieurs runs à
   comparer, conserver une copie manuellement. Pas critique pour
   Phase 0.

## Commande

```bash
# Self-check Singapour + 15 fixtures fictives + génère Markdown.
flutter test test/snapshots/compare_snapshot.dart

# Génère le snapshot baseline (Tâche 0.1) — pré-requis du
# self-check si le baseline n'existe pas encore.
flutter test test/snapshots/generate_baseline.dart

# Suite complète (incluant compare_snapshot + métriques + flags).
flutter test
```

## Résultat self-check Singapour (run actuel)

```
Singapore snapshot comparison
Baseline: test/snapshots/singapore_baseline.json
Current : test/snapshots/singapore_baseline.json
Verdict : PASS

Volume
─ visits      : 19 → 19 (delta +0)
─ meals       : 4 → 4
─ slots       : 23 → 23
─ active days : 8 → 8
─ free days   : 0 → 0

Quality scores
─ overall     : 78.6 → 78.6 (delta +0.0) OK
─ coherence   : 73.1 → 73.1 (delta +0.0) OK
─ diversity   : 34.4 → 34.4 (delta +0.0) OK
─ repetition  : 100.0 → 100.0 (delta +0.0) OK
─ transition  : 85.6 → 85.6 (delta +0.0) OK
─ coverage    : 100.0 → 100.0 (delta +0.0) OK

Places
─ removed : 0
─ added   : 0
─ change ratio : 0.0 %

Distances
─ avg inter-slot (m) : 1234.9 → 1234.9 (delta +0.0)

Days
─ no day became empty

Warnings : (none)
```

Verdict **PASS** confirmé sur self-check identique.

Le rapport Markdown complet est dans
[`test/snapshots/singapore_diff_report.md`](../../test/snapshots/singapore_diff_report.md).

## Exemple de verdict — fixtures de test

Pour démontrer les déclencheurs, les 15 fixtures testent chaque
classe de seuil :

| Fixture | Description | Verdict attendu | Vérifié |
|---------|-------------|----------------|---------|
| Self-check fixture | baseline = current | PASS | ✓ |
| Petite variation | overall -5 | PASS | ✓ |
| WARN-zone | overall -12 | WARN | ✓ |
| Coverage drop -30 | -30 points | FAIL | ✓ |
| Coverage absolue < 60 | current=55 | FAIL | ✓ |
| Repetition < 70 | current=50 | FAIL | ✓ |
| Overall drop -25 | -25 points | FAIL | ✓ |
| Visits drop -50% | 20 → 10 | FAIL | ✓ |
| Quasi vide | baseline 20, current 1 | FAIL | ✓ |
| JSON vide | maps vides | PASS + notes | ✓ |
| Snapshot partiel | summary OK, quality absent | PASS | ✓ |
| Lieux added/removed | normalisation casse+ponct | added/removed corrects | ✓ |
| Diacritiques | "Éïffèl Tower" = "Eiffel Tower" | added/removed empty | ✓ |
| Markdown sections | génération valide | sections présentes | ✓ |
| Jour devenu vide | 19/05 disparu | WARN + emptyDates | ✓ |

## Résultats de validation

```
flutter analyze
  35 issues found (info préexistants Tâche 0.1, inchangés)
  → lib/quality/snapshot_comparator.dart : No issues found
  → test/snapshots/compare_snapshot.dart : No issues found
  0 warning, 0 error sur les nouveaux fichiers

flutter test
  All tests passed! 483 tests verts (inchangé Tâche 0.3).
  Convention projet : les fichiers sans suffixe `_test.dart` NE
  sont PAS picked-up par `flutter test` global (cohérent avec
  `generate_baseline.dart` et `places_first_harness.dart`). Le
  comparator s'invoque explicitement.

flutter test test/snapshots/compare_snapshot.dart
  16 tests passés (1 self-check Singapour PASS + 15 fixtures)
  Markdown report écrit → test/snapshots/singapore_diff_report.md

flutter test test/snapshots/generate_baseline.dart
  1 test passé (baseline régénéré).
```

## Confirmation contraintes

- ✅ `places_first_pipeline.dart` **non modifié**
- ✅ Pipeline production **non modifié**
- ✅ Aucun feature flag branché
- ✅ Aucun `DestinationIntelligence` créé
- ✅ Aucun `SameComplexGroup` créé
- ✅ Aucun `DayTemplate` créé
- ✅ Aucun comportement utilisateur changé
- ✅ Aucun appel réseau (le comparateur ne lit que des JSON locaux)
- ✅ Le comparateur travaille uniquement sur des JSON déjà générés
- ✅ Variations Google Places **documentées**, non corrigées
- ✅ Une seule tâche, un seul commit

## Hors scope (n'est PAS dans cette tâche)

- Rendre Google Places déterministe (impossible côté client).
- Mécanisme de fixtures HTTP / replay des appels Places.
- UI / dashboard de visualisation des comparaisons.
- Branchement automatique du comparateur dans la CI.
- Calibration statistique des seuils (Phase 0 = intuition).
- Détection complexes sémantiques (Phase 2 `SameComplexGroup`).
