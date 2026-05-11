-- Phase 1 / Tâche 1.1 — Schéma Supabase pour `DestinationIntelligence`.
--
-- Table de configuration des destinations Lunao. Le payload JSONB
-- contient le modèle complet sérialisé (cf.
-- `lib/models/destination_intelligence.dart` — `toJson()` /
-- `fromJson()`). Les colonnes top-level dupliquent quelques champs
-- du payload pour permettre des requêtes filtrées rapides
-- (`country_code`, `trip_mode`, `border_sensitivity`) sans parser
-- le JSON.
--
-- **Aucun seed dans cette migration.** Le seed Singapour viendra
-- dans la Tâche 1.2. Cette migration crée uniquement la table
-- vide + indexes + RLS.
--
-- À appliquer une fois dans le SQL editor Supabase. Convention
-- alignée sur les autres fichiers `supabase/sql/*` du projet
-- (`feature_flags.sql`, `country_regions.sql`, etc.).
--
-- ## Convention de payload
--
-- Le `payload` JSONB contient l'objet complet avec clés
-- **snake_case** (cohérent avec les autres modèles Flutter du
-- projet : `day_date`, `start_time`, `country_code`, etc.). Cf.
-- `lib/models/destination_intelligence.dart` pour le schéma exact.
--
-- Exemple `payload` (extrait) :
-- {
--   "destination_key": "singapore",
--   "canonical_center": { "lat": 1.3521, "lng": 103.8198 },
--   "country_code": "SG",
--   "allowed_country_codes": ["SG"],
--   "blocked_country_codes": ["MY", "ID"],
--   "border_sensitivity": "high",
--   "trip_mode": "megaCity",
--   "zones": [...],
--   "anchors": [...],
--   "transport_rules": {...}
-- }

create table if not exists public.destination_intelligence (
  destination_key     text        primary key,
  country_code        text        not null,
  trip_mode           text        not null,
  border_sensitivity  text        not null,
  payload             jsonb       not null,
  created_at          timestamptz not null default now(),
  updated_at          timestamptz not null default now()
);

-- Indexes pour les requêtes filtrées courantes attendues côté
-- loader. Tous `if not exists` pour idempotence.
create index if not exists destination_intelligence_country_code_idx
  on public.destination_intelligence (country_code);

create index if not exists destination_intelligence_trip_mode_idx
  on public.destination_intelligence (trip_mode);

create index if not exists destination_intelligence_border_sensitivity_idx
  on public.destination_intelligence (border_sensitivity);

-- Index GIN pour les requêtes JSON `payload @> '{...}'` (futur loader
-- pourrait filtrer par `payload->'allowed_country_codes' ? 'SG'`,
-- etc.).
create index if not exists destination_intelligence_payload_gin_idx
  on public.destination_intelligence using gin (payload);

-- RLS : lecture publique (authenticated + anon), écriture réservée
-- au service_role (admin via dashboard Supabase / migrations seed).
-- Convention alignée sur `feature_flags.sql` et `country_regions.sql`.
alter table public.destination_intelligence enable row level security;

drop policy if exists "destination_intelligence_read_all"
  on public.destination_intelligence;
create policy "destination_intelligence_read_all"
  on public.destination_intelligence
  for select
  using (true);

-- Pas de policy insert/update/delete → écriture impossible depuis
-- client anon/authenticated. Service_role bypasse RLS pour les
-- mises à jour admin.

-- Trigger updated_at automatique. Idempotent via drop/create.
create or replace function public.destination_intelligence_set_updated_at()
returns trigger
language plpgsql
as $$
begin
  new.updated_at = now();
  return new;
end;
$$;

drop trigger if exists destination_intelligence_updated_at
  on public.destination_intelligence;
create trigger destination_intelligence_updated_at
  before update on public.destination_intelligence
  for each row
  execute function public.destination_intelligence_set_updated_at();
