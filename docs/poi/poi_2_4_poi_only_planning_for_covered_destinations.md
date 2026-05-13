# POI-2.4 — POI-Only Planning for Covered Destinations

## Context

- **Jira:** POI-2.4
- **Depends on:** POI-2.3 (multi-city POI import completed)
- **Scope:** For destinations with curated POI coverage, bypass Google Places API and use Supabase POIs as the primary candidate source.

## Problem Statement

The planning "Suggérer" flow (`gatherCandidatesForTrip`) called Google Places API first, then enriched results with POIs. When Places API was blocked (API-0.6 guards), planning was blocked even for destinations with full POI coverage.

## Solution

Added a **POI-only branch** inside `gatherCandidatesForTrip()` that activates **before** any Google Places calls when:
1. The trip destination maps to a known `destinationKey` (via `DestinationKeyMapper`)
2. A `PoiRepository` is available
3. POI coverage is sufficient (≥5 total AND ≥1 per valid day)

If any condition fails, the function returns `null` and the existing Google Places flow proceeds unchanged.

## Implementation

### Files Changed

| File | Change |
|------|--------|
| `lib/features/planning/services/places_first_pipeline.dart` | Added `_tryGatherPoiOnlyCandidates()` helper + early-return call in `gatherCandidatesForTrip()` |
| `test/features/planning/services/poi_only_planning_test.dart` | 6 offline tests for covered/empty/non-covered scenarios |

### `_tryGatherPoiOnlyCandidates()` Logic

```
1. destinationKey = DestinationKeyMapper.map(trip.destination)
2. If destinationKey == null → log [poi_planning] fallback=google reason=not_covered → return null
3. If poiRepository == null → log [poi_planning] fallback=google reason=no_repository → return null
4. poiCandidates = PoiCandidateAdapter(poiRepository).adaptForDestination(destinationKey)
5. If poiCandidates.length < 5 OR < validDayCenters.length → log fallback=google reason=insufficient_poi → return null
6. Build poolBySig: for each group + interest, assign ALL POI candidates (consistent with POI-2.0 enrichment)
7. Assemble List<DayCandidates> → log [poi_planning] source=poi_only → return pool
```

### Insertion Point

Placed immediately after "Étape 2" (day grouping by center signature) and **before**:
- Blueprint must-see fetch
- Per-group Places Nearby + Text Search
- Metro anchor fanout
- Segment pool guard
- POI-2.0 enrichment (now skipped in POI-only mode)

This means a covered destination with sufficient POIs makes **zero** Google Places API calls.

### Fallback Threshold

| Threshold | Value | Rationale |
|-----------|-------|-----------|
| Minimum total POIs | 5 | Enough variety for selector scoring |
| Minimum per day | 1 × validDayCenters.length | At least one candidate per planned day |

Both conditions must be met. If either fails → fallback to Google Places.

### Logs

| Scenario | Log line |
|----------|----------|
| POI-only success | `[poi_planning] destination="..." destinationKey=... poiCandidates=N source=poi_only days=D` |
| Not covered | `[poi_planning] destination="..." destinationKey=null fallback=google reason=not_covered` |
| No repository | `[poi_planning] destination="..." destinationKey=... fallback=google reason=no_repository` |
| Insufficient POIs | `[poi_planning] destination="..." destinationKey=... fallback=google reason=insufficient_poi poiCandidates=N thresholdTotal=5 thresholdPerDay=D` |

## Covered Destinations

As of POI-2.4, `DestinationKeyMapper` covers:

| Destination Key | Recognized Aliases |
|-----------------|--------------------|
| `lisbon` | `lisbon`, `lisbonne`, `lisboa` |
| `paris` | `paris`, `paris france` |
| `rome` | `rome`, `roma`, `rome italy`, `rome italie`, `roma italia` |
| `barcelona` | `barcelona`, `barcelone`, `barca`, `barcelona spain`, `barcelona espagne` |

## Test Coverage

File: `test/features/planning/services/poi_only_planning_test.dart`

| Test | Description |
|------|-------------|
| covered + enough POIs | Does NOT call `PlacesNearbyService`. POI candidates present in `DayCandidates` for all days/interests. |
| covered + empty POIs | Falls back to `PlacesNearbyService`. |
| covered + insufficient POIs (2 POIs, 3 days) | Falls back to `PlacesNearbyService`. |
| non-covered destination (Tokyo) | Calls `PlacesNearbyService` as before. |
| null `poiRepository` | Falls back to `PlacesNearbyService`. |
| POI placeId correctness | POIs with `googlePlaceId` use it; others use synthetic `poi:<id>`. |

All tests run offline (fake repository, fake geocoding, recording places service).

## Behavior Matrix

| Destination | POI Count | Result | Places Calls |
|-------------|-----------|--------|--------------|
| Paris (25 POIs) | 25 | ✅ POI-only | 0 |
| Rome (25 POIs) | 25 | ✅ POI-only | 0 |
| Barcelona (25 POIs) | 25 | ✅ POI-only | 0 |
| Lisbon (10 POIs) | 10 | ✅ POI-only | 0 |
| Paris (0 POIs) | 0 | Fallback to Places | >0 |
| Paris (2 POIs, 3 days) | 2 | Fallback to Places | >0 |
| Tokyo | 0 | Places only | >0 |

## Non-Goals (Explicitly Out of Scope)

- No changes to `TripActivity`
- No changes to `ActivitySuggestion`
- No changes to `trip_activities` schema
- No changes to Gemini prompts
- No new POI data added
- No refactoring of the full planning engine
- POI-to-interest mapping remains coarse (all POIs in all interests)

## Commit

```
feat(poi): use POI-only planning for covered destinations
```
