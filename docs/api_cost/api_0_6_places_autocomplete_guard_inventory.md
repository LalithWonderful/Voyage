# API-0.6 — Places Autocomplete Guard Inventory

## Date
2026-05-12

## Executive Summary

Google Places Autocomplete is called from **2 UI widgets** while typing, with a **350ms debounce** but **zero caching**. The most expensive call (`autocompleteCities`) fires **3 parallel Google Places requests** per debounced keystroke. There is no Lunao-first lookup, no min-length guard beyond 2 characters, and no cache layer. This inventory documents every call site before any code changes.

---

## 1. Live Autocomplete Call Sites (while typing)

### 1.1 `CityAutocompleteField` — Destination / City / Step

| Attribute | Value |
|-----------|-------|
| **File** | `lib/core/widgets/city_autocomplete_field.dart` |
| **Trigger** | `TextField.onChanged` → `Timer(350ms)` → `_runSearch(value)` |
| **Min length** | 2 characters (widget + service both enforce) |
| **Debounce** | 350ms (widget-level) |
| **Cache** | ❌ None |
| **Google Places** | ✅ Yes |

**Service methods called:**
- `PlacesService.autocompleteDestinations(query)` — 1× Google Places Autocomplete (`types=geocode`)
- `PlacesService.autocompleteCities(query, countryCode: ...)` — **3× parallel** Google Places Autocomplete (`(cities)`, `geocode`, `establishment`)

**Usage locations:**

| # | File | Line | Use case | Mode |
|---|------|------|----------|------|
| 1 | `lib/features/onboarding/screens/destination_screen.dart` | ~675 | Trip destination (onboarding) | `acceptAnyDestination: true` → `autocompleteDestinations` |
| 2 | `lib/features/trips/widgets/trip_edit_sheet.dart` | ~1590 | Trip destination (edit) | `acceptAnyDestination: true` → `autocompleteDestinations` |
| 3 | `lib/features/trips/widgets/trip_edit_sheet.dart` | ~3883 | Step/segment city (edit) | `acceptAnyDestination: false` → `autocompleteCities` |

**Cost per keystroke burst:**
- Destination mode: 1 request
- City/step mode: 3 parallel requests

---

### 1.2 `TransportAutocompleteField` — Airport / Train Station

| Attribute | Value |
|-----------|-------|
| **File** | `lib/core/widgets/transport_autocomplete_field.dart` |
| **Trigger** | `TextField.onChanged` → `Timer(350ms)` → `_runSearch(value)` |
| **Min length** | 2 characters (widget + service both enforce) |
| **Debounce** | 350ms (widget-level) |
| **Cache** | ❌ None |
| **Google Places** | ✅ Yes |

**Service method called:**
- `PlacesService.autocompleteTransport(query, type: 'airport'|'train_station', sessionToken: ...)` — 1× Google Places Autocomplete

**Usage locations:**

| # | File | Line | Use case |
|---|------|------|----------|
| 1 | `lib/features/wallet/widgets/document_form_sheet.dart` | ~1755 | Flight/train `from`/`to` fields |

---

## 2. Background Call Sites (not while typing, but live Google Places)

These are called on mount, button tap, or background processing — not triggered by user keystrokes, but still consume API quota.

| # | File | Function | Line | Use case | Trigger | Cache | Google |
|---|------|----------|------|----------|---------|-------|--------|
| 1 | `trip_edit_sheet.dart` | `_detectInitialKind` | ~164 | Determine if existing destination is city/country/region | On mount | ❌ | ✅ `autocompleteDestinations` |
| 2 | `trip_detail_screen.dart` | `_detectDestinationKind` | ~243 | Determine kind of trip destination | On mount | ❌ | ✅ `autocompleteDestinations` |
| 3 | `planning_screen.dart` | `_openSuggestionMenu` guard | ~147 | Check destination is valid before suggesting | On button tap | ❌ | ✅ `autocompleteDestinations` |
| 4 | `document_form_sheet.dart` | `_autoResolveTransportPlaceIds` | ~443 | Resolve Gemini-extracted transport names to place IDs | Background (after Gemini) | ❌ | ✅ `autocompleteTransport` |
| 5 | `planning_screen.dart` | `_resolveHotelAddress` | ~? | Resolve hotel address to coords | On hotel document add | ❌ | ✅ `GeocodingService.geocode` |

---

## 3. Service Methods Summary

| Method | File | Lines | Google Calls | Min Length | Cache | Lunao First |
|--------|------|-------|-------------|------------|-------|-------------|
| `autocompleteCities` | `places_service.dart` | 334-358 | **3× parallel** Autocomplete | 2 | ❌ | ❌ |
| `autocompleteDestinations` | `places_service.dart` | 497-579 | 1× Autocomplete | 2 | ❌ | ❌ |
| `autocompleteTransport` | `places_service.dart` | 597-655 | 1× Autocomplete | 2 | ❌ | ❌ |
| `resolvePlaceCoords` | `places_service.dart` | 671+ | 1× Place Details | N/A | ❌ | ❌ |
| `geocode` | `geocoding_service.dart` | varies | 1× Geocoding API | N/A | ❌ | ❌ |

---

## 4. Safe / Local-Only Autocomplete

These do **NOT** call Google Places and are already optimal.

| Widget | File | Source | Network |
|--------|------|--------|---------|
| `AirportPickerDialog` | `lib/features/trips/widgets/airport_picker_dialog.dart` | Hardcoded ~366 airports (Dart list) | ❌ None |
| POI Debug `_FilterTextField` | `lib/features/poi/debug/poi_debug_screen.dart` | Explicit submit only (no onChanged) | ❌ None |
| All other `TextField`/`TextFormField` | Various | Local state only | ❌ None |

---

## 5. Problem Statement

### 5.1 Cost Risk
- `autocompleteCities` (step city): **3 requests per keystroke burst** × $2.83/1000 = **~$8.49/1000 bursts**
- `autocompleteDestinations` (trip destination): **1 request per keystroke burst** × $2.83/1000 = **~$2.83/1000 bursts**
- `autocompleteTransport` (airport/train): **1 request per keystroke burst** × $2.83/1000 = **~$2.83/1000 bursts**
- No cache means **repeated queries cost every time**.

### 5.2 Missing Guards
- No min length > 2 (typing "li" already triggers Google)
- No Lunao/internal lookup first
- No cache layer
- Country fields call Google instead of using local list
- Region fields call Google instead of using existing `country_regions` data

---

## 6. Recommended Guard Strategy

### 6.1 Central Policy (`AutocompletePolicy`)
Implement a single policy class that every autocomplete call must go through:

```
Policy rules:
1. MIN_LENGTH = 4 (do not call Google below 4 chars)
2. DEBOUNCE_MS = 350 (already present in UI, also enforce in service)
3. LUNAO_FIRST = true (check Lunao/local sources before Google)
4. CACHE_FIRST = true (check in-memory cache before Google)
5. FALLBACK_GOOGLE = controlled (only if no strong internal result)
```

### 6.2 Per-Field Guard Matrix

| Field | Lunao Source | Min Length | Debounce | Cache | Google Fallback |
|-------|-------------|------------|----------|-------|-----------------|
| **Trip destination** | `DestinationKeyMapper` + POI DB | 4 | 350ms | ✅ | Yes (after internal) |
| **Step/segment city** | POI DB + destination cache | 4 | 350ms | ✅ | Yes (after internal) |
| **Country** | Local country list | 1 | 0ms | ✅ | **No** |
| **Region** | `country_regions` data | 2 | 0ms | ✅ | **No** |
| **Address (hotel)** | None | 4 | 350ms | ✅ | Yes |
| **Airport** | `AirportPickerDialog` (local) | 1 | 0ms | ✅ | **No** |
| **Train station** | None | 4 | 350ms | ✅ | Yes |

### 6.3 Lunao-First Destination Source (MVP)
For covered destinations, return Lunao results immediately without Google:

```dart
static const _lunaoDestinations = {
  'lisbon': ('Lisbonne, Portugal', 'lisbon'),
  'lisbonne': ('Lisbonne, Portugal', 'lisbon'),
  'lisboa': ('Lisbonne, Portugal', 'lisbon'),
  'lisbon portugal': ('Lisbonne, Portugal', 'lisbon'),
  'lisbonne portugal': ('Lisbonne, Portugal', 'lisbon'),
  'lisboa portugal': ('Lisbonne, Portugal', 'lisbon'),
};
```

---

## 7. Files to Modify (tentative, pending approval)

| # | File | Action |
|---|------|--------|
| 1 | `lib/features/planning/services/places_service.dart` | Add `AutocompletePolicy` guard; add Lunao-first lookup; add cache layer |
| 2 | `lib/core/widgets/city_autocomplete_field.dart` | Increase min length to 4 before calling service; pass through policy |
| 3 | `lib/core/widgets/transport_autocomplete_field.dart` | Increase min length to 4 before calling service; pass through policy |
| 4 | `lib/features/trips/widgets/trip_edit_sheet.dart` | Use local country list for country fields; use `country_regions` for region fields |
| 5 | `lib/features/onboarding/screens/destination_screen.dart` | Use policy-guarded autocomplete |
| 6 | `lib/features/wallet/widgets/document_form_sheet.dart` | Use policy-guarded transport autocomplete |
| 7 | `test/planning/places_autocomplete_guard_test.dart` | Offline tests for policy, Lunao-first, cache, no-Google-guards |
| 8 | `docs/api_cost/api_0_6_places_autocomplete_guard_inventory.md` | This document |

---

## 8. Before/After Summary (target state)

| Scenario | Before (API-0.5) | After (API-0.6 target) |
|----------|-----------------|------------------------|
| Type "li" in destination | 1 Google call | 0 calls (min length 4) |
| Type "lisbo" in destination | 1 Google call | 0 calls (Lunao match) |
| Type "lisbon" in destination | 1 Google call | 0 calls (Lunao match) |
| Type "tok" in destination | 1 Google call | 0 calls (min length 4) |
| Type "tokyo" in destination | 1 Google call | 1 Google call (unknown) |
| Type "fra" in country field | 1 Google call | 0 calls (local list) |
| Type "pari" in step city | 3 Google calls | 0-3 calls (cache first, then Google) |
| Type "cdg" in airport | 1 Google call | 0 calls (local airport picker) |
| Re-type same query | 1-3 Google calls | 0 calls (cache hit) |
