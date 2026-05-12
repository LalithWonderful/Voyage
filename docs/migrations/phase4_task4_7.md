# Phase 4 / Tâche 4.7 — Stabilisation template-first day quality

> Statut : **livrée**, en attente de validation A/B live (reportée après
> Phase 0 maîtrise API).

## Contexte

La Tâche 4.6 a livré l'A/B test template-first vs places-first. Résultats
sur le snapshot Singapore 18/05/2026 → 25/05/2026 (commit `88f4f87`) :

| Metric | Places-first OFF | Template-first ON | Δ |
|--------|-----------------:|------------------:|--:|
| overall | 81.97 | 74.87 | **-7.10** |
| coherence | 82.89 | 52.52 | **-30.37** ⚠️ |
| diversity | 34.41 | 44.67 | +10.26 |
| repetition | 100 | 100 | 0 |
| transition | 92.53 | 77.16 | **-15.37** ⚠️ |
| coverage | 100 | 100 | 0 |
| visites | 19 | **29** | +53 % |
| free_days | 1 | **0** | non respecté |
| avg inter-slot | 1 255 m | **5 174 m** | ×4.1 ⚠️ |
| long transitions (> 5 km) | **0** | **12** | bloquant |

**Régressions concrètes identifiées** :
- 2 hawker centres en visit slot (Lau Pa Sat, Maxwell Food Centre).
- 5 cafés obscurs et lieux faiblement notés sélectionnés en visites.
- 12 transitions intra-jour > 5 km (zigzag entre quartiers).
- `free_day` non honoré (rempli avec 3 visites).
- Universal Studios placé en arrival day (zone primaire ignorée).

Référence chiffres complets : `docs/migrations/phase4_ab_test.md`.

## Décision de stabilisation

Sous-phase 4.7 = **stabilisation minimale**, pas refonte. Cible
exclusive : corriger les régressions A/B 4.6 les plus graves sans
toucher au flag `useDayTemplates` (qui reste **OFF par défaut**).

Le pipeline legacy reste intact et inchangé en mode flag OFF.

## Détail des 4 axes

### Axe 1 — Anti-zigzag / zone primaire

Le `TemplateFirstDayBuilder` reçoit désormais en option le centre
canonique de la zone primaire du template (`primaryZoneCenter`,
résolu par le pipeline via `di.zones`).

Politique appliquée :
- **Pré-filtre haversine** : candidat distance > 10 km du centre de
  zone → rejet, **sauf** si `anchorKey` ∈ `recommendedAnchorKeys`
  (exception explicite : un anchor recommandé hors zone reste un
  choix éditorial du template).
- **Bucket de tri** inséré en position 2 du comparator (après
  l'anchor match, avant le score) :
  - bucket 0 : ≤ 2 km (très proche)
  - bucket 1 : ]2, 5] km (acceptable)
  - bucket 2 : ]5, 10] km (déprioriser fort)
  - bucket 3 : pas de coordonnées ou pas de zoneCenter (neutre,
    comportement pré-4.7 préservé)

Bypass complet si `primaryZoneCenter` est `null` (rétro-compat
tests 4.4/4.5).

### Axe 2 — Respect `freeTime` / `free_day`

Les slots `ExpectedSlotType.freeTime` ne sont **plus jamais remplis
automatiquement** par le builder. L'assignment correspondant a
`candidate: null` et `warnings: []` (vide volontaire, pas un
manque).

Conséquence sur `isFallback` : le ratio empty-slots / total-slots
**exclut** les slots `freeTime` du dénominateur. Sans cette
correction, le template `free_day` (qui contient 2 slots
`freeTime` + 1 meal) serait toujours marqué `isFallback`.

### Axe 3 — Quality floor

Pour les slots de type **non-meal** et **non-rest**, un candidat
est rejeté si :
- `rating != null && rating < 4.0`, **ou**
- `userRatingCount != null && userRatingCount < 50`.

**Exception** : un candidat dont `anchorKey` ∈
`recommendedAnchorKeys` du template échappe entièrement au quality
floor (préserve le choix éditorial).

Les slots `meal` et `rest` sont exemptés du quality floor : la
sélection repas est déléguée à `insertDeterministicMeals` (logique
legacy V8.x) qui applique ses propres règles.

### Axe 4 — Hawker / food-centre block en visit

Pour les slots non-`meal`, un candidat est rejeté si son `title`
contient (case-insensitive substring) l'un des patterns :

```
hawker centre, hawker center,
food centre, food center, food court,
lau pa sat,
maxwell food centre, maxwell food center,
hong lim food centre, hong lim market,
tekka centre, tekka market.
```

En slot `meal`, ces lieux sont **autorisés** (un hawker centre est
une expérience food structurante, pas un restaurant
interchangeable).

Liste intentionnellement courte : on bloque les indicateurs
génériques (« hawker centre », « food centre », « food court »)
plus quelques noms emblématiques Singapour observés en régression
A/B 4.6. **Pas un catalogue** — c'est le moteur, pas la donnée.

## Fichiers modifiés

| Fichier | Nature de la modification |
|---------|---------------------------|
| `lib/services/template_first_day_builder.dart` | Implémentation des 4 axes + extension `TemplateDayBuildInput` (champ `primaryZoneCenter`). |
| `lib/features/planning/services/template_first_pipeline.dart` | Résolution `template.primaryZoneName` → `TouristZone.center` via `di.zones`, passage au builder. |
| `test/services/template_first_day_builder_test.dart` | + groupes I/J/K/L/M (15 tests 4.7). Adaptation 2 tests existants (`F.Template free_day`, `G.arrival_day`) impactés par Axe 2. |

Aucune autre modification : pipeline legacy intact, modèles `DayTemplate`
inchangés, données `singapore_templates.dart` inchangées, `FeatureFlags`
inchangés.

## Tests ajoutés (15 cas, 100 % offline)

### Groupe I — Anti-zigzag / zone primaire (5 cas)
1. Candidat ≤ 2 km vs > 5 km à score égal → le proche zone gagne.
2. Candidat > 10 km non-anchor rejeté si alternative existe.
3. Anchor recommandé hors zone (> 10 km) toléré (exception).
4. `primaryZoneCenter` null → axe en bypass (rétro-compat).
5. Candidat sans coordonnées accepté (pas pénalisé).

### Groupe J — Respect `freeTime` (1 cas)
6. `arrival_day` : slot `freeTime` non rempli même si candidat
   compatible dans le pool.

Couverture complémentaire dans groupe **F** et **H** :
- `F.Template free_day` adapté : les 2 slots `freeTime` restent
  vides sans warning.
- `H.isFallback ne compte pas les slots freeTime` : avec meal rempli
  → not fallback.

### Groupe K — Quality floor (4 cas)
7. Candidat `rating: 3.5` rejeté en slot visit.
8. Candidat `userRatingCount: 12` rejeté en slot visit.
9. Anchor recommandé `rating: 3.5` **accepté** (exception).
10. Slot meal accepte `rating: 3.8` (exempté du quality floor).

### Groupe L — Hawker / food-centre block (3 cas)
11. « Maxwell Food Centre » rejeté en slot visit.
12. « Maxwell Food Centre » accepté en slot meal.
13. « Some Random Hawker Centre » (substring générique) rejeté en
    visit.

### Groupe M — Intégration multi-axes (1 cas)
14. `marina_bay_day` avec pool mixte (anchors recommandés in-zone,
    hawker centre, candidat faible qualité, candidat > 50 km) :
    seuls les choix conformes aux 4 axes sortent.

## Commandes lancées (toutes offline, garanties)

```bash
flutter analyze
# → 35 issues info préexistants (identique à baseline 4.6, aucune
#   nouvelle issue introduite par 4.7).

flutter analyze \
  lib/services/template_first_day_builder.dart \
  lib/features/planning/services/template_first_pipeline.dart \
  test/services/template_first_day_builder_test.dart \
  test/features/planning/services/template_first_pipeline_test.dart
# → No issues found.

flutter test test/services/template_first_day_builder_test.dart
# → 54 tests passing (39 préexistants conservés + 15 nouveaux 4.7).

flutter test test/features/planning/services/template_first_pipeline_test.dart
# → 25 tests passing (aucun impact 4.7 sur les tests pipeline).

flutter test test/snapshots/compare_snapshot.dart
# → 16 tests passing (offline, lit JSON existants).

flutter test
# → 1 071 tests passing (totalité de la suite hors snapshots
#   live-API).
```

## Commandes explicitement **NON** lancées

```bash
# ↓↓↓ Interdites par règle zéro-API-live ↓↓↓

flutter test test/snapshots/generate_baseline.dart
flutter test --dart-define=USE_DAY_TEMPLATES=true \
  test/snapshots/generate_baseline.dart
flutter test test/dev/places_first_harness.dart
```

Ces commandes appellent `gatherCandidatesForTrip` →
`PlacesNearbyService.http.post(...)` → Google Places live
(~ 50-100 RPC par run, clé hardcodée dans
`AiConstants.googleMapsApiKey`).

## Aucune API live consommée

Confirmation explicite : **aucun appel Google Places / Routes /
Geocoding / Gemini / Supabase n'a été effectué pendant la Tâche 4.7**.

Tous les tests, fixtures et candidats utilisés sont en mémoire,
construits via les helpers `_cand` / `_nc` inline. Les coordonnées
réelles utilisées dans les tests (Marina Bay, Botanic Gardens, etc.)
sont des constantes copiées depuis
`lib/data/destinations/singapore.dart` (fichier source local, pas
un appel réseau).

## Validation A/B live — reportée

Le re-run A/B Singapore (`generate_baseline.dart` ON vs OFF) **n'a
pas été effectué** dans cette tâche. Raison : `generate_baseline.dart`
déclenche 50-100 RPC Google Places live par run.

Conformément à la décision produit de maîtrise des coûts API, cette
validation est reportée à **après la Phase 0 maîtrise API** (cache /
proxy / mocks pour les snapshots dynamiques).

À ce moment-là, on attend les améliorations suivantes sur le run
template-first ON par rapport au snapshot 4.6 (commit `88f4f87`,
fichier `test/snapshots/singapore_phase4_template_first.json`) :

- `coherence` : 52.52 → ≥ 70 (+ par Axe 1 anti-zigzag).
- `transition` : 77.16 → ≥ 85 (+ par Axe 1).
- `avg inter-slot` : 5 174 m → < 2 000 m (+ par Axe 1).
- `long transitions` (> 5 km) : 12 → ≤ 3 (+ par Axe 1, rejet > 10 km).
- `free_days` : 0 → ≥ 1 (+ par Axe 2).
- 0 hawker centre en visit slot (+ par Axe 4).
- 0 visite à `rating < 4.0` ou `reviews < 50` hors anchor recommandé
  (+ par Axe 3).
- `visites` : peut baisser (29 → ~20-24) — acceptable car remplace
  des sélections de mauvaise qualité ou hors zone par du vide
  volontaire (`freeTime`) ou du fallback meal legacy.

Si ces seuils sont atteints, la Phase 5 (`DayPlanStatus` + UI) peut
démarrer en se basant sur le moteur stabilisé. Sinon, réévaluation
produit + Tâche 4.8.

## Confirmation flag par défaut

```dart
// lib/config/feature_flags.dart (inchangé)
const FeatureFlags.fromEnvironment() :
  useDayTemplates =
    bool.fromEnvironment('USE_DAY_TEMPLATES', defaultValue: false),
  ...
```

Le pipeline legacy reste le chemin par défaut. Aucune activation
utilisateur — la Tâche 4.7 stabilise le mode template-first **sans
le rendre actif**.

## Limites connues

1. **Validation A/B live non effectuée** dans cette tâche (cf.
   section dédiée ci-dessus). Les améliorations attendues sont
   chiffrées mais non mesurées.
2. **Pas de tests multi-destinations** : la liste
   `_kVisitBlockedNamePatterns` cible spécifiquement Singapour.
   Pour d'autres destinations à culture hawker (Bangkok, Kuala
   Lumpur, Hong Kong, etc.), il faudra étendre la liste — sans
   doute via un champ optionnel sur `DayTemplate` ou
   `DestinationIntelligence` dans une tâche future. Pour
   l'instant : suffit pour Singapour, ne casse pas les autres
   destinations (les patterns ne matchent rien hors hawker).
3. **`mealStrategy` non consommée** : la stratégie repas du
   template (`hawkerCenters`, `zoneRestaurants`, `fineDining`,
   `mixed`) reste indicative — le builder ne s'en sert pas. La
   sélection repas reste déléguée au legacy
   `insertDeterministicMeals`. Évolution future.
4. **`useSameComplexDedup` non activé en parallèle de
   `useDayTemplates`** : doublons type « Skyline Luge / Skyline
   Luge Singapore » observés en A/B 4.6 → reportés en tâche
   séparée.

## Prochaine étape

1. **Phase 0 — Maîtrise API** : cache / proxy / mocks pour les
   snapshots dynamiques afin de pouvoir re-runner l'A/B
   `generate_baseline.dart` sans burn budget.
2. **Validation A/B live 4.7** : exécuter le snapshot ON vs OFF,
   confronter aux seuils chiffrés de la section « Validation A/B
   live — reportée ».
3. Si seuils atteints → **Phase 5** (`DayPlanStatus` + UI).
4. Si seuils non atteints → **Tâche 4.8** (corrections complémentaires
   ciblées).

## Contraintes respectées

- ✅ `useDayTemplates` reste OFF par défaut.
- ✅ Pipeline legacy inchangé.
- ✅ Aucun nouveau modèle créé (`TemplateDayBuildInput` étendu).
- ✅ Pas de `DayPlanStatus`.
- ✅ Pas d'UI.
- ✅ Pas de dépendance Supabase / Gemini.
- ✅ Pas de refactor massif.
- ✅ Une tâche, un commit.
- ✅ Toute nouvelle règle est déterministe et testée.
- ✅ Zéro API live consommée.
