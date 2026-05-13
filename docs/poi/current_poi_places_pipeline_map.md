# Current POI / Places / Destination Pipeline Map

Date: 2026-05-13

Scope: offline code audit only. No live API calls, credentials, or live opt-in flags were used.

## 1. Executive Summary

Lunao currently uses a Places-first planning pipeline with an emerging curated POI layer. The production suggestion flows still depend on Google Geocoding for day centers and Google Places New for candidate pools, with Gemini used only in CoPilot and the legacy restaurants-only path. The new POI repository abstraction is already present and can enrich the Places pool, but the default provider is an offline empty fake, and only `lisbon` is mapped into POI coverage today.

Google Places is therefore still the main runtime source for candidate discovery, photo/rating enrichment, transport hub resolution, and some destination-kind detection. It is guarded at service level by `LiveApiGuards`, while UI runtime providers intentionally instantiate those services with environment-based guards. Tooling and tests are expected to remain closed by default.

The future Supabase POI knowledge base has good seams already: `PoiRepository`, `PoiSupabaseClient`, `PoiCandidateAdapter`, fixture validation/review, Overpass extraction, and guarded Supabase import/verify scripts. The main missing product seam is a runtime override that injects `SupabasePoiRepository(LivePoiSupabaseClient(...))` only where production intentionally wants live Supabase reads.

## 2. Main Files And Responsibilities

| File | Responsibility |
| --- | --- |
| `AGENTS.md:1` | Repo-level no-live-by-default instructions for future agents. |
| `lib/config/live_api_guards.dart:41` | Central live API families and closed-by-default `LiveApiGuards`; blocked errors include the opt-in dart-define. |
| `lib/features/planning/services/places_service.dart:188` | Legacy Google Places wrapper for Find Place, Autocomplete, Place Details, country code, city coords, and photo URLs. |
| `lib/features/planning/services/autocomplete_guard.dart:4` | Min-length, in-memory cache, timeout, and error wrapper for autocomplete calls. |
| `lib/features/planning/services/places_nearby_service.dart:120` | Google Places New wrapper for `places:searchNearby` and `places:searchText`, cached via `gemini_cache`, with per-run budget tracking. |
| `lib/features/planning/services/geocoding_service.dart:34` | Google Geocoding wrapper used to resolve day centers. |
| `lib/features/planning/services/day_center_service.dart:28` | Chooses the day search center: active hotel, segment city, then trip destination. |
| `lib/features/planning/services/places_first_pipeline.dart:1972` | Gathers POI/Places candidates per day and interest. |
| `lib/features/planning/services/places_first_pipeline.dart:6061` | CoPilot orchestration: candidate pool plus Gemini selection. |
| `lib/features/planning/services/places_first_pipeline.dart:6471` | Auto orchestration: candidate pool plus deterministic visit/meal selection, except restaurants-only legacy Gemini path. |
| `lib/features/planning/services/poi_candidate_adapter.dart:4` | Converts curated `Poi` rows into `NearbyCandidate` objects consumed by the planning pipeline. |
| `lib/features/poi/domain/poi_repository.dart:27` | Pure read contract for POI knowledge base access. |
| `lib/features/poi/data/fake_poi_repository.dart:29` | Offline in-memory POI repository used by default and tests. |
| `lib/features/poi/data/supabase_poi_repository.dart:15` | Read-only POI repository implementation over an injectable PostgREST-like client. |
| `lib/features/poi/data/live_poi_supabase_client.dart:28` | Thin live Supabase adapter for POI reads. |
| `lib/features/poi/providers/poi_repository_provider.dart:43` | Root POI repository provider; default is empty offline fake. |
| `supabase/sql/poi_knowledge_base.sql:20` | Supabase schema for `poi_sources`, `pois`, aliases, links, tags, and quality flags. |
| `lib/features/poi/tools/poi_fixture_validator.dart:106` | Offline JSON fixture validator aligned with the POI schema. |
| `lib/features/poi/tools/poi_fixture_reviewer.dart:223` | Offline reviewer/enricher for raw POI fixtures plus manual overrides. |
| `lib/features/poi/tools/osm_overpass_extractor.dart:101` | OSM/Overpass extractor and mapper to Lunao POI fixture format. |
| `lib/features/poi/tools/poi_supabase_importer.dart:107` | Dry-run-first importer; writes require explicit opt-in. |
| `lib/features/poi/tools/poi_supabase_import_checker.dart:84` | Post-import read-only checker over injectable readers. |
| `lib/features/poi/tools/supabase_live_guard.dart:7` | Supabase tooling guard helper. |
| `lib/features/planning/data/destination_blueprints.dart:32` | Manual destination blueprints for must-see and experience seed queries. |
| `lib/features/planning/data/metro_profile.dart:91` | Metro profiles, zones, and tourist anchors for better big-city coverage. |
| `lib/services/destination_intelligence_loader.dart:125` | Dormant async local-first `DestinationIntelligence` loader with optional remote/resolver seams. |
| `lib/data/destinations/destination_intelligence_registry.dart:58` | Sync local DI registry used by deterministic planning selectors. |
| `lib/features/planning/data/destination_key_mapper.dart:3` | Minimal trip destination to POI `destination_key` mapper; currently Lisbon only. |

## 3. End-To-End Flow Diagrams

### Trip Creation Destination Flow

```text
User types destination
  -> CityAutocompleteField / trip edit UI
  -> placesServiceProvider
  -> PlacesService.autocompleteDestinations()
  -> local Lunao destination/country/region maps first
  -> AutocompleteGuard: min length, memory cache, timeout
  -> guarded Google Places autocomplete fallback if allowed
  -> destination kind stored/used by UI
  -> optional getCountryCodeFromPlaceId()
  -> local synthetic lunao:* IDs resolve locally
  -> guarded Google Place Details fallback if needed
  -> trip saved in Supabase runtime tables
```

Key references: `lib/core/widgets/city_autocomplete_field.dart:133`, `lib/features/planning/services/places_service.dart:728`, `lib/features/planning/services/places_service.dart:1068`, `lib/features/trips/widgets/trip_edit_sheet.dart:96`, `lib/features/onboarding/screens/destination_screen.dart:364`.

### Autocomplete Flow

```text
City/destination/transport field input
  -> PlacesService.autocompleteCities / autocompleteDestinations / autocompleteTransport
  -> synthetic Lunao destination/country/region match where applicable
  -> AutocompleteGuard.execute()
       - skip short query
       - return in-memory cache hit
       - timeout/error-safe fallback
  -> PlacesService _*Impl()
  -> LiveApiGuards.assertAllowed(googlePlaces)
  -> Google Places legacy autocomplete endpoint
```

Destination/city autocomplete can avoid Google for covered synthetic entries. Transport autocomplete intentionally has no Lunao-first destination match because airports and train stations are not destinations.

### Itinerary Suggestion Flow

```text
Planning CTA / turnkey generation
  -> planning screen or trip detail screen
  -> runAutoPlacesFirst() or runCoPilotPlacesFirst()
  -> PlacesNearbyService.startRun()
  -> gatherCandidatesForTrip()
       - centerForDay(): hotel -> segment city -> destination
       - GeocodingService.geocode() for live geocoding if needed
       - PlacesNearbyService.searchNearby/searchText() per interest
       - destination blueprints and metro tourist anchors add seed candidates
       - optional PoiRepository -> PoiCandidateAdapter -> merge curated POIs
  -> Auto:
       - template-first optional local branch if flag enabled
       - deterministic visit selection
       - deterministic meal insertion for category=all
       - restaurants-only still uses Gemini legacy path
  -> CoPilot:
       - Gemini chooses among real candidates
       - parser reconstructs suggestions from candidate refs
  -> UI filters and inserts accepted activities into Supabase runtime tables
  -> PlacesNearbyService.endRun()
```

Key references: `lib/features/planning/screens/planning_screen.dart:701`, `lib/features/planning/screens/planning_screen.dart:762`, `lib/features/trips/screens/trip_detail_screen.dart:443`, `lib/features/planning/services/places_first_pipeline.dart:1972`, `lib/features/planning/services/places_first_pipeline.dart:2710`, `lib/features/planning/services/places_first_pipeline.dart:6061`, `lib/features/planning/services/places_first_pipeline.dart:6471`.

### POI Fixture / Reviewer Flow

```text
raw fixture JSON
  -> PoiFixtureValidator.validate()
  -> optional review_poi_fixture CLI
  -> PoiFixtureReviewer applies manual overrides
  -> reviewed fixture JSON + quality report
  -> importer dry-run / staging plan
  -> guarded Supabase write only with explicit opt-in
```

Key references: `lib/features/poi/tools/poi_fixture_validator.dart:106`, `tool/poi/review_poi_fixture.dart:31`, `lib/features/poi/tools/poi_fixture_reviewer.dart:223`, `lib/features/poi/tools/poi_supabase_importer.dart:128`.

### OSM / Overpass Extraction Flow

```text
extract_osm_pois CLI
  -> parse destination/country/bbox
  -> OsmOverpassExtractor.fetchOverpass()
  -> LiveApiGuards.assertAllowed(overpass)
  -> Overpass HTTP POST only if explicitly allowed
  -> extractFromResponse()
  -> map OSM tags/coords/sources to Lunao fixture JSON
  -> stdout fixture
  -> reviewer/validator/importer pipeline
```

Key references: `tool/poi/extract_osm_pois.dart:34`, `lib/features/poi/tools/osm_overpass_extractor.dart:212`, `lib/features/poi/tools/osm_overpass_extractor.dart:217`, `lib/features/poi/tools/osm_overpass_extractor.dart:247`.

### Supabase POI Tooling Flow

```text
verify_schema / verify_import / run_pilot_import --write
  -> assertLiveSupabaseAllowedForPoiTool()
  -> LiveApiGuards.assertAllowed(supabase)
  -> create SupabaseClient only after guard
  -> read/write verification or import

import_poi_to_supabase --write
  -> ALLOW_POI_SUPABASE_WRITE compile-time flag
  -> create SupabaseClient only for writes
  -> PoiSupabaseImporter
```

Key references: `tool/poi/verify_schema.dart:15`, `tool/poi/verify_import.dart:21`, `tool/poi/run_pilot_import.dart:40`, `tool/poi/import_poi_to_supabase.dart:34`, `lib/features/poi/tools/supabase_live_guard.dart:7`.

## 4. Current Live API Surfaces And Guard Status

| API family | Surface | Trigger path | Guard status | Notes |
| --- | --- | --- | --- | --- |
| Google Places legacy | `PlacesService.findInfo()` | Activity sheets, suggestion sheets, planning enrichment, route endpoint resolution | Guarded by `LiveApiFamily.googlePlaces` at `places_service.dart:424` | Builds Place Photo URLs on success; photos then load separately in UI. |
| Google Places legacy | `PlacesService.autocompleteCities()` | City/step autocomplete | Guarded at `places_service.dart:560`, wrapped by `AutocompleteGuard` | Synthetic Lunao hits and short queries avoid Google. |
| Google Places legacy | `PlacesService.autocompleteDestinations()` | Trip destination kind and destination autocomplete | Guarded at `places_service.dart:785`, wrapped by `AutocompleteGuard` | Used also by runtime screens to detect country/region. |
| Google Places legacy | `PlacesService.autocompleteTransport()` | Airport/train autocomplete | Guarded at `places_service.dart:907`, wrapped by `AutocompleteGuard` | Session token supported. |
| Google Places legacy | `resolvePlaceCoords`, `getCountryCodeFromPlaceId`, `findCityCoords`, `getDetails` | Transport document save, country restriction, destination diagnostics, activity details | Guarded at `places_service.dart:974`, `places_service.dart:1084`, `places_service.dart:1137`, `places_service.dart:1196` | `lunao:*` IDs resolve country code locally. |
| Google Places New | `PlacesNearbyService.searchNearby()` | Candidate gathering, restaurant pool, metro anchors | Guarded at `places_nearby_service.dart:228` | Cache checked first at `places_nearby_service.dart:200`; live fallback only on miss/key/allow. |
| Google Places New | `PlacesNearbyService.searchText()` | Interest text queries and destination blueprints | Guarded at `places_nearby_service.dart:359` | Cache checked first at `places_nearby_service.dart:330`. |
| Google Geocoding | `GeocodingService.geocode()` | `centerForDay()` hotel/segment/destination resolution | Guarded at `geocoding_service.dart:52` | Canonical segment fallback can avoid bad geocode outputs after a response/failure. |
| Gemini | `AiSuggestionsService.generateRaw()` and direct methods | CoPilot, restaurants-only auto, descriptions, alternatives, regional loops | Guarded in `ai_suggestions_service.dart:548` and call-specific methods | Some actions use `gemini_cache`; cache lookup itself is Supabase runtime. |
| Supabase runtime | `GeminiCacheService`, `PlacesCacheService`, `PlaceLookupCacheService`, trip/activity writes | Product UI/runtime providers | Runtime behavior, not tooling guard | Valid product runtime surface; tests should override/fake. |
| Supabase POI reads | `SupabasePoiRepository` via `LivePoiSupabaseClient` | Future production POI KB if provider is overridden | Runtime-capable by design; default provider is offline fake | Good seam; live production override should be explicit and documented. |
| Supabase tooling | `verify_schema`, `verify_import`, `run_pilot_import --write` | CLI/tools | Guarded by `LiveApiFamily.supabase` | Fails fast by default. |
| Supabase POI import | `import_poi_to_supabase --write` | CLI import | Guarded by `ALLOW_POI_SUPABASE_WRITE` equivalent | Older write-specific guard; dry-run does not require client. |
| Overpass | `OsmOverpassExtractor.fetchOverpass()` | OSM extraction CLI | Guarded by `LiveApiFamily.overpass` | Transform path is offline. |
| Network images | Cached network image widgets and profile avatar | Runtime image rendering | Audited separately in `docs/api_cost/maps_images_runtime_surface_audit.md` | Not part of POI candidate generation, but Place Photo URLs can feed it. |

## 5. Current Cache Layers And Reuse Rules

| Cache | Location | Key / scope | Reuse rule |
| --- | --- | --- | --- |
| Autocomplete memory cache | `AutocompleteGuard` at `autocomplete_guard.dart:21` | `context:normalizedQuery` | 5-minute in-memory cache per service instance; skips repeated autocomplete fallback calls. |
| Places metadata cache | `PlacesCacheService` at `places_cache_service.dart:5` | `title_key + destination_key` in Supabase `places_cache` | 90-day TTL; hit returns photos/rating/details without Google; miss calls `PlacesService`. |
| Place lookup cache | `PlaceLookupCacheService` at `place_lookup_cache_service.dart:19` | Google `place_id` in Supabase `place_lookup_cache` | Permanent-ish transport hub cache; hits update `last_seen_at`; missing country/city triggers enrichment. |
| Generic Gemini/cache table | `GeminiCacheService` at `gemini_cache_service.dart:17` | `(action, cache_key)` in Supabase `gemini_cache` | 90-day TTL; reused for Gemini outputs, Places New search results, route results, destination resolve actions. |
| Places per-run budget dedup | `PlacesNearbyService.startRun()` at `places_nearby_service.dart:142` | Run-local dedup key | Avoids duplicate Places calls and can bail out after rate-limit/hard cap. |
| Local destination data | `lib/data/destinations/singapore.dart:118` and registry at `destination_intelligence_registry.dart:58` | Destination name/key | Sync local curation for deterministic selectors; no network. |
| Destination blueprints | `destination_blueprints.dart:32` | Normalized destination key | Manual query seeds; still resolved via Places searchText today, then cached. |
| Metro profiles | `metro_profile.dart:91` | Haversine match to metro center | Local curated zones/anchors; anchors can trigger Places searches when used by pipeline. |
| POI fixtures | `test/fixtures/poi/*.json` | File assets for tests/tooling | Deterministic offline inputs for validator, repository, importer, and mapping tests. |
| Trips local cache | `lib/core/services/local_trips_cache_service.dart` | App-local trip snapshot | General app cache, not a POI candidate source. |

## 6. Where Google Places Is Still Used And Why

Google Places is still used for:

- Destination and city autocomplete where Lunao synthetic maps do not cover the query: `places_service.dart:728`, `places_service.dart:531`.
- Transport hub autocomplete and Place Details coordinate resolution: `places_service.dart:879`, `places_service.dart:971`, plus `place_lookup_cache_service.dart:32`.
- Activity metadata enrichment for photos, rating, price, reviews, and opening hours: `places_service.dart:414`, `places_cache_service.dart:22`, `places_cache_service.dart:112`.
- Candidate discovery for planning: `places_nearby_service.dart:171`, `places_nearby_service.dart:302`, consumed by `gatherCandidatesForTrip()` at `places_first_pipeline.dart:1972`.
- Destination blueprints and metro tourist anchors, which are local curated query/anchor definitions but still use Places search to resolve candidates.
- Route endpoint fallback when existing activities lack coordinates: `planning_screen.dart:1843`.

The reason is practical coverage: the curated Supabase POI KB is not yet the primary runtime source, and only Lisbon currently maps to POI coverage via `DestinationKeyMapper`. Places remains the broad fallback/enrichment source, with strict service-level guards for tests/scripts and environment-controlled runtime behavior.

## 7. Recommended Seams For The Future Supabase POI Knowledge Base

1. Make `poiRepositoryProvider` production override explicit in app bootstrap.
   - Keep default fake for tests.
   - Add a documented provider/runtime exception for product Supabase POI reads.
   - Reference seam: `poi_repository_provider.dart:43`.

2. Expand `DestinationKeyMapper` from the current Lisbon-only map to a canonical destination registry.
   - It should align with `DestinationIntelligence`, blueprints, metro profiles, and POI table `destination_key`.
   - Reference seam: `destination_key_mapper.dart:3`.

3. Move destination blueprints from Places query seeds toward curated POI rows.
   - `mustSeeQueries` / `experienceQueries` can become POI tags, editorial score, importance, and source links.
   - Reference: `destination_blueprints.dart:41`.

4. Use `PoiCandidateAdapter` as the main bridge, but enrich it with POI metadata rather than pretending all POIs are Places candidates.
   - Preserve synthetic IDs `poi:<uuid>` for POIs without Google place IDs.
   - Reference: `poi_candidate_adapter.dart:20`.

5. Split candidate gathering into explicit sources.
   - Proposed order: local deterministic fixtures/cache -> Supabase POI -> cached Places -> guarded live Places fallback.
   - Current merge happens late at `places_first_pipeline.dart:2710`.

6. Keep Overpass as an offline ingestion source, not a runtime dependency.
   - Extract -> review -> validate -> import.
   - Runtime should read curated Supabase POIs, not call Overpass.

7. Add fakes/test seams for all POI runtime consumers.
   - Continue using `FakePoiRepository`.
   - Add tests where `runAutoPlacesFirst` gets POI-only pools and does not require Google.

8. Introduce a first-class POI cache/repository contract for local bundled JSON if Supabase should not be required in tests or demos.
   - Current fixtures live under `test/fixtures/poi`, not app assets.

## 8. Risks / Unknowns

- `LivePoiSupabaseClient` is runtime-capable and not itself guarded. This is acceptable only if the production override is explicit; tests should continue using fakes.
- `DestinationKeyMapper` covers only Lisbon, so most trips still cannot use curated POI enrichment even if Supabase POIs exist.
- Destination blueprints and metro tourist anchors are curated locally but still resolve through Google Places search, so they are not a full cost escape hatch yet.
- `PlacesCacheService` catches cache read errors and falls back to live Places. Good UX, but tests must avoid real clients or use closed guards.
- `GeminiCacheService` is a Supabase runtime cache. Cache misses in planning can still lead to Google/Gemini live calls if guards allow them.
- `runAutoPlacesFirst(category: restaurants)` still uses the legacy Gemini selection path.
- Place Photo URLs are stored/propagated as Google URLs; image loading is a separate runtime network surface.
- The dormant async `DestinationIntelligenceLoader` has optional remote/resolver seams but is not the sync pipeline source today.

## 9. Suggested Next Implementation Tasks

1. Add a documented production-only POI repository override that wires `SupabasePoiRepository(LivePoiSupabaseClient(Supabase.instance.client))`, while keeping tests offline by default.
2. Add a POI-only planning test for Lisbon proving `runAutoPlacesFirst` can select from curated POIs without Google Places when supplied a fake geocoder/nearby service.
3. Expand `DestinationKeyMapper` and POI fixtures for the next target destination, then import through the guarded dry-run/review/write flow.
4. Convert one destination blueprint into POI rows and compare output against the existing Places blueprint path.
5. Add a source attribution field mapping from `poi_source_links` into UI/debug output so curated candidates remain explainable.
6. Make candidate source explicit in `NearbyCandidate` or a wrapper type (`google`, `supabase_poi`, `fixture`) to avoid relying on synthetic `placeId` prefixes.
7. Replace restaurants-only Gemini selection with deterministic restaurant scoring, matching the current visits path.
8. Document when production runtime is allowed to read Supabase POIs and how tests must override with `FakePoiRepository`.
