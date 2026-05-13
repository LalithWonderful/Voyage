# POI-2.2 — First Multi-City POI Coverage Pack

## Date
2026-05-13

## Executive Summary

Expanded Lunao POI coverage beyond Lisbon with a manually curated multi-city pack of **75 POIs across 3 pilot cities** (25 each). This enables the POI-first planning pipeline to reduce Google Places usage and improve itinerary quality for Paris, Rome, and Barcelona.

---

## Cities Covered

| City | Destination Key | Country Code | POIs | Must-See | Free | Family-Friendly |
|------|----------------|--------------|------|----------|------|-----------------|
| **Paris** | `paris` | FR | 25 | 8 | 11 | 25 |
| **Rome** | `rome` | IT | 25 | 8 | 11 | 25 |
| **Barcelona** | `barcelona` | ES | 25 | 4 | 11 | 25 |

---

## Fixture Files

| File | POIs | Size |
|------|------|------|
| `test/fixtures/poi/pilot_pois_paris.json` | 25 | ~16 KB |
| `test/fixtures/poi/pilot_pois_rome.json` | 25 | ~17 KB |
| `test/fixtures/poi/pilot_pois_barcelona.json` | 25 | ~17 KB |

---

## POI Mix per City

Each city includes a balanced mix of:

- **Must-see monuments** (Eiffel Tower, Colosseum, Sagrada Família)
- **Museums** (Louvre, Vatican Museums, Picasso Museum)
- **Viewpoints** (Sacré-Cœur, Gianicolo, Bunkers del Carmel)
- **Neighborhoods** (Montmartre, Trastevere, Gothic Quarter)
- **Markets / food halls** (La Boqueria, Campo de' Fiori, Marché Bastille)
- **Parks** (Jardin du Luxembourg, Villa Borghese, Park Güell)
- **Local experiences** (Canal Saint-Martin, Appian Way, Poble Espanyol)
- **Rainy-day options** (museums with `is_rain_friendly: true`)
- **Free options** (neighborhoods, parks, viewpoints with `is_free: true`)

---

## UUID Generation

All POI IDs and source IDs are **deterministic UUID v5** generated from:
- Namespace: `6ba7b810-9dad-11d1-80b4-00c04fd430c8` (DNS)
- Name format: `voyage.poi.{city}.{slug}` or `voyage.poi.source.{city}`

This ensures:
- Reproducible builds
- No collision risk
- Traceability from slug to UUID

---

## Schema Compliance

All fixtures validate against `PoiFixtureValidator` with **zero errors**:

- ✅ Required fields present (`poi_id`, `name`, `normalized_name`, `category`, `destination_key`, `aliases`, `tags`)
- ✅ UUID format valid
- ✅ `normalized_name` matches `normalizeName(name)`
- ✅ Coordinates within valid ranges
- ✅ `editorial_score` 0–100, `touristic_importance` 1–5, `price_level` 1–4 or null
- ✅ Categories in `allowedCategories`
- ✅ Source types in `allowedSourceTypes`
- ✅ Tag categories in `allowedTagCategories`
- ✅ Confidence values 0–100
- ✅ At least 1 canonical alias per POI
- ✅ At least 3 tags per POI
- ✅ No duplicate `normalized_name` within a destination
- ✅ No duplicate aliases within a POI

---

## Destination Mapping

### `DestinationKeyMapper` (`lib/features/planning/data/destination_key_mapper.dart`)

Updated to recognize aliases for the 3 new cities:

| City | Aliases Mapped |
|------|---------------|
| Paris | `paris`, `paris france` |
| Rome | `rome`, `roma`, `rome italy`, `rome italie`, `roma italia` |
| Barcelona | `barcelona`, `barcelone`, `barca`, `barcelona spain`, `barcelona espagne` |

### `PlacesService` Lunao Autocomplete

Added to both `_lunaoDestinations` and `_lunaoCities`:

| Query Prefix | Result | placeId |
|-------------|--------|---------|
| `pari` | Paris, France | `lunao:paris` |
| `rome` | Rome, Italie | `lunao:rome` |
| `roma` | Rome, Italie | `lunao:rome` |
| `barc` | Barcelone, Espagne | `lunao:barcelona` |
| `barca` | Barcelone, Espagne | `lunao:barcelona` |

### `getCountryCodeFromPlaceId`

Added a lookup map for Lunao city placeIds:
```dart
const lunaoCityCountryCodes = <String, String>{
  'lunao:lisbon': 'pt',
  'lunao:paris': 'fr',
  'lunao:rome': 'it',
  'lunao:barcelona': 'es',
};
```

---

## Tests

### Fixture Validation (`test/poi/poi_fixture_multi_city_test.dart`)

15 tests per city × 3 cities = **45 tests**:
- Parses successfully
- Dry-run zero errors
- Expected source/POI counts
- Allowed categories/source types
- Destination key isolation
- Must-see / family-friendly counts
- Normalized name correctness
- Alias normalization
- Tag category validity
- Confidence ranges
- Coordinate ranges
- Score/importance ranges

### Autocomplete Tests (`test/planning/places_service_autocomplete_guard_test.dart`)

12 new tests:
- `autocompleteDestinations` for "pari", "paris", "rome", "roma", "barc", "barcelona"
- `autocompleteCities` for "pari", "rome", "barc"
- `getCountryCodeFromPlaceId` for `lunao:paris`, `lunao:rome`, `lunao:barcelona`

### Destination Key Mapper Tests (`test/planning/poi_candidate_adapter_test.dart`)

Updated to expect Paris/Rome/Barcelona mappings instead of null.

---

## Test Summary

| Suite | Tests | Result |
|-------|-------|--------|
| `poi_fixture_multi_city_test.dart` | 45 | ✅ Pass |
| `places_service_autocomplete_guard_test.dart` | 40 | ✅ Pass |
| `poi_candidate_adapter_test.dart` | 13 | ✅ Pass |
| `city_autocomplete_field_test.dart` | 10 | ✅ Pass |
| `autocomplete_guard_test.dart` | 15 | ✅ Pass |
| **Total** | **123** | **✅ All Pass** |

---

## Files Modified

| # | File | Change |
|---|------|--------|
| 1 | `test/fixtures/poi/pilot_pois_paris.json` | New fixture (25 POIs) |
| 2 | `test/fixtures/poi/pilot_pois_rome.json` | New fixture (25 POIs) |
| 3 | `test/fixtures/poi/pilot_pois_barcelona.json` | New fixture (25 POIs) |
| 4 | `lib/features/planning/services/places_service.dart` | Added Paris/Rome/Barcelona to `_lunaoDestinations`, `_lunaoCities`, and `getCountryCodeFromPlaceId` |
| 5 | `lib/features/planning/data/destination_key_mapper.dart` | Added Paris/Rome/Barcelona aliases |
| 6 | `test/poi/poi_fixture_multi_city_test.dart` | New validation tests |
| 7 | `test/planning/places_service_autocomplete_guard_test.dart` | Added autocomplete + country code tests |
| 8 | `test/planning/poi_candidate_adapter_test.dart` | Updated mapper expectations |
