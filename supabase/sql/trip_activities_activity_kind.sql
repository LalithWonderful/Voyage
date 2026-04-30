-- Ajout de la colonne `activity_kind` sur `trip_activities`.
--
-- Distingue les activités principales (visites, restos, expériences — le
-- "contenu" du voyage) des étapes logistiques (aéroport, gare, transferts,
-- retour hôtel — les déplacements). Le rendu UI les présente différemment
-- pour ne pas vampiriser la timeline tout en gardant les infos critiques
-- (heures, lieu, durée, itinéraire) toujours visibles.
--
-- Default 'main' : toute activité existante ou créée sans préciser kind est
-- considérée comme principale. Seuls les flows logistiques (Vol/Train/voiture
-- via document_to_activity, retours hôtel via _autoInsertHotelReturns,
-- suggestions IA explicites) écrivent 'logistic'.

alter table public.trip_activities
  add column if not exists activity_kind text not null default 'main'
  check (activity_kind in ('main', 'logistic'));

-- Backfill des activités "Retour à <hôtel>" existantes : ce sont des transits
-- vers l'hôtel (créés par _autoInsertHotelReturns), avec tag 'Hébergement'
-- mais sémantiquement logistic. On les marque pour que la timeline les rende
-- correctement dès le prochain refresh.
update public.trip_activities
  set activity_kind = 'logistic'
  where tag = 'Hébergement'
    and lower(title) like 'retour%'
    and activity_kind = 'main';
