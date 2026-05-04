-- Ajout du mois cible pour les voyages dont l'utilisateur ne connaît pas
-- encore les dates exactes. Cf. UX écran "Où veux-tu voyager ?" — 4 modes :
--
-- - `period_mode = 'exact'` (ou NULL pour les voyages legacy) : start_date
--   et end_date sont les vraies dates choisies par l'utilisateur.
--
-- - `period_mode = 'month'` : l'utilisateur a explicitement choisi un mois
--   cible. start_date/end_date sont synthétisées (1er du mois → +6 jours,
--   fenêtre exploratoire de 7 jours) pour rester exploitables par les
--   pipelines IA / planning / wallet sans changement downstream.
--   `target_period` stocke le mois cible au format 'YYYY-MM' pour
--   l'affichage humain ("Plutôt en septembre 2026").
--
-- - `period_mode = 'unspecified'` : l'utilisateur n'a rien indiqué (ni dates,
--   ni mois). On synthétise quand même start/end sur le mois courant pour
--   alimenter les pipelines, mais l'UI N'AFFICHE PAS ce mois (afficherait
--   "Mai 2026" alors que l'utilisateur ne l'a pas choisi → trompeur). À la
--   place : "Dates à préciser". Cf. helper `hasUnspecifiedPeriod` dans
--   trip_model.dart.
--
-- - `period_mode = 'recommended'` (commit 3 à venir) : l'app a suggéré une
--   période optimale selon la destination (saisonnalité). target_period
--   contient le mois conseillé.
--
-- Pas de migration de données : les voyages existants ont period_mode
-- NULL → traités comme 'exact' par le code.
--
-- À exécuter une fois dans Supabase SQL Editor.

ALTER TABLE trips
  ADD COLUMN IF NOT EXISTS target_period text,
  ADD COLUMN IF NOT EXISTS period_mode text;

-- Verrouille les valeurs autorisées pour éviter qu'une régression côté code
-- n'écrive un mode inconnu. NULL reste permis (= legacy 'exact'). Idempotent
-- via DROP IF EXISTS pour réexécution sans perte.
ALTER TABLE trips
  DROP CONSTRAINT IF EXISTS trips_period_mode_check;
ALTER TABLE trips
  ADD CONSTRAINT trips_period_mode_check
  CHECK (period_mode IS NULL OR period_mode IN ('exact', 'month', 'unspecified', 'recommended'));

COMMENT ON COLUMN trips.target_period IS
  'Mois cible au format YYYY-MM quand period_mode IN (''month'', ''unspecified'', ''recommended''). NULL si dates exactes.';

COMMENT ON COLUMN trips.period_mode IS
  '''exact'' (default, dates réelles) | ''month'' (mois explicite) | ''unspecified'' (rien choisi, mois synthétique masqué côté UI) | ''recommended'' (saison conseillée).';
