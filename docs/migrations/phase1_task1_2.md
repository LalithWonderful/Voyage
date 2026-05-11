# Phase 1 / Tâche 1.2 — Données Singapour DestinationIntelligence

## Objectif

Créer un fichier de **données locales** pour Singapour
(`lib/data/destinations/singapore.dart`) construisant un objet
`DestinationIntelligence` complet à partir des informations
actuellement dispersées dans le pipeline. **Fichier de données
uniquement** — pas de loader, pas de branchement pipeline, pas de
consommation du flag `useDestinationIntelligence`.

## Fichiers lus

Sources mappées vers `DestinationIntelligence` :

- `lib/features/planning/data/destination_blueprints.dart`
  → `_singaporeBlueprint` (lignes 385-407) :
  - 10 `mustSeeQueries`
  - 5 `experienceQueries`
- `lib/features/planning/data/metro_profile.dart`
  → `_singaporeMetro` (lignes 879-997) :
  - `lat: 1.3521, lng: 103.8198`
  - `clusterRadiusKm: 35.0`
  - `isMegaCity: true`
  - `disabledArchetypes`
  - `blockedAddressPatterns` (15 patterns)
  - `visitBlockedNamePatterns` (4 patterns)
  - 9 `touristAnchors`
  - 5 zones (`singaporeMarinaBayDay`, `singaporeSentosaDay`,
    `singaporeChinatownCivicDay`, `singaporeOrchardBotanicDay`,
    `singaporeKampongGlamLittleIndiaDay`)
- `lib/features/planning/data/segment_city_canonicals.dart`
  → `'singapore'` + `'singapour'` (lignes 192-208) :
  - `expectedLat: 1.3521, expectedLng: 103.8198, countryCode: 'sg'`
- `lib/models/destination_intelligence.dart` — schéma cible.

## Fichiers créés

- **`lib/data/destinations/singapore.dart`** *(créé, ~290 lignes)* —
  fonction `buildSingaporeDestinationIntelligence()` retournant
  l'objet construit. Aucun import des fichiers de production
  (`destination_blueprints.dart`, `metro_profile.dart`,
  `segment_city_canonicals.dart`) — uniquement le modèle
  `DestinationIntelligence`. Pas de couplage parasite.
- **`test/data/destinations/singapore_destination_intelligence_test.dart`**
  *(créé, ~370 lignes)* — **35 tests** purement unitaires, 7 groupes.
- **`docs/migrations/phase1_task1_2.md`** *(ce document)*.

**Aucun fichier modifié** :
- `lib/features/planning/services/places_first_pipeline.dart` intact
- `lib/features/planning/data/destination_blueprints.dart` intact
- `lib/features/planning/data/metro_profile.dart` intact
- `lib/features/planning/data/segment_city_canonicals.dart` intact
- `lib/features/planning/services/day_builder.dart` intact
- `lib/config/feature_flags.dart` intact (flag toujours OFF, non consommé)
- `lib/models/destination_intelligence.dart` **intact** — pas de
  champ ajouté au modèle Phase 1.1 dans cette tâche.

## Mapping des sources existantes vers DestinationIntelligence

| Champ DestinationIntelligence | Valeur | Source |
|---|---|---|
| `destinationKey` | `'singapore'` | `_singaporeBlueprint.destinationKey` |
| `canonicalCenter` | `GeoPoint(1.3521, 103.8198)` | `_canonicalCities['singapore']` (cohérent avec `_singaporeMetro.lat/lng`) |
| `countryCode` | `'SG'` | `_canonicalCities['singapore'].countryCode = 'sg'` → uppercase ISO |
| `allowedCountryCodes` | `['SG']` | déduit du `countryCode` (un seul pays) |
| `blockedCountryCodes` | `['MY', 'ID']` | dérivé de `_singaporeMetro.blockedAddressPatterns` (Malaisie + Indonésie) |
| `borderSensitivity` | `BorderSensitivity.high` | choix produit — contexte frontière Johor + Bintan |
| `tripMode` | `TripMode.megaCity` | `_singaporeMetro.isMegaCity == true` |
| `zones` | 10 zones (cf. liste ci-dessous) | split des 5 zones MetroProfile + ajout Bugis |
| `anchors` | 15 anchors | fusion `_singaporeBlueprint.mustSeeQueries` (10) + `experienceQueries` (5) |
| `transportRules.maxTransitionKm` | `5.0` | V8.28d-fix `_kMaxTransitionMegaCityKm` |
| `transportRules.dominantMode` | `'public_transport'` | Singapore MRT + bus denses |
| `transportRules.hasMetro` | `true` | MRT couvre tout le territoire |
| `transportRules.hasMetroAnchorLogic` | `true` | `_singaporeMetro.touristAnchors` consommés par fan-out V8.28d |

## Liste des 10 zones Singapour

| # | Zone | Centre | Rayon | Thème | Source |
|---|------|--------|-------|-------|--------|
| 1 | Marina Bay | (1.2830, 103.8600) | 1.5 km | `waterfront_iconic` | `singaporeMarinaBayDay` |
| 2 | Chinatown | (1.2814, 103.8443) | 0.8 km | `chinatown_heritage` | split de `singaporeChinatownCivicDay` |
| 3 | Civic District | (1.2906, 103.8512) | 0.8 km | `civic_museums` | split de `singaporeChinatownCivicDay` |
| 4 | Orchard | (1.3050, 103.8327) | 1.0 km | `shopping_modern` | split de `singaporeOrchardBotanicDay` |
| 5 | Sentosa | (1.2494, 103.8303) | 3.0 km | `island_resort` | `singaporeSentosaDay` |
| 6 | Little India | (1.3066, 103.8520) | 0.7 km | `little_india_ethnic` | split de `singaporeKampongGlamLittleIndiaDay` |
| 7 | Kampong Glam | (1.3019, 103.8590) | 0.6 km | `muslim_quarter_arab` | split de `singaporeKampongGlamLittleIndiaDay` |
| 8 | Botanic Gardens | (1.3138, 103.8159) | 1.5 km | `nature_garden` | split de `singaporeOrchardBotanicDay` |
| 9 | **Bugis** | (1.3007, 103.8559) | 0.6 km | `street_market` | **AJOUT user** (non MetroProfile standalone) |
| 10 | Clarke Quay | (1.2904, 103.8467) | 0.6 km | `riverside_nightlife` | split de `singaporeChinatownCivicDay` |

**Note Bugis** : la spec Tâche 1.2 demande explicitement Bugis dans
les 10 zones, mais ce n'est pas une zone standalone dans le
MetroProfile existant. Ajouté ici avec coordonnées dérivées de
Bugis MRT / Bugis Junction area (~1.3007, 103.8559). Documenté
dans le commentaire de tête de `singapore.dart` et confirmé par
test dédié.

## Liste des 15 anchors Singapour

Issus de `_singaporeBlueprint.mustSeeQueries` (10) +
`experienceQueries` (5). Dédup contre `_singaporeMetro.touristAnchors`
(qui répliquent largement le blueprint).

### Importance 5 (incontournable)
| Anchor | Duration (min) | Source query |
|--------|---:|--------------|
| Marina Bay Sands | 120 | `'Marina Bay Sands Singapore'` |
| Gardens by the Bay | 180 | `'Gardens by the Bay Supertree'` |
| Sentosa Island | 360 | `'Sentosa Island Singapore'` |
| Singapore Botanic Gardens | 150 | `'Singapore Botanic Gardens'` |
| Buddha Tooth Relic Temple | 60 | `'Buddha Tooth Relic Temple Singapore'` |

### Importance 4 (très recommandé)
| Anchor | Duration (min) | Source query |
|--------|---:|--------------|
| Chinatown | 120 | `'Chinatown Singapore'` |
| Little India | 90 | `'Little India Singapore'` |
| Merlion Park | 30 | `'Merlion Park Singapore'` |
| Orchard Road | 120 | `'Orchard Road Singapore'` |
| ArtScience Museum | 120 | `'ArtScience Museum Singapore'` |
| Kampong Glam / Arab Street | 90 | `'Kampong Glam Arab Street'` |

### Importance 3 (experience / secondaire)
| Anchor | Duration (min) | Source query | Note |
|--------|---:|--------------|------|
| Clarke Quay | 90 | `'Clarke Quay Singapore night'` | nightlife |
| Lau Pa Sat | 60 | `'Lau Pa Sat hawker centre'` | **hawker, normalement bloqué visite** (cf. note 2) |
| Maxwell Food Centre | 60 | `'Maxwell Food Centre Singapore'` | **hawker, normalement bloqué visite** (cf. note 2) |
| Singapore Flyer | 60 | `'Singapore Flyer'` | — |

## Choix `borderSensitivity = high`

Singapour est limitrophe de :
- Johor Bahru (Malaisie, ~25 km au sud de Woodlands) → `'MY'`
- Bintan / Batam / Tanjung Pinang (Indonésie, ~50-75 km au SE) → `'ID'`

Le pipeline a historiquement dérivé dans ces deux pays
(V8.28b1 Johor + V8.28b1.2 Bintan). `borderSensitivity.high` est
le bon niveau pour drive l'agressivité du filter
`blockedAddressPatterns` futur (Phase 3 DestinationScope).

## Choix `tripMode = megaCity`

`_singaporeMetro.isMegaCity == true`. Conséquences héritées :
- Cap distance intra-journée 5 km (`_kMaxTransitionMegaCityKm`)
- Quality floor mégalopole fallback (`isMetroQualifiedCandidate`)
- Cap fallback transition 5 km / 0 long hop V8.28b1.3

Confirmé par test dédié.

## Choix `transportRules`

- `maxTransitionKm: 5.0` — convention Lunao mégacité dense
  (`_kMaxTransitionMegaCityKm`).
- `dominantMode: 'public_transport'` — Singapore MRT + bus
  ultra-denses, transport public dominant.
- `hasMetro: true` — MRT couvre tout, y compris Sentosa via
  Sentosa Express.
- `hasMetroAnchorLogic: true` — `_singaporeMetro` définit 9
  `touristAnchors` consommés par le fan-out V8.28d
  `metro_anchor_fanout` du pipeline.

## Informations existantes NON représentables dans le modèle 1.1

Le commentaire de tête de `singapore.dart` documente ces 4 limites.
Aucun hack Singapour spécifique introduit ; chaque limite a une
voie de traitement futur claire.

### 1. `blockedAddressPatterns` littéraux fins

Patterns du MetroProfile non représentables comme codes pays ISO :
- `'ksl city'`, `'komtar'`, `'jbcc'` (mots-clés malls/lieux Johor)
- `'lagoi'`, `'tanjung pinang'`, `'kepri'`, `'riau islands'`,
  `'kepulauan riau'` (mots-clés Indonésie infranationale)
- `'johor bahru'`, `'johor darul ta\'zim'` (sous-régions Malaisie)

Le champ `blockedCountryCodes: ['MY', 'ID']` couvre la sémantique
**pays** mais pas la sémantique **mots-clés d'adresse**. Devra
être traité en **Phase 3 — DestinationScope** via une abstraction
générique (ex: `DestinationScope.blockedPlacePatterns: List<String>`),
**sans hack Singapour spécifique**.

### 2. `visitBlockedNamePatterns` hawker centres

Patterns `visitBlockedNamePatterns` du MetroProfile :
- `'lau pa sat'`, `'maxwell food centre'`, `'hong lim market'`,
  `'food centre'`

Règle business : "hawker centre = repas, jamais visite"
(V8.28b1). Le modèle 1.1 n'a pas de champ pour catégoriser un
anchor en `visit` vs `meal`.

**Conséquence concrète** dans `singapore.dart` : Lau Pa Sat et
Maxwell Food Centre sont **inclus** dans `anchors` (fidélité au
blueprint `experienceQueries`) avec `importance: 3`, **SANS**
catégorisation visite/repas. Le commentaire de tête + le commentaire
in-line sur ces 2 anchors documentent cette limite. À traiter
dans une phase ultérieure (`DestinationAnchor.category` ou tag
équivalent).

### 3. `disabledArchetypes` legacy

`_singaporeMetro.disabledArchetypes = {oldCityDay, riversideDay,
marketDay, modernDay}` — Singapore désactive les archétypes
génériques du Day Builder au profit des 5 archétypes spécifiques.

Concept propre au Day Builder actuel, **pas transposable
directement**. La structure de `zones` dans
`DestinationIntelligence` (10 zones nommées avec thèmes
sémantiques) remplace conceptuellement ce mécanisme : plus de
fallback générique nécessaire, la taxonomie est explicite.
**Ne nécessite PAS de field additionnel.**

### 4. `clusterRadiusKm: 35.0`

Rayon d'activation du Day Builder autour du centre canonique
Singapour. Le modèle 1.1 a `transportRules.maxTransitionKm` (cap
intra-journée) mais pas de rayon global de destination.

À considérer pour Phase ultérieure si une logique de scope
géographique en a besoin (probablement Phase 3 DestinationScope).
Pas urgent — la `canonicalCenter` + les `zones` couvrent
implicitement la zone géographique pertinente.

## Confirmation : aucun pipeline ne consomme encore DestinationIntelligence

- ✅ `grep -rn "buildSingaporeDestinationIntelligence\|DestinationIntelligence"
  lib/features/`  → **aucune référence** dans les fichiers du
  pipeline production
- ✅ `lib/config/feature_flags.dart::useDestinationIntelligence`
  reste à `false` par défaut et **n'est consommé nulle part**
- ✅ `places_first_pipeline.dart` n'importe NI le modèle, NI
  les données Singapour
- ✅ Le fichier `singapore.dart` n'importe QUE
  `lib/models/destination_intelligence.dart` (pas les
  `MetroProfile`, `Blueprint`, ni autre fichier de production)

## Résultats validation

```
flutter analyze
  35 issues found (info préexistants Tâche 0.1, inchangés)
  → lib/data/destinations/singapore.dart : No issues found
  → test/data/destinations/...test.dart : No issues found
  0 warning, 0 error sur les nouveaux fichiers

flutter test
  559 tests verts (524 Tâche 1.1 + 35 nouveaux Tâche 1.2)

flutter test test/snapshots/generate_baseline.dart
  1 test passé, baseline JSON régénéré (variation Google Places
  attendue, cf. limite Tâche 0.1)

flutter test test/snapshots/compare_snapshot.dart
  16 tests passés (1 self-check + 15 fixtures)
  Verdict self-check : PASS
```

## Commande

```bash
# Tests unitaires purs (35 tests)
flutter test test/data/destinations/singapore_destination_intelligence_test.dart

# Suite complète
flutter test
flutter test test/snapshots/generate_baseline.dart
flutter test test/snapshots/compare_snapshot.dart
```

## Hors scope (n'est PAS dans cette tâche)

- ❌ Loader (Supabase, asset, ou autre) — Tâche 1.3
- ❌ Branchement au pipeline `places_first_pipeline.dart`
- ❌ Consommation du flag `useDestinationIntelligence`
- ❌ Migration des autres destinations (Bangkok, Tokyo, Paris, …)
- ❌ Seed SQL Singapour dans Supabase (le projet a `feature_flags.sql`
  + `destination_intelligence.sql` schema mais ne seede pas les
  données — la source de vérité est le fichier Dart local)
- ❌ Ajout de champ au modèle `DestinationIntelligence` (Phase 1.1
  schema gelé jusqu'à Tâche 1.3+)
- ❌ Détection complexes sémantiques (Sentosa Island / Sentosa) —
  Phase 2 `SameComplexGroup`
- ❌ DayTemplate — Phase 4

## Recommandations Phase 3 (DestinationScope)

Les 4 limites documentées ci-dessus convergent vers une abstraction
**DestinationScope** à introduire en Phase 3 :

- Ajouter `DestinationScope.blockedPlacePatterns: List<String>` au
  modèle (patterns littéraux fins, génériques pour Singapour /
  Hong Kong / autres villes frontalières).
- Ajouter `DestinationAnchor.category: AnchorCategory` enum
  `{visit, meal, dayTrip, ...}` pour distinguer hawker centres
  (= meal) des visites classiques.
- Considérer `DestinationScope.activationRadiusKm: double` pour le
  rayon global de destination (équivalent `clusterRadiusKm` du
  MetroProfile actuel).

Ces ajouts ne sont **pas** des hacks Singapour spécifiques —
ils servent toutes les destinations frontalières et toutes les
villes avec hawker culture / street food iconique (Bangkok,
Hong Kong, Taipei, etc.).
