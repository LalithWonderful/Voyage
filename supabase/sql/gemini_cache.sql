-- Cache générique des réponses Gemini, partagé entre tous les voyageurs.
-- Pattern aligné sur places_cache : table large, lookup par (action, cache_key),
-- TTL géré côté client (champ refreshed_at lu par GeminiCacheService).
--
-- À appliquer une fois dans le SQL editor Supabase pour activer le cache IA.

create table if not exists public.gemini_cache (
  action      text        not null,
  cache_key   text        not null,
  payload     jsonb       not null,
  refreshed_at timestamptz not null default now(),
  primary key (action, cache_key)
);

create index if not exists gemini_cache_refreshed_idx
  on public.gemini_cache (refreshed_at);

-- RLS : lecture par tout user authentifié, écriture par tout user authentifié.
-- Cache partagé entre voyageurs (même logique que places_cache) — la valeur
-- ajoutée par un user profite à tous, ce qui est l'intérêt même du cache.
alter table public.gemini_cache enable row level security;

create policy "gemini_cache_read_authenticated"
  on public.gemini_cache for select
  to authenticated
  using (true);

create policy "gemini_cache_insert_authenticated"
  on public.gemini_cache for insert
  to authenticated
  with check (true);

create policy "gemini_cache_update_authenticated"
  on public.gemini_cache for update
  to authenticated
  using (true)
  with check (true);
