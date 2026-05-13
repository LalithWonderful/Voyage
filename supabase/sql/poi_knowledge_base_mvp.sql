-- POI MVP — Supabase knowledge-base schema layer.
--
-- This migration is additive over `poi_knowledge_base.sql` (POI-0.1).
-- It keeps the legacy import/runtime contract intact while adding the
-- target MVP tables described in
-- `docs/poi/supabase_poi_knowledge_base_design.md`.
--
-- No seed data. No live API calls. Apply manually in Supabase SQL Editor
-- only when intentionally migrating an environment.
--
-- Idempotence style: `create table if not exists`, `add column if not exists`,
-- `create index if not exists`, and drop/create for policies/triggers.

-- =============================================================================
-- 0. Shared updated_at trigger helper
-- =============================================================================

create or replace function public.poi_mvp_set_updated_at()
returns trigger
language plpgsql
as $$
begin
  new.updated_at = now();
  return new;
end;
$$;

-- =============================================================================
-- 1. Extend existing source and POI tables without breaking POI-0.1
-- =============================================================================

-- Keep `poi_sources` as the source registry, but broaden source_type for
-- Wikidata/Wikipedia/feedback/Google-enrichment provenance.
alter table public.poi_sources
  drop constraint if exists poi_sources_source_type_check;

alter table public.poi_sources
  add constraint poi_sources_source_type_check
  check (source_type in (
    'official_board',
    'official_venue',
    'unesco',
    'wikidata',
    'wikipedia',
    'openstreetmap',
    'open_data_gov',
    'editorial',
    'traveler_feedback',
    'google_places_enrichment'
  ));

comment on column public.poi_sources.source_type is
  'Type de source : official_board, official_venue, unesco, wikidata, wikipedia, openstreetmap, open_data_gov, editorial, traveler_feedback, google_places_enrichment';

create index if not exists poi_sources_is_active_idx
  on public.poi_sources (is_active);

-- `pois` keeps legacy columns (`name`, `category`, `destination_key`) so
-- current import scripts remain valid. Target columns are added as nullable
-- additive fields for the next repository/import generation.
alter table public.pois
  add column if not exists canonical_name text,
  add column if not exists primary_category_key text,
  add column if not exists admin1 text,
  add column if not exists admin2 text,
  add column if not exists locality text,
  add column if not exists neighborhood text,
  add column if not exists is_active boolean not null default true,
  add column if not exists is_hidden_gem boolean not null default false;

comment on column public.pois.canonical_name is
  'Target MVP canonical display name. Legacy `name` remains for POI-0.1 compatibility.';
comment on column public.pois.primary_category_key is
  'Target MVP taxonomy key. Legacy `category` remains for POI-0.1 compatibility.';
comment on column public.pois.locality is
  'City/locality used for destination identity and duplicate reduction.';
comment on column public.pois.neighborhood is
  'Neighborhood or local area when known.';
comment on column public.pois.is_hidden_gem is
  'Editorial signal for lower-famous but high-quality places.';

do $$
begin
  if not exists (
    select 1
    from pg_constraint
    where conname = 'pois_country_code_upper_check'
      and conrelid = 'public.pois'::regclass
  ) then
    alter table public.pois
      add constraint pois_country_code_upper_check
      check (country_code is null or country_code ~ '^[A-Z]{2}$');
  end if;
end $$;

create index if not exists pois_primary_category_key_idx
  on public.pois (primary_category_key);

create index if not exists pois_locality_idx
  on public.pois (locality);

create index if not exists pois_neighborhood_idx
  on public.pois (neighborhood);

create index if not exists pois_is_active_idx
  on public.pois (is_active);

create index if not exists pois_is_hidden_gem_idx
  on public.pois (is_hidden_gem) where is_hidden_gem = true;

create index if not exists pois_lat_lng_idx
  on public.pois (lat, lng);

create index if not exists pois_country_locality_name_idx
  on public.pois (country_code, locality, normalized_name);

-- =============================================================================
-- 2. Controlled taxonomy
-- =============================================================================

create table if not exists public.poi_categories (
  category_key             text        primary key,
  parent_category_key      text,
  label_fr                 text        not null,
  label_en                 text,
  planning_tag             text,
  priority                 integer     not null default 50,
  default_duration_minutes integer,
  is_meal_category         boolean     not null default false,
  is_visit_category        boolean     not null default true,
  payload                  jsonb       not null default '{}',
  created_at               timestamptz not null default now(),
  updated_at               timestamptz not null default now(),

  constraint poi_categories_parent_fk
    foreign key (parent_category_key)
    references public.poi_categories(category_key),
  constraint poi_categories_priority_check
    check (priority >= 0 and priority <= 100),
  constraint poi_categories_duration_check
    check (default_duration_minutes is null or default_duration_minutes > 0)
);

comment on table public.poi_categories is
  'Controlled Lunao POI taxonomy for planning and import mapping.';
comment on column public.poi_categories.category_key is
  'Stable category key used by POI import and planning.';

create index if not exists poi_categories_parent_idx
  on public.poi_categories (parent_category_key);

create index if not exists poi_categories_planning_tag_idx
  on public.poi_categories (planning_tag);

create index if not exists poi_categories_meal_idx
  on public.poi_categories (is_meal_category);

create index if not exists poi_categories_visit_idx
  on public.poi_categories (is_visit_category);

-- Add the target FK only after the taxonomy table exists. Nullable by design
-- during the transition from legacy `category`.
do $$
begin
  if not exists (
    select 1
    from pg_constraint
    where conname = 'pois_primary_category_key_fk'
      and conrelid = 'public.pois'::regclass
  ) then
    alter table public.pois
      add constraint pois_primary_category_key_fk
      foreign key (primary_category_key)
      references public.poi_categories(category_key);
  end if;
end $$;

-- =============================================================================
-- 3. Localized names and aliases
-- =============================================================================

create table if not exists public.poi_localized_names (
  localized_name_id uuid        primary key default gen_random_uuid(),
  poi_id            uuid        not null,
  locale            text        not null,
  name              text        not null,
  normalized_name   text        not null,
  name_type         text        not null,
  is_primary        boolean     not null default false,
  source_id         uuid,
  created_at        timestamptz not null default now(),

  constraint poi_localized_names_poi_fk
    foreign key (poi_id)
    references public.pois(poi_id)
    on delete cascade,
  constraint poi_localized_names_source_fk
    foreign key (source_id)
    references public.poi_sources(source_id),
  constraint poi_localized_names_type_check
    check (name_type in (
      'canonical',
      'alias',
      'transliteration',
      'historic',
      'local',
      'search'
    )),
  constraint poi_localized_names_locale_check
    check (locale ~ '^[a-z]{2}(-[A-Z]{2})?$'),
  constraint poi_localized_names_unique
    unique (poi_id, locale, normalized_name, name_type)
);

comment on table public.poi_localized_names is
  'Multilingual canonical names, aliases, local names, and search variants.';

create index if not exists poi_localized_names_poi_id_idx
  on public.poi_localized_names (poi_id);

create index if not exists poi_localized_names_locale_idx
  on public.poi_localized_names (locale);

create index if not exists poi_localized_names_normalized_idx
  on public.poi_localized_names (normalized_name);

create index if not exists poi_localized_names_primary_idx
  on public.poi_localized_names (is_primary) where is_primary = true;

-- =============================================================================
-- 4. Destination links
-- =============================================================================

create table if not exists public.poi_destination_links (
  link_id              uuid        primary key default gen_random_uuid(),
  poi_id               uuid        not null,
  destination_key      text        not null,
  destination_scope    text        not null,
  country_code         text,
  city_key             text,
  admin_key            text,
  zone_key             text,
  zone_key_value       text        generated always as (coalesce(zone_key, '')) stored,
  distance_to_center_m integer,
  relevance_score      integer,
  is_primary           boolean     not null default false,
  created_at           timestamptz not null default now(),

  constraint poi_destination_links_poi_fk
    foreign key (poi_id)
    references public.pois(poi_id)
    on delete cascade,
  constraint poi_destination_links_scope_check
    check (destination_scope in (
      'city',
      'metro',
      'region',
      'country',
      'zone',
      'day_trip'
    )),
  constraint poi_destination_links_country_code_check
    check (country_code is null or country_code ~ '^[A-Z]{2}$'),
  constraint poi_destination_links_relevance_check
    check (relevance_score is null or (relevance_score >= 0 and relevance_score <= 100)),
  constraint poi_destination_links_distance_check
    check (distance_to_center_m is null or distance_to_center_m >= 0),
  constraint poi_destination_links_unique
    unique (poi_id, destination_key, destination_scope, zone_key_value)
);

comment on table public.poi_destination_links is
  'Links POIs to canonical destinations, regions, cities, zones, and day-trip scopes.';

create index if not exists poi_destination_links_poi_id_idx
  on public.poi_destination_links (poi_id);

create index if not exists poi_destination_links_destination_key_idx
  on public.poi_destination_links (destination_key);

create index if not exists poi_destination_links_scope_idx
  on public.poi_destination_links (destination_scope);

create index if not exists poi_destination_links_country_code_idx
  on public.poi_destination_links (country_code);

create index if not exists poi_destination_links_city_key_idx
  on public.poi_destination_links (city_key);

create index if not exists poi_destination_links_zone_key_idx
  on public.poi_destination_links (zone_key);

create index if not exists poi_destination_links_relevance_idx
  on public.poi_destination_links (relevance_score);

create index if not exists poi_destination_links_primary_idx
  on public.poi_destination_links (is_primary) where is_primary = true;

-- =============================================================================
-- 5. External references
-- =============================================================================

create table if not exists public.poi_external_refs (
  external_ref_id uuid        primary key default gen_random_uuid(),
  poi_id          uuid        not null,
  source_id       uuid        not null,
  ref_type        text        not null,
  ref_value       text        not null,
  source_url      text,
  source_payload  jsonb       not null default '{}',
  fetched_at      timestamptz,
  verified_at     timestamptz,
  created_at      timestamptz not null default now(),

  constraint poi_external_refs_poi_fk
    foreign key (poi_id)
    references public.pois(poi_id)
    on delete cascade,
  constraint poi_external_refs_source_fk
    foreign key (source_id)
    references public.poi_sources(source_id),
  constraint poi_external_refs_type_check
    check (ref_type in (
      'osm_node',
      'osm_way',
      'osm_relation',
      'wikidata_qid',
      'wikipedia_page',
      'official_url',
      'google_place_id',
      'tripadvisor_url',
      'manual_slug'
    )),
  constraint poi_external_refs_value_check
    check (length(trim(ref_value)) > 0),
  constraint poi_external_refs_unique
    unique (source_id, ref_type, ref_value)
);

comment on table public.poi_external_refs is
  'Stable source identifiers such as OSM IDs, Wikidata QIDs, Wikipedia pages, and controlled Google place IDs.';
comment on column public.poi_external_refs.source_payload is
  'Raw source fragment retained for audit and deterministic reprocessing.';

create index if not exists poi_external_refs_poi_id_idx
  on public.poi_external_refs (poi_id);

create index if not exists poi_external_refs_source_id_idx
  on public.poi_external_refs (source_id);

create index if not exists poi_external_refs_ref_type_idx
  on public.poi_external_refs (ref_type);

create index if not exists poi_external_refs_ref_lookup_idx
  on public.poi_external_refs (ref_type, ref_value);

create index if not exists poi_external_refs_verified_at_idx
  on public.poi_external_refs (verified_at);

create index if not exists poi_external_refs_payload_gin_idx
  on public.poi_external_refs using gin (source_payload);

-- =============================================================================
-- 6. Deterministic quality score snapshots
-- =============================================================================

create table if not exists public.poi_quality_scores (
  poi_id                uuid        primary key,
  touristic_importance  integer,
  editorial_score       integer,
  source_confidence     integer,
  rating_score          integer,
  review_confidence     integer,
  category_priority     integer,
  duplicate_confidence  integer,
  freshness_score       integer,
  overall_score         integer     not null,
  score_version         text        not null,
  computed_at           timestamptz not null default now(),
  explanation           jsonb       not null default '{}',

  constraint poi_quality_scores_poi_fk
    foreign key (poi_id)
    references public.pois(poi_id)
    on delete cascade,
  constraint poi_quality_scores_touristic_check
    check (touristic_importance is null or (touristic_importance >= 1 and touristic_importance <= 5)),
  constraint poi_quality_scores_editorial_check
    check (editorial_score is null or (editorial_score >= 0 and editorial_score <= 100)),
  constraint poi_quality_scores_source_check
    check (source_confidence is null or (source_confidence >= 0 and source_confidence <= 100)),
  constraint poi_quality_scores_rating_check
    check (rating_score is null or (rating_score >= 0 and rating_score <= 100)),
  constraint poi_quality_scores_review_check
    check (review_confidence is null or (review_confidence >= 0 and review_confidence <= 100)),
  constraint poi_quality_scores_category_check
    check (category_priority is null or (category_priority >= 0 and category_priority <= 100)),
  constraint poi_quality_scores_duplicate_check
    check (duplicate_confidence is null or (duplicate_confidence >= 0 and duplicate_confidence <= 100)),
  constraint poi_quality_scores_freshness_check
    check (freshness_score is null or (freshness_score >= 0 and freshness_score <= 100)),
  constraint poi_quality_scores_overall_check
    check (overall_score >= 0 and overall_score <= 100)
);

comment on table public.poi_quality_scores is
  'Deterministic score snapshot used for ranking, QA, and planning inputs.';

create index if not exists poi_quality_scores_overall_idx
  on public.poi_quality_scores (overall_score);

create index if not exists poi_quality_scores_touristic_idx
  on public.poi_quality_scores (touristic_importance);

create index if not exists poi_quality_scores_version_idx
  on public.poi_quality_scores (score_version);

create index if not exists poi_quality_scores_computed_at_idx
  on public.poi_quality_scores (computed_at);

create index if not exists poi_quality_scores_explanation_gin_idx
  on public.poi_quality_scores using gin (explanation);

-- =============================================================================
-- 7. Import batches and issues
-- =============================================================================

create table if not exists public.poi_import_batches (
  batch_id        uuid        primary key default gen_random_uuid(),
  batch_type      text        not null,
  destination_key text,
  source_id       uuid,
  input_uri       text,
  input_hash      text,
  status          text        not null default 'planned',
  dry_run         boolean     not null default true,
  started_at      timestamptz,
  finished_at     timestamptz,
  created_by      text,
  summary         jsonb       not null default '{}',
  created_at      timestamptz not null default now(),
  updated_at      timestamptz not null default now(),

  constraint poi_import_batches_source_fk
    foreign key (source_id)
    references public.poi_sources(source_id),
  constraint poi_import_batches_type_check
    check (batch_type in (
      'fixture',
      'osm_overpass',
      'wikidata',
      'wikipedia',
      'manual',
      'google_enrichment',
      'quality_recompute'
    )),
  constraint poi_import_batches_status_check
    check (status in (
      'planned',
      'running',
      'succeeded',
      'failed',
      'blocked',
      'review_required'
    )),
  constraint poi_import_batches_finished_check
    check (finished_at is null or started_at is null or finished_at >= started_at)
);

comment on table public.poi_import_batches is
  'Auditable import/enrichment runs. Tooling table; no client write policies.';
comment on column public.poi_import_batches.input_hash is
  'Stable hash of source fixture/export for idempotence and audit.';

create unique index if not exists poi_import_batches_input_hash_unique_idx
  on public.poi_import_batches (destination_key, source_id, input_hash)
  where input_hash is not null;

create index if not exists poi_import_batches_destination_key_idx
  on public.poi_import_batches (destination_key);

create index if not exists poi_import_batches_source_id_idx
  on public.poi_import_batches (source_id);

create index if not exists poi_import_batches_type_idx
  on public.poi_import_batches (batch_type);

create index if not exists poi_import_batches_status_idx
  on public.poi_import_batches (status);

create index if not exists poi_import_batches_started_at_idx
  on public.poi_import_batches (started_at);

create index if not exists poi_import_batches_summary_gin_idx
  on public.poi_import_batches using gin (summary);

create table if not exists public.poi_import_issues (
  issue_id    uuid        primary key default gen_random_uuid(),
  batch_id    uuid        not null,
  poi_id      uuid,
  severity    text        not null,
  issue_type  text        not null,
  message     text        not null,
  source_ref  text,
  payload     jsonb       not null default '{}',
  resolved_at timestamptz,
  resolved_by text,
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now(),

  constraint poi_import_issues_batch_fk
    foreign key (batch_id)
    references public.poi_import_batches(batch_id)
    on delete cascade,
  constraint poi_import_issues_poi_fk
    foreign key (poi_id)
    references public.pois(poi_id),
  constraint poi_import_issues_severity_check
    check (severity in ('info', 'warning', 'error', 'blocking')),
  constraint poi_import_issues_type_check
    check (length(trim(issue_type)) > 0),
  constraint poi_import_issues_message_check
    check (length(trim(message)) > 0)
);

comment on table public.poi_import_issues is
  'Validation, mapping, duplicate, licensing, and review issues detected during imports.';

create index if not exists poi_import_issues_batch_id_idx
  on public.poi_import_issues (batch_id);

create index if not exists poi_import_issues_poi_id_idx
  on public.poi_import_issues (poi_id);

create index if not exists poi_import_issues_severity_idx
  on public.poi_import_issues (severity);

create index if not exists poi_import_issues_type_idx
  on public.poi_import_issues (issue_type);

create index if not exists poi_import_issues_resolved_at_idx
  on public.poi_import_issues (resolved_at);

create index if not exists poi_import_issues_payload_gin_idx
  on public.poi_import_issues using gin (payload);

-- =============================================================================
-- 8. Editorial overrides
-- =============================================================================

create table if not exists public.poi_editorial_overrides (
  override_id uuid        primary key default gen_random_uuid(),
  poi_id      uuid        not null,
  field_name  text        not null,
  value       jsonb       not null,
  reason      text,
  priority    integer     not null default 100,
  created_by  text,
  expires_at  timestamptz,
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now(),

  constraint poi_editorial_overrides_poi_fk
    foreign key (poi_id)
    references public.pois(poi_id)
    on delete cascade,
  constraint poi_editorial_overrides_priority_check
    check (priority >= 0 and priority <= 1000),
  constraint poi_editorial_overrides_field_check
    check (length(trim(field_name)) > 0)
);

comment on table public.poi_editorial_overrides is
  'Manual editorial corrections kept separate from imported source facts.';

create unique index if not exists poi_editorial_overrides_active_field_unique_idx
  on public.poi_editorial_overrides (poi_id, field_name)
  where expires_at is null;

create index if not exists poi_editorial_overrides_poi_id_idx
  on public.poi_editorial_overrides (poi_id);

create index if not exists poi_editorial_overrides_field_name_idx
  on public.poi_editorial_overrides (field_name);

create index if not exists poi_editorial_overrides_priority_idx
  on public.poi_editorial_overrides (priority);

create index if not exists poi_editorial_overrides_expires_at_idx
  on public.poi_editorial_overrides (expires_at);

-- =============================================================================
-- 9. RLS policies
-- =============================================================================

alter table public.poi_categories enable row level security;
alter table public.poi_localized_names enable row level security;
alter table public.poi_destination_links enable row level security;
alter table public.poi_external_refs enable row level security;
alter table public.poi_quality_scores enable row level security;
alter table public.poi_import_batches enable row level security;
alter table public.poi_import_issues enable row level security;
alter table public.poi_editorial_overrides enable row level security;

-- Public/config POI read surfaces. Writes remain service_role only.
drop policy if exists "poi_categories_read_all" on public.poi_categories;
create policy "poi_categories_read_all"
  on public.poi_categories
  for select
  using (true);

drop policy if exists "poi_localized_names_read_all" on public.poi_localized_names;
create policy "poi_localized_names_read_all"
  on public.poi_localized_names
  for select
  using (true);

drop policy if exists "poi_destination_links_read_all" on public.poi_destination_links;
create policy "poi_destination_links_read_all"
  on public.poi_destination_links
  for select
  using (true);

drop policy if exists "poi_external_refs_read_all" on public.poi_external_refs;
create policy "poi_external_refs_read_all"
  on public.poi_external_refs
  for select
  using (true);

drop policy if exists "poi_quality_scores_read_all" on public.poi_quality_scores;
create policy "poi_quality_scores_read_all"
  on public.poi_quality_scores
  for select
  using (true);

-- Operational/editorial tables intentionally have no anon/authenticated
-- policies in the MVP. Service_role bypasses RLS for imports/admin review.

-- =============================================================================
-- 10. updated_at triggers for MVP tables
-- =============================================================================

drop trigger if exists poi_categories_updated_at on public.poi_categories;
create trigger poi_categories_updated_at
  before update on public.poi_categories
  for each row
  execute function public.poi_mvp_set_updated_at();

drop trigger if exists poi_import_batches_updated_at on public.poi_import_batches;
create trigger poi_import_batches_updated_at
  before update on public.poi_import_batches
  for each row
  execute function public.poi_mvp_set_updated_at();

drop trigger if exists poi_import_issues_updated_at on public.poi_import_issues;
create trigger poi_import_issues_updated_at
  before update on public.poi_import_issues
  for each row
  execute function public.poi_mvp_set_updated_at();

drop trigger if exists poi_editorial_overrides_updated_at on public.poi_editorial_overrides;
create trigger poi_editorial_overrides_updated_at
  before update on public.poi_editorial_overrides
  for each row
  execute function public.poi_mvp_set_updated_at();
