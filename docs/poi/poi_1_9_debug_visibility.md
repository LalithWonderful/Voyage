# POI-1.9 — POI Debug Visibility

## Objective

Add a minimal read-only debug visibility layer to inspect POI data from the app before connecting it to the planning engine.

## Status

✅ Completed.

## Debug Screen

### Location
`lib/features/poi/debug/poi_debug_screen.dart`

### Route
`/debug/poi` (registered in `lib/core/router/app_router.dart`)

### Access
Gated by `kDebugMode` at the call site (`ProfileScreen`). Only available in debug builds.

### Features

1. **Destination search** — default key is `lisbon` (pilot data)
2. **Text search** — matches name, normalized_name, and aliases
3. **Category filter** — dropdown with all 18 POI categories + emoji
4. **Must-see filter** — checkbox to show only must-see POIs
5. **Limit** — max results cap
6. **Top 10 mode** — quick toggle that uses `getTopPoisForDestination` directly
7. **Detailed cards** showing:
   - Name + category emoji
   - Editorial score
   - Touristic importance
   - Typical duration
   - Price level
   - Free / family-friendly / rain-friendly flags
   - Must-see badge
   - Source ID

### POI Data Displayed

Each POI card shows the fields available from the `Poi` domain model:

| Field | Display |
|-------|---------|
| `name` | Card title |
| `category` | Emoji + slug |
| `editorial_score` | Score chip (📊 95/100) |
| `touristic_importance` | Importance chip (⭐ 5/5) |
| `typical_duration_minutes` | Duration chip (⏱️ 180 min) |
| `price_level` | Price chip (💰 4/4) |
| `is_must_see` | MUST-SEE badge |
| `is_free` | 🆓 chip |
| `is_family_friendly` | 👨‍👩‍👧‍👦 chip |
| `is_rain_friendly` | 🌧️ chip |

Tags and aliases are queried during text search but not yet rendered on cards (requires enriched POI model — deferred to POI-2.0).

## Read Path Architecture

```
PoiDebugScreen
  └─► poiSearchProvider / topPoisProvider (Riverpod)
        └─► poiRepositoryProvider
              └─► FakePoiRepository  (default, offline)
              └─► SupabasePoiRepository  (when overridden in app)
                    └─► LivePoiSupabaseClient
                          └─► SupabaseClient (real PostgREST)
```

## Usage

### Offline (default)
```dart
// In a widget test or local dev — no network, no credentials.
final repo = FakePoiRepository(pois: myTestPois);
final container = ProviderContainer(
  overrides: [poiRepositoryProvider.overrideWithValue(repo)],
);
```

### Live debug (requires Supabase credentials)
```bash
# Run the app with the live repository overridden at startup.
# The debug screen will then fetch real POIs from Supabase.
```

### In-app navigation
```dart
if (kDebugMode) {
  context.push('/debug/poi');
}
```

## New Providers (POI-1.9)

- `topPoisProvider` — wraps `PoiRepository.getTopPoisForDestination`

## Test Results

All POI tests pass:
- **281 passing**
- **5 skipped** (live tests)
- **0 failures**

## Files Changed

- `lib/features/poi/debug/poi_debug_screen.dart` — default destination `lisbon`, Top 10 toggle
- `lib/features/poi/providers/poi_providers.dart` — added `topPoisProvider`
- `test/poi/poi_debug_screen_test.dart` — updated for new default + Top 10 mode test
