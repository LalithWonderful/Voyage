# POI-2.6 — Improve POI suggestion scoring and day quality

## Goal

Make the deterministic selector (`selectVisitsDeterministic`) POI-aware so that curated POIs are scored more accurately than generic Google Places candidates. The existing Google Places fallback path must remain untouched.

## Changes

### 1. `NearbyCandidate` extended with POI metadata

**File:** `lib/features/planning/services/places_nearby_service.dart`

Added three fields:
- `isCurated` (`bool`, default `false`) — true for candidates coming from the internal POI database.
- `editorialScore` (`int?`) — raw 0-100 editorial score.
- `typicalDurationMinutes` (`int?`) — typical visit duration in minutes.

These fields are ignored by the Google Places factory (`fromPlacesV1`) and only populated by `PoiCandidateAdapter`.

### 2. `PoiCandidateAdapter` propagates metadata

**File:** `lib/features/planning/services/poi_candidate_adapter.dart`

- `isCurated: true`
- `editorialScore: poi.editorialScore`
- `typicalDurationMinutes: poi.typicalDurationMinutes`

The synthetic rating formula (`4.0 + editorialScore/100`) and synthetic review count (`50 + touristicImportance*50`) are unchanged; they feed the existing `qualityScore` component.

### 3. Scoring formula enhanced in `selectVisitsDeterministic`

**File:** `lib/features/planning/services/places_first_pipeline.dart`

New score components added to the `score(e)` closure:

| Component | Formula | Rationale |
|-----------|---------|-----------|
| `poiQualityBonus` | `editorialScore * 0.4` (max +40) | Direct bonus proportional to editorial quality. A POI with score 90 gets +36, making it competitive against high-Google-rating fillers. |
| `curatedBonus` | `+5` if `isCurated` | Small edge for any curated candidate over an equivalent Google Place. |
| `durationBonus` | `+3` if `typicalDurationMinutes` is between 60 and 180 | Favours standard tourist visit lengths; null or extreme durations get 0. |
| `tagDiversityPenalty` | `sameTagCountInDay * 15.0` (was 10.0) | Strengthened to break same-tag streaks within a day. |

Existing signals are preserved unchanged:
- `qualityScore` = `rating × log(reviews)`
- `blueprintBonus` = +100 (must-see), +70 (experience)
- `interestBonus`, `iconicMuseumBonus`, `iconicTouristBonus`
- `distancePenalty`, `diversityPenalty`, `wellnessConsecutivePenalty`

### 4. Offline tests

**File:** `test/features/planning/services/poi_only_planning_test.dart`

Four new tests under group `POI-2.6 : POI scoring quality`:

1. **high editorial_score POIs rank higher** — Two POIs with scores 90 and 70; the 90-ranked one is picked first.
2. **must-see POIs receive extra scoring bonus** — A must-see POI (score 70) outranks a non-must-see POI (score 90) thanks to the existing `blueprintBonus (+100)`.
3. **suggestions distributed across days without duplicates** — Six POIs over two days; no duplicates, at least two days covered.
4. **category diversity respected** — Three museums (editorial scores 90, 88, 87) and one park (85). Despite the museums having higher scores, the park appears because the strengthened `tagDiversityPenalty` (15×) pushes it ahead of the third museum.

All 18 tests pass (14 POI-2.4 + 4 POI-2.6).

## Verification

```bash
flutter test test/features/planning/services/poi_only_planning_test.dart
# 00:00 +18: All tests passed!
```

No live API calls were made.

## Risks & Notes

- The `tagDiversityPenalty` increase from 10 to 15 may slightly change day layouts for existing fixture-based destinations (Paris, Barcelona, Rome, Lisbon). The change is intentionally small; a tag dominant by quality can still win if its quality lead exceeds `15 × count`.
- `typicalDurationMinutes` is currently null for most fixture POIs, so the `durationBonus` is effectively dormant until fixture data is enriched.
- The preexisting analyze warning `unused local variable 'foreignPois'` (line 2017) and two `unused local variable 'trip'` warnings in the test file are **not** introduced by this task.
