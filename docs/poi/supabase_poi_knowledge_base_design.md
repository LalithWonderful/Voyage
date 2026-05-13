# Supabase POI Knowledge Base Design

Date: 2026-05-13

Scope: architecture proposal only. No app code, migrations, credentials, live APIs, or live opt-in flags were used.

## 1. Objectives

The target POI knowledge base should make Supabase the primary tourism knowledge source for Lunao planning. Google Places should become a controlled fallback and enrichment layer, not the default source of itinerary candidates.

Primary objectives:

- Replace Google Places as the primary source for tourism candidates, destination anchors, must-sees, neighborhoods, and curated experiences.
- Keep Google Places only for controlled autocomplete, targeted details, fallback quality checks, and enrichment of already selected POIs.
- Ensure every Google Places call is cacheable and reusable, never repeated blindly.
- Keep tests, tooling, diagnostics, scripts, and imports no-live-by-default.
- Keep runtime Supabase reads explicit and documented through the existing POI repository seam.
- Preserve deterministic fixture, review, and import flows so POI quality can be audited before it reaches production.

Non-goals for the MVP:

- Do not mass-fill Supabase from Google Places.
- Do not make Overpass a runtime dependency.
- Do not require Gemini for POI creation or validation.
- Do not replace existing trip/activity runtime tables.

## 2. Proposed Supabase Schema

This section proposes a target model. It should inform future migrations, but this document does not create migrations.

### `poi_sources`

Purpose: Registry of trusted data sources used to create or update POIs.

Key columns:

- `source_id uuid primary key`
- `name text not null`
- `source_type text not null`
- `base_url text`
- `license_name text`
- `license_url text`
- `trust_level int not null`
- `is_active boolean not null default true`
- `notes text`
- `created_at timestamptz`
- `updated_at timestamptz`

Constraints/indexes:

- Check `trust_level between 1 and 5`.
- Check `source_type in ('official_board', 'official_venue', 'unesco', 'wikidata', 'wikipedia', 'openstreetmap', 'open_data_gov', 'editorial', 'traveler_feedback', 'google_places_enrichment')`.
- Index `source_type`, `trust_level`, `is_active`.

Data ownership: Platform/editorial owned. Import tools may create batch-specific source rows only when reviewed.

Update frequency: Rare. New source types or official boards are added manually.

### `pois`

Purpose: Canonical POI record. One row per real-world place or travel-relevant area.

Key columns:

- `poi_id uuid primary key`
- `canonical_name text not null`
- `normalized_name text not null`
- `primary_category_key text not null`
- `lat double precision`
- `lng double precision`
- `address text`
- `country_code text`
- `admin1 text`
- `admin2 text`
- `locality text`
- `neighborhood text`
- `zone_name text`
- `official_url text`
- `is_active boolean not null default true`
- `is_must_see boolean not null default false`
- `is_hidden_gem boolean not null default false`
- `is_family_friendly boolean`
- `is_rain_friendly boolean`
- `is_free boolean`
- `typical_duration_minutes int`
- `price_level int`
- `payload jsonb not null default '{}'`
- `created_at timestamptz`
- `updated_at timestamptz`

Constraints/indexes:

- Check valid lat/lng ranges.
- Check `country_code` uppercase ISO-2 when present.
- Check `price_level between 0 and 4` when present. Use 0 for free if known.
- Foreign key `primary_category_key -> poi_categories(category_key)`.
- Index `normalized_name`, `country_code`, `locality`, `primary_category_key`, `is_must_see`, `is_hidden_gem`, `is_active`.
- Spatial future: GiST index on geography point if PostGIS is enabled.
- Unique candidate: `(country_code, normalized_name, locality)` as a soft uniqueness signal, not necessarily a hard constraint for MVP.

Data ownership: Canonical fields are editorial/import owned. Runtime should not mutate canonical POI rows.

Update frequency: Moderate. Stable attractions update rarely; restaurants and opening-sensitive venues update more often.

### `poi_localized_names`

Purpose: Store multilingual names, aliases, transliterations, and canonical display names by locale.

Key columns:

- `localized_name_id uuid primary key`
- `poi_id uuid not null`
- `locale text not null`
- `name text not null`
- `normalized_name text not null`
- `name_type text not null`
- `is_primary boolean not null default false`
- `source_id uuid`
- `created_at timestamptz`

Constraints/indexes:

- Foreign key `poi_id -> pois(poi_id) on delete cascade`.
- Check `name_type in ('canonical', 'alias', 'transliteration', 'historic', 'local', 'search')`.
- Unique `(poi_id, locale, normalized_name, name_type)`.
- Index `normalized_name`, `locale`, `is_primary`.

Data ownership: Import plus editorial review. Manual overrides can promote a primary localized name.

Update frequency: Low to moderate. Updated when adding language support or correcting names.

### `poi_categories`

Purpose: Controlled taxonomy mapping source categories into Lunao planning categories.

Key columns:

- `category_key text primary key`
- `parent_category_key text`
- `label_fr text not null`
- `label_en text`
- `planning_tag text`
- `priority int not null default 50`
- `default_duration_minutes int`
- `is_meal_category boolean not null default false`
- `is_visit_category boolean not null default true`
- `payload jsonb not null default '{}'`

Constraints/indexes:

- Self foreign key `parent_category_key -> poi_categories(category_key)`.
- Check `priority between 0 and 100`.
- Check positive `default_duration_minutes` when present.
- Index `planning_tag`, `is_meal_category`, `is_visit_category`.

Data ownership: Product/editorial owned.

Update frequency: Rare, but mappings may be extended during imports.

### `poi_destination_links`

Purpose: Link a POI to one or more canonical destinations, cities, regions, or zones.

Key columns:

- `link_id uuid primary key`
- `poi_id uuid not null`
- `destination_key text not null`
- `destination_scope text not null`
- `country_code text`
- `city_key text`
- `admin_key text`
- `zone_key text`
- `distance_to_center_m int`
- `relevance_score int`
- `is_primary boolean not null default false`
- `created_at timestamptz`

Constraints/indexes:

- Foreign key `poi_id -> pois(poi_id) on delete cascade`.
- Check `destination_scope in ('city', 'metro', 'region', 'country', 'zone', 'day_trip')`.
- Check `relevance_score between 0 and 100`.
- Unique `(poi_id, destination_key, destination_scope, coalesce(zone_key, ''))`.
- Index `destination_key`, `city_key`, `zone_key`, `is_primary`, `relevance_score`.

Data ownership: Import can create links; editorial review can adjust relevance and primary destination.

Update frequency: Moderate. Updated as destination identity gets refined.

### `poi_quality_scores`

Purpose: Deterministic scoring snapshot used by planning, sorting, and QA.

Key columns:

- `poi_id uuid primary key`
- `touristic_importance int`
- `editorial_score int`
- `source_confidence int`
- `rating_score int`
- `review_confidence int`
- `category_priority int`
- `duplicate_confidence int`
- `freshness_score int`
- `overall_score int not null`
- `score_version text not null`
- `computed_at timestamptz not null`
- `explanation jsonb not null default '{}'`

Constraints/indexes:

- Foreign key `poi_id -> pois(poi_id) on delete cascade`.
- Check every score is `0..100` except `touristic_importance`, which may be `1..5`.
- Index `overall_score`, `touristic_importance`, `score_version`, `computed_at`.

Data ownership: Generated by deterministic tooling, with editorial inputs from `pois` and overrides.

Update frequency: After imports, overrides, source updates, or scoring algorithm changes.

### `poi_external_refs`

Purpose: Store source identifiers and external references without making Google the canonical ID.

Key columns:

- `external_ref_id uuid primary key`
- `poi_id uuid not null`
- `source_id uuid not null`
- `ref_type text not null`
- `ref_value text not null`
- `source_url text`
- `source_payload jsonb not null default '{}'`
- `fetched_at timestamptz`
- `verified_at timestamptz`
- `created_at timestamptz`

Constraints/indexes:

- Foreign key `poi_id -> pois(poi_id) on delete cascade`.
- Foreign key `source_id -> poi_sources(source_id)`.
- Check `ref_type in ('osm_node', 'osm_way', 'osm_relation', 'wikidata_qid', 'wikipedia_page', 'official_url', 'google_place_id', 'tripadvisor_url', 'manual_slug')`.
- Unique `(source_id, ref_type, ref_value)`.
- Index `poi_id`, `ref_type`, `verified_at`.

Data ownership: Import owned; editorial can verify or detach refs.

Update frequency: Moderate. Updated by imports/enrichment and dedup passes.

### `poi_opening_hours`

Purpose: Store structured and human-readable opening data from non-Google sources and selected Google enrichment.

Key columns:

- `opening_hours_id uuid primary key`
- `poi_id uuid not null`
- `source_id uuid not null`
- `hours_format text not null`
- `raw_hours text`
- `structured_hours jsonb`
- `timezone text`
- `valid_from date`
- `valid_to date`
- `confidence int`
- `fetched_at timestamptz`
- `verified_at timestamptz`

Constraints/indexes:

- Foreign key `poi_id -> pois(poi_id) on delete cascade`.
- Check `hours_format in ('osm_opening_hours', 'google_periods', 'manual_text', 'official_json', 'unknown')`.
- Check `confidence between 0 and 100`.
- Index `poi_id`, `valid_from`, `valid_to`, `verified_at`.

Data ownership: Source import plus editorial overrides. Google opening hours are enrichment-only for selected POIs.

Update frequency: High for restaurants/venues, low for monuments and outdoor sites.

### `poi_media`

Purpose: Store media metadata and licensed image references without relying blindly on remote image URLs.

Key columns:

- `media_id uuid primary key`
- `poi_id uuid not null`
- `source_id uuid not null`
- `media_type text not null`
- `url text not null`
- `thumbnail_url text`
- `attribution text`
- `license_name text`
- `license_url text`
- `width int`
- `height int`
- `sort_order int`
- `is_primary boolean not null default false`
- `fetched_at timestamptz`
- `verified_at timestamptz`

Constraints/indexes:

- Foreign key `poi_id -> pois(poi_id) on delete cascade`.
- Check `media_type in ('photo', 'map_thumbnail', 'icon', 'official_logo')`.
- Unique `(poi_id, url)`.
- Index `poi_id`, `is_primary`, `source_id`.

Data ownership: Import plus editorial. Google Place Photo URLs should be stored only as controlled enrichment, with cache/TTL and attribution.

Update frequency: Moderate. Media licensing and URL freshness need periodic checks.

### `poi_import_batches`

Purpose: Auditable import runs for fixtures, OSM/Wikidata pulls, manual seeds, and enrichment batches.

Key columns:

- `batch_id uuid primary key`
- `batch_type text not null`
- `destination_key text`
- `source_id uuid`
- `input_uri text`
- `input_hash text`
- `status text not null`
- `dry_run boolean not null default true`
- `started_at timestamptz`
- `finished_at timestamptz`
- `created_by text`
- `summary jsonb not null default '{}'`

Constraints/indexes:

- Check `batch_type in ('fixture', 'osm_overpass', 'wikidata', 'wikipedia', 'manual', 'google_enrichment', 'quality_recompute')`.
- Check `status in ('planned', 'running', 'succeeded', 'failed', 'blocked', 'review_required')`.
- Index `destination_key`, `batch_type`, `status`, `started_at`.
- Unique optional `input_hash` per destination/source for idempotent imports.

Data ownership: Tooling owned. Write access must be guarded.

Update frequency: Every import/enrichment run.

### `poi_import_issues`

Purpose: Persist validation, dedup, licensing, mapping, and review issues from imports.

Key columns:

- `issue_id uuid primary key`
- `batch_id uuid not null`
- `poi_id uuid`
- `severity text not null`
- `issue_type text not null`
- `message text not null`
- `source_ref text`
- `payload jsonb not null default '{}'`
- `resolved_at timestamptz`
- `resolved_by text`

Constraints/indexes:

- Foreign key `batch_id -> poi_import_batches(batch_id) on delete cascade`.
- Nullable foreign key `poi_id -> pois(poi_id)`.
- Check `severity in ('info', 'warning', 'error', 'blocking')`.
- Index `batch_id`, `poi_id`, `severity`, `issue_type`, `resolved_at`.

Data ownership: Tooling creates issues; editorial resolves them.

Update frequency: Every import/review run.

### `poi_editorial_overrides` (optional)

Purpose: Keep manual corrections separate from imported source facts.

Key columns:

- `override_id uuid primary key`
- `poi_id uuid not null`
- `field_name text not null`
- `value jsonb not null`
- `reason text`
- `priority int not null default 100`
- `created_by text`
- `created_at timestamptz`
- `expires_at timestamptz`

Constraints/indexes:

- Foreign key `poi_id -> pois(poi_id) on delete cascade`.
- Unique `(poi_id, field_name, priority)` or use one active override per field.
- Index `poi_id`, `field_name`, `priority`, `expires_at`.

Data ownership: Editorial/product only.

Update frequency: As reviewers correct imports or tune planning behavior.

## 3. Destination Identity Model

The current `DestinationKeyMapper` is intentionally small and maps only Lisbon. The target model needs canonical destination identity that can support cities, metros, regions, countries, zones, and day trips.

Proposed destination concepts:

- `destination_key`: stable lowercase slug, for example `lisbon`, `singapore`, `tokyo`, `bali`, `provence`, `france`.
- `destination_type`: `city`, `metro`, `region`, `country`, `island`, `neighborhood`, `day_trip_cluster`.
- `country_code`: ISO-2 uppercase, nullable only for multi-country regions.
- `parent_destination_key`: hierarchy link, for example `shibuya -> tokyo`, `provence -> france`.
- `admin1`, `admin2`, `locality`: administrative metadata for matching and disambiguation.
- `center_lat`, `center_lng`, `radius_km`, optional polygon/bbox later.
- `aliases`: localized and spelling variants, for example `lisbonne`, `lisboa`, `singapour`, `sg`.
- `is_planning_enabled`: whether Lunao can generate POI-first plans for this destination.
- `coverage_level`: `none`, `seed`, `pilot`, `production`, `deprecated`.

Implementation options:

- MVP can use a new `destinations` or `poi_destinations` table plus `destination_aliases`.
- If existing `destination_intelligence` becomes the canonical destination table, POI destination links should reference its `destination_key`.
- `DestinationBlueprint` and `MetroProfile` should become seed inputs to destination metadata, not separate runtime-only registries forever.

Large-country and region handling:

- A country-level trip should not query a country centroid.
- Country/region destinations should require child city/region selections or use curated regional itineraries.
- `poi_destination_links` should allow the same POI to belong to a city, region, and country with different relevance scores.
- For broad regions, planning should choose a concrete child destination or zone before selecting POIs.

Relation to existing code:

- `DestinationKeyMapper` should become a repository-backed resolver with local fixture fallback.
- `DestinationBlueprint.destinationKey` should map to canonical `destination_key`.
- `MetroProfile.cityKey` should map to canonical `destination_key` and its zones/anchors.
- `DestinationIntelligence` should either read from Supabase destination metadata or be generated from the same canonical source.

## 4. Source Strategy

### OSM / Overpass

Use for broad seed extraction of museums, monuments, viewpoints, parks, markets, beaches, transport hubs, and named attractions.

Rules:

- Overpass remains a guarded offline/tooling source only.
- Import OSM IDs into `poi_external_refs`.
- Keep ODbL attribution in `poi_sources` and per-ref/source payloads.
- Do not trust OSM category or importance alone; use it as a candidate source.

### Wikidata

Use for stable identifiers, multilingual names, coordinates, categories, official links, inception/heritage signals, and Wikipedia links.

Rules:

- Store QIDs in `poi_external_refs`.
- Use Wikidata sitelinks to connect Wikipedia pages.
- Use deterministic mapping rules; flag ambiguous QIDs for review.

### Wikipedia

Use for public encyclopedic summaries, page existence, language variants, and notability signal.

Rules:

- Store page refs and URLs, not large copied article content.
- Summaries, if used, need licensing-aware handling and attribution.
- Page existence boosts source confidence but should not create a POI by itself without location and category.

### Curated Manual Lists

Use as the highest-signal source for must-sees, hidden gems, neighborhoods, day templates, and destination-specific anchors.

Rules:

- Manual lists should import as `source_type='editorial'` or official source rows.
- They can override category, importance, duration, zone, and must-see flags.
- Existing `DestinationBlueprint`, `MetroProfile`, and tourist anchors are first-class seed material.

### Future Traveler Feedback

Use as a quality signal, not canonical truth.

Rules:

- Store aggregated feedback separately or as source refs, never overwrite canonical POI fields directly.
- Feedback can affect freshness, hidden-gem confidence, duplicate flags, and ranking.
- Personal/private feedback must not leak into shared POI records without aggregation.

### Google Places Enrichment

Use only for controlled fallback and selected POI enrichment.

Allowed uses:

- Controlled autocomplete for user input.
- Targeted details for an already selected POI.
- Fallback quality checks for a small candidate set.
- Enrichment of selected POIs with Google place ID, rating, opening hours, or photo reference when explicitly allowed.

Forbidden uses:

- Mass-filling Supabase.
- Blind background discovery.
- Per-user repeated lookup for the same POI when a reusable cache key exists.
- Tests/scripts without explicit live guard opt-in.

## 5. Quality Scoring Model

The planning pipeline should rank POIs using deterministic fields. LLMs may explain or summarize, but not decide canonical quality.

Recommended fields:

- `touristic_importance`: 1..5 human-readable tourism importance. `5` means destination-defining.
- `editorial_score`: 0..100 Lunao editorial/product confidence.
- `source_confidence`: 0..100 based on trusted sources, official refs, Wikidata/OSM agreement, and verification state.
- `review_rating_value`: optional external rating, stored separately from score.
- `review_rating_count`: optional count, with source and freshness.
- `review_confidence`: 0..100 derived from rating count, recency, source reliability, and category.
- `category_priority`: 0..100 from `poi_categories.priority`, adjusted per traveler profile at runtime.
- `distance_relevance`: runtime score based on day center, zone, or cluster, not a static POI field.
- `cluster_relevance`: how strongly the POI belongs to a destination zone or day template.
- `duplicate_confidence`: 0..100 confidence that this POI is the canonical representative, not a duplicate.
- `freshness_score`: higher for recently verified time-sensitive venues.
- `is_must_see`: boolean editorial flag.
- `is_hidden_gem`: boolean editorial flag for lower-famous but high-quality places.

Suggested overall score:

```text
overall_score =
  0.30 * editorial_score
+ 0.20 * source_confidence
+ 0.15 * touristic_importance_scaled
+ 0.10 * category_priority
+ 0.10 * review_confidence
+ 0.10 * freshness_score
+ 0.05 * duplicate_confidence
+ must_see_boost
+ hidden_gem_contextual_boost
```

Runtime selectors should still apply traveler profile, distance, time of day, category, budget, weather/rain friendliness, family friendliness, and duplicate/same-complex rules outside the static score.

## 6. Import Pipeline MVP

### Phase 1: Schema, Fixtures, Pilot Cities

Goal: Establish deterministic POI data for one or two pilot cities, likely Lisbon plus Singapore or Paris.

Steps:

- Create target migrations after this design is accepted.
- Extend fixture format to cover localized names, external refs, destination links, quality scores, and import issues.
- Convert existing pilot fixtures into the target format.
- Add SQL contract tests and fixture validator tests.
- Keep import dry-run first.
- Write only with explicit Supabase tooling guard and write opt-in.

Exit criteria:

- One pilot city has 50-150 reviewed tourism POIs.
- Tests can load the fixture offline and produce stable repository results.
- No Google Places dependency exists in fixture validation or import dry-run.

### Phase 2: OSM / Wikidata Enrichment

Goal: Add source breadth without creating runtime network dependencies.

Steps:

- Use guarded Overpass extraction only when intentionally run.
- Map OSM IDs to `poi_external_refs`.
- Add offline Wikidata fixture ingestion from saved JSON exports or guarded tooling.
- Add deterministic dedup by coordinates, normalized names, aliases, and external refs.
- Record issues in `poi_import_issues` instead of silently dropping ambiguous rows.

Exit criteria:

- Pilot city data has source refs and duplicate issue reports.
- OSM/Wikidata import can run from saved fixtures offline.

### Phase 3: Manual Overrides / Editorial Review

Goal: Make imported data product-grade.

Steps:

- Add override fixture format or `poi_editorial_overrides`.
- Review must-see, hidden gem, family/rain/free flags, duration, category, and zone.
- Generate quality report for every import batch.
- Block production import when critical issues remain.

Exit criteria:

- Reviewed pilot city produces coherent candidate pools.
- Quality report is readable by product/editorial reviewers.

### Phase 4: Runtime Read Service

Goal: Let production planning read Supabase POIs intentionally.

Steps:

- Keep `PoiRepository` as the app-facing interface.
- Add production provider override for `SupabasePoiRepository(LivePoiSupabaseClient(...))`.
- Keep default provider as `FakePoiRepository`.
- Add local fixture repository for offline/demo tests if needed.
- Add tests proving `runAutoPlacesFirst` can use POI-only candidates.

Exit criteria:

- Production can read Supabase POIs by destination.
- Tests remain closed and deterministic.
- Planning can produce useful results for a pilot city with no Google candidate discovery.

### Phase 5: Google Places Enrichment Cache For Selected POIs Only

Goal: Use Google for targeted freshness, not discovery.

Steps:

- Create enrichment cache keyed by `poi_id`, `google_place_id`, field mask, language, and source version.
- Enrich only selected POIs or small reviewed candidate sets.
- Store rating, review count, opening hours, photo refs, and resolved Google place ID with TTL.
- Never enrich entire destinations blindly.

Exit criteria:

- Re-opening the same POI uses Supabase/cache.
- Google calls are traceable, TTL-bound, and guard-controlled.

## 7. Runtime Integration Plan

Runtime consumption should use the existing seam:

```text
planning pipeline
  -> PoiRepository
  -> default FakePoiRepository in tests
  -> production override SupabasePoiRepository(LivePoiSupabaseClient)
  -> optional local fixture repository for offline/demo
```

Provider rules:

- `poiRepositoryProvider` remains fake/offline by default.
- Production app bootstrap may override it with the live Supabase repository.
- Tests must override with fake fixtures and must not instantiate live Supabase clients unless explicitly requested.
- Tooling reads/writes remain guarded by `LiveApiGuards` or equivalent write flags.

Cache behavior:

- Supabase POI rows are the shared canonical cache.
- Local JSON fixtures can be used for tests, snapshots, and pilot comparisons.
- Google enrichment writes must go to Supabase/cache before UI reuse.
- Candidate gathering should prefer POI repository results before cached Places fallback.

No-live-by-default compliance:

- No test should depend on Google Places, Overpass, Supabase live, Gemini, or external HTTP.
- Scripts must fail fast before client creation unless live APIs are explicitly allowed.
- Runtime live Supabase reads are allowed only as a documented product provider exception.

## 8. Migration From Existing Curated Anchors

### DestinationBlueprint

Current `mustSeeQueries` and `experienceQueries` should become curated POI seeds:

- Query string -> `poi_localized_names` search alias or import hint.
- Must-see query -> `pois.is_must_see=true`, high `touristic_importance`, high `editorial_score`.
- Experience query -> `is_hidden_gem` or category/tag depending on content.
- Destination key -> `poi_destination_links.destination_key`.
- Blueprint kind -> destination metadata, not per-POI data.

### MetroProfile

Metro profiles should become destination metadata plus zone links:

- `MetroProfile.cityKey` -> canonical `destination_key`.
- `MetroZone` -> destination zone rows or `poi_destination_links.zone_key`.
- Zone patterns -> localized aliases/search rules for matching POIs to zones.
- `blockedAddressPatterns` and neighbor exclusions -> destination scope metadata.
- `visitBlockedNamePatterns` -> category/slot rules or editorial overrides.

### Tourist Anchors

Tourist anchors should become either POIs or destination zones:

- Specific attraction anchor, such as a museum or landmark -> `pois`.
- Neighborhood or area anchor -> destination zone/area metadata.
- Anchor radius -> destination zone radius or planning search radius metadata.
- Anchor labels -> localized names/aliases.

Migration principle:

```text
curated runtime constants
  -> source fixtures
  -> validated POI/destination records
  -> Supabase runtime reads
  -> local fixture fallback for tests
```

## 9. Google Places Cost-Control Rules

**Every Google Places call must be stored in Supabase/cache so the same call can be reused and not repeated.**

Rules:

- Google Places is forbidden by default in tests, tools, scripts, diagnostics, imports, and ordinary agent work.
- Google Places is allowed only for controlled autocomplete, targeted details, fallback quality checks, and enrichment on already selected POIs.
- Google Places must never be used for mass-filling Supabase.
- Every call must have an operation name, guard, cache key, field mask/scope, TTL or freshness rule, and reuse path.
- Place Details enrichment must be keyed by `poi_id` and/or `google_place_id`, not only by free text.
- Text Search and Nearby Search should not be the normal production candidate source once a destination has POI coverage.
- If a Google response cannot be stored because of licensing, terms, or schema uncertainty, do not make that call in background tooling.

## 10. Risks And Open Questions

- Data licensing: OSM ODbL, Wikidata/Wikipedia licenses, official tourism board terms, and Google Places terms must be handled separately.
- Duplicate detection: Same attraction may appear as OSM node/way/relation, Wikidata QID, Wikipedia page, and Google place ID.
- Multilingual names: Local script, French UI labels, English common names, and transliterations need stable matching rules.
- Photos/media licensing: Google Place Photos, Wikimedia images, official venue photos, and hotlinked images have different rights and caching rules.
- Freshness of restaurants: Restaurants need much shorter freshness cycles than monuments, and may not belong in the same MVP quality policy.
- City boundary ambiguity: Islands, metro areas, border cities, day trips, and broad regions need explicit destination scope logic.
- Production Supabase runtime reads: The app needs a clear documented runtime exception, provider override, RLS policy, and test fake discipline.
- Google terms: Storing or reusing specific Google fields may have constraints; legal/product review is needed before long-lived storage.
- Editorial workload: Quality improves only if manual review is lightweight and issue reports are actionable.
- Performance: Large cities may require pagination, radius/zone queries, or precomputed candidate bundles.

## 11. Suggested Next Implementation Tasks

1. Create a migration proposal for `poi_destinations`, `poi_localized_names`, `poi_categories`, `poi_destination_links`, `poi_quality_scores`, `poi_external_refs`, `poi_opening_hours`, `poi_media`, `poi_import_batches`, and `poi_import_issues`.
2. Update the offline POI SQL contract tests for the proposed schema without touching runtime app code.
3. Extend the fixture validator to validate localized names, external refs, destination links, quality scores, and import issues.
4. Create a target-format Lisbon fixture from the existing pilot data.
5. Add a local fixture-backed `PoiRepository` for tests and demos.
6. Add a POI-only planning test proving Lisbon suggestions can be generated without Google Places candidate discovery.
7. Design a `DestinationIdentityRepository` to replace the hardcoded Lisbon-only `DestinationKeyMapper`.
8. Convert one `DestinationBlueprint` into POI fixture rows and compare its candidate coverage against the current blueprint Places path.
9. Convert one `MetroProfile` zone set into destination zone metadata and POI destination links.
10. Add an import batch report writer that persists issues offline first and can later write to Supabase behind guards.
11. Design the Google Places enrichment cache schema and document allowed field masks/TTLs before implementing any enrichment call.
12. Add production provider override documentation for Supabase POI reads, including how tests must keep `FakePoiRepository`.
