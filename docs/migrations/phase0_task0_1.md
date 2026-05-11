# Phase 0 / Tâche 0.1 — Snapshot de référence Singapour

## Objectif de la tâche

Créer un snapshot de référence du planning actuel pour Singapour
(18/05/2026 → 25/05/2026), qui servira de baseline immuable avant toute
refonte du moteur de planning.

Conformément à la **règle d'or 2** du plan de refonte (cf. mémoire
[`project_refonte_planning_engine.md`](../../) → fichier source
`REFONTE_PLAN.md.pages` à la racine, **format Apple Pages**, voir
section *« Limites connues »*), ce snapshot ne doit plus être modifié
après création. Toutes les phases ultérieures comparent leur output à
ce baseline pour détecter régressions ou améliorations.

## Fichiers lus

Pour comprendre l'architecture actuelle avant d'écrire le script :

- `lib/features/planning/services/places_first_pipeline.dart` (6241
  lignes) — orchestrateur monolithique. Points d'entrée publics
  identifiés : `gatherCandidatesForTrip`, `groupDaysByCenter`,
  `partitionByQuartier`, `selectVisitsDeterministic`,
  `insertDeterministicMeals`, `priceLevelCapForBudget`. Pipeline
  production : `runAutoPlacesFirst` (orchestre les 5 fonctions
  ci-dessus, sans Gemini sur `category=all` / `activities`).
- `lib/features/planning/data/destination_blueprints.dart` —
  `DestinationBlueprint` avec `mustSeeQueries` / `experienceQueries`,
  `getBlueprintForDestination` + aliases. Singapour présent.
- `lib/features/planning/data/metro_profile.dart` — `MetroProfile`
  (zones / anchors / `blockedAddressPatterns` /
  `visitBlockedNamePatterns` / `disabledArchetypes` / `isMegaCity` /
  `clusterRadiusKm`). 17 villes au registre (`metroProfiles`),
  Singapour avec 5 zones spécifiques + blocage Johor/Indonésie.
- `lib/features/planning/data/segment_city_canonicals.dart` —
  Canonical Singapour (1.3521, 103.8198, country=sg) + Bali, Hanoi,
  Bangkok, Koh Samet, Hoi An, etc.
- `lib/features/planning/services/day_builder.dart` — `DayPackType`
  enum (12 valeurs dont 5 Singapore-specific), `buildDayPacksForCluster`,
  `isCandidateTripLevelDedupEligible`.
- `lib/features/planning/services/traveler_to_places_mapping.dart` —
  10 profils voyageurs (`Couple`, `En famille`, `Backpack`, …).
- `lib/features/planning/models/activity_suggestion_model.dart` —
  modèle plat des suggestions (pas de `placeId`, seulement `lat/lng`).
- `lib/features/trips/models/trip_model.dart` — `Trip` (destination,
  startDate, endDate, interests, budgetPerPersonEur,
  localTransportMode, travelerType, itinerarySegments).
- `test/dev/places_first_harness.dart` — harness existant (10
  profils sur Marrakech + Essaouira), pattern de référence pour le
  branchement pipeline + hit API + capture logs.

## Fichiers créés

- **`test/snapshots/generate_baseline.dart`** — script de génération
  (~290 lignes). Sans suffixe `_test` pour ne PAS être picked-up par
  `flutter test` sans args (CI). Run manuel explicite uniquement.
- **`test/snapshots/singapore_baseline.json`** — snapshot baseline
  produit par le run du `2026-05-11`, ~54 KB, format JSON
  pretty-printed.
- **`docs/migrations/phase0_task0_1.md`** — ce document.

## Commande pour générer le snapshot

```bash
flutter test test/snapshots/generate_baseline.dart
```

Run manuel. Durée ~30-90 secondes (hit la vraie Google Places API).
Génère / écrase `test/snapshots/singapore_baseline.json`.

## Format du JSON généré

Schéma (top-level keys) :

```json
{
  "metadata": {
    "generated_at": "<ISO8601 UTC>",
    "pipeline_commit": "<git rev-parse HEAD>",
    "pipeline_version": "V8.28c",
    "warning": "Baseline immuable PAR ENGAGEMENT HUMAIN ...",
    "trip": { "id", "destination", "country_code", "country_name",
              "start_date", "end_date", "duration_days",
              "traveler_type", "interests", "local_transport_mode",
              "budget_per_person_eur" }
  },
  "summary": {
    "total_visits": 19,
    "total_meals": 4,
    "total_generated_days": 7,
    "free_days_count": 1,
    "duplicate_name_visits_count": 0,
    "repeated_names": [],
    "avg_inter_slot_distance_meters": "1615.8"
  },
  "visits": [
    {
      "day_date": "2026-05-18",
      "start_time": "09:30",
      "title": "Singapore Botanic Gardens Eco Lake",
      "detail": "...",
      "tag": "Nature",
      "kind": "main",
      "duration_minutes": 90,
      "price_estimate": null,
      "match_reason": "...",
      "latitude": 1.3213,
      "longitude": 103.8165
    },
    ...
  ],
  "meals": [ ... ],
  "captured_logs": [
    "[places_selector_summary] tripId=baseline-singapore-2026-05 ...",
    "[places_first_pick] ...",
    "[day_pack_selected] ...",
    "[places_first_skip_visit] ..."
  ]
}
```

`captured_logs` capture exhaustive de TOUS les `print` du pipeline
pendant le run (via `runZoned`). Permet une analyse fine post-run :
compteurs `rejectedByOutOfCountry`, `rejectedByRestaurantOutOfScope`,
`rejectedByIconicTripDedup`, breakdown `[places_first_skip_visit]`,
décisions Day Builder par jour, etc.

## Choix paramètres "moyens / standards"

Spec demandait *profil voyageur moyen, intérêts variés, budget moyen,
transport public*. Choix concrets faits :

| Paramètre | Valeur | Justification |
|-----------|--------|---------------|
| `travelerType` | `Couple` | Profil le plus représentatif d'un voyage standard. Transport public natif, intérêts variés. |
| `interests` | `['Culture', 'Gastronomie', 'Spots populaires', 'Nature', 'Shopping']` | Couvre les 5 zones spécifiques Singapour (Marina Bay = Spots, Chinatown Civic = Culture, Orchard Botanic = Nature/Shopping, etc.). Évite `Nightlife` qui biaiserait vers bars / Lan Kwai Fong, `Wellness` qui saturerait spa cap, `Plage` non iconique à Singapour. |
| `budgetPerPersonEur` | `800` | ~100 €/j sur 8 jours → `priceLevelCapForBudget` cap=3 standard non-économique non-premium. |
| `localTransportMode` | `public_transport` | Spec explicite. |
| `itinerarySegments` | `const []` | Singapour = 1 destination, pas de segmentation multi-villes. Tous les jours résolvent en `source=destination` → centre canonical Singapour (1.3521, 103.8198) via `segment_city_canonicals`. |

## Résultat obtenu sur Singapour (run du 2026-05-11, commit d7feed8)

```
Total visites      : 19
Total repas        :  4
Jours avec activité:  7
Jours libres       :  1   (= 2026-05-22, rejected_by_iconic_trip_dedup
                            sur tous les slots — toutes les iconiques
                            ont déjà été pickées avant)
Doublons (par nom) :  0
Lieux répétés      : (aucun)
Distance inter-slot moyenne : 1615.8 m
```

Compteurs `[places_selector_summary]` extraits :
- `rejectedByFinalQuality=73`
- `rejectedByOutOfCountry=0` (run n'a pas vu de candidat Johor/Bintan
  dans le pool — sub-cluster Bintan absent ce coup-ci, geocoder a
  stabilisé sur le canonical Singapour grâce à V8.28b1.2)
- `rejectedByRestaurantOutOfScope=19` (hawker centres / restaurants
  V8.28f2 + visitBlockedNamePatterns)
- `rejectedByMajorsCap=49` (cap V8.9 « 2 majors par jour »)
- `rejectedByLowRating=15`
- `rejectedByBlockedType=12`
- `rejectedByBlockedLodging=6`

Day Builder a sélectionné des packs sur :
- `singapore_marina_bay_day` (3 packs au moins)
- `singapore_sentosa_day` (2 packs — 19/05 + 24/05)
- `singapore_chinatown_civic_day` (1 pack)
- `singapore_orchard_botanic_day` (1 pack)

Le 21/05 n'a pas eu de Day Builder pack (Day Builder `disabled` sur
ce cluster — `not_enough_archetype_matches`, fallback slot picker
avec quality floor).

Le **22/05 reste journée libre** : iconic trip dedup rejette tous les
candidats du pool car déjà sélectionnés ailleurs (8 lieux rejetés par
slot via `rejected_by_iconic_trip_dedup`, comportement nominal
V8.28b1.4 / V8.28b1.3).

Note observée pour info (hors scope correction) : les restaurants
sont mal résolus côté pool repas. Beaucoup de `rejected_by_rating`
sur les 8 slots restos (pool centré destination, pas re-cherché par
zone). Probablement à traiter dans une phase future post-refonte.

## Limites connues

1. **Non-déterminisme Google Places API** — le baseline est *immuable
   par engagement humain* (règle d'or 2), pas par construction.
   Google peut renvoyer des candidats différents d'un run à l'autre.
   Conséquence : si la baseline doit être *régénérée* (ex: pour
   changer le profil voyageur de référence), créer un nouveau fichier
   séparé (`singapore_baseline_v2.json`) plutôt que d'écraser le
   premier.

2. **Coût API** — chaque run consomme ~50-100 RPC Google Places New
   API (clé hardcodée `AiConstants.googleMapsApiKey`). Acceptable car
   très occasionnel, mais à documenter pour suite.

3. **Pas de fixtures HTTP / replay** — un système recorder/replay
   serait techniquement souhaitable pour déterminisme, mais hors
   scope Tâche 0.1. À envisager si la couche métriques (Tâche 0.2)
   en a besoin.

4. **Master plan `REFONTE_PLAN.md` non lisible au-delà page 1** — le
   fichier à la racine du projet s'appelle `REFONTE_PLAN.md.pages`
   (format Apple Pages binaire, malgré le `.md` dans le nom). Seule
   la page 1 (mission + 10 règles d'or) est lisible via `preview.jpg`
   extrait de l'archive zip. Le contenu textuel des pages 2+ est
   dans `Index/Document.iwa` (format protobuf+snappy propriétaire
   Apple, non lisible par `textutil` ni `strings`). Pour les Tâches
   0.2+ et phases suivantes, le `.pages` doit être exporté en `.md`
   ou `.pdf` à la racine pour que les contenus phases soient
   accessibles. La spec de la Tâche 0.1 a été transmise directement
   par message utilisateur, donc cette limite n'a pas bloqué.

5. **Métriques calculables simplement** — toutes les métriques
   demandées sont fournies (`total_visits`, `total_generated_days`,
   `free_days_count`, `duplicate_name_visits_count`, `repeated_names`,
   `avg_inter_slot_distance_meters`). Aucune n'est `not_available`.
   La spec disait *"si certaines métriques ne sont pas calculables
   proprement sans créer un module de métriques, affiche
   `not_available`"* — pas nécessaire ici. La couche métriques
   complète viendra en Tâche 0.2.

## Confirmation : pipeline de production NON modifié

- `lib/features/planning/services/places_first_pipeline.dart` :
  **aucune modification** — `git diff --stat` doit montrer 0 ligne
  modifiée sur ce fichier.
- `lib/features/planning/data/` : **aucune modification** — toutes
  les `DestinationBlueprint`, `MetroProfile`, canonicals, etc.
  inchangées.
- `lib/features/planning/services/day_builder.dart` : **aucune
  modification**.
- Aucun feature flag introduit.
- Aucun modèle `Planning` créé.
- Aucun modèle `DestinationIntelligence` ou `DayTemplate` créé.
- Le script utilise UNIQUEMENT des fonctions publiques déjà existantes
  (mêmes points d'entrée que `test/dev/places_first_harness.dart` qui
  faisait déjà le branchement direct vers `gatherCandidatesForTrip` /
  `selectVisitsDeterministic` / `insertDeterministicMeals` /
  `priceLevelCapForBudget`).

## Validation

- `flutter analyze test/snapshots/generate_baseline.dart` → `No
  issues found! (ran in 1.3s)`.
- `flutter test test/snapshots/generate_baseline.dart` → `All tests
  passed!` (1 test, le run du snapshot).
- Suite complète `flutter test` non affectée — le script n'est pas
  picked-up car nommé sans `_test`.

## Hors scope (n'est PAS dans cette tâche)

- Module métriques complet (KPIs avancés, asserts) — Tâche 0.2.
- Feature flag — phase ultérieure.
- DestinationIntelligence / DayTemplate — phases 1+.
- Modification du pipeline — interdit avant Phase 6.

## Recommandations pour les tâches suivantes

- **Exporter `REFONTE_PLAN.md.pages` en `.md` ou `.pdf`** à la racine
  avant la Tâche 0.2, sans quoi je ne pourrai pas lire les détails
  des tâches au-delà de ce qui est transmis manuellement par message.
- Si la Tâche 0.2 introduit une couche métriques formelle, elle
  pourra ré-utiliser ce JSON comme entrée (`captured_logs` permet
  d'extraire les compteurs sans re-run).
