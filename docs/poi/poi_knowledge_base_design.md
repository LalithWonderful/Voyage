# POI-0.1 — Design de la base de connaissances POI Lunao

> **Phase :** POI-0.1 (design uniquement, aucune donnée réelle importée)  
> **Objectif :** Réduire la dépendance à Google Places en construisant progressivement une base POI éditoriale propre dans Supabase.  
> **Règle d'or :** Ne jamais modifier le moteur de planning existant. Les nouvelles tables sont créées vides et ne seront branchées qu'en phase future derrière un feature flag.

---

## 1. Contexte & objectifs

Le moteur Lunao dépend aujourd'hui fortement de Google Places pour :
- la découverte de lieux (searchNearby, textSearch) ;
- les détails (photos, avis, horaires, priceLevel) ;
- le géocodage des anchors.

Cette dépendance entraîne :
- des coûts API élevés et difficilement prévisibles ;
- une qualité touristique inégale (Google privilégie la popularité générale, pas l'intérêt voyageur) ;
- des erreurs de périmètre (lieux hors destination, faux matchs).

La base POI Lunao vise à :
1. **Centraliser** les lieux touristiques de référence par destination.
2. **Normaliser** les noms, catégories, scores et métadonnées.
3. **Permettre un fallback Supabase** quand Google Places est désactivé ou en cache miss.
4. **Réduire les coûts** en lisant Supabase d'abord, et en n'appelant Google qu'en enrichissement contrôlé.

---

## 2. Politique des sources

### 2.1 Sources autorisées

| Type | Exemples | Niveau de confiance |
|---|---|---|
| **Office de tourisme officiel** | Singapore Tourism Board, Atout France, Visit Japan | 5/5 |
| **Site officiel du lieu** | Site du musée, du parc national, du monument | 5/5 |
| **Institutions publiques / UNESCO** | UNESCO WHC, bases patrimoine national | 5/5 |
| **OpenStreetMap / Overpass** | Données sous licence ODbL, attribution respectée | 4/5 |
| **Open data gouvernementale** | data.gouv.fr, data.gov.sg, data.london.gov.uk | 4/5 |
| **Wikidata / Wikipedia** | Utilisé avec prudence : vérification croisée obligatoire | 3/5 |
| **Sources éditoriales reconnues** | Guides Lonely Planet (extraits structurés), National Geographic | 3/5 |

### 2.2 Sources interdites ou à éviter

| Source | Motif |
|---|---|
| **Google Maps scraping** | Violation des CGU ; risque juridique ; données propriétaires. |
| **TripAdvisor scraping** | CGU strictes ; données propriétaires. |
| **GetYourGuide / Booking / Agoda scraping** | Données commerciales protégées. |
| **Bases propriétaires sans licence** | Risque légal ; non auditable. |
| **Contenus copiés depuis blogs** | Droits d'auteur ; qualité non garantie. |

> **Règle opérationnelle :** Chaque POI doit être traçable jusqu'à sa source primaire. Aucun POI sans `source_primary_id` ne sera accepté en production.

---

## 3. Schéma Supabase

### 3.1 Vue d'ensemble des tables

```
poi_sources          — référentiel des sources de données
pois                 — lieux touristiques Lunao (cœur de la base)
poi_aliases          — noms alternatifs pour matching et déduplication
poi_source_links     — traçabilité source ↔ POI (données brutes, IDs externes)
poi_tags             — tags sémantiques (vibe, accessibilité, activité)
poi_quality_flags    — signalements qualité (doublon, fermeture, doute)
```

### 3.2 Table `poi_sources`

Référentiel des sources de données autorisées.

| Colonne | Type | Contrainte | Description |
|---|---|---|---|
| `source_id` | `uuid` | PK, `gen_random_uuid()` | Identifiant unique |
| `name` | `text` | `not null` | Nom humain (ex: "Singapore Tourism Board") |
| `source_type` | `text` | `not null` | `official_board`, `official_venue`, `unesco`, `wikidata`, `openstreetmap`, `open_data_gov`, `editorial` |
| `base_url` | `text` | — | URL racine de la source |
| `license_name` | `text` | — | Nom de la licence (ex: "ODbL", "CC BY-SA 4.0") |
| `license_url` | `text` | — | URL de la licence |
| `trust_level` | `integer` | `check (1..5)` | Niveau de confiance éditorial (1=faible, 5=officiel) |
| `is_active` | `boolean` | `default true` | Source toujours maintenue ? |
| `notes` | `text` | — | Notes internes |
| `created_at` | `timestamptz` | `default now()` | — |
| `updated_at` | `timestamptz` | `default now()` | — |

**Index :**
- `poi_sources_source_type_idx` (B-tree) — filtre par type de source.
- `poi_sources_trust_level_idx` (B-tree) — tri par confiance.

**Justification :** Isoler les sources permet de tracer la provenance de chaque POI, de révoquer une source entière si besoin, et de pondérer la fiabilité lors du matching.

---

### 3.3 Table `pois`

Cœur de la base de connaissances.

| Colonne | Type | Contrainte | Description |
|---|---|---|---|
| `poi_id` | `uuid` | PK, `gen_random_uuid()` | Identifiant unique Lunao |
| `destination_key` | `text` | `not null` | Clé destination (ex: `singapore`, `tokyo`) — cohérent avec `DestinationIntelligence.destination_key` |
| `name` | `text` | `not null` | Nom officiel / display |
| `normalized_name` | `text` | `not null` | Nom normalisé (`lower`, `trim`, collapse espaces) — utilisé pour le matching |
| `category` | `text` | `not null` | Catégorie taxonomique (cf. §5) |
| `subcategory` | `text` | — | Sous-catégorie libre (ex: `hawker_centre`, `national_museum`) |
| `lat` | `double precision` | — | Latitude WGS-84 |
| `lng` | `double precision` | — | Longitude WGS-84 |
| `address` | `text` | — | Adresse formatée |
| `country_code` | `text` | — | ISO-3166-1 alpha-2 (ex: `SG`) |
| `zone_name` | `text` | — | Zone touristique (ex: `Marina Bay`) — référence vers `DestinationIntelligence.zones.name` |
| `official_url` | `text` | — | Site officiel du lieu |
| `source_primary_id` | `uuid` | `not null → poi_sources` | Source primaire qui a défini ce POI |
| `editorial_score` | `integer` | `check (0..100)` | Score qualité éditoriale Lunao (0=anecdotique, 100=incontournable) |
| `touristic_importance` | `integer` | `check (1..5)` | Importance touristique (1=anecdotique, 5=must-see absolu) — aligné sur `DestinationAnchor.importance` |
| `is_must_see` | `boolean` | `default false` | Flag must-see pour filtres rapides |
| `is_family_friendly` | `boolean` | — | Adapté aux familles |
| `is_rain_friendly` | `boolean` | — | Lieu couvert / indoor pertinent jour de pluie |
| `is_free` | `boolean` | — | Gratuit d'accès (entrée) |
| `typical_duration_minutes` | `integer` | `check (>0)` | Durée recommandée de visite |
| `opening_notes` | `text` | — | Notes d'ouverture (ex: "Fermé le lundi", "Dernier entrée 17h") |
| `price_level` | `integer` | `check (1..4)` | 1=gratuit/cheap, 2=modéré, 3=cher, 4=luxe — aligné Google |
| `google_place_id` | `text` | — | Place ID Google (pour enrichissement futur contrôlé) |
| `same_complex_group_key` | `text` | — | Clé vers `same_complex_groups.complex_key` (Phase 2+) |
| `payload` | `jsonb` | `default '{}'` | Champs extensibles futurs sans migration |
| `created_at` | `timestamptz` | `default now()` | — |
| `updated_at` | `timestamptz` | `default now()` | — |

**Index :**
- `pois_destination_key_idx` (B-tree) — requêtes par destination.
- `pois_category_idx` (B-tree) — filtre par catégorie.
- `pois_normalized_name_idx` (B-tree) — recherche exacte / prefix.
- `pois_country_code_idx` (B-tree) — filtres pays.
- `pois_zone_name_idx` (B-tree) — filtres zone.
- `pois_google_place_id_idx` (B-tree, unique where not null) — lookup enrichissement Google.
- `pois_same_complex_group_key_idx` (B-tree) — jointure complexes.
- `pois_editorial_score_idx` (B-tree) — tri par qualité.
- `pois_touristic_importance_idx` (B-tree) — tri par importance.
- `pois_payload_gin_idx` (GIN) — requêtes JSON flexibles.

**Contraintes additionnelles :**
- `check (lat is null or (lat >= -90 and lat <= 90))`
- `check (lng is null or (lng >= -180 and lng <= 180))`
- `check (editorial_score is null or (editorial_score >= 0 and editorial_score <= 100))`
- `check (touristic_importance is null or (touristic_importance >= 1 and touristic_importance <= 5))`
- `check (price_level is null or (price_level >= 1 and price_level <= 4))`
- `check (typical_duration_minutes is null or typical_duration_minutes > 0)`

**Justification :**
- `normalized_name` séparé de `name` pour garantir la stabilité du matching (pas de logique côté client).
- `editorial_score` et `touristic_importance` distincts : l'un est un score continu qualitatif, l'autre un niveau discret d'importance pour l'ordonnancement.
- `google_place_id` nullable et indexé : permettra le cache write-through Google sans rendre la colonne obligatoire.
- `payload` JSONB : extensibilité sans ALTER TABLE (ex: futures données d'accessibilité, langues parlées, etc.).

---

### 3.4 Table `poi_aliases`

Noms alternatifs pour le matching, la recherche, et la déduplication.

| Colonne | Type | Contrainte | Description |
|---|---|---|---|
| `alias_id` | `uuid` | PK, `gen_random_uuid()` | — |
| `poi_id` | `uuid` | `not null → pois (on delete cascade)` | POI parent |
| `alias` | `text` | `not null` | Nom alternatif (ex: "MBS" pour "Marina Bay Sands") |
| `alias_normalized` | `text` | `not null` | Alias normalisé pour matching |
| `is_canonical` | `boolean` | `default false` | `true` si cet alias est le nom principal recommandé par la source |
| `source_id` | `uuid` | `→ poi_sources` | Source de cet alias (peut différer de la source primaire) |
| `created_at` | `timestamptz` | `default now()` | — |

**Index & contraintes :**
- `poi_aliases_poi_id_idx` (B-tree)
- `poi_aliases_alias_normalized_idx` (B-tree) — recherche rapide par nom normalisé.
- `unique (poi_id, alias_normalized)` — évite les doublons d'alias au sein d'un même POI.

**Justification :** Séparer les aliases de la table `pois` permet un matching multi-nom sans duplication de lignes, et facilite la fusion future de POI doublons (les aliases migrent avec le POI cible).

---

### 3.5 Table `poi_source_links`

Traçabilité fine : chaque lien entre un POI et une source externe, avec l'identifiant brut dans la source.

| Colonne | Type | Contrainte | Description |
|---|---|---|---|
| `link_id` | `uuid` | PK, `gen_random_uuid()` | — |
| `poi_id` | `uuid` | `not null → pois (on delete cascade)` | POI concerné |
| `source_id` | `uuid` | `not null → poi_sources` | Source externe |
| `source_poi_identifier` | `text` | — | ID brut dans la source (ex: Q12345 pour Wikidata, node 123 pour OSM) |
| `source_url` | `text` | — | Lien direct vers la fiche source |
| `source_raw_data` | `jsonb` | `default '{}'` | Données brutes stockées pour audit |
| `verified_at` | `timestamptz` | — | Date de vérification manuelle ou script |
| `created_at` | `timestamptz` | `default now()` | — |

**Index & contraintes :**
- `poi_source_links_poi_id_idx` (B-tree)
- `poi_source_links_source_id_idx` (B-tree)
- `unique (poi_id, source_id, coalesce(source_poi_identifier, ''))` — évite les liens dupliqués.

**Justification :** Un POI peut avoir plusieurs sources (ex: un musée référencé par l'office de tourisme ET Wikidata ET OSM). Cette table permet la traçabilité complète sans polluer `pois`.

---

### 3.6 Table `poi_tags`

Tags sémantiques riches, plus granulaires que `category`.

| Colonne | Type | Contrainte | Description |
|---|---|---|---|
| `tag_id` | `uuid` | PK, `gen_random_uuid()` | — |
| `poi_id` | `uuid` | `not null → pois (on delete cascade)` | POI concerné |
| `tag` | `text` | `not null` | Valeur du tag (ex: `night_photography`, `wheelchair_accessible`, `halal`) |
| `tag_category` | `text` | — | Catégorie du tag (`vibe`, `accessibility`, `activity_type`, `audience`, `season`) |
| `confidence` | `integer` | `check (0..100)` | Confiance dans l'attribution (100 = confirmé par source officielle) |
| `source_id` | `uuid` | `→ poi_sources` | Source du tag |
| `created_at` | `timestamptz` | `default now()` | — |

**Index :**
- `poi_tags_poi_id_idx` (B-tree)
- `poi_tags_tag_idx` (B-tree) — requête "tous les POI taggés `rainy_day`".
- `poi_tags_tag_category_idx` (B-tree)

**Justification :** Les tags permettront des filtres riches côté moteur (ex: "journée pluvieuse → indoor + museum + rainy_day") sans alourdir la table principale.

---

### 3.7 Table `poi_quality_flags`

Signalements qualité et maintenance.

| Colonne | Type | Contrainte | Description |
|---|---|---|---|
| `flag_id` | `uuid` | PK, `gen_random_uuid()` | — |
| `poi_id` | `uuid` | `not null → pois (on delete cascade)` | POI concerné |
| `flag_type` | `text` | `not null` | `duplicate`, `location_inaccurate`, `name_disputed`, `closed`, `deprecated`, `needs_review` |
| `flag_reason` | `text` | — | Description détaillée |
| `reported_by` | `text` | — | `system`, `admin`, `user:<uuid>` |
| `resolved_at` | `timestamptz` | — | Date de résolution |
| `resolution_notes` | `text` | — | Commentaire de résolution |
| `created_at` | `timestamptz` | `default now()` | — |

**Index :**
- `poi_quality_flags_poi_id_idx` (B-tree)
- `poi_quality_flags_flag_type_idx` (B-tree)
- `poi_quality_flags_resolved_at_idx` (B-tree) — flags ouverts en premier.

**Justification :** Permet un workflow de curation continue. Un POI avec un flag `duplicate` ou `location_inaccurate` peut être exclu du moteur temporairement sans suppression définitive.

---

## 4. Stratégie de qualité et déduplication

### 4.1 Normalisation des noms

**Règle côté SQL (recommandé) :**
```sql
lower(trim(regexp_replace(name, '\s+', ' ', 'g')))
```

- Passage en minuscules.
- Suppression des espaces en début/fin.
- Collapse des espaces multiples.
- Conservation des accents (pour l'instant) : le matching est plus robuste si on garde les caractères unicode exacts côté base, et on normalise en ASCII côté client si besoin.

**Champ `normalized_name`** dans `pois` pré-calculé à l'insertion pour éviter les calculs à la volée.

### 4.2 Gestion des aliases

- Tout nom alternatif connu (acronymes, traductions, anciens noms) entre dans `poi_aliases`.
- `is_canonical = true` pour l'alias privilégié par la source officielle.
- Le matching fuzzy futur utilisera `poi_aliases.alias_normalized` en priorité.

### 4.3 Détection des doublons

**Approche en 3 niveaux (documentée pour POI-0.2+) :**

1. **Niveau strict (DB)** : `unique` sur `(destination_key, normalized_name)` ? **Non retenu pour l'instant** — trop rigide (homonymes légitimes possibles : "National Museum" existe dans plusieurs villes, mais `destination_key` le dissocie).
   - Contrainte proposée : `unique (destination_key, normalized_name)` **avec exception explicite** via `poi_quality_flags(flag_type='duplicate')` si un doublon légitime est détecté.

2. **Niveau géographique (script)** : deux POI dans la même `destination_key` avec distance < 50 m et noms similaires → candidats doublons. Le script alimentera `poi_quality_flags`.

3. **Niveau sémantique (future)** : appartenance au même `same_complex_group_key` (Phase 2+) → les POI sont liés mais pas fusionnés.

### 4.4 POI proches géographiquement

- Distance inter-POI non stockée en base (coût de maintenance).
- Requête à la volée via formule haversine ou extension PostGIS si volume justifie.
- Pour l'instant, le filtre géographique se fait par `zone_name` (zone touristique) et `destination_key`.

### 4.5 Complexe vs lieu individuel

- Un **complexe** (ex: Sentosa) est représenté par une entrée dans `same_complex_groups` (table existante Phase 2).
- Un **lieu individuel** (ex: Universal Studios Singapore) est un POI dans `pois` avec `same_complex_group_key = 'sentosa'`.
- Cette distinction empêche le moteur de suggérer 5 activités Sentosa le même jour, tout en conservant chaque lieu comme POI indépendant.

---

## 5. Taxonomie des catégories

Alignée sur les besoins du moteur Lunao et les types de lieux listés dans le cahier des charges POI.

| `category` | Description | Exemples |
|---|---|---|
| `must_see` | Incontournable absolu de la destination | Merlion, Tour Eiffel |
| `museum` | Musées, galeries d'art | National Museum, Louvre |
| `monument` | Monuments, mémoriaux, statues | Cenotaph, Statue de la Liberté |
| `viewpoint` | Points de vue panoramiques | Marina Bay Sands SkyPark, rooftop |
| `park` | Parcs urbains, jardins botaniques | Gardens by the Bay, Central Park |
| `nature` | Nature hors parc urbain (réserve, forêt) | Bukit Timah Nature Reserve |
| `beach` | Plages | Sentosa Beach, Bondi Beach |
| `neighborhood` | Quartiers / districts touristiques | Chinatown, Kampong Glam |
| `market` | Marchés couverts, souks, night markets | Lau Pa Sat, Chatuchak |
| `food` | Lieux food importants (hawker centres, food courts, rue food) | Maxwell Food Centre |
| `shopping` | Centres commerciaux, rues commerçantes | Orchard Road, VivoCity |
| `nightlife` | Bars, clubs, spectacles nocturnes | Clarke Quay |
| `family` | Attractions famille (parcs à thème, zoo) | Singapore Zoo, USS |
| `wellness` | Spas, sources thermales | — |
| `transport_hub` | Gares, aéroports, ferry terminals | Changi, Sentosa Gateway |
| `photo_spot` | Lieux explicitement photogéniques | Helix Bridge, Haji Lane |
| `rainy_day` | Lieux indoor recommandés par mauvais temps | Musées, malls, galeries |
| `local_experience` | Expériences culturelles locales | Atelier de cuisine, temple visit |

**Règles :**
- Un POI a **une seule** `category` obligatoire.
- `subcategory` est libre pour affiner (ex: `category='museum'`, `subcategory='art_gallery'`).
- Les tags (`poi_tags`) permettent les classifications croisées (ex: un musée peut aussi être `rainy_day` et `family`).

---

## 6. Relation avec le moteur Lunao

### 6.1 Consommation future (non branchée en POI-0.1)

| Composant Lunao | Comment la base POI l'alimentera |
|---|---|
| **DestinationIntelligence anchors** | Les POIs avec `touristic_importance = 5` et `is_must_see = true` deviendront des `DestinationAnchor`. |
| **DayTemplates** | Les `recommended_anchor_keys` d'un template pointeront vers `pois.name` (ou `poi_id` en version typée). |
| **TemplateFirstPipeline** | Le pipeline pourra piocher dans `pois` par `(destination_key, zone_name, category)` avant de solliciter Google Places. |
| **SameComplexGroup** | `pois.same_complex_group_key` jointure naturelle avec `same_complex_groups.complex_key`. |
| **DestinationScope** | `pois.country_code` permettra de valider qu'un POI appartient bien au périmètre autorisé. |
| **Fallback Google Places** | Si `google_place_id` est null, le POI Lunao est utilisé tel quel. Si non null, un enrichissement contrôlé (photos, avis) peut être déclenché. |

### 6.2 Feature flag recommandé (future POI-1.x)

```dart
// Dans lib/config/feature_flags.dart (futur)
const _envKeyUsePoiKnowledgeBase = 'USE_POI_KNOWLEDGE_BASE';
final bool usePoiKnowledgeBase; // default false
```

Le moteur ne basculera sur la base POI que lorsque ce flag sera ON et que la base contiendra suffisamment de données validées pour une destination donnée.

### 6.3 Cache write-through Google Places

```
Flux futur (design uniquement) :
1. Moteur demande un lieu pour "Gardens by the Bay".
2. Requête Supabase : SELECT * FROM pois WHERE normalized_name = 'gardens by the bay' AND destination_key = 'singapore'.
3. Cache HIT → retourne le POI Lunao directement (0 appel Google).
4. Cache MISS → appel Google Places (si autorisé par LiveApiGuards).
5. Enrichissement : le résultat Google est stocké dans `poi_source_links` (source Google Places si licence le permet) ou utilisé pour mettre à jour `google_place_id` et `payload`.
```

---

## 7. Sécurité et coûts API

### 7.1 Réduction des appels Google

| Stratégie | Mécanisme |
|---|---|
| **Lecture Supabase d'abord** | `pois` est interrogée avant tout appel Google. |
| **Google uniquement en enrichissement** | `google_place_id` est un bonus, pas un prérequis. |
| **Pas d'appel Google en test** | Les tests unitaires utilisent `test/fixtures/poi/*.json`. |
| **Pas de scraping** | Aucune donnée Google n'est scrapée ; seuls les IDs Place sont stockés (ils ne sont pas protégés par droit d'auteur). |

### 7.2 RLS (Row Level Security)

Toutes les tables POI suivent la convention existante du projet :
- `enable row level security`
- Policy `*_read_all` : `for select using (true)` — lecture publique pour les clients authentifiés et anonymes.
- **Aucune policy insert/update/delete côté client** — l'écriture est réservée au `service_role` (administrations via dashboard Supabase, migrations, ou edge functions).

---

## 8. Livrables créés en POI-0.1

| Fichier | Description |
|---|---|
| `docs/poi/poi_knowledge_base_design.md` | Ce document de design. |
| `supabase/sql/poi_knowledge_base.sql` | Migration SQL idempotente (tables, index, contraintes, RLS, triggers). |
| `test/fixtures/poi/sample_pois_singapore.json` | Exemple de 8 POIs Singapour en format JSON, structurés selon le schéma. |

---

## 9. Validation plan (POI-0.2+)

> **Non exécuté en POI-0.1** — documenté pour la suite.

1. **Validation statique** : `flutter analyze` après ajout des modèles Dart (futur).
2. **Validation schéma** : exécution de `poi_knowledge_base.sql` dans l'éditeur SQL Supabase (staging).
3. **Test insertion** : script d'insertion de 10 POIs test, vérification des contraintes `CHECK` et des index.
4. **Test requêtes** :
   - `SELECT * FROM pois WHERE destination_key = 'singapore' AND category = 'museum'`
   - `SELECT * FROM poi_aliases WHERE alias_normalized = 'gardens by the bay'`
   - `SELECT p.* FROM pois p JOIN poi_tags t ON p.poi_id = t.poi_id WHERE t.tag = 'rainy_day'`
5. **Test RLS** : tentative d'insertion depuis un client anon → doit échouer.
6. **Test qualité** : script de détection de doublons géographiques → doit alimenter `poi_quality_flags`.

---

## 10. Prochaines étapes (hors scope POI-0.1)

- **POI-0.2** : Création des modèles Dart (`Poi`, `PoiSource`, `PoiAlias`, etc.) et providers Riverpod.
- **POI-0.3** : Import manuel des 20-30 POIs incontournables d'une destination pilote (Singapour probablement, cohérent avec les phases précédentes).
- **POI-1.0** : Branchement conditionnel derrière un feature flag dans le pipeline de planning (lecture POI avant Google Places).
- **POI-1.x** : Enrichissement contrôlé Google Places (cache write-through).
