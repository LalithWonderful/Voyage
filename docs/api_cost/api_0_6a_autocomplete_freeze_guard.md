# API-0.6a — Places Autocomplete Freeze Guard

## Date
2026-05-12

## Scope
**Typing-only guard.** This patch protects live Google Places autocomplete calls triggered by user keystrokes. It does NOT touch background calls on mount, hotel geocoding, country/region local source migration, or POI planning logic.

## Problem
Two widgets call Google Places while typing with only a **2-character minimum** and **zero caching**:
- `CityAutocompleteField` — trip destination, step city
- `TransportAutocompleteField` — airport / train station

The most expensive path (`autocompleteCities`) fires **3 parallel Google Places requests** per debounced keystroke.

## Solution

### 1. Central `AutocompleteGuard`

**File:** `lib/features/planning/services/autocomplete_guard.dart`

A generic guard that every autocomplete call must go through:

| Layer | Rule | Behavior |
|-------|------|----------|
| Min length | ≥ 4 chars | Skip + log `google_skipped reason=too_short` |
| Cache | In-memory, 5-min TTL | Return cached + log `source=cache` |
| Fallback | Google Places with 5s timeout | Cache result + log `source=google_fallback` |
| Error/timeout | Safe empty return | Log `reason=error` / `reason=timeout` |

### 2. Lunao-First Destination Source

**File:** `lib/features/planning/services/places_service.dart`

For `autocompleteDestinations` and `autocompleteCities`, a static Lunao source is checked **before** the guard:

```dart
static const _lunaoDestinations = {
  'lisbon': ('Lisbonne, Portugal', 'Lisbonne', 'lunao:lisbon', 'city'),
  'lisbonne': ('Lisbonne, Portugal', 'Lisbonne', 'lunao:lisbon', 'city'),
  'lisboa': ('Lisbonne, Portugal', 'Lisbonne', 'lunao:lisbon', 'city'),
  'lisbon portugal': ('Lisbonne, Portugal', 'Lisbonne', 'lunao:lisbon', 'city'),
  'lisbonne portugal': ('Lisbonne, Portugal', 'Lisbonne', 'lunao:lisbon', 'city'),
  'lisboa portugal': ('Lisbonne, Portugal', 'Lisbonne', 'lunao:lisbon', 'city'),
};
```

For `autocompleteTransport`, **no Lunao lookup** is performed (airports ≠ destinations).

### 3. Widget Min-Length Raise

| Widget | Before | After |
|--------|--------|-------|
| `CityAutocompleteField` | 2 | 4 |
| `TransportAutocompleteField` | 2 | 4 |

The widget-level guard acts as a first-line defense before the service-level guard.

## Files Modified

| # | File | Action |
|---|------|--------|
| 1 | `lib/features/planning/services/autocomplete_guard.dart` | **Create** — central guard |
| 2 | `lib/features/planning/services/places_service.dart` | **Modify** — Lunao source + guard integration |
| 3 | `lib/core/widgets/city_autocomplete_field.dart` | **Modify** — min length 2 → 4 |
| 4 | `lib/core/widgets/transport_autocomplete_field.dart` | **Modify** — min length 2 → 4 |
| 5 | `test/planning/autocomplete_guard_test.dart` | **Create** — 12 offline tests |
| 6 | `test/planning/places_service_autocomplete_guard_test.dart` | **Create** — 10 integration tests |
| 7 | `docs/api_cost/api_0_6a_autocomplete_freeze_guard.md` | **Create** — this doc |

## Before/After Behavior

| Scenario | Before | After |
|----------|--------|-------|
| Type `"l"` in destination | 1 Google call | 0 calls (min length 4) |
| Type `"li"` in destination | 1 Google call | 0 calls (min length 4) |
| Type `"lis"` in destination | 1 Google call | 0 calls (min length 4) |
| Type `"lisbo"` in destination | 1 Google call | 0 calls (Lunao match) |
| Type `"lisbon"` in destination | 1 Google call | 0 calls (Lunao match) |
| Type `"tok"` in destination | 1 Google call | 0 calls (min length 4) |
| Type `"tokyo"` in destination | 1 Google call | 1 Google call (unknown) |
| Re-type `"tokyo"` | 1 Google call | 0 calls (cache hit) |
| Type `"cdg"` in transport | 1 Google call | 0 calls (min length 4) |
| Type `"lisbon"` in transport | 1 Google call | 1 Google call (no Lunao) |

## Debug Logs

```
[autocomplete] source=lunao query="lisbon" context=destination results=1
[autocomplete] google_skipped reason=too_short query="li" length=2 context=destination
[autocomplete] source=cache query="tokyo" context=destination results=5
[autocomplete] source=google_fallback query="tokyo" context=destination results=5
[autocomplete] source=google_fallback reason=timeout query="slow" context=destination
```

## Tests

```bash
flutter test test/planning/autocomplete_guard_test.dart
flutter test test/planning/places_service_autocomplete_guard_test.dart
```

**Results:** 22 tests, 0 failures, 0 live API calls.

## Explicitly Out of Scope

- Background mount calls (`_detectInitialKind`, `_detectDestinationKind`)
- Hotel geocoding (`GeocodingService.geocode`)
- Country/region local source migration
- Onboarding/trip-edit/wallet sheet logic beyond min-length change
- POI planning logic
- Live Supabase writes
