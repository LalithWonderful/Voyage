# Refonte moteur planning Lunao — État de synthèse après Phase 4.8

> **Document de référence statut au 2026-05-12.** Synthèse des Phases 0
> à 4.8 du plan de refonte du moteur de planning. Pré-requis avant
> Phase 5, avant A/B live 4.9, et avant toute reprise future.
>
> **Aucune logique métier dans ce document** — il consolide ce qui
> existe et où on en est. Cf. `docs/migrations/phaseN_taskN_M.md`
> pour les détails par tâche.

---

## 1. Executive summary

| Aspect | État |
|--------|------|
| **Phases livrées** | 0, 1, 2, 3, 4 (jusqu'à 4.8 inclus) |
| **Pipeline production par défaut** | **Legacy places-first inchangé** (V8.28+) |
| **Template-first** | Code livré et stabilisé (4.7) + validé offline (4.8) ; **flag `useDayTemplates` reste OFF par défaut** |
| **Tous les nouveaux flags** | OFF par défaut ; aucune exposition utilisateur |
| **Tests** | 1085 verts (suite globale) |
| **`flutter analyze`** | 35 issues info préexistants (Phase 0.1), inchangés depuis |
| **API live** | Aucun appel ajouté depuis Phase 0. `generate_baseline.dart` toujours unique consommateur Places live et **interdit** sans Phase 0 maîtrise API |
| **Prochaine étape** | API cost guardrails (Codex sur API-0.x), PUIS A/B live 4.9, PUIS seulement Phase 5 |

**Verdict** : la refonte a posé une base solide (4 modèles génériques,
3 services dormants/flag-gated, 1 pipeline alternatif) sans casser le
pipeline legacy. Le moteur template-first est techniquement
fonctionnel et stabilisé, mais **pas encore production-ready**.
Activation user-facing conditionnée à un A/B live post-4.7
maîtrisé en coûts.

---

## 2. Timeline des phases

### Phase 0 — Observabilité (livrée)

| Tâche | Sujet | Commit | Statut |
|-------|-------|--------|--------|
| 0.1 | Snapshot baseline Singapour (`generate_baseline.dart` + `singapore_baseline.json`) | `eb57677` | Dormant (seul consommateur Places live, **interdit** sans Phase 0 API) |
| 0.2 | Module métriques qualité (`lib/quality/planning_metrics.dart`, 5 scores) | `7f0c84d` | Actif (pure compute) |
| 0.3 | `FeatureFlags` skeleton (4 flags, tous OFF) | `fa0669f` | Actif (infrastructure, branchés progressivement Phases 2.4/3.2/4.5) |
| 0.4 | Snapshot comparator (`snapshot_comparator.dart`) | `9cd26ce` | Actif (outil pur, lecture JSON existant) |

### Phase 1 — DestinationIntelligence (livrée, dormante)

| Tâche | Sujet | Commit | Statut |
|-------|-------|--------|--------|
| 1.1 | Modèle `DestinationIntelligence` + `TouristZone` + `DestinationAnchor` + `TransportRules` | `f8465e0` | Dormant |
| 1.2 | Données Singapour (10 zones, 15 anchors, transport rules) | `6421169` | Dormant — consommée par Phases 3.2 et 4.5 quand flags ON |
| 1.3 | Loader (`DestinationIntelligenceLoader`, cache session, local→remote→fallback) | `8816ac4` | Dormant — aucun consommateur runtime |
| 1.4 | Tests d'intégration Phase 1 (18 tests) | `56acde1` | — |

### Phase 2 — SameComplexGroup (livrée, branché flag-gated)

| Tâche | Sujet | Commit | Statut |
|-------|-------|--------|--------|
| 2.1 | Modèle `SameComplexGroup` + `normalizeComplexText` | `cb82d38` | Dormant |
| 2.2 | Données Singapour (6 complexes : sentosa, gardens_by_the_bay, marina_bay_sands, chinatown_heritage, clarke_quay_riverside, orchard_shopping) | `50b5cf9` | Dormant |
| 2.3 | `complex_matcher.dart` (placeId > exact alias > fuzzy Levenshtein > 0.85) | `78ec8aa` | Dormant (pure service) |
| 2.4 | Intégration pipeline derrière `useSameComplexDedup` | `5aa0091` | **Branché flag-gated** (OFF par défaut) |
| Results | A/B SameComplex doc | `d8bc3ea` | — |

### Phase 3 — DestinationScope (livrée, branchée flag-gated)

| Tâche | Sujet | Commit | Statut |
|-------|-------|--------|--------|
| 3.1 | `scope_validator.dart` (countryCode + adresse hints, BorderSensitivity-aware) | `a443755` | Dormant (pure service) |
| 3.2 | Branchement pipeline derrière `useDestinationScope` + champ `blockedNeighborRegions` ajouté au modèle DI | `9465725` | **Branché flag-gated** (OFF par défaut). Effectivement dormant sur Singapour (legacy intercept déjà) |
| 3.3 | Fixtures HK / Dubai / Rome + cross-destinations tests (41 tests) | `6b25c34` | Dormant (test-only) |

### Phase 4 — DayTemplate + Template-first pipeline (livrée 4.1-4.8)

| Tâche | Sujet | Commit | Statut |
|-------|-------|--------|--------|
| 4.1 | Modèle `DayTemplate` + `SlotSpec` + enums `DayIntensity`/`MealStrategy`/`ExpectedSlotType` | `e5ab97d` / `bf54187` | Dormant |
| 4.2 | Données Singapour (8 templates : arrival, marina_bay, chinatown_civic, sentosa, orchard_botanic, little_india_kampong, free, departure) | `157ca49` | Dormant |
| 4.3 | `DayThemeAssigner` (jour → template, déterministe, free_day insertion) | `b2f1658` | Dormant (consommé par 4.5 quand flag ON) |
| 4.4 | `TemplateFirstDayBuilder` (template + pool → journée structurée, cascading tiers) | `ad9c336` | Dormant (consommé par 4.5 quand flag ON) |
| 4.5 | `tryTemplateFirstPipeline` + routing dans `places_first_pipeline.dart` derrière `useDayTemplates` | `ac595c7` | **Branché flag-gated** (OFF par défaut) |
| 4.6 | A/B test live Singapour (`docs/migrations/phase4_ab_test.md`) | `88f4f87` | Doc uniquement |
| 4.7 | Stabilisation moteur — 4 axes (anti-zigzag, freeTime, quality floor, hawker block) | `476ad96` | **Branché flag-gated** (OFF par défaut), stabilisé |
| 4.8 | Validation A/B fixture-based offline (14 tests, regression guard durable) | `b0be161` | Test + doc uniquement |

### Hors refonte planning (en parallèle)

| Tâche | Sujet | Commit |
|-------|-------|--------|
| API-0.1 (Codex) | Inventaire des sites d'appel API live | `8f3d0a0` |

---

## 3. Feature flags

Tous les flags sont définis dans [`lib/config/feature_flags.dart`](../../lib/config/feature_flags.dart) (commit `fa0669f`). Parsing 3-niveaux : override Supabase futur (non câblé) > `--dart-define` > defaults.

| Flag | Default | Branché dans pipeline ? | Statut recommandé |
|------|--------:|-------------------------|-------------------|
| `useDestinationIntelligence` | **OFF** | Non. Pas de consommateur runtime direct (le modèle DI est utilisé en lecture par Phases 3.2 et 4.5 — mais leurs propres flags gèrent l'activation). | **Garder OFF**. Pas activable seul (pas de consommateur). |
| `useSameComplexDedup` | **OFF** | Oui — `selectVisitsDeterministic` dans `places_first_pipeline.dart` applique les caps maxPerDay / maxPerTrip si ON. | **Garder OFF**. A/B 2.5 : delta marginal (+0.29 overall) sur Singapour ; besoin matcher refinement + 3 destinations avant activation par défaut. |
| `useDestinationScope` | **OFF** | Oui — `places_first_pipeline.dart` applique `ScopeValidator` en plus du legacy si ON. Effectivement dormant sur Singapour (legacy intercept déjà). | **Garder OFF**. Couche défensive future pour destinations sans MetroProfile curé. |
| `useDayTemplates` | **OFF** | Oui — `_runAutoPlacesFirstBody` route vers `tryTemplateFirstPipeline` si ON, `category == all`, DI + templates disponibles. Stabilisé Phase 4.7. | **Garder OFF**. Pas d'activation user-facing avant Phase 0 maîtrise API + A/B live 4.9 confirmant les seuils chiffrés post-4.7. |

**Combinaisons testées** :
- OFF × OFF × OFF × OFF → comportement legacy strict (toujours validé en CI).
- OFF × ON × OFF × OFF → A/B 2.5 Singapour live.
- OFF × OFF × ON × OFF → A/B 3.2 Singapour live.
- OFF × OFF × OFF × ON → A/B 4.6 Singapour live.

**Combinaisons NON testées** :
- ON × ON (SameComplex + Templates) — risque doublons sémantiques en template-first sans dedup.
- Toute combinaison hors Singapour live.

---

## 4. Architecture actuelle

### Pipeline legacy (places-first, V8.28+)

Le pipeline de production. Inchangé par défaut. Implémenté dans
[`lib/features/planning/services/places_first_pipeline.dart`](../../lib/features/planning/services/places_first_pipeline.dart).

```
Trip
  → gatherCandidatesForTrip (Google Places live)
  → groupDaysByCenter / partitionByQuartier
  → selectVisitsDeterministic
       (+ V8.21 anti-zigzag, V8.23 coherence guard,
        V8.26 second-pick guard, V8.28b1 hawker block,
        V8.28f quality floor, V8.28d metro anchor fan-out,
        same-complex dedup si useSameComplexDedup ON,
        scope filter si useDestinationScope ON)
  → insertDeterministicMeals
  → ActivitySuggestion[]
```

### Pipeline template-first (alternatif, flag-gated)

Activé uniquement si `useDayTemplates == true` ET
`category == SuggestionCategory.all` ET DI + templates disponibles.
Implémenté dans
[`lib/features/planning/services/template_first_pipeline.dart`](../../lib/features/planning/services/template_first_pipeline.dart).

```
Trip + DestinationIntelligence + DayTemplate[]
  → TripSkeleton
  → DayThemeAssigner.assignThemesToDays() (jour → DayTemplate)
  → pour chaque jour :
       → adapter NearbyCandidate → TemplateCandidate
       → TemplateFirstDayBuilder.buildTemplateFirstDay()
            (4 axes 4.7 : anti-zigzag, freeTime, quality floor, hawker block)
       → ActivitySuggestion[] pour le jour
  → critère isUsable (≥3 activités OU ≥50 % jours remplis)
       → si OUI : + insertDeterministicMeals legacy → return
       → si NON : fallback legacy complet
```

### Composants génériques cross-pipeline

- **`DestinationIntelligence`** (Phase 1) — zones, anchors, transport,
  borderSensitivity, blockedNeighborRegions. Une instance par
  destination (Singapour seule pour l'instant).
- **`SameComplexGroup`** (Phase 2) — groupes sémantiques d'attractions
  (Sentosa = Universal + Resorts + Adventure Cove…).
  Consommé par `ScopeValidator` (3.2 via `complexKey`) et
  `TemplateFirstDayBuilder` (4.4 via `forbiddenComplexKeys`).
- **`ScopeValidator`** (Phase 3) — filtre par pays autorisés/bloqués +
  régions voisines bloquées (Johor pour Singapour).
- **`DayTemplate`** (Phase 4) — gabarit journée (thème + zone +
  intensité + anchors recommandés + complexes interdits + slots +
  mealStrategy + flexibility).
- **`FeatureFlags`** (Phase 0.3) — 4 flags env-based, lus par
  `_runAutoPlacesFirstBody`.

---

## 5. Ce qui est actif par défaut

**Le pipeline legacy places-first uniquement.** Tous les composants
de la refonte sont OFF par défaut. Aucune exposition utilisateur des
nouveaux moteurs.

| Composant | Default activation | Effet utilisateur |
|-----------|--------------------|-------------------|
| `selectVisitsDeterministic` (legacy V8.28+) | ✅ Actif | Le moteur de planning utilisé en production |
| `insertDeterministicMeals` (legacy) | ✅ Actif | Insertion repas en pipeline legacy et template-first |
| `planning_metrics` (Phase 0.2) | ✅ Actif | Calcul scores qualité, pure compute (pas d'effet user) |
| `snapshot_comparator` (Phase 0.4) | ✅ Actif | Outil de tests, pas d'effet user |
| `FeatureFlags.fromEnvironment` | ✅ Actif | Lecture flags `--dart-define` ; tous defaults FALSE |

**Aucun flag à ON par défaut.** Aucune migration silencieuse de
comportement runtime. Le user voit le même planning qu'avant la
refonte.

---

## 6. Ce qui est dormant ou expérimental

### Dormant (code livré, jamais appelé en runtime)

- **`DestinationIntelligenceLoader`** (Phase 1.3) — service de
  chargement avec cache, aucun consommateur runtime câblé. Les
  pipelines 3.2 et 4.5 consomment la DI via le registry Dart
  (`lookupLocalDestinationIntelligence`), pas via ce loader.
- **`destination_intelligence_registry.dart`** (Phase 3.2) — registre
  local des DI Singapour. Consommé uniquement par les pipelines
  flag-gated quand leurs flags sont ON.
- **`day_template_registry.dart`** (Phase 4.5) — registre local des
  `DayTemplate`. Consommé uniquement par le pipeline template-first
  quand `useDayTemplates == true`.

### Expérimental / dev-QA uniquement (flag OFF par défaut)

- **`useSameComplexDedup`** — filtrage caps maxPerDay/maxPerTrip
  intégré au sélecteur legacy. Activable manuellement via
  `--dart-define=USE_SAME_COMPLEX_DEDUP=true`.
- **`useDestinationScope`** — filtre supplémentaire (en plus du
  legacy `_isAllowedFinalVisitCandidate`). Effectivement dormant
  sur Singapour (legacy intercept déjà tous les cas).
- **`useDayTemplates`** — pipeline alternatif complet. Stabilisé
  4.7, validé offline 4.8. **Pas activable user-facing sans A/B
  live post-4.7.**

### Test-only

- **`test/fixtures/destinations/scope_test_destinations.dart`**
  (Phase 3.3) — fixtures HK / Dubai / Rome pour prouver la
  généricité du scope validator.
- **`test/fixtures/planning/singapore_template_first_fixtures.dart`**
  (Phase 4.8) — fixtures Singapour pour validation A/B offline du
  template-first.

---

## 7. Résultats A/B importants

### Phase 2.5 — SameComplexGroup A/B live Singapour (commit `d8bc3ea`)

| Metric | OFF | ON | Δ |
|--------|----:|---:|--:|
| overall | 81.46 | 81.76 | **+0.29** (marge bruit Places) |
| coverage | 100 | 100 | 0 |
| diversity | — | — | **+1.85 pts** |
| transitions avg | — | — | **-135 m** |
| visites totales | 19 | 19 | 0 |
| substitutions | 3/18 (Cloud Forest, Indian Heritage Centre vs Wings of Time, Fort Canning) |
| rejets observés | 0 | 1 (`same_complex_cap_day` sentosa) |

**Verdict** : delta marginal positif mais dans la marge de bruit
Google Places. Recommandation : 🟡 activable test, **garder OFF
global** ; besoin matcher refinement + validation 3+ destinations.

### Phase 3.2 — DestinationScope A/B live Singapour (commit `9465725`)

| Metric | OFF | ON | Δ |
|--------|----:|---:|--:|
| overall | 81.46 | 81.46 | 0 |
| log scope rejection | 0 | 0 | 0 |

**Verdict** : effectivement dormant sur Singapour — le filtre legacy
`_isAllowedFinalVisitCandidate` intercept déjà tous les cas. Le
validator reste une couche défensive utile pour destinations futures
sans MetroProfile curé.

### Phase 4.6 — Template-first A/B live Singapour (commit `88f4f87`)

| Metric | OFF | ON | Δ | Lecture |
|--------|----:|---:|--:|---------|
| overall | 81.97 | 74.87 | **-7.10** | Dégradation nette |
| coherence | 82.89 | 52.52 | **-30.37** | **Catastrophique** ⚠️ |
| diversity | 34.41 | 44.67 | **+10.26** | Amélioration |
| transition | 92.53 | 77.16 | **-15.37** | Dégradation forte ⚠️ |
| coverage | 100 | 100 | 0 | — |
| visites | 19 | 29 | **+53 %** | Sur-remplissage |
| free_days | 1 | 0 | -1 | Free_day non respecté |
| avg inter-slot | 1 255 m | 5 174 m | **× 4.1** | ⚠️ |
| long transitions (>5 km) | 0 | 12 | bloquant |

**6 régressions concrètes identifiées** : 2 hawker en visit slot,
5 cafés obscurs, 12 transitions > 5 km, free_day rempli, Universal
Studios sur arrival_day, doublons sémantiques.

**Verdict** : template-first 4.5 **pas production-ready** →
décision sous-phase 4.7.

### Phase 4.7 — Stabilisation moteur (commit `476ad96`)

4 axes ajoutés au builder pour répondre aux 6 régressions A/B 4.6 :
1. Anti-zigzag / zone primaire (pré-filtre > 10 km + bucket tri).
2. Respect `freeTime` / `free_day` (slots vides volontaires).
3. Quality floor (rating < 4.0 ou reviews < 50, sauf anchor recommandé).
4. Hawker / food-centre block en non-meal.

**Validation A/B live POST-4.7 : non effectuée** (interdit sans
Phase 0 maîtrise API). Seuils chiffrés à atteindre quand re-run sera
possible : coherence ≥ 70, transition ≥ 85, avg inter-slot < 2 000 m,
long transitions ≤ 3, free_days ≥ 1, 0 hawker en visit, 0 visite
rating < 4 hors anchor.

### Phase 4.8 — Validation A/B fixture-based offline (commit `b0be161`)

14 tests sur 8 scénarios + regression guard durable. Confirme
**offline** que les 6 régressions A/B 4.6 sont **absentes** sur le
pool simulé. **Pas un substitut au re-run live**.

---

## 8. Décisions produit en vigueur

- **`useDayTemplates` reste OFF par défaut.** Cohérent avec
  Phase 4.6 recommandation initiale ("activation par défaut : NON")
  et maintenu après 4.7/4.8.
- **Aucune exposition utilisateur** du template-first. Mode dev/QA
  uniquement.
- **Pipeline legacy reste la voie par défaut** pour toutes les
  destinations.
- **Pas de Phase 5 user-facing** avant :
  1. Phase 0 maîtrise API (cache / proxy / mocks pour
     `generate_baseline.dart`).
  2. Tâche 4.9 A/B live contrôlé Singapour confirmant les seuils
     chiffrés post-4.7.
  3. Validation utilisateur explicite.
- **`useSameComplexDedup`, `useDestinationScope`,
  `useDestinationIntelligence` restent OFF par défaut.** Aucune
  activation Singapour par défaut avant validation 3+ destinations.
- **Pas de mealStrategy custom** : la sélection repas reste déléguée
  à `insertDeterministicMeals` legacy dans les deux pipelines.

---

## 9. Prochaines étapes recommandées

Ordre **strict** confirmé par user (2026-05-12) :

1. **API-0.1 — Inventaire des appels API live**
   *(en cours côté Codex, commit `8f3d0a0`)*
   → cartographier tous les sites d'appel Google Places / Routes /
   Geocoding / Gemini / Supabase.
2. **API-0.2 — Kill switch global API**
   → mécanisme uniforme pour désactiver tous les appels live (env
   var / flag / proxy).
3. **API-0.3 — Protection `generate_baseline.dart`**
   → cache / proxy / mocks rejouables pour permettre le re-run du
   snapshot sans burn de quota Google Places.
4. **Phase 4 / Tâche 4.9 — A/B live contrôlé Singapour**
   → re-run `generate_baseline.dart` ON vs OFF avec budget maîtrisé,
   comparaison aux seuils chiffrés de 4.7.
5. **Phase 5 — DayPlanStatus + UI**
   → uniquement si A/B 4.9 confirme les améliorations attendues. Et
   uniquement avec validation utilisateur explicite. Sinon : Tâche
   4.10 (corrections complémentaires) avant.

**Hors séquence, sans risque** :
- Multi-destinations : créer DI/templates pour Bangkok, Tokyo,
  Paris (data-only, zéro API).
- `mealStrategy` consommé par builder (logique pure).
- Combinaison `useSameComplexDedup` + `useDayTemplates` simultanée
  (test offline).

---

## 10. Risques restants

| # | Risque | Sévérité | Mitigation prévue |
|---|--------|----------|-------------------|
| 1 | **Coûts API Google Places** : `generate_baseline.dart` brûle 50-100 RPC par run, clé hardcodée | **HAUTE** | API-0.x (Codex en cours) |
| 2 | **Template-first non validé live post-4.7** : on a chiffré les améliorations attendues mais pas mesuré | MOYENNE | Tâche 4.9 après API-0.x |
| 3 | **Multi-destinations non testé** : fixtures et patterns hawker/quality Singapour-only | MOYENNE | Étendre fixtures Phase 4.8 à d'autres destinations |
| 4 | **`mealStrategy` non consommée** par le builder template-first | FAIBLE | Tâche future ; legacy `insertDeterministicMeals` gère correctement pour l'instant |
| 5 | **Combinaison `useSameComplexDedup` + `useDayTemplates`** non testée → doublons sémantiques restent un risque en template-first | FAIBLE-MOYENNE | Tester offline une fois 4.9 stable |
| 6 | **Loader DI dormant** : `DestinationIntelligenceLoader` jamais exercé en runtime → si on l'active un jour, surprises possibles | FAIBLE | Tests d'intégration 1.4 couvrent déjà ; à re-exercer avant activation |
| 7 | **Snapshot baseline non-déterministe** : Google Places renvoie des résultats variables d'un run à l'autre | MOYENNE | Cache / mocks API-0.3 corrigeront ce point |
| 8 | **Bruit A/B sur métriques** : marge ±2 pts overall sur 1 run unique | FAIBLE | À documenter dans chaque A/B futur, idéalement ≥ 3 runs |
| 9 | **Pas de validation utilisateur subjective** : les métriques `planning_metrics` sont des heuristiques, pas du feedback humain | MOYENNE | Hors scope refonte moteur, sujet produit séparé |

---

## 11. Règles de sécurité opérationnelle

Ces règles s'appliquent **à toute session future** sur ce projet.
Elles sont durables et ne dépendent pas du contexte conversationnel.

### Zéro API live sans opt-in explicite

- **Aucun script ne doit déclencher Google Places / Routes /
  Geocoding / Gemini / Supabase live** sans confirmation explicite
  de l'utilisateur dans la conversation en cours.
- **`flutter test test/snapshots/generate_baseline.dart`** est
  **interdit** par défaut. Il brûle 50-100 RPC par run. Le re-run
  ne sera autorisé qu'après livraison des API guardrails Phase 0
  maîtrise API.
- **`test/dev/places_first_harness.dart`** : même régime que
  `generate_baseline.dart`.
- Les fichiers `lib/features/planning/services/places_nearby_service.dart`
  et `lib/features/planning/services/geocoding_service.dart`
  contiennent les `http.post` / `http.get` directs vers Google. À
  ne pas exercer en test sans mock.

### Pas d'activation flags par défaut

- Ne **jamais** changer le default d'un flag dans
  [`lib/config/feature_flags.dart`](../../lib/config/feature_flags.dart)
  vers `true` sans demande utilisateur explicite + validation A/B
  live correspondante + 3+ destinations testées.
- Toute activation `--dart-define` reste manuelle et locale.

### Une tâche = un commit

- Convention respectée pour les 25+ tâches livrées (cf. timeline).
- Commits structurants taggés par phase : `feat:` (code nouveau /
  branchement), `test:` (tests / fixtures), `docs:` (migration
  notes / A/B results).

### Ne pas casser le pipeline legacy

- Toute modification de
  [`places_first_pipeline.dart`](../../lib/features/planning/services/places_first_pipeline.dart)
  doit rester **flag-gated** par défaut OFF.
- Tests legacy (groupes principaux du dossier `test/`) doivent
  rester verts à chaque commit. La suite globale `flutter test`
  est l'invariant final (1085 verts au 2026-05-12).

### Pas de modèles parallèles

- Avant de créer un nouveau modèle / class / struct, grep les
  structures existantes et préférer l'extension (champ optionnel
  avec default safe, composition, sous-classe).
- Création seulement si concept sémantiquement distinct ET
  extension impossible.
- Référence : `feedback_no_parallel_models` (mémoire user) et règle
  d'or 7 du plan de refonte.

### Lecture obligatoire avant reprise

À ouvrir en début de chaque session refonte :
1. Ce document (`planning_engine_refactor_status.md`).
2. `docs/migrations/phase4_task4_7.md` et `phase4_task4_8.md`
   (dernières tâches livrées).
3. `git log --oneline -10` pour vérifier les commits intercalés
   (notamment côté Codex).
4. Memo persistant
   `~/.claude/projects/-Users-lalith-Projets/memory/project_refonte_phase4_next_session.md`
   pour le statut le plus récent.
