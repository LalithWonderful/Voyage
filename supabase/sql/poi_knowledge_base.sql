-- POI-0.1 — Schéma Supabase pour la base de connaissances POI Lunao.
--
-- Cette migration crée 6 tables vides, leurs indexes, contraintes,
-- RLS et triggers updated_at. Aucune donnée réelle n'est insérée.
--
-- Convention alignée sur :
--   - destination_intelligence.sql (Tâche 1.1)
--   - same_complex_groups.sql (Tâche 2.1)
--   - day_templates.sql (Tâche 4.1)
--
-- Idempotente via `if not exists` et `drop / create` pour policies
-- et triggers.
--
-- À appliquer une fois dans le SQL editor Supabase (staging puis prod).

-- =============================================================================
-- 1. poi_sources — référentiel des sources de données autorisées
-- =============================================================================

create table if not exists public.poi_sources (
  source_id       uuid        primary key default gen_random_uuid(),
  name            text        not null,
  source_type     text        not null,
  base_url        text,
  license_name    text,
  license_url     text,
  trust_level     integer     not null default 3,
  is_active       boolean     not null default true,
  notes           text,
  created_at      timestamptz not null default now(),
  updated_at      timestamptz not null default now(),

  constraint poi_sources_trust_level_check
    check (trust_level >= 1 and trust_level <= 5),
  constraint poi_sources_source_type_check
    check (source_type in (
      'official_board', 'official_venue', 'unesco',
      'wikidata', 'openstreetmap', 'open_data_gov', 'editorial'
    ))
);

comment on table public.poi_sources is 'Référentiel des sources de données POI autorisées';
comment on column public.poi_sources.source_type is 'Type de source : official_board, official_venue, unesco, wikidata, openstreetmap, open_data_gov, editorial';
comment on column public.poi_sources.trust_level is 'Niveau de confiance éditorial : 1 (faible) à 5 (officiel)';

create index if not exists poi_sources_source_type_idx
  on public.poi_sources (source_type);

create index if not exists poi_sources_trust_level_idx
  on public.poi_sources (trust_level);

-- =============================================================================
-- 2. pois — cœur de la base de connaissances
-- =============================================================================

create table if not exists public.pois (
  poi_id                   uuid             primary key default gen_random_uuid(),
  destination_key          text             not null,
  name                     text             not null,
  normalized_name          text             not null,
  category                 text             not null,
  subcategory              text,
  lat                      double precision,
  lng                      double precision,
  address                  text,
  country_code             text,
  zone_name                text,
  official_url             text,
  source_primary_id        uuid             not null,
  editorial_score          integer,
  touristic_importance     integer,
  is_must_see              boolean          not null default false,
  is_family_friendly       boolean,
  is_rain_friendly         boolean,
  is_free                  boolean,
  typical_duration_minutes integer,
  opening_notes            text,
  price_level              integer,
  google_place_id          text,
  same_complex_group_key   text,
  payload                  jsonb            not null default '{}',
  created_at               timestamptz      not null default now(),
  updated_at               timestamptz      not null default now(),

  constraint pois_source_primary_id_fk
    foreign key (source_primary_id) references public.poi_sources(source_id),

  constraint pois_lat_check
    check (lat is null or (lat >= -90 and lat <= 90)),
  constraint pois_lng_check
    check (lng is null or (lng >= -180 and lng <= 180)),
  constraint pois_editorial_score_check
    check (editorial_score is null or (editorial_score >= 0 and editorial_score <= 100)),
  constraint pois_touristic_importance_check
    check (touristic_importance is null or (touristic_importance >= 1 and touristic_importance <= 5)),
  constraint pois_price_level_check
    check (price_level is null or (price_level >= 1 and price_level <= 4)),
  constraint pois_typical_duration_check
    check (typical_duration_minutes is null or typical_duration_minutes > 0),
  constraint pois_category_check
    check (category in (
      'must_see', 'museum', 'monument', 'viewpoint', 'park',
      'nature', 'beach', 'neighborhood', 'market', 'food',
      'shopping', 'nightlife', 'family', 'wellness',
      'transport_hub', 'photo_spot', 'rainy_day', 'local_experience'
    ))
);

comment on table public.pois is 'Lieux touristiques de référence Lunao';
comment on column public.pois.destination_key is 'Clé destination (ex: singapore) — cohérent avec DestinationIntelligence';
comment on column public.pois.normalized_name is 'Nom normalisé (lower, trim, collapse espaces) pour matching';
comment on column public.pois.editorial_score is 'Score qualité Lunao 0-100';
comment on column public.pois.touristic_importance is 'Importance touristique 1-5, aligné sur DestinationAnchor.importance';
comment on column public.pois.google_place_id is 'Place ID Google pour enrichissement futur contrôlé';
comment on column public.pois.same_complex_group_key is 'Référence vers same_complex_groups.complex_key (Phase 2+)';
comment on column public.pois.payload is 'Champs extensibles futurs sans migration';

create index if not exists pois_destination_key_idx
  on public.pois (destination_key);

create index if not exists pois_category_idx
  on public.pois (category);

create index if not exists pois_subcategory_idx
  on public.pois (subcategory);

create index if not exists pois_normalized_name_idx
  on public.pois (normalized_name);

create index if not exists pois_country_code_idx
  on public.pois (country_code);

create index if not exists pois_zone_name_idx
  on public.pois (zone_name);

create index if not exists pois_google_place_id_idx
  on public.pois (google_place_id);

create index if not exists pois_same_complex_group_key_idx
  on public.pois (same_complex_group_key);

create index if not exists pois_editorial_score_idx
  on public.pois (editorial_score);

create index if not exists pois_touristic_importance_idx
  on public.pois (touristic_importance);

create index if not exists pois_is_must_see_idx
  on public.pois (is_must_see) where is_must_see = true;

create index if not exists pois_payload_gin_idx
  on public.pois using gin (payload);

-- =============================================================================
-- 3. poi_aliases — noms alternatifs pour matching et recherche
-- =============================================================================

create table if not exists public.poi_aliases (
  alias_id          uuid        primary key default gen_random_uuid(),
  poi_id            uuid        not null,
  alias             text        not null,
  alias_normalized  text        not null,
  is_canonical      boolean     not null default false,
  source_id         uuid,
  created_at        timestamptz not null default now(),

  constraint poi_aliases_poi_id_fk
    foreign key (poi_id) references public.pois(poi_id) on delete cascade,
  constraint poi_aliases_source_id_fk
    foreign key (source_id) references public.poi_sources(source_id),
  constraint poi_aliases_unique_normalized
    unique (poi_id, alias_normalized)
);

comment on table public.poi_aliases is 'Noms alternatifs des POI pour matching et déduplication';
comment on column public.poi_aliases.alias_normalized is 'Alias normalisé (lower, trim, collapse espaces)';
comment on column public.poi_aliases.is_canonical is 'True si cet alias est le nom privilégié par la source';

create index if not exists poi_aliases_poi_id_idx
  on public.poi_aliases (poi_id);

create index if not exists poi_aliases_alias_normalized_idx
  on public.poi_aliases (alias_normalized);

-- =============================================================================
-- 4. poi_source_links — traçabilité fine POI ↔ source externe
-- =============================================================================

create table if not exists public.poi_source_links (
  link_id                      uuid        primary key default gen_random_uuid(),
  poi_id                       uuid        not null,
  source_id                    uuid        not null,
  source_poi_identifier        text,
  source_poi_identifier_key    text        generated always as (coalesce(source_poi_identifier, '')) stored,
  source_url                   text,
  source_raw_data              jsonb       not null default '{}',
  verified_at                  timestamptz,
  created_at                   timestamptz not null default now(),

  constraint poi_source_links_poi_id_fk
    foreign key (poi_id) references public.pois(poi_id) on delete cascade,
  constraint poi_source_links_source_id_fk
    foreign key (source_id) references public.poi_sources(source_id),
  constraint poi_source_links_unique_link
    unique (poi_id, source_id, source_poi_identifier_key)
);

comment on table public.poi_source_links is 'Liens de traçabilité entre un POI et ses sources externes';
comment on column public.poi_source_links.source_poi_identifier is 'Identifiant brut du POI dans la source (ex: Q12345 pour Wikidata)';
comment on column public.poi_source_links.source_raw_data is 'Données brutes stockées pour audit';

create index if not exists poi_source_links_poi_id_idx
  on public.poi_source_links (poi_id);

create index if not exists poi_source_links_source_id_idx
  on public.poi_source_links (source_id);

-- =============================================================================
-- 5. poi_tags — tags sémantiques granulaires
-- =============================================================================

create table if not exists public.poi_tags (
  tag_id        uuid        primary key default gen_random_uuid(),
  poi_id        uuid        not null,
  tag           text        not null,
  tag_category  text,
  confidence    integer,
  source_id     uuid,
  created_at    timestamptz not null default now(),

  constraint poi_tags_poi_id_fk
    foreign key (poi_id) references public.pois(poi_id) on delete cascade,
  constraint poi_tags_source_id_fk
    foreign key (source_id) references public.poi_sources(source_id),
  constraint poi_tags_confidence_check
    check (confidence is null or (confidence >= 0 and confidence <= 100))
);

comment on table public.poi_tags is 'Tags sémantiques des POI (vibe, accessibilité, audience, etc.)';
comment on column public.poi_tags.tag_category is 'Catégorie du tag : vibe, accessibility, activity_type, audience, season';
comment on column public.poi_tags.confidence is 'Confiance dans le tag, 0-100';

create index if not exists poi_tags_poi_id_idx
  on public.poi_tags (poi_id);

create index if not exists poi_tags_tag_idx
  on public.poi_tags (tag);

create index if not exists poi_tags_tag_category_idx
  on public.poi_tags (tag_category);

-- =============================================================================
-- 6. poi_quality_flags — signalements qualité et maintenance
-- =============================================================================

create table if not exists public.poi_quality_flags (
  flag_id           uuid        primary key default gen_random_uuid(),
  poi_id            uuid        not null,
  flag_type         text        not null,
  flag_reason       text,
  reported_by       text,
  resolved_at       timestamptz,
  resolution_notes  text,
  created_at        timestamptz not null default now(),

  constraint poi_quality_flags_poi_id_fk
    foreign key (poi_id) references public.pois(poi_id) on delete cascade,
  constraint poi_quality_flags_flag_type_check
    check (flag_type in (
      'duplicate', 'location_inaccurate', 'name_disputed',
      'closed', 'deprecated', 'needs_review'
    ))
);

comment on table public.poi_quality_flags is 'Signalements qualité pour la curation des POI';
comment on column public.poi_quality_flags.flag_type is 'Type de signalement : duplicate, location_inaccurate, name_disputed, closed, deprecated, needs_review';
comment on column public.poi_quality_flags.reported_by is 'system, admin, ou user:<uuid>';

create index if not exists poi_quality_flags_poi_id_idx
  on public.poi_quality_flags (poi_id);

create index if not exists poi_quality_flags_flag_type_idx
  on public.poi_quality_flags (flag_type);

create index if not exists poi_quality_flags_resolved_at_idx
  on public.poi_quality_flags (resolved_at);

-- =============================================================================
-- 7. RLS — lecture publique, écriture réservée au service_role
-- =============================================================================

alter table public.poi_sources enable row level security;
alter table public.pois enable row level security;
alter table public.poi_aliases enable row level security;
alter table public.poi_source_links enable row level security;
alter table public.poi_tags enable row level security;
alter table public.poi_quality_flags enable row level security;

-- poi_sources
drop policy if exists "poi_sources_read_all" on public.poi_sources;
create policy "poi_sources_read_all"
  on public.poi_sources for select using (true);

-- pois
drop policy if exists "pois_read_all" on public.pois;
create policy "pois_read_all"
  on public.pois for select using (true);

-- poi_aliases
drop policy if exists "poi_aliases_read_all" on public.poi_aliases;
create policy "poi_aliases_read_all"
  on public.poi_aliases for select using (true);

-- poi_source_links
drop policy if exists "poi_source_links_read_all" on public.poi_source_links;
create policy "poi_source_links_read_all"
  on public.poi_source_links for select using (true);

-- poi_tags
drop policy if exists "poi_tags_read_all" on public.poi_tags;
create policy "poi_tags_read_all"
  on public.poi_tags for select using (true);

-- poi_quality_flags
drop policy if exists "poi_quality_flags_read_all" on public.poi_quality_flags;
create policy "poi_quality_flags_read_all"
  on public.poi_quality_flags for select using (true);

-- Aucune policy insert/update/delete côté client.
-- Seul service_role peut écrire (admin dashboard, migrations, edge functions).

-- =============================================================================
-- 8. Triggers updated_at automatiques
-- =============================================================================

-- poi_sources
create or replace function public.poi_sources_set_updated_at()
returns trigger language plpgsql as $$
begin new.updated_at = now(); return new; end;
$$;

drop trigger if exists poi_sources_updated_at on public.poi_sources;
create trigger poi_sources_updated_at
  before update on public.poi_sources
  for each row execute function public.poi_sources_set_updated_at();

-- pois
create or replace function public.pois_set_updated_at()
returns trigger language plpgsql as $$
begin new.updated_at = now(); return new; end;
$$;

drop trigger if exists pois_updated_at on public.pois;
create trigger pois_updated_at
  before update on public.pois
  for each row execute function public.pois_set_updated_at();

-- =============================================================================
-- 9. Contraintes uniques additives (POI-1.3)
-- =============================================================================
-- Ajout de contraintes uniques sur les tables filles pour permettre
-- l'upsert idempotent côté client via PostgREST.

-- poi_source_links — migrate existing tables to generated column + unique constraint
alter table public.poi_source_links
  add column if not exists source_poi_identifier_key text
  generated always as (coalesce(source_poi_identifier, '')) stored;

drop index if exists poi_source_links_unique_link;

do $$
begin
  if not exists (
    select 1
    from pg_constraint
    where conname = 'poi_source_links_unique_link'
      and conrelid = 'public.poi_source_links'::regclass
  ) then
    alter table public.poi_source_links
      add constraint poi_source_links_unique_link
      unique (poi_id, source_id, source_poi_identifier_key);
  end if;
end $$;

do $$
begin
  if not exists (
    select 1
    from pg_constraint
    where conname = 'poi_tags_unique_tag'
      and conrelid = 'public.poi_tags'::regclass
  ) then
    alter table public.poi_tags
      add constraint poi_tags_unique_tag
      unique (poi_id, tag);
  end if;
end $$;

do $$
begin
  if not exists (
    select 1
    from pg_constraint
    where conname = 'poi_quality_flags_unique_flag'
      and conrelid = 'public.poi_quality_flags'::regclass
  ) then
    alter table public.poi_quality_flags
      add constraint poi_quality_flags_unique_flag
      unique (poi_id, flag_type, flag_reason);
  end if;
end $$;
