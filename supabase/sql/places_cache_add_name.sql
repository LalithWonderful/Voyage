-- Ajoute la colonne `place_name` à places_cache pour stocker le nom canonique
-- retourné par Google Places (ex: "Place Stanislas", "Brasserie Excelsior").
--
-- Permet le filtre anti-hallucination côté client : on rejette une suggestion
-- Gemini si aucun token significatif de son titre ne matche le nom canonique
-- Places (ex: titre "Galerie Myrtille Beck" → name "Bijouterie Lefranc" → rejet).
--
-- Idempotent : `if not exists` garantit qu'une re-application ne casse rien.

alter table public.places_cache
  add column if not exists place_name text;
