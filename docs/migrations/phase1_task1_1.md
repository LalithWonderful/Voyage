# Phase 1 / Tâche 1.1 — Schéma de données `DestinationIntelligence`

## Objectif

Créer **le squelette de données** de la future abstraction
`DestinationIntelligence` qui remplacera conceptuellement plus tard :

- `DestinationBlueprint` (queries mustSee / experience)
- `MetroProfile` (zones, anchors, `blockedAddressPatterns`,
  `disabledArchetypes`)
- `segment_city_canonicals` (canonical coords)
- règles transport (`isMegaCity` → `TransportRules`)
- règles frontière (`blockedAddressPatterns` → `borderSensitivity` +
  `allowed/blockedCountryCodes`)

**Phase 1.1 = uniquement le modèle + validation + JSON + migration
SQL + tests.** Aucune migration de données, aucun loader, aucun
branchement pipeline.

## Fichiers créés

- **`lib/models/destination_intelligence.dart`** *(créé, ~575 lignes)*
  — modèle pur, immutable, sans dépendance Flutter/réseau. Top-level
  class `DestinationIntelligence` + sous-modèles `GeoPoint`,
  `TouristZone`, `DestinationAnchor`, `TransportRules` + enums
  `BorderSensitivity`, `TripMode`. Sérialisation `toJson()` /
  `fromJson()` round-trip pour chaque type. Validation
  `List<String> validate()` agrégée.
- **`test/models/destination_intelligence_test.dart`** *(créé)* —
  **41 tests** purement unitaires, sans réseau, sans Supabase.
- **`supabase/sql/destination_intelligence.sql`** *(créé)* — table
  + indexes + RLS + trigger updated_at. **Aucun seed** (réservé
  Tâche 1.2).
- **`docs/migrations/phase1_task1_1.md`** *(ce document)*.

**Pipeline production NON modifié** :
- `lib/features/planning/services/places_first_pipeline.dart` intact
- `lib/features/planning/data/destination_blueprints.dart` intact
- `lib/features/planning/data/metro_profile.dart` intact
- `lib/features/planning/data/segment_city_canonicals.dart` intact
- `lib/config/feature_flags.dart` intact (flag
  `useDestinationIntelligence` reste OFF par défaut, **non consommé**)

## Choix de modélisation

### Path : `lib/models/destination_intelligence.dart`

Le projet a une convention feature-based (`lib/features/<domain>/
models/`). La spec demande explicitement `lib/models/` à la racine.
Justification retenue (documentée dans le fichier) :
- `DestinationIntelligence` est un modèle **cross-feature**
  (consommé par le pipeline planning, mais aussi potentiellement
  par d'autres modules : trip resolver, scope manager, etc.)
- Conformer à la spec littérale
- Cohérent avec la philosophie "abstraction générique" du plan
  refonte (cf. règle d'or 7)

### Convention JSON : `snake_case`

Choix : **snake_case** pour cohérence avec les modèles existants
du projet (vérifié sur `activity_suggestion_model.dart`,
`trip_model.dart`) :
- `day_date`, `start_time`, `activity_kind`, `check_in`,
  `country_code`, etc.

Conséquence : exemple JSON de la spec converti :
```json
{
  "destination_key": "singapore",
  "canonical_center": { "lat": 1.3521, "lng": 103.8198 },
  "country_code": "SG",
  "allowed_country_codes": ["SG"],
  "blocked_country_codes": ["MY", "ID"],
  "border_sensitivity": "high",
  "trip_mode": "megaCity",
  "zones": [
    {
      "name": "Marina Bay",
      "center": { "lat": 1.283, "lng": 103.860 },
      "radius_km": 2.0,
      "theme": "waterfront_iconic"
    }
  ],
  "anchors": [
    {
      "name": "Gardens by the Bay",
      "place_queries": ["Gardens by the Bay Singapore"],
      "importance": 5,
      "recommended_duration_minutes": 180
    }
  ],
  "transport_rules": {
    "max_transition_km": 5.0,
    "dominant_mode": "public_transport",
    "has_metro": true,
    "has_metro_anchor_logic": true
  }
}
```

**Exception** : les **valeurs d'enums** (`borderSensitivity`,
`tripMode`) restent en camelCase (`megaCity`, `historicCity`,
etc.) — c'est la valeur `name` directe de l'enum Dart, et cohérent
avec les autres serializations enum du projet.

### Validation : retour de `List<String>`

3 options proposées par la spec ; retenu : **retour de liste
d'erreurs**.

Justifications :
- Capture TOUTES les erreurs en un appel (un loader peut remonter
  toutes les erreurs à l'admin, pas seulement la première).
- Testable sans `try/catch` (juste `expect(model.validate(), …)`).
- Pas d'exception levée → l'appelant choisit son comportement
  (logger, throw, skip, warn).

API :
```dart
List<String> errors = destination.validate();
if (errors.isEmpty) {
  // OK
} else {
  // Traiter les erreurs
}
// Helper booléen :
bool ok = destination.isValid;
```

Tests prouvent qu'un modèle avec 8 problèmes simultanés retourne
8+ erreurs en un seul appel.

### Enums : strict-by-default

Valeur JSON inconnue → `FormatException` levée par `fromJsonString`.
Cohérent avec la philosophie Phase 1 (squelette strict, on durcira
ou on assouplira en phase ultérieure si besoin).

### `Duration` Dart-side, JSON `recommended_duration_minutes` int

Stockage Dart : `final Duration recommendedDuration`. Sérialisé
JSON en `recommended_duration_minutes` (int) pour éviter les
problèmes de parsing ISO 8601 et garder la cohérence
snake_case + intégers simples.

## Description des classes et enums

### `GeoPoint`
| Champ | Type | Validation |
|-------|------|-----------|
| `lat` | `double` | `[-90, 90]`, non NaN |
| `lng` | `double` | `[-180, 180]`, non NaN |

### `TouristZone`
| Champ | Type | Validation |
|-------|------|-----------|
| `name` | `String` | non vide |
| `center` | `GeoPoint` | déléguée |
| `radiusKm` | `double` | `> 0`, non NaN |
| `theme` | `String` | non vide |

### `DestinationAnchor`
| Champ | Type | Validation |
|-------|------|-----------|
| `name` | `String` | non vide |
| `placeQueries` | `List<String>` | ≥ 1 query non vide |
| `importance` | `int` | `[1, 5]` (constantes `minImportance` / `maxImportance`) |
| `recommendedDuration` | `Duration` | `inMinutes > 0` |

### `TransportRules`
| Champ | Type | Validation |
|-------|------|-----------|
| `maxTransitionKm` | `double` | `> 0`, non NaN |
| `dominantMode` | `String` | non vide |
| `hasMetro` | `bool` | — |
| `hasMetroAnchorLogic` | `bool` | — |

### `BorderSensitivity` enum
`low` | `medium` | `high` — drives l'agressivité du filter
`blockedAddressPatterns` futur.

### `TripMode` enum
`cityBreak` | `megaCity` | `island` | `multiRegion` | `historicCity`
| `beachResort` — drives heuristiques haut-niveau (cap distances,
structure journées).

### `DestinationIntelligence` (top-level)
| Champ | Type | Validation |
|-------|------|-----------|
| `destinationKey` | `String` | non vide |
| `canonicalCenter` | `GeoPoint` | déléguée |
| `countryCode` | `String` | non vide (uppercase recommandé, non forcé) |
| `allowedCountryCodes` | `List<String>` | ≥ 1 |
| `blockedCountryCodes` | `List<String>` | peut être vide |
| `borderSensitivity` | `BorderSensitivity` | présent |
| `tripMode` | `TripMode` | présent |
| `zones` | `List<TouristZone>` | ≥ 1, chacune validée |
| `anchors` | `List<DestinationAnchor>` | ≥ 1, chacun validé |
| `transportRules` | `TransportRules` | déléguée |

## Migration Supabase

Fichier : **`supabase/sql/destination_intelligence.sql`**.

Convention projet (alignée sur `feature_flags.sql`,
`country_regions.sql`) : fichiers SQL standalone dans
`supabase/sql/`, application manuelle dans le SQL editor.

Schéma :
```sql
create table if not exists public.destination_intelligence (
  destination_key     text primary key,
  country_code        text not null,
  trip_mode           text not null,
  border_sensitivity  text not null,
  payload             jsonb not null,
  created_at          timestamptz not null default now(),
  updated_at          timestamptz not null default now()
);
```

Le `payload` JSONB contient l'objet complet sérialisé en
**snake_case** (cf. `lib/models/destination_intelligence.dart`).

Indexes :
- `country_code` (filtrage par pays)
- `trip_mode` (filtrage par mode de voyage)
- `border_sensitivity` (filtrage par sensibilité)
- GIN sur `payload` (requêtes JSON `payload @> '{...}'`)

RLS : `enable row level security` + policy `for select using (true)`
(anon + authenticated lecture). Pas de write policy → seul le
service_role peut insérer/modifier. Cohérent avec
`feature_flags.sql` et `country_regions.sql`.

Trigger `updated_at` automatique à chaque update.

**Pas de seed dans cette migration.** Le seed Singapour est
Tâche 1.2 explicitement, pour respecter la séparation schéma/données.

## Ce qui n'est volontairement PAS fait dans cette tâche

- ❌ Pas de `lib/data/destinations/singapore.dart` (Tâche 1.2)
- ❌ Pas de migration des MetroProfile / Blueprint Singapour
  existants vers `DestinationIntelligence` (Tâche 1.2)
- ❌ Pas de loader (Supabase, asset, ou autre)
- ❌ Pas de branchement au pipeline (`places_first_pipeline.dart`
  inchangé)
- ❌ Pas de consommation de `FeatureFlags.useDestinationIntelligence`
- ❌ Pas de modification de `DestinationBlueprint`
- ❌ Pas de modification de `MetroProfile`
- ❌ Pas de modification de `segment_city_canonicals`
- ❌ Pas de suppression d'ancien code

## Tests unitaires — 41 tests, 10 groupes

| Groupe | Tests | Couverture |
|--------|------:|-----------|
| Round-trip JSON | 3 | toJson/fromJson, snake_case, Duration |
| Validation modèle valide | 1 | errors empty + `isValid` true |
| Champs obligatoires | 5 | destination_key / allowed / zones / anchors / country_code vides |
| Coordonnées invalides | 7 | lat/lng hors plage, NaN, bornes, propagation |
| Enums | 5 | parsing valide, round-trip, valeur inconnue → FormatException |
| Anchor | 7 | importance / duration / queries / name |
| TransportRules | 4 | max_transition / dominant_mode |
| TouristZone | 4 | name / radius / theme |
| Validation agrégation | 1 | 8 erreurs simultanées en un appel |
| fromJson erreurs explicites | 4 | GeoPoint type errors, champ optionnel |

Aucune dépendance réseau / Supabase / Google Places.

## Confirmation pipeline production NON modifié

- ✅ `lib/features/planning/services/places_first_pipeline.dart` —
  intact (vérifié via `git status`)
- ✅ `lib/features/planning/data/destination_blueprints.dart` — intact
- ✅ `lib/features/planning/data/metro_profile.dart` — intact
- ✅ `lib/features/planning/data/segment_city_canonicals.dart` — intact
- ✅ `lib/features/planning/services/day_builder.dart` — intact
- ✅ `lib/config/feature_flags.dart` — intact (flag toujours OFF)
- ✅ Aucun grep `DestinationIntelligence` hors du nouveau module
  et du flag preexistant
- ✅ Aucun comportement utilisateur changé

## Résultats validation

```
flutter analyze
  35 issues found (info préexistants depuis Tâche 0.1, inchangés)
  → lib/models/destination_intelligence.dart : No issues found
  → test/models/destination_intelligence_test.dart : No issues found
  0 warning, 0 error sur les nouveaux fichiers

flutter test
  524 tests verts (483 Tâche 0.4 + 41 nouveaux Tâche 1.1)

flutter test test/snapshots/generate_baseline.dart
  1 test passé, baseline JSON régénéré (variation Google Places
  attendue, cf. limite Tâche 0.1)

flutter test test/snapshots/compare_snapshot.dart
  16 tests passés (1 self-check Singapour + 15 fixtures)
  Verdict self-check : à confirmer (le baseline régénéré peut
  varier vs commit précédent à cause de Google Places).
```

## Limites connues

1. **Pas d'ID admin / versioning du payload** — la table a juste
   `destination_key` PK + `updated_at` trigger. Pas de version
   incrémentale. Si on a besoin de tracer les changements
   éditoriaux, ajouter une colonne `version int` en phase
   ultérieure.

2. **`countryCode` non normalisé automatiquement** — la validation
   accepte n'importe quel string non vide. Recommandation
   "uppercase ISO 3166-1" non forcée. À durcir si on observe des
   inconsistences dans la table prod.

3. **Pas de validation de cohérence cross-zone** — la validation
   ne vérifie pas que les zones ne se chevauchent pas, ni qu'elles
   sont effectivement à l'intérieur du `canonicalCenter ±
   radius`. Hors scope Phase 1.1.

4. **Enums extensibles uniquement par modification source** —
   ajouter une valeur à `TripMode` ou `BorderSensitivity` =
   modification du fichier Dart + tests + migration potentielle
   des payloads existants. C'est l'effet désiré (strict typing).

5. **Aucun validation de la conformité `placeQueries`** — un
   query peut être n'importe quelle string non vide. La validation
   syntaxique des queries Places n'est pas dans le scope.

## Commande

```bash
# Tests unitaires purs
flutter test test/models/destination_intelligence_test.dart

# Suite complète + baseline + comparator (sans surprise)
flutter test
flutter test test/snapshots/generate_baseline.dart
flutter test test/snapshots/compare_snapshot.dart
```

## Hors scope (pour Tâche 1.2+)

- Seed Singapour
- Loader Supabase / asset
- Branchement pipeline (derrière `useDestinationIntelligence`)
- Migration des données existantes (Bangkok, Paris, Tokyo, …)
- Helper de conversion `MetroProfile + Blueprint + canonical` →
  `DestinationIntelligence`
- Validation cross-zone (overlaps, bounds)
