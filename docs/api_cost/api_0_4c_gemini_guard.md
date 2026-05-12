# API-0.4c — Gemini Live API Guard

## Objective

API-0.4c protects Gemini live calls behind `LiveApiGuards`.

Protected services:

- `AiSuggestionsService`
- `AssistantService`

Places legacy, Routes, Places New, and Geocoding are not part of this phase.

## Behavior

Gemini is blocked by default.

Allowed flags:

```bash
--dart-define=ALLOW_LIVE_GEMINI=true
```

The global flag also allows Gemini:

```bash
--dart-define=ALLOW_LIVE_APIS=true
```

Cache behavior:

- valid Gemini cache hits are allowed without `ALLOW_LIVE_GEMINI`;
- cache misses require live Gemini permission;
- methods without cache require live Gemini permission immediately;
- blocked calls throw `LiveApiBlockedException`;
- blocked calls do not instantiate or call a real Gemini model.

## AiSuggestionsService

Guarded live paths:

- `suggestRegionalItinerary()`
- `generateRaw()`
- `suggestAlternatives()`
- `describeActivitiesBatch()`
- `generateTransportBetween()`
- `describeActivity()`
- `extractDocumentFromText()`
- `extractDocumentFromImage()`

Cache hits remain usable for:

- `regional_itinerary`
- `raw`
- `describe_activity`
- `transport_pair`
- custom `generateRaw()` actions such as `places_first_copilot` and
  `places_first_auto`

The guard is placed after cache lookup and before Gemini generation.

## AssistantService

`AssistantService.sendMessage()` has no cache, so it requires live Gemini
permission before generating a response.

`LiveApiBlockedException` is not converted into `AssistantTransientException`.

## Rate Limiting

`_rateLimitEnabled` remains unchanged and disabled.

API-0.4c is only the live-call guard. Re-enabling the Supabase RPC
`check_and_log_ai_usage` should be handled in a separate phase after the RPC is
validated in the target environments.

## Offline Tests

Added:

- `test/features/planning/services/ai_suggestions_service_gemini_guard_test.dart`
- `test/features/assistant/services/assistant_service_gemini_guard_test.dart`

The tests use fake text generators and in-memory cache fixtures. They do not
call Gemini, Supabase, Google, or any live script.

## Limits

API-0.4c does not guard:

- `PlacesService` legacy;
- network images;
- device location;
- currency API;
- Maps SDK loads.
