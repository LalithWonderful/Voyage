# Remaining Live API Audit - 2026-05-13

Scope: offline audit for remaining live API surfaces in Lunao. This pass used
`rg`, targeted source reads, and offline guard tests only. No Google, Gemini,
Supabase, Overpass, Frankfurter, Maps SDK, or network-image live calls were
intentionally executed by this audit.

## Summary

The core paid Google/Gemini services are guarded before their live calls:

- Google Places New: `PlacesNearbyService.searchNearby/searchText`.
- Google Places legacy: `PlacesService` Find Place, Autocomplete, Details.
- Google Geocoding: `GeocodingService.geocode`.
- Google Routes: `RoutesService.computeOptionsFromEndpoints`.
- Gemini: `AiSuggestionsService` and `AssistantService`.

Remaining unguarded or partially guarded surfaces are mostly outside that core:
Overpass CLI/extractor, currency HTTP, Supabase read/verification scripts,
general app Supabase reads/writes, network images, Maps SDK/Google Maps URLs,
and a dormant Supabase RPC rate-limit path.

## Findings

| Risk | API family | File / lines | Trigger path | Guarded? | Recommended minimal fix |
| --- | --- | --- | --- | --- | --- |
| critical | Overpass / external HTTP | `lib/features/poi/tools/osm_overpass_extractor.dart:206`, `:215` | Any caller of `OsmOverpassExtractor.fetchOverpass()` performs `http.Client.post()` to `https://overpass-api.de/api/interpreter`. | No central guard. Comment says opt-in, but the method itself does not enforce it. | Add an Overpass/external HTTP family to `LiveApiGuards` or a dedicated script guard, and assert before `post()`. |
| critical | Overpass / script | `tool/poi/extract_osm_pois.dart:53` | CLI `dart tool/poi/extract_osm_pois.dart ...` calls `fetchOverpass()` directly. | No guard. Required args are destination/country only. | Require explicit opt-in, e.g. `ALLOW_LIVE_OVERPASS=true`, before constructing/calling the extractor. |
| medium | Overpass / test | `test/poi/osm_poi_mapping_test.dart:530`, `:535`, `:551` | Live test calls `fetchOverpass(BoundingBox.singapore)`. | Partially guarded by `RUN_LIVE_OVERPASS`, skipped by default. Not integrated with `LiveApiGuards`. | Rename/bridge to the same Overpass live guard used by CLI; keep skip-by-default. |
| medium | Currency API / external HTTP | `lib/core/services/currency_service.dart:22`, `:23` | UI/provider budget conversion paths call `CurrencyService.getRate()`: `lib/core/providers/currency_provider.dart:25`, `lib/features/planning/providers/planning_provider.dart:150`. | No, despite `LiveApiFamily.currencyApi` existing. | Inject/read `LiveApiGuards` and return `null` or throw `LiveApiBlockedException` before `http.get()` when `currencyApi` is blocked. |
| medium | Supabase RPC | `lib/features/planning/services/ai_suggestions_service.dart:445`, `:450` | `_checkRateLimit()` would call RPC `check_and_log_ai_usage` before Gemini actions if `_rateLimitEnabled` becomes true. | Dormant because `_rateLimitEnabled = false` at `:202`; no Supabase guard if re-enabled. | Add `_guards.assertAllowed(LiveApiFamily.supabase, operation: 'AiSuggestionsService._checkRateLimit')` before `_client.rpc()`. |
| critical | Supabase read / script | `tool/poi/verify_schema.dart:17`, `:34` | CLI verifies POI tables against live Supabase. Falls back to checked-in `SupabaseConstants` anon key. | No `ALLOW_LIVE_SUPABASE` guard. | Require `LiveApiGuards.fromEnvironment().assertAllowed(LiveApiFamily.supabase, ...)` before client creation/query. |
| critical | Supabase read / script | `tool/poi/verify_import.dart:18`, `:35`, `:40` | CLI checks imported POI data against live Supabase when URL/key are provided. | No live API guard; credentials are required but that is not an explicit live guard. | Require `ALLOW_LIVE_SUPABASE=true` before client creation/query. |
| low | Supabase write / script | `tool/poi/import_poi_to_supabase.dart:20`, `:34`, `:70`, `:76`; `lib/features/poi/tools/poi_supabase_importer.dart:146`, `:147` | CLI writes POI fixture with `--write`. | Yes for writes via `ALLOW_POI_SUPABASE_WRITE`; dry-run avoids client creation. Not using central `LiveApiFamily.supabase`. | Optionally also require `ALLOW_LIVE_SUPABASE=true` for consistency; current write opt-in is explicit and safe. |
| low | Supabase write / script | `tool/poi/run_pilot_import.dart:28`, `:39`, `:46`; `lib/features/poi/tools/poi_supabase_importer.dart:147` | Pilot CLI constructs a `SupabaseClient`, then calls importer. Real writes are still blocked by importer unless `ALLOW_POI_SUPABASE_WRITE=true`. | Partially guarded for writes; no early central Supabase guard. | Prefer deleting/retiring in favor of `import_poi_to_supabase.dart`, or add the same early `ALLOW_LIVE_SUPABASE`/write guard. |
| medium | Supabase PostgREST / app UI | `lib/main.dart:15`; provider at `lib/features/auth/providers/auth_provider.dart:5`; examples: `auth_provider.dart:49`, `:66`, `:74`, `:83`; `lib/features/planning/providers/planning_provider.dart:88`, `:111`, `:331`, `:367`; `lib/features/trips/providers/trips_provider.dart:23`, `:67`; `lib/features/wallet/providers/wallet_provider.dart:15`, `:37` | Normal app boot/providers and UI actions read/write Supabase. Widget/integration tests can hit live Supabase if providers are not overridden. | No central guard. This may be intended production behavior, but it is not no-live-by-default for tests. | Add a test-mode/fake Supabase provider convention or guard `supabaseProvider` initialization in non-production entry points; require explicit opt-in for tests/scripts. |
| medium | Supabase PostgREST cache | `lib/features/planning/services/gemini_cache_service.dart:39`, `:72`; `lib/features/planning/services/places_cache_service.dart:35`, `:70`, `:125`, `:162`; `lib/features/planning/services/place_lookup_cache_service.dart:44`, `:77`, `:96` | Cache reads/writes around Gemini, Places, Routes, and place lookup. Cache hits can avoid paid APIs, but still hit Supabase. | No Supabase guard. | Decide whether cache Supabase is allowed by default in app runtime; for tests/scripts, inject fake caches or guard with `LiveApiFamily.supabase`. |
| medium | Supabase live adapter | `lib/features/poi/data/live_poi_supabase_client.dart:31`, `:99`, `:108`, `:118` | `LivePoiSupabaseClient` wraps a real Supabase client and executes selects. | Adapter itself has no guard. `test/poi/live_poi_supabase_client_test.dart:15`, `:64`, `:82` skips live tests unless `ALLOW_LIVE_SUPABASE` and credentials are present. | Keep test skip; consider making the adapter accept/require `LiveApiGuards` or only instantiate it from guarded providers/scripts. |
| medium | Network images / external HTTP | `lib/features/planning/services/places_service.dart:321`; UI loads at `lib/features/planning/widgets/suggestion_detail_sheet.dart:358`, `lib/features/planning/screens/planning_screen.dart:2142`, `lib/features/planning/widgets/alternatives_sheet.dart:404`, `lib/features/planning/widgets/activity_detail_sheet.dart:540`, `lib/features/profile/screens/profile_screen.dart:530` | Places photo URLs and profile/avatar URLs are fetched by image widgets. | No, despite `LiveApiFamily.networkImages` existing. | Gate rendering or URL production behind `allowNetworkImages`; in tests, use placeholders/fakes. |
| medium | Google Maps SDK / external network | `lib/features/map/screens/trip_map_screen.dart:219` | Opening trip map screen renders `GoogleMap`, which can trigger Maps SDK network usage. | No guard. Existing `LiveApiGuards` has no maps SDK family. | Add a maps SDK/external maps guard or provide a static/offline map placeholder in tests. |
| low | Google Maps URLs / external app | `lib/features/map/screens/trip_map_screen.dart:334`, `:373`; `lib/features/planning/widgets/suggestion_detail_sheet.dart:108`, `:111`; `lib/features/planning/widgets/activity_detail_sheet.dart:443`, `:898`; `lib/features/planning/screens/planning_screen.dart:3033`, `:3779` | User taps open directions/search in Google Maps via URL launcher. | No. User-initiated, not automatic test/script network by itself. | Leave as product behavior or add a lightweight external-link guard for automated tests. |

## Guarded Core Surfaces

| API family | File / lines | Trigger path | Guarded? | Residual note |
| --- | --- | --- | --- | --- |
| Google Places New | `lib/features/planning/services/places_nearby_service.dart:228`, `:247`, `:359`, `:386` | `runAutoPlacesFirst()` via `planning_screen.dart:757` or `trip_detail_screen.dart:441`; scripts `test/snapshots/generate_baseline.dart:114` and `test/dev/places_first_harness.dart:176`. | Yes. Cache lookup happens first; cache miss asserts `LiveApiFamily.googlePlaces` before HTTP. | Scripts have explicit guard helpers for Places/Geocoding. |
| Google Places legacy | `lib/features/planning/services/places_service.dart:259`, `:282`, `:418`, `:610`, `:732`, `:799`, `:896`, `:949`, `:1008` | City/destination autocomplete, transport autocomplete, place lookup/details, cache fallback. | Yes. Each live operation calls `_assertGooglePlacesAllowed()` before `_get()`. | Photo URL generation is guarded by the original Places call, but image loading later is not. |
| Google Geocoding | `lib/features/planning/services/geocoding_service.dart:52`, `:68` | `GeocodingService.geocode()` from planning pipeline/document flows/scripts. | Yes. Non-empty query asserts `LiveApiFamily.googleGeocoding` before `http.get()`. | Empty query/missing key returns without live call. |
| Google Routes | `lib/features/planning/services/routes_service.dart:115`, `:131`, `:224`, `:528` | Transport generation via `RoutesService.computeOptionsFromEndpoints()`. | Yes. Cache hit returns first; cache miss asserts `LiveApiFamily.googleRoutes` before `_post()`. | Guard covers the four per-mode Routes calls because they are below the single assertion. |
| Gemini | `lib/features/planning/services/ai_suggestions_service.dart:295`, `:493`, `:596`, `:728`, `:839`, `:918`, `:968`, `:983`, plus generation at `:563`, `:566`; assistant guard at `lib/features/assistant/services/assistant_service.dart:245`, generation at `:302`, `:317` | Regional itinerary, raw prompts, alternatives, descriptions, transport text, document extraction, assistant chat. | Yes. The service asserts `LiveApiFamily.gemini` before model generation on cache misses or uncached actions. | Supabase cache reads/writes around Gemini remain unguarded as Supabase calls. |

## Script/Test Entry Points

| Entry point | API families | Guard status | Risk |
| --- | --- | --- | --- |
| `test/snapshots/generate_baseline.dart:114` | Places New, Geocoding | Guarded by `test/helpers/live_api_script_guards.dart:42`; services also guard. | low |
| `test/dev/places_first_harness.dart:175`, `:176` | Places New, Geocoding | Guarded by `test/helpers/live_api_script_guards.dart:55`; services also guard. | low |
| `test/poi/live_poi_supabase_client_test.dart:15`, `:64`, `:82` | Supabase | Skipped unless `ALLOW_LIVE_SUPABASE` and credentials exist. | low |
| `test/poi/osm_poi_mapping_test.dart:551` | Overpass | Skipped unless `RUN_LIVE_OVERPASS`, but not central guard. | medium |
| `tool/poi/extract_osm_pois.dart:53` | Overpass | Unguarded. | critical |
| `tool/poi/verify_schema.dart:34` | Supabase | Unguarded. | critical |
| `tool/poi/verify_import.dart:40` | Supabase | Unguarded. | critical |
| `tool/poi/import_poi_to_supabase.dart:34`, `:76` | Supabase write | Write guarded by `ALLOW_POI_SUPABASE_WRITE`; no central Supabase guard. | low |

## Validation Run

Offline-safe guard tests passed:

```text
flutter test test/config/live_api_guards_test.dart
flutter test test/config/live_api_guard_integration_test.dart
flutter test test/features/planning/services/geocoding_service_guard_test.dart \
  test/features/planning/services/places_nearby_service_guard_test.dart \
  test/features/planning/services/routes_service_guard_test.dart \
  test/features/planning/services/ai_suggestions_service_gemini_guard_test.dart \
  test/features/assistant/services/assistant_service_gemini_guard_test.dart
```

Result: all tests passed.

Note: Flutter printed package-resolution output before the tests. No command was
run with live API credentials or live API opt-in flags.
