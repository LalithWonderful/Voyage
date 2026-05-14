# TRANSPORT-0.1 — Make "Ajouter un trajet" Deterministic-First

## Status
**Fixed** in current patch.

## Problem
When the user tapped "+ Ajouter un trajet" between two activities, the app called Gemini via `AiSuggestionsService.generateTransportBetween`. If Gemini was blocked by `LiveApiGuards`, a fatal red SnackBar was shown:

```
Live API call blocked for Gemini: AiSuggestionsService.generateTransportBetween
```

This was unnecessary because most activity-to-activity transports can be estimated deterministically from coordinates.

## Solution
The "+ Ajouter un trajet" flow is now **deterministic-first** and **non-blocking** when Gemini is disabled.

### 1. Deterministic resolution (`TransportBetweenResolver`)
A new `TransportBetweenResolver` class computes transport options without any network call:

- **If both activities have coordinates:**
  - Compute distance with `haversineKm`.
  - `<= 1 km` → `walk` option only.
  - `> 1 km` → `transit` + `taxi` options.
  - Default mode is chosen based on traveler type.
- **If coordinates are missing:**
  - Return a manual fallback with a single `manual` option:
    - Label: "Trajet à compléter"
    - Emoji: 📝

### 2. Gemini as optional fallback only
When the resolver returns the manual fallback (no coordinates), the UI tries Gemini as an optional enhancement. If Gemini succeeds, the bottom sheet shows the AI-generated options. If Gemini fails or is blocked, the app falls back gracefully.

### 3. Non-blocking error handling
If `LiveApiBlockedException` (or any other Gemini error) is thrown:
- A manual transport row is inserted directly into `trip_transports`.
- A **non-blocking** SnackBar is shown:
  > "Trajet ajouté. Les détails pourront être complétés plus tard."
- No fatal red error is displayed.
- Activities remain untouched.

### 4. Debug logs
- `[transport_between] source=deterministic distanceKm=...`
- `[transport_between] source=manual_fallback reason=no_coordinates`
- `[transport_between] source=gemini`
- `[transport_between] gemini_skipped_or_blocked reason=...`

## Code Changes

### `lib/features/planning/services/transport_between_resolver.dart` (new)
- Pure Dart class, no network calls.
- Uses `haversineKm` from `location_service.dart`.
- Returns `TransportSuggestion` with `defaultMode` and `options`.

### `lib/features/planning/screens/planning_screen.dart`
- `_AddTransportButtonState._generate()` now:
  1. Calls `TransportBetweenResolver.resolve()` first.
  2. If deterministic → shows `_PickNewTransportSheet` (unchanged UX).
  3. If manual fallback → tries Gemini in an inner `try-catch`.
  4. On Gemini failure → calls `_insertManualFallback()` directly + shows warning SnackBar.
- Added `_insertManualFallback()` helper.

### `lib/features/planning/models/trip_transport_model.dart`
- Added `'manual': '📝'` to `transportModeEmojis`.
- Added `'manual': 'Trajet à compléter'` to `transportModeLabels`.

### `test/features/planning/services/transport_between_resolver_test.dart` (new)
Offline tests covering:
- Close coordinates (`<= 1 km`) → walk default, walk option.
- Medium coordinates (`1–4 km`) → transit default, transit + taxi options.
- Far coordinates (`> 4 km`) → transit default, transit + taxi options.
- Missing coordinates → manual fallback row.
- Grand luxe traveler → taxi default.
- Backpack traveler → transit default.
- Voyage pro traveler → taxi default.
- En famille traveler → transit default.

## Sequence After Fix

1. User taps "+ Ajouter un trajet" → `_generate()` starts.
2. `TransportBetweenResolver.resolve()` → **deterministic suggestion** (coords available).
3. Bottom sheet opens with walk/transit/taxi options.
4. User picks and saves → row inserted into `trip_transports`.

### Fallback sequence (no coordinates + Gemini blocked)
1. Resolver returns manual fallback.
2. UI tries Gemini → throws `LiveApiBlockedException`.
3. Inner catch inserts manual row directly.
4. SnackBar: "Trajet ajouté. Les détails pourront être complétés plus tard."
5. Transport appears as 📝 "Trajet à compléter" in the timeline.

## Constraints Respected
- No live Gemini calls in tests.
- No live Google Routes calls in tests.
- No Supabase writes in tests.
- No POI planning logic changed.
- No TripActivity schema changed.
- Existing UX preserved when AI services are available.
