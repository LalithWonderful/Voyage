-- Override aéroport de départ par voyage. Le default reste sur
-- `user_profiles.home_airport_iata` (cf. trips_budget_and_home_airport.sql) :
-- l'utilisateur a un aéroport habituel, mais peut partir ponctuellement
-- d'un autre pour un voyage spécifique (NCE pour les vacances d'été,
-- BRU pour un voyage frontalier, GVA pour le ski, LYS pour un voyage pro...).
--
-- Sémantique :
--   - NULL  → utiliser l'aéroport du profil (fallback)
--   - 'NCE' → override pour ce voyage uniquement
--
-- Côté code (Dart) : `trip.homeAirportIata ?? userProfile.homeAirportIata
-- ?? 'CDG'`. Lunao l'utilise pour le calcul de budget vol et toutes les
-- estimations qui dépendent de l'origine.
--
-- À exécuter une fois dans Supabase SQL Editor.

ALTER TABLE trips
  ADD COLUMN IF NOT EXISTS home_airport_iata text;

-- CHECK constraint idempotent : DROP IF EXISTS + ADD pour pouvoir relancer
-- la migration sans erreur si elle a déjà été appliquée.
ALTER TABLE trips
  DROP CONSTRAINT IF EXISTS trips_home_airport_iata_check;
ALTER TABLE trips
  ADD CONSTRAINT trips_home_airport_iata_check
  CHECK (
    home_airport_iata IS NULL
    OR home_airport_iata ~ '^[A-Z]{3}$'
  );

COMMENT ON COLUMN trips.home_airport_iata IS
  'Code IATA (3 lettres maj) override pour ce voyage. NULL = fallback sur user_profiles.home_airport_iata.';
