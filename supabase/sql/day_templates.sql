-- Phase 4 / Tâche 4.1 — Schéma Supabase pour `DayTemplate`.
--
-- Table de configuration des gabarits de journées thématiques par
-- destination. Le `payload` JSONB contient l'objet complet
-- sérialisé (cf. `lib/models/day_template.dart` — `toJson()` /
-- `fromJson()`). Les colonnes top-level dupliquent quelques
-- champs du payload pour permettre des requêtes filtrées rapides
-- (`destination_key`, `intensity`, `primary_zone_name`) sans
-- parser le JSON.
--
-- **Aucun seed dans cette migration.** Les templates Singapour
-- viendront en Tâche 4.2. Cette migration crée uniquement la
-- table vide + indexes + RLS + trigger. Convention alignée sur
-- `supabase/sql/destination_intelligence.sql` (Tâche 1.1) et
-- `supabase/sql/same_complex_groups.sql` (Tâche 2.1).
--
-- À appliquer une fois dans le SQL editor Supabase. Idempotent
-- via `if not exists` et `drop / create` pour policies + trigger.
--
-- ## Convention de payload
--
-- Le `payload` JSONB contient l'objet complet avec clés
-- **snake_case** (cohérent avec `destination_intelligence` et
-- `same_complex_groups`).
--
-- Exemple `payload` (extrait — données indicatives, pas seed) :
-- {
--   "template_key": "marina_bay_day",
--   "destination_key": "singapore",
--   "theme": "Marina Bay & waterfront icons",
--   "primary_zone_name": "Marina Bay",
--   "intensity": "medium",
--   "recommended_anchor_keys": ["Gardens by the Bay", "Marina Bay Sands"],
--   "forbidden_complex_keys": ["sentosa"],
--   "meal_strategy": "mixed",
--   "slots": [...],
--   "flexibility": 70
-- }
--
-- ## Clé primaire
--
-- `(destination_key, template_key)` — un même `template_key`
-- peut exister pour des destinations différentes (cas légal,
-- improbable mais permis). Cf. modèle Dart (PK composite cohérente
-- avec `same_complex_groups`).

create table if not exists public.day_templates (
  destination_key      text        not null,
  template_key         text        not null,
  theme                text        not null,
  primary_zone_name    text        not null,
  intensity            text        not null,
  meal_strategy        text        not null,
  flexibility          integer     not null default 50,
  payload              jsonb       not null,
  created_at           timestamptz not null default now(),
  updated_at           timestamptz not null default now(),
  primary key (destination_key, template_key)
);

-- Indexes B-tree pour les filtres courants (loader futur :
-- "tous les templates de Singapour", "tous les templates intense",
-- "tous les templates de la zone Marina Bay").
create index if not exists day_templates_destination_key_idx
  on public.day_templates (destination_key);

create index if not exists day_templates_intensity_idx
  on public.day_templates (intensity);

create index if not exists day_templates_primary_zone_name_idx
  on public.day_templates (primary_zone_name);

-- Index GIN pour les requêtes JSON profondes
-- (`payload @> '{"meal_strategy": "..."}'`,
--  `payload->'slots' @> '[{"expected_type":"anchor"}]'`, etc.).
create index if not exists day_templates_payload_gin_idx
  on public.day_templates using gin (payload);

-- RLS : lecture publique (authenticated + anon), écriture
-- réservée au service_role (admin via dashboard / migrations
-- seed). Convention alignée sur `destination_intelligence.sql`,
-- `same_complex_groups.sql`, `feature_flags.sql`.
alter table public.day_templates enable row level security;

drop policy if exists "day_templates_read_all"
  on public.day_templates;
create policy "day_templates_read_all"
  on public.day_templates
  for select
  using (true);

-- Pas de policy insert/update/delete → écriture impossible depuis
-- client anon/authenticated. Service_role bypasse RLS pour les
-- mises à jour admin.

-- Trigger updated_at automatique. Idempotent via drop/create.
create or replace function public.day_templates_set_updated_at()
returns trigger
language plpgsql
as $$
begin
  new.updated_at = now();
  return new;
end;
$$;

drop trigger if exists day_templates_updated_at
  on public.day_templates;
create trigger day_templates_updated_at
  before update on public.day_templates
  for each row
  execute function public.day_templates_set_updated_at();
