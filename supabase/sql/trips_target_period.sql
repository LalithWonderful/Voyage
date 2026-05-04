-- Ajout du mois cible pour les voyages dont l'utilisateur ne connaît pas
-- encore les dates exactes. Cf. UX écran "Où veux-tu voyager ?" — 2 modes :
--
-- - `period_mode = 'exact'` (ou NULL pour les voyages legacy) : start_date
--   et end_date sont les vraies dates choisies par l'utilisateur.
--
-- - `period_mode = 'month'` : start_date et end_date sont synthétisées
--   (1er du mois → +6 jours, fenêtre exploratoire de 7 jours) pour rester
--   exploitables par les pipelines IA / planning / wallet sans changement
--   downstream. `target_period` stocke le mois cible au format 'YYYY-MM'
--   pour l'affichage humain ("Plutôt en septembre 2026").
--
-- Pas de migration de données : les voyages existants ont period_mode
-- NULL → traités comme 'exact' par le code (helper `hasExactDates` dans
-- trip_model.dart).
--
-- À exécuter une fois dans Supabase SQL Editor.

ALTER TABLE trips
  ADD COLUMN IF NOT EXISTS target_period text,
  ADD COLUMN IF NOT EXISTS period_mode text;

COMMENT ON COLUMN trips.target_period IS
  'Mois cible au format YYYY-MM quand period_mode=''month'' (ou ''recommended'' en commit 3). NULL si dates exactes.';

COMMENT ON COLUMN trips.period_mode IS
  '''exact'' (default, dates réelles) | ''month'' (mois cible, dates synthétisées) | ''recommended'' (saison conseillée, à venir).';
