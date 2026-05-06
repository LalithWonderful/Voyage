-- Préférences transport en 2 niveaux distincts (arrival vs local) — V2.
--
-- Pourquoi 2 champs ? Un voyageur qui dit "transports en commun" pour la
-- Thaïlande veut probablement le BTS/MRT à Bangkok, mais évidemment l'avion
-- pour Bangkok → Krabi. Avec un seul champ "transport préféré", Gemini
-- conseille des bus 12h là où on attend un vol — et inversement, un vol
-- pour aller au temple.
--
-- Sémantique :
--   - arrival = "aller à la destination depuis chez soi"
--   - local   = "se déplacer une fois sur place"
--   - inter-étapes (Bangkok → Krabi) = décision algorithmique de Lunao,
--     pas exposé comme champ user.
--
-- NULL = pas de préférence définie → Lunao utilise sa logique par défaut
-- (équivalent 'best'). Côté code Dart, le fallback est :
--   trip.arrivalTransportMode
--     ?? userProfile.preferredArrivalTransportMode
--     ?? null  (= best)
--
-- À exécuter une fois dans Supabase SQL Editor.

-- ─── Profil utilisateur (préférences globales) ────────────────────────
ALTER TABLE user_profiles
  ADD COLUMN IF NOT EXISTS preferred_arrival_transport_mode text,
  ADD COLUMN IF NOT EXISTS preferred_local_transport_mode text;

ALTER TABLE user_profiles
  DROP CONSTRAINT IF EXISTS user_profiles_arrival_transport_mode_check;
ALTER TABLE user_profiles
  ADD CONSTRAINT user_profiles_arrival_transport_mode_check
  CHECK (
    preferred_arrival_transport_mode IS NULL
    OR preferred_arrival_transport_mode IN ('best', 'flight', 'train', 'car', 'bus')
  );

ALTER TABLE user_profiles
  DROP CONSTRAINT IF EXISTS user_profiles_local_transport_mode_check;
ALTER TABLE user_profiles
  ADD CONSTRAINT user_profiles_local_transport_mode_check
  CHECK (
    preferred_local_transport_mode IS NULL
    OR preferred_local_transport_mode IN (
      'best', 'public_transport', 'walk', 'taxi', 'car', 'scooter', 'comfort', 'budget'
    )
  );

COMMENT ON COLUMN user_profiles.preferred_arrival_transport_mode IS
  'Préférence par défaut pour rejoindre la destination (best/flight/train/car/bus). NULL = best.';
COMMENT ON COLUMN user_profiles.preferred_local_transport_mode IS
  'Préférence par défaut pour les déplacements sur place (best/public_transport/walk/taxi/car/scooter/comfort/budget). NULL = best.';

-- ─── Voyage (overrides ponctuels) ─────────────────────────────────────
ALTER TABLE trips
  ADD COLUMN IF NOT EXISTS arrival_transport_mode text,
  ADD COLUMN IF NOT EXISTS local_transport_mode text;

ALTER TABLE trips
  DROP CONSTRAINT IF EXISTS trips_arrival_transport_mode_check;
ALTER TABLE trips
  ADD CONSTRAINT trips_arrival_transport_mode_check
  CHECK (
    arrival_transport_mode IS NULL
    OR arrival_transport_mode IN ('best', 'flight', 'train', 'car', 'bus')
  );

ALTER TABLE trips
  DROP CONSTRAINT IF EXISTS trips_local_transport_mode_check;
ALTER TABLE trips
  ADD CONSTRAINT trips_local_transport_mode_check
  CHECK (
    local_transport_mode IS NULL
    OR local_transport_mode IN (
      'best', 'public_transport', 'walk', 'taxi', 'car', 'scooter', 'comfort', 'budget'
    )
  );

COMMENT ON COLUMN trips.arrival_transport_mode IS
  'Override pour ce voyage : transport pour rejoindre la destination. NULL = utiliser preferred_arrival_transport_mode du profil.';
COMMENT ON COLUMN trips.local_transport_mode IS
  'Override pour ce voyage : transport sur place. NULL = utiliser preferred_local_transport_mode du profil.';
