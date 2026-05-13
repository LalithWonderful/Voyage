# ROUTES-0.1 — Make Route Computation Non-Blocking After Suggestions

## Status
**Fixed** in current patch.

## Problem
When POI-based suggestions were added to the planning, activities were inserted successfully, but then Google Routes was called and blocked by `LiveApiGuards`. The resulting `LiveApiBlockedException` was caught by the generic `catch (e)` in `_SuggestionsSheet._save()` and surfaced as a fatal red SnackBar, even though the activities had already been saved.

This was misleading and made users think the operation had failed completely.

## Solution
Route computation is now **optional and non-blocking**:

1. **Activity insertion** remains in the outer `try` block — any failure here still shows a fatal error.
2. **Transport computation** (building `trip_transports` rows via `SuggestionTransportBuilder`) is wrapped in its own inner `try-catch`.
3. If `LiveApiBlockedException` is thrown by `RoutesService.computeOptionsFromEndpoints`:
   - Activities are **NOT** rolled back.
   - A **non-blocking warning** SnackBar is shown:
     > "Activités ajoutées. Les trajets n'ont pas pu être calculés pour le moment."
   - A debug log is emitted:
     > `[routes_optional] activitiesInserted=N routesComputed=false reason=RoutesService.computeOptionsFromEndpoints`
4. Other route computation errors (timeout, network) are caught the same way — warning, not fatal.
5. When Google Routes is available, behavior is unchanged.

## Code Changes

### `lib/features/planning/screens/planning_screen.dart`
- Extracted `SuggestionTransportBuilder` call into an inner `try-catch` inside `_save()`.
- Added specific `on LiveApiBlockedException catch` with warning SnackBar.
- Added generic `catch` for timeout/network errors with same warning.
- Added `[routes_optional]` debug logs.
- Removed `_pickDefaultMode` from `_SuggestionsSheetState` (now lives in `SuggestionTransportBuilder`).

### `lib/features/planning/services/suggestion_transport_builder.dart` (new)
- Public class `SuggestionTransportBuilder` that encapsulates:
  - Pair detection (consecutive same-day activities)
  - Endpoint resolution (coordinates or Places lookup)
  - Parallel route computation via `RoutesService.computeOptionsFromEndpoints`
  - Default mode selection based on traveler type
  - Transport row building

### `test/features/planning/services/suggestion_transport_builder_test.dart` (new)
Offline tests covering:
- Success path returns transport rows for consecutive same-day activities
- `LiveApiBlockedException` is thrown when Google Routes is blocked
- Exception can be caught without rolling back inserted activities
- Different-day pairs are skipped
- Already-existing pairs are skipped
- Activities with coordinates bypass Places lookup
- Traveler type influences default mode selection

## Sequence After Fix

1. User taps "Ajouter X activités au planning" → `_save()` starts.
2. Activities inserted into `trip_activities` → **success**.
3. Hotel returns auto-inserted → **success**.
4. Transport computation starts → `SuggestionTransportBuilder.buildRows()` → **throws `LiveApiBlockedException`**.
5. Inner catch block shows **yellow warning** SnackBar (not red fatal).
6. Providers invalidated, sheet pops, user sees new activities in planning.

## Constraints Respected
- No POI planning logic changed.
- No schema changes.
- No global Routes disable.
- No live Google Routes calls in tests.
- No Supabase writes in tests.
