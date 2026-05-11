-- Phase 0 / Tâche 0.3 — Feature flags pour la refonte progressive
-- du moteur de planning Lunao.
--
-- Table de configuration runtime des 4 flags. Préparation Supabase :
-- la lecture réelle depuis Supabase N'EST PAS encore branchée
-- côté Flutter. La table existe pour qu'une phase future puisse
-- l'utiliser via `FeatureFlags.applyOverrides({ ... }) `.
--
-- À appliquer une fois dans le SQL editor Supabase. Convention
-- alignée sur les autres fichiers `supabase/sql/*` (ex.
-- `country_regions.sql`, `gemini_cache.sql`).
--
-- Les clés `key` sont en camelCase (cohérent avec les fields Dart
-- de `lib/config/feature_flags.dart` et avec les keys de
-- `applyOverrides(Map<String, dynamic>)`).

create table if not exists public.feature_flags (
  key         text        primary key,
  enabled     boolean     not null default false,
  description text,
  updated_at  timestamptz not null default now()
);

-- RLS : lecture pour tous (authenticated + anon). Écriture
-- réservée au service_role (admin Supabase / migrations seed).
-- Cohérent avec le pattern `country_regions.sql`.
alter table public.feature_flags enable row level security;

drop policy if exists "feature_flags_read_all" on public.feature_flags;
create policy "feature_flags_read_all"
  on public.feature_flags
  for select
  using (true);

-- Pas de policy insert/update/delete → écriture impossible depuis
-- client anon/authenticated. Service_role bypasse RLS pour les
-- mises à jour admin.

-- Trigger updated_at automatique. Idempotent via drop/create.
create or replace function public.feature_flags_set_updated_at()
returns trigger
language plpgsql
as $$
begin
  new.updated_at = now();
  return new;
end;
$$;

drop trigger if exists feature_flags_updated_at on public.feature_flags;
create trigger feature_flags_updated_at
  before update on public.feature_flags
  for each row
  execute function public.feature_flags_set_updated_at();

-- Seed des 4 flags initiaux, tous désactivés. `on conflict do
-- nothing` permet de réappliquer le script sans erreur si la table
-- est déjà peuplée — la valeur `enabled` existante n'est pas
-- écrasée (admin peut activer un flag en prod et re-appliquer ce
-- script en dev sans casser).
insert into public.feature_flags (key, enabled, description) values
  (
    'useDestinationIntelligence',
    false,
    'Phase 1 — Active l''abstraction DestinationIntelligence (centralisation par destination de blueprint + MetroProfile + canonicals).'
  ),
  (
    'useSameComplexDedup',
    false,
    'Phase 2 — Active la dédup des complexes sémantiques (Sentosa / Sentosa Island, Tokyo Skytree / Skytree Tower, etc.) via SameComplexGroup.'
  ),
  (
    'useDestinationScope',
    false,
    'Phase 3 — Active le concept DestinationScope (limitation explicite du périmètre géographique d''un voyage à une destination, sans dépendance au geocoder).'
  ),
  (
    'useDayTemplates',
    false,
    'Phase 4 — Active les DayTemplate (gabarits de journées thématiques par destination, remplacent le Day Builder greedy actuel).'
  )
on conflict (key) do nothing;
