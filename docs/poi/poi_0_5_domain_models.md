# POI-0.5 — Modèles Domaine Dart

## Objectif

Créer une couche domaine pure (Dart models) pour les 6 tables de la base de
connaissances POI Lunao, en stricte cohérence avec le schéma SQL
`supabase/sql/poi_knowledge_base.sql` (POI-0.1) et le contrat POI-0.4.

## Livrables

| Fichier | Description |
|---------|-------------|
| `lib/features/poi/domain/poi_source.dart` | `PoiSource` + `PoiSourceType` |
| `lib/features/poi/domain/poi.dart` | `Poi` + `PoiCategory` |
| `lib/features/poi/domain/poi_alias.dart` | `PoiAlias` |
| `lib/features/poi/domain/poi_source_link.dart` | `PoiSourceLink` |
| `lib/features/poi/domain/poi_tag.dart` | `PoiTag` |
| `lib/features/poi/domain/poi_quality_flag.dart` | `PoiQualityFlag` + `PoiFlagType` |
| `test/poi/poi_domain_models_test.dart` | 53 tests unitaires offline |
| `docs/poi/poi_0_5_domain_models.md` | Ce document |

## Principes de conception

### Couche domaine pure
- **Aucun** `supabase_flutter`, `supabase`, `riverpod`, `go_router`.
- **Aucun** appel réseau, scraping, ou accès Google Places.
- Les modèles sont des value objects immutables (`final` fields).

### Alignement SQL strict
- Chaque champ Dart correspond à une colonne SQL (snake_case en JSON).
- Les types Dart reflètent les types SQL : `text` → `String`, `integer` → `int`,
  `boolean` → `bool`, `double precision` → `double`, `timestamptz` → `DateTime`,
  `jsonb` → `Map<String, dynamic>`.
- Les contraintes SQL CHECK sont reproduites dans `validate()` :
  - `trust_level` ∈ [1, 5]
  - `lat` ∈ [-90, 90] ou null
  - `lng` ∈ [-180, 180] ou null
  - `editorial_score` ∈ [0, 100] ou null
  - `touristic_importance` ∈ [1, 5] ou null
  - `price_level` ∈ [1, 4] ou null
  - `typical_duration_minutes` > 0 ou null
  - `confidence` ∈ [0, 100] ou null

### Enums pour les contraintes `IN`
Les champs ayant une contrainte CHECK `IN (...)` sont modélisés par des enums
Dart (camelCase) avec mapping explicite vers snake_case SQL :
- `PoiSourceType` : `official_board`, `official_venue`, `unesco`, `wikidata`,
  `openstreetmap`, `open_data_gov`, `editorial`
- `PoiCategory` : 18 catégories (must_see, museum, monument, …)
- `PoiFlagType` : `duplicate`, `location_inaccurate`, `name_disputed`,
  `closed`, `deprecated`, `needs_review`

`tag_category` n'a **pas** de CHECK SQL → reste un `String` libre.

### Sérialisation
- `toJson()` → `Map<String, dynamic>` avec clés snake_case.
- `fromJson(Map<String, dynamic>)` → parse strict avec `FormatException` sur
  type mismatch.
- `DateTime` accepte à la fois un objet `DateTime` et une chaîne ISO 8601.
- Les champs ayant un `DEFAULT` en SQL utilisent cette valeur Dart si absents
  du JSON :
  - `trust_level` → 3
  - `is_active` → true
  - `is_must_see` → false
  - `payload` → `{}`
  - `source_raw_data` → `{}`
  - `created_at` / `updated_at` → `DateTime.now()` (fallback)

### Validation
- `validate()` retourne `List<String>` (vide = OK). Cohérent avec les modèles
  existants (`DestinationIntelligence`, `DayTemplate`, `SameComplexGroup`).
- `isValid` getter sur chaque modèle.

## Mapping SQL → Dart détaillé

### `poi_sources` → `PoiSource`

| SQL colonne | Dart champ | Type | Null | Default |
|-------------|-----------|------|------|---------|
| `source_id` | `sourceId` | `String` | NOT NULL | gen_random_uuid() |
| `name` | `name` | `String` | NOT NULL | — |
| `source_type` | `sourceType` | `PoiSourceType` | NOT NULL | — |
| `base_url` | `baseUrl` | `String?` | nullable | — |
| `license_name` | `licenseName` | `String?` | nullable | — |
| `license_url` | `licenseUrl` | `String?` | nullable | — |
| `trust_level` | `trustLevel` | `int` | NOT NULL | 3 |
| `is_active` | `isActive` | `bool` | NOT NULL | true |
| `notes` | `notes` | `String?` | nullable | — |
| `created_at` | `createdAt` | `DateTime` | NOT NULL | now() |
| `updated_at` | `updatedAt` | `DateTime` | NOT NULL | now() |

### `pois` → `Poi`

| SQL colonne | Dart champ | Type | Null | Default |
|-------------|-----------|------|------|---------|
| `poi_id` | `poiId` | `String` | NOT NULL | gen_random_uuid() |
| `destination_key` | `destinationKey` | `String` | NOT NULL | — |
| `name` | `name` | `String` | NOT NULL | — |
| `normalized_name` | `normalizedName` | `String` | NOT NULL | — |
| `category` | `category` | `PoiCategory` | NOT NULL | — |
| `subcategory` | `subcategory` | `String?` | nullable | — |
| `lat` | `lat` | `double?` | nullable | — |
| `lng` | `lng` | `double?` | nullable | — |
| `address` | `address` | `String?` | nullable | — |
| `country_code` | `countryCode` | `String?` | nullable | — |
| `zone_name` | `zoneName` | `String?` | nullable | — |
| `official_url` | `officialUrl` | `String?` | nullable | — |
| `source_primary_id` | `sourcePrimaryId` | `String` | NOT NULL | — |
| `editorial_score` | `editorialScore` | `int?` | nullable | — |
| `touristic_importance` | `touristicImportance` | `int?` | nullable | — |
| `is_must_see` | `isMustSee` | `bool` | NOT NULL | false |
| `is_family_friendly` | `isFamilyFriendly` | `bool?` | nullable | — |
| `is_rain_friendly` | `isRainFriendly` | `bool?` | nullable | — |
| `is_free` | `isFree` | `bool?` | nullable | — |
| `typical_duration_minutes` | `typicalDurationMinutes` | `int?` | nullable | — |
| `opening_notes` | `openingNotes` | `String?` | nullable | — |
| `price_level` | `priceLevel` | `int?` | nullable | — |
| `google_place_id` | `googlePlaceId` | `String?` | nullable | — |
| `same_complex_group_key` | `sameComplexGroupKey` | `String?` | nullable | — |
| `payload` | `payload` | `Map<String, dynamic>` | NOT NULL | '{}' |
| `created_at` | `createdAt` | `DateTime` | NOT NULL | now() |
| `updated_at` | `updatedAt` | `DateTime` | NOT NULL | now() |

### `poi_aliases` → `PoiAlias`

| SQL colonne | Dart champ | Type | Null | Default |
|-------------|-----------|------|------|---------|
| `alias_id` | `aliasId` | `String` | NOT NULL | gen_random_uuid() |
| `poi_id` | `poiId` | `String` | NOT NULL | — |
| `alias` | `alias` | `String` | NOT NULL | — |
| `alias_normalized` | `aliasNormalized` | `String` | NOT NULL | — |
| `is_canonical` | `isCanonical` | `bool` | NOT NULL | false |
| `source_id` | `sourceId` | `String?` | nullable | — |
| `created_at` | `createdAt` | `DateTime` | NOT NULL | now() |

### `poi_source_links` → `PoiSourceLink`

| SQL colonne | Dart champ | Type | Null | Default |
|-------------|-----------|------|------|---------|
| `link_id` | `linkId` | `String` | NOT NULL | gen_random_uuid() |
| `poi_id` | `poiId` | `String` | NOT NULL | — |
| `source_id` | `sourceId` | `String` | NOT NULL | — |
| `source_poi_identifier` | `sourcePoiIdentifier` | `String?` | nullable | — |
| `source_url` | `sourceUrl` | `String?` | nullable | — |
| `source_raw_data` | `sourceRawData` | `Map<String, dynamic>` | NOT NULL | '{}' |
| `verified_at` | `verifiedAt` | `DateTime?` | nullable | — |
| `created_at` | `createdAt` | `DateTime` | NOT NULL | now() |

### `poi_tags` → `PoiTag`

| SQL colonne | Dart champ | Type | Null | Default |
|-------------|-----------|------|------|---------|
| `tag_id` | `tagId` | `String` | NOT NULL | gen_random_uuid() |
| `poi_id` | `poiId` | `String` | NOT NULL | — |
| `tag` | `tag` | `String` | NOT NULL | — |
| `tag_category` | `tagCategory` | `String?` | nullable | — |
| `confidence` | `confidence` | `int?` | nullable | — |
| `source_id` | `sourceId` | `String?` | nullable | — |
| `created_at` | `createdAt` | `DateTime` | NOT NULL | now() |

### `poi_quality_flags` → `PoiQualityFlag`

| SQL colonne | Dart champ | Type | Null | Default |
|-------------|-----------|------|------|---------|
| `flag_id` | `flagId` | `String` | NOT NULL | gen_random_uuid() |
| `poi_id` | `poiId` | `String` | NOT NULL | — |
| `flag_type` | `flagType` | `PoiFlagType` | NOT NULL | — |
| `flag_reason` | `flagReason` | `String?` | nullable | — |
| `reported_by` | `reportedBy` | `String?` | nullable | — |
| `resolved_at` | `resolvedAt` | `DateTime?` | nullable | — |
| `resolution_notes` | `resolutionNotes` | `String?` | nullable | — |
| `created_at` | `createdAt` | `DateTime` | NOT NULL | now() |

## Tests

Le fichier `test/poi/poi_domain_models_test.dart` contient **53 tests** répartis
en :

1. **Construction & defaults** — validation des valeurs par défaut SQL et des
   règles de validation (range checks, champs vides).
2. **Round-trip JSON** — `toJson()` → `fromJson()` conserve toutes les valeurs,
   y compris égalité `==` et `hashCode`.
3. **fromJson defaults** — champs absents utilisent leur valeur SQL DEFAULT.
4. **Enum serialization** — tous les membres d'enum round-trippent ; valeur
   inconnue lève `FormatException`.
5. **DateTime parsing** — accepte `DateTime` natif et chaîne ISO 8601.
6. **Nullable fields** — champs nullable sérialisent bien en `null`.
7. **Cross-model coherence** — toutes les clés JSON sont en snake_case ; tous
   les modèles ont `toString()`.

## Ce qui est volontairement hors scope

- **Pas de `copyWith`** : non requis pour POI-0.5 ; ajoutable plus tard sans
  breaking change.
- **Pas de repository** : la couche data (Supabase) viendra en POI-0.6/0.7.
- **Pas de provider Riverpod** : la couche presentation viendra après.
- **Pas de branchement au pipeline** : les modèles sont isolés du moteur de
  planning existant.

## Prochaines étapes suggérées

- **POI-0.6** — Repository abstrait + implémentation Supabase (lecture).
- **POI-0.7** — Contract test live contre Supabase (Option B du POI-0.4).
- **POI-0.8** — Providers Riverpod + intégration UI (carte, recherche).
