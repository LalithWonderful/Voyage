# API-0.6b — Places Autocomplete Fallback Reduction

## Date
2026-05-13

## Executive Summary

API-0.6a eliminated freezes and added Lunao-first prefix matching for Lisbon.
API-0.6b reduces the **remaining Google Places autocomplete fallbacks** by:
1. Adding a **local country list** (~45 countries, ~75 aliases) so country searches never hit Google.
2. Making the **`establishment` call conditional** in `autocompleteCities`, reducing 3 parallel calls to 2 for most queries.
3. Resolving **synthetic Lunao placeIds locally** in `getCountryCodeFromPlaceId`, preventing wasted Google Details calls.

---

## 1. Changes Made

### 1.1 Country-first autocomplete (`autocompleteDestinations`)

**File:** `lib/features/planning/services/places_service.dart`

**Before:**
- Typing "france" → Google Places `types=geocode` → 1 call
- Typing "maroc" → Google Places → 1 call
- Typing "japon" → Google Places → 1 call

**After:**
- Typing "fran" → `_matchLunaoCountry('fran')` finds `'france'` prefix → **0 Google calls**
- Typing "france" → exact match → **0 Google calls**
- Typing "usa" → exact match (3 chars, but exact bypasses length guard) → **0 Google calls**
- Typing "etats" → prefix match → **0 Google calls**

**Coverage:** 45 popular travel destinations with French names and common aliases (accented + unaccented, e.g., `grèce`/`grece`, `états-unis`/`etats-unis`/`etats unis`/`usa`).

**Synthetic placeId format:** `lunao:country:XX` (ISO 2-letter code)
- Example: France → `lunao:country:fr`
- Example: Japan → `lunao:country:jp`
- Example: USA → `lunao:country:us`

**Kind returned:** `country` (same as Google Places mapping)

---

### 1.2 Conditional `establishment` call in `autocompleteCities`

**File:** `lib/features/planning/services/places_service.dart`

**Before:**
- Every city query fired **3 parallel calls**: `(cities)` + `geocode` + `establishment`
- Cost: ~$8.49/1000 queries

**After:**
- Phase 1: `(cities)` + `geocode` in parallel (covers ~95% of destinations)
- Phase 2: `establishment` **only if Phase 1 returns < 3 results**
- Cost for common cities: ~$5.66/1000 queries (33% savings)
- Cost for obscure islands/parks: still ~$8.49/1000 (preserves Ko Samet, Mont Saint-Michel)

**Rationale:** The `establishment` type was added in API-0.5 to fix missing islands (Ko Samet, Mont Saint-Michel) that Google classifies as `establishment` rather than `geocode`. Most mainstream cities are found by `(cities)` + `geocode` alone.

---

### 1.3 Local resolution of synthetic placeIds

**File:** `lib/features/planning/services/places_service.dart`

**Before:**
- Selecting a Lunao result (e.g., Lisbon) → `getCountryCodeFromPlaceId('lunao:lisbon')` → Google Places Details API call → fails (invalid placeId) → returns null

**After:**
- `lunao:lisbon` → resolved locally to `'pt'`
- `lunao:country:fr` → resolved locally to `'fr'`
- `lunao:country:us` → resolved locally to `'us'`
- No Google call for synthetic placeIds

---

## 2. Test Coverage

| Test | File | What it verifies |
|------|------|-----------------|
| `"fran"` → France | `test/planning/places_service_autocomplete_guard_test.dart` | Country prefix match |
| `"france"` → France | `test/planning/places_service_autocomplete_guard_test.dart` | Country exact match |
| `"usa"` → USA | `test/planning/places_service_autocomplete_guard_test.dart` | Short exact match (3 chars) |
| `"etats"` → USA | `test/planning/places_service_autocomplete_guard_test.dart` | Multi-word prefix match |
| `"japon"` → Japan | `test/planning/places_service_autocomplete_guard_test.dart` | Country prefix match |
| `"fr"` → empty | `test/planning/places_service_autocomplete_guard_test.dart` | Short prefix blocked (< 4) |
| `getCountryCodeFromPlaceId('lunao:lisbon')` → `'pt'` | `test/planning/places_service_autocomplete_guard_test.dart` | Local resolution |
| `getCountryCodeFromPlaceId('lunao:country:fr')` → `'fr'` | `test/planning/places_service_autocomplete_guard_test.dart` | Local resolution |
| Widget: `"fran"` → France | `test/core/widgets/city_autocomplete_field_test.dart` | Full UI path |

**All 43 tests pass. Zero live Google Places calls in tests.**

---

## 3. What Was Preserved

| Feature | Status |
|---------|--------|
| Lunao Lisbon prefix matching (`"lisb"`, `"lisbo"`) | ✅ Preserved |
| Min-length 4 guard | ✅ Preserved |
| AutocompleteGuard cache (5-min TTL) | ✅ Preserved |
| Transport autocomplete (no Lunao) | ✅ Preserved |
| Google Places fallback for unknown queries | ✅ Preserved |
| POI planning logic | ✅ Not touched |
| Wallet / hotel geocoding | ✅ Not touched |

---

## 4. Remaining Work (Future Substesteps)

### 4.1 Region interception
- **Source:** `assets/data/country_regions.json` (80 regions across 15 large countries)
- **Goal:** Match queries like `"bali"`, `"californie"`, `"patagonie"` locally before Google fallback
- **Complexity:** Medium — needs alias extraction from JSON or hardcoding of popular region names

### 4.2 City expansion
- **Current:** Only Lisbon is in `_lunaoCities` / `_lunaoDestinations`
- **Goal:** Add top 20-50 most-searched cities (Paris, Tokyo, Bangkok, New York, etc.)
- **Complexity:** Low — same pattern as countries, but needs coordinate data if synthetic placeIds are used

### 4.3 Region fields in trip creation
- **Current:** `DestinationScreen` and `TripEditSheet` call Google for kind detection on mount
- **Goal:** Use local data first, then Google only if needed
- **Complexity:** Medium — touches background mount calls, which are out of scope for API-0.6b

---

## 5. Cost Impact Summary

| Scenario | Before (API-0.6a) | After (API-0.6b) |
|----------|-------------------|------------------|
| Type "france" in destination | 1 Google call | 0 calls (local country) |
| Type "japon" in destination | 1 Google call | 0 calls (local country) |
| Type "paris" in step city | 3 Google calls | 2 calls (conditional establishment) |
| Type "ko samet" in step city | 3 Google calls | 3 calls (preserved) |
| Select Lunao result → save | 1 Details call (wasted) | 0 calls (local resolution) |
| Re-type same query | 1-3 calls | 0 calls (guard cache) |
