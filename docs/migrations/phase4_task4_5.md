# Phase 4 / Tâche 4.5 — Pipeline alternatif template-first (flag-gated)

## Objectif

Créer un **pipeline alternatif template-first** orchestrant
les briques Phase 4 (4.1-4.4), branché derrière le flag
`useDayTemplates` (OFF par défaut). Quand le flag est OFF, le
pipeline legacy reste **strictement inchangé**. Quand le flag
est ON, le moteur tente template-first et fallback proprement
sur le legacy si nécessaire.

**La qualité finale (A/B) sera évaluée en Tâche 4.6.** La 4.5
livre uniquement l'orchestration exécutable.

Conforme aux règles d'or :
- **1 — Ne JAMAIS casser le pipeline existant** : flag OFF =
  comportement strictement pré-4.5. Tests pipeline pré-existants
  (182) restent verts.
- **3 — Une tâche, un commit, une PR**.
- **5 — Tests dans le même commit que la production**.
- **7 — Étendre l'existant** : aucun refactor lourd du pipeline,
  réutilisation de `gatherCandidatesForTrip`,
  `insertDeterministicMeals`, et flag pattern existants.

## Fichiers lus avant modification

- `lib/features/planning/services/places_first_pipeline.dart`
  (point d'entrée `runAutoPlacesFirst` + body, structures
  `DayCandidates` + `PlacesPromptInput`, helpers existants)
- `lib/services/day_theme_assigner.dart` (Tâche 4.3)
- `lib/services/template_first_day_builder.dart` (Tâche 4.4)
- `lib/data/day_templates/singapore_templates.dart` (Tâche 4.2)
- `lib/data/destinations/destination_intelligence_registry.dart` (Tâche 3.2)
- `lib/data/complexes/complex_registry.dart` (Tâche 2.4)
- `lib/services/complex_matcher.dart` (Tâche 2.3)
- `lib/config/feature_flags.dart`
- `lib/features/planning/models/activity_suggestion_model.dart`
- `lib/features/trips/models/trip_model.dart`
- `lib/features/planning/services/places_nearby_service.dart`
  (`NearbyCandidate`)
- `test/snapshots/generate_baseline.dart`
- Tests pipeline existants
  (`places_first_pipeline_test.dart`,
  `day_builder_test.dart`, `same_complex_dedup_test.dart`,
  `destination_scope_dedup_test.dart`)

## Fichiers créés

- **`lib/data/day_templates/day_template_registry.dart`**
  *(~55 lignes)* — `loadLocalDayTemplatesForDestination(String?)`
  resolver sync, registry par destinationKey. Mirror Tâches 2.4
  / 3.2.
- **`lib/features/planning/services/template_first_pipeline.dart`**
  *(~340 lignes)* — orchestrateur `tryTemplateFirstPipeline` +
  `TemplateFirstResult` + adapter
  `templateCandidateFromNearbyCandidate` + conversion
  `templateDayBuildResultToActivities` + mapping tag.
- **`test/data/day_templates/day_template_registry_test.dart`**
  *(~60 lignes)* — 7 tests registry.
- **`test/features/planning/services/template_first_pipeline_test.dart`**
  *(~600 lignes)* — **25 tests** en 7 groupes.
- **`docs/migrations/phase4_task4_5.md`** *(ce document)*.

## Fichiers modifiés

- **`lib/features/planning/services/places_first_pipeline.dart`** :
  - 2 imports ajoutés (`day_template_registry`,
    `template_first_pipeline`)
  - Bloc routing dans `_runAutoPlacesFirstBody` après filtrage
    `existingTitlesNormalized`, avant `groupDaysByCenter`,
    uniquement pour `category == SuggestionCategory.all`.
- **`test/snapshots/generate_baseline.dart`** :
  - 2 imports ajoutés
  - Routing template-first ajouté avant l'appel à
    `selectVisitsDeterministic` legacy

## Point exact du routing

### Production (`_runAutoPlacesFirstBody`)

Position : après `pool` fetché + filtre `existingTitlesNormalized`,
avant `groupDaysByCenter`/`partitionByQuartier`/`selectVisitsDeterministic`.

```dart
if (category == SuggestionCategory.all) {
  final templateFlags = FeatureFlags.fromEnvironment();
  if (templateFlags.useDayTemplates) {
    final tfDi = lookupLocalDestinationIntelligence(trip.destination);
    final tfTemplates =
        loadLocalDayTemplatesForDestination(trip.destination);
    if (tfDi != null && tfTemplates.isNotEmpty) {
      final tfComplexGroups =
          loadLocalComplexGroupsForDestination(trip.destination);
      final tfResult = tryTemplateFirstPipeline(
        trip: trip,
        di: tfDi,
        templates: tfTemplates,
        pool: pool,
        complexGroups: tfComplexGroups,
      );
      if (tfResult.isUsable) {
        // ... insertDeterministicMeals + return
      }
      // else: fallback legacy continue ci-dessous
    }
  }
}

final groups = groupDaysByCenter(pool);  // legacy continue
```

**Position délibérée** :
- AVANT `groupDaysByCenter` / `selectVisitsDeterministic` : évite
  le travail de clustering legacy quand template-first prend
  la main.
- APRÈS `pool` fetch : réutilise le `gatherCandidatesForTrip`
  existant (pas de duplication de logique Google Places).
- LIMITÉE à `category == all` : le template-first ne s'applique
  pas pour `restaurants` (legacy Gemini) ni `activities`
  (visites seules — cas plus rare).

### Baseline script (`generate_baseline.dart`)

Le baseline appelle directement `selectVisitsDeterministic`
(legacy path) pour des raisons historiques. Pour mesurer le
flag ON via baseline, le **même** routing est ajouté dans le
script :

```dart
if (featureFlags.useDayTemplates && tfDi != null) {
  final tfTemplates = loadLocalDayTemplatesForDestination(...);
  if (tfTemplates.isNotEmpty) {
    final tfResult = tryTemplateFirstPipeline(...);
    if (tfResult.isUsable) {
      // ... print + insertDeterministicMeals + return
    }
  }
}
// Sinon legacy continue
```

Avantage : un seul `flutter test --dart-define=USE_DAY_TEMPLATES=true
test/snapshots/generate_baseline.dart` exerce le flag ON et
permet l'A/B Tâche 4.6.

## Routing flag OFF / ON

| Cas | Comportement |
|-----|--------------|
| `useDayTemplates` OFF (default) | court-circuit total, legacy path. Aucun log template_first. Aucun appel à `tryTemplateFirstPipeline`. |
| `useDayTemplates` ON, destination inconnue (pas dans registry) | log `[template_first_fallback] reason=missing_di_or_templates`, legacy continue |
| `useDayTemplates` ON, destination supportée, `tfResult.isUsable == false` | log `[template_first_fallback] reason=<reason>`, legacy continue |
| `useDayTemplates` ON, destination supportée, `tfResult.isUsable == true` | log `[template_first_pipeline] using template-first N visits`, retourne `[...tfActivities, ...mealsViaLegacy]` |
| `category != SuggestionCategory.all` | comportement legacy strict (template-first non tenté) |

## Source des candidats

**Réutilise `gatherCandidatesForTrip` existant** — aucune
nouvelle collecte Places, aucun appel Gemini, aucun nouveau
scoring. Le pool `List<DayCandidates>` est passé tel quel à
`tryTemplateFirstPipeline`. Cohérent avec spec : *"ne pas
dupliquer la logique Google Places, ne pas réécrire une
nouvelle collecte"*.

## Adapter NearbyCandidate → TemplateCandidate

`templateCandidateFromNearbyCandidate(c, ...)` :

| Champ TemplateCandidate | Source NearbyCandidate / logique |
|-------------------------|------------------------------------|
| `placeKey` | `c.placeId` si non vide, sinon `name@lat,lng` |
| `title` | `c.name` |
| `category` | `c.types.first` (Google Places type) ou `point_of_interest` |
| `score` | `rating × log(reviews)` (cohérent legacy) |
| `anchorKey` | match exact case-insensitive sur `di.anchors.name` |
| `complexKey` | résolu via `matchComplex(name, placeId, groups)` (Tâche 2.3) |
| `rating`, `userRatingCount`, `lat`, `lng` | pass-through |
| `estimatedDurationMinutes` | `null` → builder utilise `slot.typicalDurationMinutes` |

Tests dédiés (10) vérifient chacun de ces mappings.

## Conversion TemplateDayBuildResult → ActivitySuggestion

`templateDayBuildResultToActivities(result)` produit une
`List<ActivitySuggestion>`, **ignorant les slots vides** (spec
4.5 : *"slots sans candidat : les ignorer pour cette tâche, ne
pas créer de placeholder UI"*).

| Champ ActivitySuggestion | Source |
|--------------------------|--------|
| `dayDate` | `result.date` |
| `startTime` | `assignment.slot.startTime` (HH:mm) |
| `title` | `candidate.title` |
| `tag` | mapping `_tagFromCategory(category, expectedType)` |
| `durationMinutes` | `assignment.effectiveDurationMinutes` |
| `latitude`/`longitude` | `candidate.lat`/`candidate.lng` |

Mapping tag : `restaurant/meal → Gastronomie`, `shopping_mall →
Shopping`, `park/garden → Nature`, `museum/tourist_attraction →
Culture`, etc. Fallback via `expectedType` du slot si catégorie
inconnue.

## Stratégie repas

**Réutilisation du helper legacy `insertDeterministicMeals`**.
Le pipeline template-first construit uniquement les VISITES.
Les repas sont insérés ensuite par le caller, en appelant
`insertDeterministicMeals(activities: tfVisits, pool: pool,
nearbyService: ..., ...)`. Avantages :
- Aucun refactor de la logique repas
- Aucun duplicate scoring restos
- Comportement cohérent avec legacy : flag ON visites
  template-first + flag ON repas legacy

Documenté comme **choix volontaire 4.5** : la Tâche 4.6 pourra
mesurer l'impact qualitatif sans confondre visites + repas.

## Critère `isUsable`

```dart
final isUsable = allActivities.isNotEmpty &&
    (allActivities.length >= 3 || fillRatio >= 0.5);
```

Où `fillRatio = daysWithActivities / totalDays`. Permet de
fallback legacy si template-first produit un résultat trop
pauvre (pool insuffisant, destination mal couverte, etc.).

## Fallback reasons stables

| Code | Cause |
|------|-------|
| `missing_di_or_templates` | DI ou templates absents du registry (logged au call site) |
| `missing_templates` | `templates` vide passé à l'orchestrateur |
| `empty_pool` | `pool` vide passé à l'orchestrateur |
| `no_assignments` | `assignThemesToDays` n'a produit aucune assignation |
| `result_too_sparse` | `isUsable == false` (peu d'activités générées) |
| `exception` | Exception capturée durant l'orchestration |

Toute exception inattendue est attrapée → fallback legacy
proprement. **Jamais de crash** en flag ON (testé).

## Tests — 32 tests / 8 groupes

### Registry (7 tests)
- Singapore standard / aliases / casse mixte / inconnues / null

### Adapter (10 tests)
- placeKey via placeId / fallback name+coords
- title, category, score formule
- anchor detection case-insensitive
- complexKey via matchComplex (Universal Studios → sentosa)
- lat/lng/rating/reviews mappings

### Conversion (5 tests)
- Slots avec candidat → ActivitySuggestion
- Slots vides ignorés
- Tag Gastronomie / Shopping / fallback via slot type

### Pipeline orchestrateur (3 tests)
- Voyage 3 jours produit un planning utilisable
- Dates cohérentes (couvrent plage trip)
- **alreadyUsedPlaceKeys threadé** entre jours (anti-dup
  cross-trip) — pool 6 candidates sur 3 jours → ≥ 4 uniques

### Fallback reasons (3 tests)
- `templates` vide → `missing_templates`
- `pool` vide → `empty_pool`
- pool présent sans candidats → `result_too_sparse`

### Déterminisme (1 test)
- 2 runs identiques → même séquence de titres

### Adapter integration (2 tests)
- "Gardens by the Bay" reconnu comme anchor + complex
- `forbiddenComplexKeys` (sentosa) appliqués pour marina_bay_day

### Flag OFF sanity (1 test)
- `FeatureFlags.useDayTemplates` reste OFF par défaut

## Résultats snapshot Singapour

### Flag OFF (canonical, commit final)

```
flutter test test/snapshots/generate_baseline.dart
  Overall 82.78 / 18 visites / coverage 100%
  0 log [template_first_pipeline]
  0 log [template_first_fallback]
  Verdict comparator : PASS
```

### Flag ON via `--dart-define`

```
flutter test --dart-define=USE_DAY_TEMPLATES=true \
  test/snapshots/generate_baseline.dart

[template_first_pipeline] using template-first 29 visits
  Overall 74.89 / 29 visites / coverage 100%
  Verdict comparator : PASS
```

**Observations** :
- Le routing template-first **s'active et prend la main**
  (`tfResult.isUsable == true`).
- **29 visites** vs 18-19 en OFF : le template-first remplit
  plus de slots (chaque template a 3-5 slots).
- Overall score 74.89 (vs ~80-82 OFF) — légère dégradation
  attendue : Tâche 4.5 ne fait PAS d'optimisation qualitative
  (scoring, transitions géographiques, dédup intelligente).
  **Mesure qualitative Tâche 4.6**.
- Comparator self-check PASS dans les 2 cas → pas de FAIL
  catastrophique.

**Conclusion 4.5** : orchestration fonctionnelle, observable,
réversible. Qualité à raffiner Tâche 4.6.

## Limites connues

1. **Pas d'optimisation transitions géographiques** : le
   template-first ne calcule pas la distance entre slots
   consécutifs. Possible zigzag intra-jour qui n'existe pas en
   legacy (qui a anti-zigzag V8.21).
2. **Pas de scoring sophistiqué** : `score = rating × log(reviews)`
   est plus simple que le scoring legacy
   (`+blueprintBonus -distancePenalty -diversityPenalty -tagPenalty`).
3. **Pas d'iconic dedup trip-level** comme legacy V8.28b1.3.
   L'anti-dup repose uniquement sur `alreadyUsedPlaceKeys` +
   `alreadyUsedAnchorKeys`.
4. **Pas de quality floor V8.28f** : le template-first ne
   filtre pas les candidates non-curated en mode fallback.
5. **Couverture destination limitée** : registry locale
   contient seulement Singapour. Bangkok, Tokyo, etc. tomberont
   en fallback legacy (par `missing_di_or_templates`).
6. **Repas via legacy** : `insertDeterministicMeals` réutilisé
   tel quel. Possible mismatch avec les `mealStrategy` du
   template (hawkerCenters, fineDining, etc. non honorés).
7. **`baseline.json` non comparable strict OFF vs ON** : le
   flag ON régénère un baseline différent (29 vs 18 visites).
   La canonical baseline reste OFF.

Ces limites seront évaluées en **Tâche 4.6 (A/B)**. Phase 4.7
ou phase ultérieure pourra affiner (transitions, scoring,
quality floor).

## Ce qui n'est volontairement PAS fait

- ❌ Comparaison A/B qualitative finale → Tâche 4.6
- ❌ Activation par défaut du flag
- ❌ Suppression de l'ancien pipeline
- ❌ Refactor de `places_first_pipeline.dart` (juste un bloc
  ajouté)
- ❌ Modification de `selectVisitsDeterministic`
- ❌ Optimisation transitions / scoring / quality floor
- ❌ Création de `DayPlanStatus`
- ❌ Création d'UI
- ❌ Logique spécifique Singapour dans le pipeline
- ❌ Extension de la registry à d'autres destinations
- ❌ Refactor de `insertDeterministicMeals`

## Confirmation comportement par défaut inchangé

- ✅ `FeatureFlags.useDayTemplates` reste **OFF par défaut**
  (aucune modification de `feature_flags.dart`).
- ✅ Production `_runAutoPlacesFirstBody` : court-circuit
  total quand flag OFF.
- ✅ Baseline script `generate_baseline.dart` : court-circuit
  total quand flag OFF.
- ✅ **182 tests pipeline pré-existants restent verts**
  inchangés.
- ✅ Snapshot baseline OFF : overall 82.78, 19 visites,
  coverage 100% — cohérent pré-4.5.
- ✅ 0 log `[template_first_pipeline]` ou
  `[template_first_fallback]` quand flag OFF.

## Résultats validation

```
flutter analyze
  35 issues info préexistants (Tâche 0.1, inchangés)
  → lib/data/day_templates/day_template_registry.dart       : No issues
  → lib/features/planning/services/template_first_pipeline.dart : No issues
  → test/data/day_templates/day_template_registry_test.dart : No issues
  → test/features/planning/services/template_first_pipeline_test.dart : No issues
  → lib/features/planning/services/places_first_pipeline.dart : 1 info préexistant
  0 nouveau warning/error

flutter test
  1056 tests verts (1024 Tâche 4.4 + 32 nouveaux Tâche 4.5 :
    +7 registry
    +25 pipeline orchestrateur + adapter + conversion)

flutter test test/snapshots/generate_baseline.dart   (OFF)
  → overall 82.78 / 19 visites / coverage 100%
  → 0 log template_first
  → comparator self-check : PASS

flutter test --dart-define=USE_DAY_TEMPLATES=true \
  test/snapshots/generate_baseline.dart   (ON)
  → overall 74.89 / 29 visites / coverage 100%
  → log [template_first_pipeline] using template-first 29 visits
  → comparator self-check : PASS
```

## Commande

```bash
# Tests pipeline orchestrateur uniquement
flutter test test/features/planning/services/template_first_pipeline_test.dart
flutter test test/data/day_templates/day_template_registry_test.dart

# Suite complète
flutter test

# Snapshot baseline (flag OFF par défaut)
flutter test test/snapshots/generate_baseline.dart
flutter test test/snapshots/compare_snapshot.dart

# Snapshot baseline avec flag ON
flutter test --dart-define=USE_DAY_TEMPLATES=true \
  test/snapshots/generate_baseline.dart
```

## Prochaine étape : Tâche 4.6

A/B Singapour qualitatif OFF vs ON :
- Mesure exhaustive des scores (overall, coherence, diversity,
  repetition, transition, coverage)
- Analyse des activités substituées (template-first ajoute des
  slots — quels lieux apparaissent vs disparaissent ?)
- Analyse des transitions géographiques (template-first n'a pas
  d'anti-zigzag — quels zigzags apparaissent ?)
- Recommandation : activer par défaut, garder OFF, ou
  améliorer 4.7 avant d'activer ?

Cohérent avec le pattern Tâches 2.5 (`phase2_results.md`) :
**mesure rigoureuse + recommandation** avant toute activation
par défaut.
