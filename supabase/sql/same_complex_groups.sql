-- Phase 2 / Tâche 2.1 — Schéma Supabase pour `SameComplexGroup`.
--
-- Table de configuration des "complexes touristiques" (groupes de
-- lieux Google Places différents mais sémantiquement le même
-- complexe pour un voyageur — ex: Sentosa Island / Universal
-- Studios / Resorts World Sentosa). Le `payload` JSONB contient
-- l'objet complet sérialisé (cf.
-- `lib/models/same_complex_group.dart` — `toJson()` /
-- `fromJson()`). Les colonnes top-level dupliquent quelques
-- champs du payload pour permettre des requêtes filtrées rapides
-- et indexer alias / place_ids en GIN sans parser le JSON.
--
-- **Aucun seed dans cette migration.** Les données Singapour
-- arriveront en Tâche 2.2. Cette migration crée uniquement la
-- table vide + indexes + RLS + trigger. Convention alignée sur
-- `supabase/sql/destination_intelligence.sql` (Tâche 1.1).
--
-- À appliquer une fois dans le SQL editor Supabase. Idempotent
-- via `if not exists` et `drop / create` pour policies + trigger.
--
-- ## Convention de payload
--
-- Le `payload` JSONB contient l'objet complet avec clés
-- **snake_case** (cohérent avec `destination_intelligence`).
--
-- Exemple `payload` (extrait — données indicatives, pas seed) :
-- {
--   "complex_key": "sentosa",
--   "destination_key": "singapore",
--   "aliases": [
--     "Sentosa Island",
--     "Universal Studios Singapore",
--     "Resorts World Sentosa"
--   ],
--   "place_ids": [],
--   "max_per_day": 1,
--   "max_per_trip": 2,
--   "priority": 5
-- }
--
-- ## Clé primaire
--
-- `(destination_key, complex_key)` car le même `complex_key`
-- pourrait être réutilisé pour des destinations différentes (cas
-- d'homonymie improbable mais légal). Cf. modèle Dart : aucune
-- contrainte d'unicité globale sur `complex_key`.

create table if not exists public.same_complex_groups (
  destination_key  text        not null,
  complex_key      text        not null,
  aliases          jsonb       not null default '[]'::jsonb,
  place_ids        jsonb       not null default '[]'::jsonb,
  max_per_day      integer     not null default 1,
  max_per_trip     integer     not null default 2,
  priority         integer     not null default 3,
  payload          jsonb       not null,
  created_at       timestamptz not null default now(),
  updated_at       timestamptz not null default now(),
  primary key (destination_key, complex_key)
);

-- Indexes B-tree pour les filtres courants attendus côté loader /
-- matcher (Tâche 2.3+).
create index if not exists same_complex_groups_destination_key_idx
  on public.same_complex_groups (destination_key);

create index if not exists same_complex_groups_complex_key_idx
  on public.same_complex_groups (complex_key);

-- Indexes GIN pour les recherches "any alias / place_id matches".
-- Le matcher Tâche 2.3 pourra requêter
--   `where aliases @> '["Sentosa Island"]'::jsonb`
-- ou
--   `where place_ids @> '["ChIJxxxx"]'::jsonb`
-- en milliseconde sur des dizaines de milliers de lignes.
create index if not exists same_complex_groups_aliases_gin_idx
  on public.same_complex_groups using gin (aliases);

create index if not exists same_complex_groups_place_ids_gin_idx
  on public.same_complex_groups using gin (place_ids);

create index if not exists same_complex_groups_payload_gin_idx
  on public.same_complex_groups using gin (payload);

-- RLS : lecture publique (authenticated + anon), écriture
-- réservée au service_role (admin via dashboard / migrations
-- seed). Convention alignée sur `destination_intelligence.sql` et
-- `feature_flags.sql`.
alter table public.same_complex_groups enable row level security;

drop policy if exists "same_complex_groups_read_all"
  on public.same_complex_groups;
create policy "same_complex_groups_read_all"
  on public.same_complex_groups
  for select
  using (true);

-- Pas de policy insert/update/delete → écriture impossible depuis
-- client anon/authenticated. Service_role bypasse RLS pour les
-- mises à jour admin.

-- Trigger updated_at automatique. Idempotent via drop/create.
-- Cohérent avec `destination_intelligence_set_updated_at`.
create or replace function public.same_complex_groups_set_updated_at()
returns trigger
language plpgsql
as $$
begin
  new.updated_at = now();
  return new;
end;
$$;

drop trigger if exists same_complex_groups_updated_at
  on public.same_complex_groups;
create trigger same_complex_groups_updated_at
  before update on public.same_complex_groups
  for each row
  execute function public.same_complex_groups_set_updated_at();
