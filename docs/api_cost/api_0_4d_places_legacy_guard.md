# API-0.4d — Legacy Places Live API Guard

## Objective

API-0.4d protects `PlacesService` legacy from accidental Google Places API
calls.

Protected methods:

- `findInfo()`
- `autocompleteCities()`
- `autocompleteDestinations()`
- `autocompleteTransport()`
- `resolvePlaceCoords()`
- `getCountryCodeFromPlaceId()`
- `findCityCoords()`
- `getDetails()`

## Behavior

`PlacesService` now receives `LiveApiGuards`, defaulting to
`LiveApiGuards.fromEnvironment()`.

Live Google Places legacy calls are blocked by default. The required opt-in is:

```bash
--dart-define=ALLOW_LIVE_GOOGLE_PLACES=true
```

The global flag also allows legacy Places:

```bash
--dart-define=ALLOW_LIVE_APIS=true
```

When an input is invalid or the Google key is absent, existing fallback behavior
is preserved. When an input is valid and a live Google Places request would be
made, `PlacesService` throws `LiveApiBlockedException` before any `http.get`.

## Cache Behavior

API-0.4d guards `PlacesService`, not the Supabase cache services directly.

That preserves the intended flow:

- `PlacesCacheService` / `PlaceLookupCacheService` cache hits return before
  reaching `PlacesService`;
- cache misses or stale/incomplete cache entries fall through to `PlacesService`;
- if live Places is not allowed, `PlacesService` blocks the miss explicitly.

## Place Photos

`findInfo()` still only builds Place Photo URLs after a guarded Find Place
response. Existing cached photo URLs may still be loaded by UI image widgets.
Runtime image loading is a separate `ALLOW_LIVE_NETWORK_IMAGES` concern and is
not changed in API-0.4d.

## Tests

Added:

- `test/features/planning/services/places_service_guard_test.dart`

The tests use a fake `http.Client` and an injected fake API key. They do not
call Google or Supabase.

Covered cases:

- blocked methods throw `LiveApiBlockedException` before HTTP;
- `ALLOW_LIVE_GOOGLE_PLACES=true` reaches fake HTTP;
- `ALLOW_LIVE_APIS=true` also authorizes;
- invalid inputs keep existing fallbacks without requiring a flag.

## Limits

API-0.4d does not change:

- Places New / `PlacesNearbyService`;
- Geocoding;
- Routes;
- Gemini;
- Supabase cache policy;
- network image loading;
- POI files or Phase 4.8 files.
