# ALTERNATIVES-0.1 — Make Activity Alternatives POI-First

## Status
**Fixed** in current patch.

## Problem
When the user tapped **"Voir des alternatives"** from an activity detail sheet, the app called Gemini via `AiSuggestionsService.suggestAlternatives`. If Gemini was blocked by `LiveApiGuards`, a fatal red error was displayed in the alternatives sheet, even though Lunao had its own POI database for covered destinations.

## Solution
The alternatives flow is now **POI-first** and **non-blocking** when Gemini is disabled.

### 1. POI-first alternative provider (`PoiAlternativesProvider`)
A new `PoiAlternativesProvider` class computes alternatives without any network call:

- **Maps** `trip.destination` to a `destinationKey` via `DestinationKeyMapper`.
- **Loads** POIs from `PoiRepository.listPoisByDestination(destinationKey)`.
- **Excludes** the current activity (by normalized title).
- **Excludes** activities already present in the planning.
- **Scores** remaining POIs by:
  - Same or compatible category: +50
  - `editorialScore` (0-100)
  - `touristicImportance` (1-5) × 5
- **Returns** top 5 POIs as `ActivitySuggestion` objects.

### 2. Category → tag mapping
POI categories are mapped to user-facing activity tags:

| PoiCategory | Activity tag |
|---|---|
| museum, monument | Culture |
| park, nature | Nature |
| beach | Plage |
| food, market | Gastronomie |
| shopping | Shopping |
| nightlife | Nightlife |
| wellness | Wellness |
| viewpoint, photoSpot | Spots populaires |
| neighborhood | Hors circuit |
| localExperience | Bons plans |
| default | Activité |

### 3. Gemini as optional fallback only
When the provider returns an empty list (destination not covered, no POIs, or all POIs already planned), the UI tries Gemini as an optional enhancement. If Gemini succeeds, the sheet shows AI-generated alternatives. If Gemini is blocked or fails, the app falls back gracefully.

### 4. Non-blocking error handling
If `LiveApiBlockedException` (or any other Gemini error) is thrown:
- The alternatives list remains empty.
- The sheet shows a neutral empty state:
  > "Aucune alternative trouvée."
- No fatal red error is displayed.

### 5. Debug logs
- `[alternatives] source=poi destinationKey=... count=...`
- `[alternatives] source=none reason=destination_not_covered`
- `[alternatives] source=none reason=no_pois`
- `[alternatives] source=gemini_fallback reason=no_poi_alternatives`
- `[alternatives] gemini_blocked reason=...`

## Code Changes

### `lib/features/planning/services/poi_alternatives_provider.dart` (new)
- Pure Dart class, no network calls.
- Reuses `DestinationKeyMapper` and `PoiRepository`.
- Returns `List<ActivitySuggestion>` (empty if destination not covered).

### `lib/features/planning/widgets/alternatives_sheet.dart`
- `_AlternativesSheetState._load()` now:
  1. Calls `PoiAlternativesProvider.suggestAlternatives()` first.
  2. If POI alternatives are returned → displays them directly (no Gemini call).
  3. If empty → tries Gemini in an inner `try-catch`.
  4. On `LiveApiBlockedException` → logs and continues with empty list.
  5. On any other Gemini error → logs and continues with empty list.
- Outer `catch (e)` still handles real errors (trip not found, etc.) as fatal.

## Sequence After Fix

### Covered destination (e.g. Paris)
1. User opens activity detail → taps **"Voir des alternatives"**.
2. `PoiAlternativesProvider` loads Paris POIs.
3. Current activity and already-planned activities are filtered out.
4. Top 5 POI alternatives are scored and returned.
5. Sheet displays POI alternatives with title, address, rating, tag, duration.
6. User taps **"Remplacer par celle-ci"** → `trip_activities` row is updated.

### Non-covered destination (e.g. Tokyo) with Gemini blocked
1. `PoiAlternativesProvider` returns empty (destination not covered).
2. UI tries Gemini → throws `LiveApiBlockedException`.
3. Inner catch logs `[alternatives] gemini_blocked reason=...`.
4. Sheet shows empty state **without** red fatal error.

## Offline Tests

### `test/features/planning/services/poi_alternatives_provider_test.dart` (new)
- returns POI alternatives for covered destination
- excludes current activity by title
- excludes already planned activities
- same-category POIs rank higher
- non-covered destination returns empty list
- destination isolation — Paris query does not return Rome POIs
- maps POI fields to ActivitySuggestion correctly

## Constraints Respected
- No POI data modified.
- No schema modified.
- No live Gemini calls in tests.
- No live Google Places/Routes calls in tests.
- No Supabase writes in tests.
- Existing UI preserved where possible.
