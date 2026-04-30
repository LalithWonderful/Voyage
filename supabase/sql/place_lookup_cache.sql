-- Cache partagé entre tous les utilisateurs pour résoudre placeId Google →
-- coords sans re-payer Place Details à chaque save. Ciblé sur les hubs de
-- transport (aéroports, gares) qui sont quasi-statiques : un IATA code ne
-- change pas, donc cache permanent (pas de TTL).
--
-- Utilisé par PlaceLookupCacheService au save d'un doc Vol/Train : check
-- table par place_id → hit = lecture coords gratuite, miss = Place Details
-- API + INSERT. Après warm-up (~100 users actifs) le cache couvre 80%+ des
-- aéroports/gares utilisés mondialement.

create table if not exists public.place_lookup_cache (
  place_id text primary key,
  name text not null,
  latitude double precision not null,
  longitude double precision not null,
  kind text not null check (kind in ('airport', 'train_station')),
  -- Optionnel : code IATA pour les aéroports, extrait du nom canonique
  -- Google quand présent (ex: "Suvarnabhumi Airport (BKK)" → "BKK").
  iata_code text,
  last_seen_at timestamptz not null default now()
);

create index if not exists place_lookup_cache_kind_idx
  on public.place_lookup_cache (kind);

-- RLS : lecture/insertion ouvertes aux users authentifiés (pas de PII, juste
-- des infos publiques d'aéroports/gares). Update autorisé pour rafraîchir
-- last_seen_at quand on hit le cache.
alter table public.place_lookup_cache enable row level security;

drop policy if exists "place_lookup_cache select" on public.place_lookup_cache;
create policy "place_lookup_cache select"
  on public.place_lookup_cache for select
  to authenticated using (true);

drop policy if exists "place_lookup_cache insert" on public.place_lookup_cache;
create policy "place_lookup_cache insert"
  on public.place_lookup_cache for insert
  to authenticated with check (true);

drop policy if exists "place_lookup_cache update" on public.place_lookup_cache;
create policy "place_lookup_cache update"
  on public.place_lookup_cache for update
  to authenticated using (true) with check (true);
