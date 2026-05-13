# ROUTES-0.1 — Routes API Error After Activities Added

## Status
**Fixed.** See `docs/api_cost/routes_0_1_non_blocking_after_suggestions.md` for the full fix documentation.

## Symptom (Historical)
When adding selected suggestions to the planning, the following error appeared:

```
Live API call blocked for Google Routes: RoutesService.computeOptionsFromEndpoints
```

Despite the error, the activities were **successfully added** to the planning.

## Root Cause (Historical)
The `_save()` method in `_SuggestionsSheet` inserted activities into `trip_activities` first, then called `RoutesService.computeOptionsFromEndpoints()` to build transport pairs between consecutive activities. When Google Routes was blocked by `LiveApiGuards`, this call threw `LiveApiBlockedException`, which was caught by the generic `catch (e)` at the end of `_save()` and surfaced as a fatal error SnackBar.

## Fix Applied
Route computation is now wrapped in its own inner `try-catch` inside `_save()`. When `LiveApiBlockedException` is thrown:
- Activities are **NOT** rolled back.
- A **non-blocking warning** SnackBar is shown:
  > "Activités ajoutées. Les trajets n'ont pas pu être calculés pour le moment."
- The outer `catch (e)` still handles real insertion errors as fatal errors.

## Files Changed
- `lib/features/planning/screens/planning_screen.dart`
- `lib/features/planning/services/suggestion_transport_builder.dart` (new)
- `test/features/planning/services/suggestion_transport_builder_test.dart` (new)
- `docs/api_cost/routes_0_1_non_blocking_after_suggestions.md` (new)
