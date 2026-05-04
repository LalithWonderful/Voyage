-- Budget par personne sur le voyage + aéroport de départ par défaut sur
-- l'utilisateur. Cf. UX écran "Où veux-tu voyager ?" — section budget :
--
-- 1. Le voyageur peut indiquer un budget par personne dès la création du
--    voyage. Sert à filtrer/alerter sur la faisabilité d'une destination
--    ("Le Brésil dépasse ton budget de 600€"), pas seulement au tracking
--    rétrospectif (cf. wallet).
--
-- 2. Les estimations dépendent de l'aéroport de départ (vol Paris→Maroc
--    ≠ Marseille→Maroc). On stocke `home_airport_iata` au niveau du profil
--    pour pré-remplir les calculs sans le redemander à chaque voyage.
--    Default 'CDG' (Paris) car la majorité de l'audience FR.
--
-- À exécuter une fois dans Supabase SQL Editor.

ALTER TABLE trips
  ADD COLUMN IF NOT EXISTS budget_per_person_eur numeric(10, 2),
  ADD COLUMN IF NOT EXISTS budget_includes_flight boolean DEFAULT true;

COMMENT ON COLUMN trips.budget_per_person_eur IS
  'Budget par personne en euros. Null = pas de budget renseigné. Sert au filtre destination + comparaison wallet.';

COMMENT ON COLUMN trips.budget_includes_flight IS
  'Si true (default), le budget couvre vol AR + séjour. Si false, vol payé séparément (logique d''estimations différente).';

ALTER TABLE user_profiles
  ADD COLUMN IF NOT EXISTS home_airport_iata text DEFAULT 'CDG';

COMMENT ON COLUMN user_profiles.home_airport_iata IS
  'Code IATA de l''aéroport de départ habituel (3 lettres majuscules, ex: CDG, NCE, MRS). Default ''CDG'' (Paris) pour audience FR. Modifiable dans le profil.';
