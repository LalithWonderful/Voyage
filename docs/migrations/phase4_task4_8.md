# Phase 4 / Tâche 4.8 — Validation offline fixture-based du template-first stabilisé

> Statut : **livrée**. Tâche test-only, aucune modification de `lib/`.

## Objectif

Construire un harnais de validation **entièrement offline** du moteur
template-first stabilisé en 4.7, à base de fixtures Singapour
représentatives. La cible est de prouver, sans appel API, que les
corrections 4.7 produisent le comportement attendu sur les cas
problématiques observés en A/B 4.6.

Cette tâche **ne refait pas** l'A/B live `generate_baseline.dart` (qui
brûlerait 50-100 RPC Google Places). Le re-run live reste reporté
après Phase 0 maîtrise API.

## Pourquoi cette tâche est offline

Trois raisons :
1. **Coût** : `generate_baseline.dart` appelle `gatherCandidatesForTrip`
   → `PlacesNearbyService.http.post` → Google Places. Chaque run = 50
   à 100 RPC.
2. **Reproductibilité** : Google Places renvoie des résultats
   légèrement différents d'un run à l'autre (rotation, mise à jour
   catalogue). Une validation déterministe demande des inputs fixés.
3. **Anti-régression durable** : ces tests resteront dans la suite
   permanente. Ils tournent à chaque `flutter test` et défendent
   les 4 axes 4.7 contre toute régression future.

Conformité **règle absolue zéro-API-live** maintenue.

## Fichiers créés (3)

| Fichier | Rôle |
|---------|------|
| [`test/fixtures/planning/singapore_template_first_fixtures.dart`](../../test/fixtures/planning/singapore_template_first_fixtures.dart) | Fixtures Singapour : pools par zone, hawker, cafés faibles, helpers `NearbyCandidate`, helper rapport offline (`OfflineAbReport`, `reportFor`). |
| [`test/features/planning/services/template_first_offline_ab_test.dart`](../../test/features/planning/services/template_first_offline_ab_test.dart) | 14 tests couvrant les 8 scénarios de la spec 4.8. |
| `docs/migrations/phase4_task4_8.md` | Ce document. |

**Aucune modification de `lib/`** : la tâche est strictement
test-only, ne touche ni au builder, ni au pipeline, ni aux
feature flags.

## Fichiers lus

- [`docs/migrations/phase4_ab_test.md`](phase4_ab_test.md) — chiffres
  de référence A/B 4.6 (coherence -30, transition -15, 12 long
  transitions, 5 cafés obscurs, 2 hawker en visit, free_day rempli).
- [`docs/migrations/phase4_task4_7.md`](phase4_task4_7.md) — détail
  des 4 axes 4.7.
- [`lib/services/template_first_day_builder.dart`](../../lib/services/template_first_day_builder.dart) — implémentation des 4 axes.
- [`lib/features/planning/services/template_first_pipeline.dart`](../../lib/features/planning/services/template_first_pipeline.dart) — résolution `primaryZoneCenter` depuis `di.zones`.
- [`lib/data/day_templates/singapore_templates.dart`](../../lib/data/day_templates/singapore_templates.dart) — 8 templates Singapour.
- [`lib/data/destinations/singapore.dart`](../../lib/data/destinations/singapore.dart) — 10 zones + 15 anchors (centres copiés en fixtures).
- [`lib/data/complexes/singapore_complexes.dart`](../../lib/data/complexes/singapore_complexes.dart) — 6 complex keys (sentosa, gardens_by_the_bay, marina_bay_sands, chinatown_heritage, clarke_quay_riverside, orchard_shopping).
- [`test/services/template_first_day_builder_test.dart`](../../test/services/template_first_day_builder_test.dart) — patterns helper `_cand` réutilisés.
- [`test/features/planning/services/template_first_pipeline_test.dart`](../../test/features/planning/services/template_first_pipeline_test.dart) — patterns helper `_nc` réutilisés.

## Description des fixtures Singapour

### Pools par zone (input direct du builder)

```dart
marinaBayPool()          // 5 candidats : MBS, GBB, Merlion, Supertree, ArtScience
sentosaPool()            // 3 candidats : Sentosa, Universal Studios, Oceanarium
orchardBotanicPool()     // 2 candidats : Botanic Gardens, Orchard Road
chinatownPool()          // 2 candidats : Buddha Tooth Relic Temple, Chinatown
kampongLittleIndiaPool() // 2 candidats : Little India, Kampong Glam
hawkerPool()             // 4 candidats meal : Lau Pa Sat, Maxwell, Hong Lim, Tekka
hawkerMislabeledAsVisit()// 3 mêmes hawker étiquetés `visit` (cas A/B 4.6)
weakPool()               // 3 candidats : café reviews<50, café rating<4, lieu faible
veryFarCandidate(...)    // candidat à ~50 km (équivalent Johor)
```

Tous les `placeKey` préfixés `p_*` pour distinction visuelle. Toutes
les coordonnées sont des constantes copiées depuis
`singapore.dart` (zones) ou des valeurs publiques Google Maps
usuelles (anchors).

### Helper de rapport offline

`OfflineAbReport` calcule sur un `TemplateDayBuildResult` :

- `filledSlotsCount` / `nonFreeSlotsCount`
- `intraDayHopsKm` (liste des transitions intra-jour)
- `transitionsAboveKm(threshold)` (équivalent A/B « long transitions
  > 5 km »)
- `hawkerInNonMealSlotsCount` (équivalent A/B régression hawker)
- `outOfZoneCount(zoneCenter, thresholdKm)` (zone primaire respectée
  ou non)
- `avgHopKm` / `maxHopKm`

Sert aux assertions chiffrées du Test 8 (regression guard) — on peut
comparer aux valeurs A/B 4.6 sans relancer le snapshot live.

## Cas testés (8 scénarios → 14 tests)

### 1. Marina Bay — zone primaire respectée (2 tests)

| Test | Vérifie |
|------|---------|
| Sentosa très scoré rejeté face à Marina Bay dans template `marina_bay_day` | Universal Studios (score 99 > MBS 95) **rejeté** par `forbiddenComplexKeys=sentosa`. Anchor slot rempli par un anchor recommandé in-zone. `outOfZoneCount == 0`. `transitionsAboveKm(5.0) ≤ 1`. |
| Pool partiel uniquement → anchor tombe sur l'alternative la plus proche en zone | Sans MBS dans le pool, GBB (autre anchor recommandé) prend le slot. |

### 2. Sentosa — zone primaire respectée (1 test)

Template `sentosa_day` avec `forbiddenComplexKeys: gardens_by_the_bay,
marina_bay_sands, orchard_shopping`. Pool intentionnellement chargé
avec Marina Bay (MBS, GBB, Supertree, ArtScience). Vérifie qu'aucun
de ces lieux Marina Bay ne sort, et que Sentosa Island prend le slot
anchor `morning_sentosa_anchor`. `outOfZoneCount == 0`.

### 3. `free_day` reste léger (2 tests)

| Test | Vérifie |
|------|---------|
| `free_day` : slots `freeTime` restent vides même avec pool généreux | Les 2 slots `freeTime` du template `free_day` ont `candidate: null` et `warnings: []`. `filledNonFree ≤ 1`. |
| `free_day` avec un meal dispo : exactement 1 slot rempli | `filledSlotsCount == 1` (le meal slot). `isFallback == false`. |

### 4. Hawker centres bloqués comme visites (2 tests)

| Test | Vérifie |
|------|---------|
| Hawker mis en catégorie `visit` (cas trompeur A/B 4.6) → bloqué sur visit/anchor/viewpoint | `report.hawkerInNonMealSlotsCount == 0`. Lau Pa Sat / Maxwell / Hong Lim étiquetés `visit` ne sortent dans aucun slot non-meal. |
| Hawker en catégorie `meal` : accepté sur slot meal (`chinatown_civic_day → lunch_hawker`) | Le slot `lunch_hawker` est rempli par Lau Pa Sat ou Maxwell. |

### 5. Quality floor (2 tests)

| Test | Vérifie |
|------|---------|
| Cafés obscurs / lieux faibles rejetés en visit | Columbus Coffee (reviews=35 < 50) **rejeté**, SOD Cafe (rating=3.7 < 4.0) **rejeté**, Obscure Random Place (les deux) **rejeté**. |
| Anchor recommandé avec rating bas : exception → accepté | Fixture MBS fictive avec `rating: 3.4` + `userRatingCount: 20`, anchor recommandé → **accepté** quand même. |

### 6. Transition longue rejetée (1 test)

Candidat fictif `veryFarCandidate('p_johor')` à ~50 km au nord de
Marina Bay, score 200 (énorme). Vérifie qu'il est **rejeté** au
profit des candidats Marina Bay malgré son score. `transitionsAboveKm(10.0) == 0`.

### 7. Déterminisme global (2 tests)

| Test | Vérifie |
|------|---------|
| Pool shuffled → mêmes assignments | Inputs en ordre inversé produisent la même séquence de `placeKey` + même séquence de `slotKey`. |
| Deux runs successifs identiques → mêmes warnings | Aucune source de non-déterminisme dans les warnings émis. |

### 8. Regression guard pré/post-4.7 (2 tests)

Tests de **garde anti-régression durable** — ils défendent les 4
axes 4.7 contre toute régression future.

| Test | Vérifie (référence A/B 4.6) |
|------|------------------------------|
| Pool Marina Bay + Sentosa + hawker mal-étiquetés + cafés obscurs → 0 régression observée | Toutes les régressions A/B 4.6 absentes : `transitionsAboveKm(10.0) == 0` (vs 12), `transitionsAboveKm(5.0) ≤ 1` (vs 12 sur 8 jours), `outOfZoneCount == 0`, `hawkerInNonMealSlotsCount == 0` (vs 2), aucun café obscur dans la sélection (vs 5), aucun Sentosa dans la sélection Marina Bay (vs Universal Studios sur arrival_day en 4.6). |
| `free_day` pollué par pool généreux → 0 régression sur-remplissage | `free_day` post-4.7 : aucun slot `freeTime` rempli (vs 3 visites en 4.6 ON), `filledSlotsCount ≤ 1`. |

## Résultats des commandes lancées

```bash
flutter analyze
# → 35 issues info préexistants (identique baseline 4.6/4.7,
#   aucune nouvelle issue introduite).

flutter analyze \
  test/features/planning/services/template_first_offline_ab_test.dart \
  test/fixtures/planning/singapore_template_first_fixtures.dart
# → No issues found.

flutter test test/services/template_first_day_builder_test.dart
# → 54/54 passing (inchangé vs 4.7).

flutter test test/features/planning/services/template_first_pipeline_test.dart
# → 25/25 passing (inchangé vs 4.7).

flutter test test/features/planning/services/template_first_offline_ab_test.dart
# → 14/14 passing (nouveaux 4.8).

flutter test
# → 1085/1085 passing (1071 avant 4.8 → +14 nouveaux).
```

### Commandes **NON** lancées (interdites par règle 4.8)

```bash
flutter test test/snapshots/generate_baseline.dart                              # 50-100 RPC Places live
flutter test --dart-define=USE_DAY_TEMPLATES=true \
  test/snapshots/generate_baseline.dart                                        # idem
flutter test test/dev/places_first_harness.dart                                # places_nearby_service live
```

## Confirmation zéro API live

**Aucun appel Google Places / Routes / Geocoding / Gemini / Supabase
n'a été effectué pendant la Tâche 4.8.**

Les fixtures sont :
- des `TemplateCandidate` construits inline ;
- des coordonnées copiées comme constantes Dart depuis les fichiers
  source locaux `lib/data/destinations/singapore.dart` (zones) ;
- des valeurs anchor publiques Google Maps usuelles (Marina Bay
  Sands ≈ 1.2834/103.8607, Universal Studios ≈ 1.2540/103.8238,
  etc.) — pas un fetch dynamique.

Aucun import de `http`, aucun `dart:io` réseau, aucun
`PlacesNearbyService` instancié. La conformité offline est garantie
par construction.

## Synthèse — ce que 4.8 valide

✅ **Anti-zigzag (Axe 1)** : zone primaire respectée sur Marina Bay
et Sentosa ; candidats > 10 km hors zone rejetés ; anchor recommandé
exempté.

✅ **freeTime respect (Axe 2)** : `free_day` ne sur-remplit plus ;
slots `freeTime` restent vides même avec pool généreux.

✅ **Quality floor (Axe 3)** : cafés obscurs et lieux faibles
rejetés en visit ; anchor recommandé exempté.

✅ **Hawker block (Axe 4)** : hawker / food centres rejetés en
slots non-meal, acceptés en slot `meal` du template
`chinatown_civic_day`.

✅ **Déterminisme** : pool shuffled → même output.

✅ **Regression guard** : les 6 régressions A/B 4.6 listées (12
long transitions, coherence -30, 2 hawker en visit, 5 cafés obscurs,
free_day rempli, Universal Studios sur arrival_day) sont
**toutes absentes** sur le même pool simulé offline.

## Ce que 4.8 ne valide PAS

❌ **Pas un substitut au re-run A/B live.** Les chiffres exacts du
snapshot ON post-4.7 (overall, coherence, transition, avg inter-slot)
ne peuvent être mesurés que via `generate_baseline.dart`. La doc 4.7
les chiffre en cibles attendues, mais sans run live, on ne peut pas
les confirmer.

❌ **Pas une validation multi-destinations.** Les fixtures sont
purement Singapour. Les hawker patterns / quality thresholds /
zones sont calibrés Singapour. Sur Bangkok, Tokyo, Paris, le
comportement reste à valider.

❌ **Pas une validation utilisateur subjective.** Les métriques
mesurées sont des heuristiques. Le voyageur réel pourrait préférer
un planning différent — non testable offline.

❌ **Pas une validation `mealStrategy`.** La stratégie repas du
template (`hawkerCenters`, `zoneRestaurants`, `fineDining`, `mixed`)
reste indicative — le builder ne s'en sert toujours pas. Reporté en
tâche future.

❌ **Pas une validation `useSameComplexDedup` + `useDayTemplates`
combinés.** Doublons sémantiques (Skyline Luge / Skyline Luge
Singapore, Merlion / Merlion Park) restent un risque non couvert.

## Limites restantes avant activation user-facing

1. **A/B live à relancer** une fois la Phase 0 maîtrise API
   livrée. Seuils chiffrés à atteindre listés dans
   `docs/migrations/phase4_task4_7.md` (section « Validation A/B
   live — reportée »).
2. **Tests multi-destinations** : créer des fixtures équivalentes
   pour ≥ 2 autres destinations (Bangkok, Tokyo, Paris) avec
   patterns adaptés.
3. **Activation `useSameComplexDedup` en parallèle** : tester le
   builder avec les deux flags ON.
4. **`mealStrategy` consommé par le builder** : reporté tâche future.

## Décision recommandée après 4.8

> **`useDayTemplates` reste OFF par défaut.**
>
> Le template-first stabilisé 4.7 est confirmé conforme aux 4 axes
> sur fixtures Singapour offline. Le moteur peut **rester en mode
> dev/QA**.
>
> **Ne pas démarrer la Phase 5 user-facing dépendante du
> template-first** tant que le re-run A/B live post-4.7 n'a pas
> confirmé les seuils chiffrés.
>
> Prochaines étapes possibles, par ordre de priorité produit :
>
> 1. **Phase 0 — Maîtrise API** : cache / proxy / mocks pour les
>    snapshots dynamiques. Permet de relancer
>    `generate_baseline.dart` sans burn de budget.
> 2. **Tâche 4.9 — A/B live contrôlé Singapour** : une fois Phase 0
>    livrée, comparer chiffres ON post-4.7 vs cibles 4.7.
> 3. **Phase 5 — DayPlanStatus + UI** : uniquement si découplée du
>    template-first, OU si 4.9 confirme les améliorations attendues.

## Contraintes respectées

- ✅ Aucune modification de `lib/` (test-only).
- ✅ Aucune commande live API lancée.
- ✅ `useDayTemplates` reste OFF par défaut.
- ✅ Pipeline legacy intact.
- ✅ `FeatureFlags` defaults inchangés.
- ✅ Snapshots existants intouchés (`singapore_baseline.json`,
  `singapore_phase4_places_first.json`,
  `singapore_phase4_template_first.json`,
  `singapore_diff_report.md`).
- ✅ Aucun nouveau modèle, aucune UI, aucune dépendance Supabase /
  Gemini.
- ✅ Une tâche, un commit.
- ✅ Tests déterministes, reproductibles, offline.
