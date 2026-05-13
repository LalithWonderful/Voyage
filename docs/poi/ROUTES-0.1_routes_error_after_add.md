# ROUTES-0.1 — Routes API Error After Activities Added

## Status
Known follow-up. **Not fixed in this patch.** Documented for future prioritization.

## Symptom
When adding selected suggestions to the planning, the following error appears:

```
Live API call blocked for Google Routes: RoutesService.computeOptionsFromEndpoints
```

Despite the error, the activities are **successfully added** to the planning.

## Root Cause
The `_save()` method in `_SuggestionsSheet` inserts activities into `trip_activities` first, then calls `RoutesService.computeOptionsFromEndpoints()` to build transport pairs between consecutive activities. When Google Routes is blocked by `LiveApiGuards`, this call throws `LiveApiBlockedException`, which is caught by the generic `catch (e)` at the end of `_save()` and surfaces as a fatal error SnackBar.

## Sequence
1. User taps "Ajouter X activités au planning" → `_save()` starts.
2. Activities inserted into `trip_activities` → **success**.
3. Hotel returns auto-inserted → **success**.
4. Transport computation starts → `RoutesService.computeOptionsFromEndpoints()` → **throws `LiveApiBlockedException`**.
5. Generic catch block shows red SnackBar: `Erreur : $e`.

## Expected Future Behavior (backlog)
- Activities are added successfully.
- If route computation fails, show a **non-blocking warning**:
  > "Activités ajoutées. Les trajets n'ont pas pu être calculés pour le moment."
- Do **not** rollback added activities.
- Do **not** show a fatal red SnackBar.

## Suggested Minimal Fix (future PR)
In `_SuggestionsSheet._save()`, catch `LiveApiBlockedException` separately after the activity insert block:

```dart
try {
  // ... transport computation ...
} on LiveApiBlockedException catch (_) {
  if (mounted) {
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text(
          'Activités ajoutées. Les trajets n\'ont pas pu être calculés pour le moment.',
        ),
      ),
    );
  }
}
```

## Constraints
- No changes required in this patch (POI-2.5 scope is wrong-destination bug only).
- No schema changes.
- No new POI data.
