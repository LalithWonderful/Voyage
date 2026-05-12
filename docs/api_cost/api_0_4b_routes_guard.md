# API-0.4b — RoutesService Live API Guard

## Objective

API-0.4b protects `RoutesService` from accidental Google Routes API v2 calls.

The risk is concrete: `computeOptionsFromEndpoints()` can launch up to four
Routes requests for a single pair of endpoints (`WALK`, `DRIVE`, `TRANSIT`,
`BICYCLE`). The guard must block those live calls unless the run explicitly opts
in.

## Protected Service

- `lib/features/planning/services/routes_service.dart`

No other live service is part of API-0.4b.

## Behavior

`RoutesService` now receives `LiveApiGuards` through its constructor, defaulting
to `LiveApiGuards.fromEnvironment()`.

Cache behavior:

- invalid endpoints still return `null`;
- same origin/destination still returns `null`;
- `gemini_cache` action `routes_pair` cache hit is allowed without a live flag;
- cache miss requires the Google Routes family to be allowed before any
  `http.post`;
- if live Routes is blocked, the service throws `LiveApiBlockedException`;
- the exception is raised outside the per-mode HTTP catch blocks, so it is not
  converted into a silent empty or `null` result;
- when live Routes is allowed but the API key is missing, the existing `null`
  fallback is preserved.

## Required Flags

Preferred explicit opt-in:

```bash
--dart-define=ALLOW_LIVE_GOOGLE_ROUTES=true
```

The global flag also authorizes Routes:

```bash
--dart-define=ALLOW_LIVE_APIS=true
```

The global flag is supported by `LiveApiGuards`, but cost-sensitive live runs
should prefer the family-specific flag.

## Offline Tests

Added:

- `test/features/planning/services/routes_service_guard_test.dart`

The tests use:

- an in-memory fake `GeminiCacheService`;
- a fake `http.Client`;
- no Google Routes request;
- no Supabase network call.

Covered cases:

- cache miss with live Routes blocked throws `LiveApiBlockedException`;
- cache miss with `allowGoogleRoutes=true` reaches the fake HTTP client;
- cache hit returns cached transport options without any live flag;
- `ALLOW_LIVE_APIS=true` also authorizes Routes.

## Limits

API-0.4b does not guard:

- `AiSuggestionsService` / Gemini;
- `PlacesService` legacy;
- `PlacesNearbyService` beyond the already validated API-0.4a work;
- `GeocodingService` beyond the already validated API-0.4a work;
- network images, currency API, device location, or Maps SDK loads.

The dangerous scripts remain protected by API-0.3 and were not executed during
this phase.
