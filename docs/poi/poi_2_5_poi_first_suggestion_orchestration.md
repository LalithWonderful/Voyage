# POI-2.5 — POI-First Suggestion Orchestration

## Context

- **Jira:** POI-2.5
- **Depends on:** POI-2.4 (POI-only planning branch), POI-2.3 (multi-city import)
- **Scope:** Ensure "Suggérer des activités" works for covered destinations even when Google Places API and/or Google Geocoding API are blocked.

## Problem Statement

After POI-2.4, the POI-only branch in `gatherCandidatesForTrip` still failed in manual validation because:
1. `centerForDay()` runs **before** the POI-only branch
2. `centerForDay()` calls `geocoder.geocode()` which throws `LiveApiBlockedException` when geocoding is disabled
3. This exception propagates unchecked, aborting the entire pipeline before POIs are ever loaded

Additionally, the generic error message "les services de géolocalisation ou Gemini sont désactivés" was unhelpful for users on covered destinations.

## Solution

### 1. POI-First Reordering

Moved `_tryGatherPoiOnlyCandidates()` to run **BEFORE** any external API call in `gatherCandidatesForTrip`:

**Before (POI-2.4):**
```
gatherCandidatesForTrip()
  → centerForDay() → geocode()  ← THROWS if blocked
  → group days by center
  → _tryGatherPoiOnlyCandidates()  ← never reached
  → fallback to Places
```

**After (POI-2.5):**
```
gatherCandidatesForTrip()
  → _tryGatherPoiOnlyCandidates()
    → load POIs from Supabase
    → if sufficient: build synthetic centers from POI centroid
    → return POI-only DayCandidates
  → if null: centerForDay() → geocode()
  → fallback to Places
```

### 2. Self-Contained POI-Only Gather

Redesigned `_tryGatherPoiOnlyCandidates()` to be **independent** of `centerForDay`:
- No longer depends on `validDayCenters` or `groups`
- Accepts `days` (calendar days) directly
- Builds a synthetic `DayCenter` from the **centroid of all POI coordinates**
- Creates one `DayCandidates` per calendar day, all sharing the same POI centroid center

```dart
// Centre synthétique = centroïde des POIs
var latSum = 0.0, lngSum = 0.0;
for (final c in poiCandidates) {
  latSum += c.latitude;
  lngSum += c.longitude;
}
final center = DayCenter(
  latitude: latSum / poiCandidates.length,
  longitude: lngSum / poiCandidates.length,
  source: 'poi_centroid',
);
```

### 3. No External APIs in POI-First Path

For covered destinations with sufficient POIs:

| API | Called? |
|-----|---------|
| Google Geocoding | ❌ No |
| Google Places Nearby | ❌ No |
| Google Places Text | ❌ No |
| Gemini (Auto) | ❌ No |
| Gemini (CoPilot) | ❌ No (gather step only; CoPilot still calls Gemini AFTER gather) |
| Supabase POI read | ✅ Yes |

### 4. Improved Error Messages

Updated user-facing error messages in `planning_screen.dart` and `trip_detail_screen.dart`:

| Mode | Before | After |
|------|--------|-------|
| CoPilot | "services de géolocalisation ou Gemini sont désactivés" | "le service IA (Gemini) est désactivé. En mode Co-pilote, Gemini est nécessaire." |
| Auto | "services de géolocalisation ou Gemini sont désactivés" | "les services de géolocalisation (Google Maps) sont désactivés. Pour les destinations couvertes (Lisbonne, Paris, Rome, Barcelone), le mode Auto utilise les POIs Lunao sans appel externe." |
| Turnkey | same generic | specific family + mentions covered destinations |

## Files Changed

| File | Change |
|------|--------|
| `lib/features/planning/services/places_first_pipeline.dart` | Moved `_tryGatherPoiOnlyCandidates` before `centerForDay`; redesigned to use `days` instead of `validDayCenters`/`groups`; builds synthetic POI centroid center |
| `lib/features/planning/screens/planning_screen.dart` | Specific error messages for CoPilot and Auto modes based on `LiveApiFamily` |
| `lib/features/trips/screens/trip_detail_screen.dart` | Specific error message for turnkey flow |
| `test/features/planning/services/poi_only_planning_test.dart` | 3 new tests: geocoding-blocked POI-first, geocoding-blocked fallback throws, geocoding never called |

## Test Coverage

| Test | Description |
|------|-------------|
| covered + enough POIs + geocoding blocked | POI-first succeeds, Places not called, center source = `poi_centroid` |
| covered + empty POIs + geocoding blocked | Fallback triggers, `LiveApiBlockedException` thrown from geocoding |
| covered + enough POIs + throwing geocoder | POI-first bypasses geocoding entirely |
| (existing) covered + enough POIs | No Places calls, POI candidates present |
| (existing) covered + empty POIs | Falls back to Places |
| (existing) covered + insufficient POIs | Falls back to Places |
| (existing) non-covered destination | Places behavior unchanged |
| (existing) null repository | Falls back to Places |

## Behavior Matrix

| Destination | POIs | Geocoding | Places | Gemini (Auto) | Result |
|-------------|------|-----------|--------|---------------|--------|
| Paris (25 POIs) | ✅ 25 | blocked | blocked | blocked | ✅ POI-only, 0 external APIs |
| Paris (25 POIs) | ✅ 25 | enabled | blocked | blocked | ✅ POI-only, 0 external APIs |
| Paris (0 POIs) | ❌ 0 | blocked | blocked | — | ❌ Throws (no POIs, geocoding blocked) |
| Paris (0 POIs) | ❌ 0 | enabled | blocked | — | ⚠️ Fallback to Places fails |
| Tokyo | — | blocked | blocked | — | ❌ Throws (non-covered, geocoding blocked) |
| Tokyo | — | enabled | blocked | — | ⚠️ Fallback to Places fails |

## Covered Destinations

Same as POI-2.4:

| Destination Key | Recognized Aliases |
|-----------------|--------------------|
| `lisbon` | `lisbon`, `lisbonne`, `lisboa` |
| `paris` | `paris`, `paris france` |
| `rome` | `rome`, `roma`, `rome italy`, `rome italie`, `roma italia` |
| `barcelona` | `barcelona`, `barcelone`, `barca`, `barcelona spain`, `barcelona espagne` |

## Logs

| Log line | When |
|----------|------|
| `[suggestion_source] destination="..." destinationKey=... source=places_fallback reason=not_covered` | Destination not in `DestinationKeyMapper` |
| `[suggestion_source] destination="..." destinationKey=... source=places_fallback reason=no_repository` | `poiRepository` is null |
| `[suggestion_source] destination="..." destinationKey=... source=places_fallback reason=insufficient_poi` | POIs < 5 or < 1 per day |
| `[suggestion_source] destination="..." destinationKey=... poiCandidates=N source=poi_only days=D google_places_called=false gemini_called=false` | POI-first success |

## Non-Goals (Explicitly Out of Scope)

- No changes to `TripActivity` schema
- No changes to `ActivitySuggestion` schema
- No new POI data
- No changes to Gemini prompts
- No changes to `selectVisitsDeterministic` scoring logic
- CoPilot still requires Gemini (accepted limitation)

## Commit

```
feat(poi): route suggestion flows through POI-first planning
```
