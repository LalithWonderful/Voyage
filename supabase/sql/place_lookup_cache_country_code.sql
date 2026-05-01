-- Ajout de `country_code` (ISO 2) sur `place_lookup_cache`. Permet de
-- détecter une incohérence entre le pays d'un aéroport/gare et la
-- destination du voyage (ex: vol BKK→CNX = TH dans un voyage Chine).
--
-- Nullable : les entrées existantes restent valides (warning ne se
-- déclenche pas tant que le code pays n'est pas connu, pas de faux
-- positif). Les nouveaux écritures via PlaceLookupCacheService
-- alimentent le champ.

alter table public.place_lookup_cache
  add column if not exists country_code text;

create index if not exists place_lookup_cache_country_idx
  on public.place_lookup_cache (country_code);
