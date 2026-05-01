-- Ajout de `city` (nom de la ville) sur `place_lookup_cache`. Permet de
-- déduire l'étape voyage (`TripSegment.city`) depuis un aéroport / gare —
-- ex: aéroport "CNX" → city "Chiang Mai". Sans ça on aurait l'étape
-- "Aéroport international de Chiang Mai" qui n'a pas de sens.
--
-- Extrait des `address_components` au Place Details (Geocoding aussi).
-- Nullable : entrées existantes restent valides, le code retombe sur le
-- nom de l'aéroport en absence de city (fallback safe).

alter table public.place_lookup_cache
  add column if not exists city text;
