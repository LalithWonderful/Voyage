-- V6 (Lalith 2026-05-10 — Lot E TODO 3) — état de planification d'une
-- activité dans le voyage.
--
-- Avant : les activités générées par Lunao (`suggested=true`) étaient
-- SUPPRIMÉES dès que l'itinéraire changeait structurellement
-- (cf. `activity_staleness_service.clearGeneratedActivitiesForTrip`).
-- Trade-off accepté en MVP V4 : préférable à un planning corrompu, mais
-- l'utilisateur perdait du temps si il avait apprécié la sélection.
--
-- Après : on MARQUE les activités générées comme `stale` au lieu de
-- les supprimer. Lunao les cache du planning principal mais les
-- conserve dans une section dédiée « Activités obsolètes » d'où
-- l'utilisateur peut :
--   - les restaurer (status → 'planned')
--   - les supprimer définitivement
--   - les ignorer (régénération propre via Suggérer)
--
-- Valeurs autorisées :
--   - 'planned'      → activité valide dans l'itinéraire courant
--   - 'stale'        → générée par une mutation antérieure, masquée
--                       du planning principal en attendant une action
--                       utilisateur (restaurer ou supprimer)
--   - 'to_reposition' → activité utilisateur dont la date est sortie
--                       de la plage des segments (cf. Lot E TODO 1).
--                       Géré côté client pour l'instant ; ce status
--                       deviendra persistant quand on voudra survivre
--                       à un redémarrage de l'app.
--   - 'conflict'     → activité importée d'un doc dont la ville n'est
--                       plus dans l'itinéraire (cf. Lot E TODO 2).
--                       Surface par `document_consistency` actuellement.
--
-- À exécuter une fois dans Supabase SQL Editor. Idempotent.

ALTER TABLE trip_activities
  ADD COLUMN IF NOT EXISTS planning_status text NOT NULL DEFAULT 'planned';

-- CHECK contrainte idempotente : DROP IF EXISTS + ADD pour relance.
ALTER TABLE trip_activities
  DROP CONSTRAINT IF EXISTS trip_activities_planning_status_check;
ALTER TABLE trip_activities
  ADD CONSTRAINT trip_activities_planning_status_check
  CHECK (
    planning_status IN ('planned', 'stale', 'to_reposition', 'conflict')
  );

-- Index pour les filtrages rapides (le planning principal exclut les
-- 'stale', et la section dédiée n'affiche que les 'stale'). Petite
-- table utilisateur → impact négligeable mais accélère les écrans
-- où le voyage a beaucoup d'activités historiques.
CREATE INDEX IF NOT EXISTS trip_activities_planning_status_idx
  ON trip_activities (trip_id, planning_status);

COMMENT ON COLUMN trip_activities.planning_status IS
  'État de planification : planned (valide), stale (générée puis itinéraire muté), to_reposition (date sortie des segments), conflict (ville plus dans itinéraire).';
