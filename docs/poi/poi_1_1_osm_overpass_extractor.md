# POI-1.1 — Extracteur OSM/Overpass vers Fixture Lunao

## Objectif

Pipeline contrôlé pour récupérer des POI touristiques depuis OpenStreetMap (via Overpass API) et les transformer en fixture JSON compatible avec `PoiFixtureValidator` (POI-0.2) et `PoiStagingImporter` (POI-0.3).

Ce n'est **pas** une intégration runtime dans l'app Flutter. C'est un outil de génération de données à exécuter manuellement ou en CI.

## Architecture

```
┌─────────────────┐     ┌──────────────────────────┐     ┌──────────────────┐
│  Overpass API   │────▶│ OsmOverpassExtractor     │────▶│ Fixture JSON     │
│  (OSM data)     │     │  - fetchOverpass()       │     │ (Lunao format)   │
└─────────────────┘     │  - extractFromResponse() │     └──────────────────┘
                        └──────────────────────────┘              │
                              ▲                                   │
                              │                                   ▼
                        tool/poi/extract_osm_pois.dart      PoiFixtureValidator
                              (CLI)                               (validation)
```

## Fichiers

| Fichier | Description |
|---------|-------------|
| `lib/features/poi/tools/osm_overpass_extractor.dart` | Logique d'extraction et de mapping |
| `tool/poi/extract_osm_pois.dart` | Script CLI |
| `test/poi/osm_poi_mapping_test.dart` | Tests offline (mapping + validation) |
| `docs/poi/poi_1_1_osm_overpass_extractor.md` | Ce document |

## Mapping OSM → Lunao

| Tags OSM | Catégorie Lunao | Notes |
|----------|----------------|-------|
| `tourism=museum` | `museum` | |
| `tourism=theme_park` / `zoo` / `aquarium` | `family` | |
| `tourism=viewpoint` | `viewpoint` | |
| `historic=monument` / `memorial` / `castle` / `fort` | `monument` | |
| `historic=*` (autre) | `monument` | Fallback |
| `leisure=park` | `park` | |
| `leisure=nature_reserve` | `nature` | |
| `natural=beach` | `beach` | |
| `amenity=marketplace` | `market` | |
| `tourism=attraction` | `must_see` | Fallback |

## Champs générés

| Champ | Source | Déterministe ? |
|-------|--------|----------------|
| `poi_id` | UUID v4 aléatoire | Non (re-généré à chaque extraction) |
| `name` | `tags['name']` | Oui |
| `normalized_name` | `normalizeName(name)` | Oui |
| `category` | Mapping OSM (voir tableau) | Oui |
| `subcategory` | Premier tag pertinent (tourism/historic/…) | Oui |
| `lat` / `lng` | Node direct ou `center` way/relation | Oui |
| `address` | `addr:housenumber` + `addr:street` + `addr:city` | Oui |
| `country_code` | Paramètre CLI `--country` | Oui |
| `zone_name` | `addr:district` ou `addr:suburb` | Oui |
| `official_url` | `website` ou `contact:website` | Oui |
| `source_primary_id` | Paramètre CLI `--source-id` ou UUID aléatoire | Configurable |
| `editorial_score` | Heuristique (base 60 + wiki/website) | Oui |
| `touristic_importance` | Heuristique par catégorie | Oui |
| `is_must_see` | `category == 'must_see'` | Oui |
| `is_family_friendly` | Heuristique par catégorie | Oui |
| `is_rain_friendly` | `museum` ou `family` | Oui |
| `is_free` | `fee == 'no'` | Oui |
| `typical_duration_minutes` | Table par catégorie (ex: museum=120) | Oui |
| `price_level` | `fee` tag ou heuristique | Oui |
| `aliases` | `name` (canonical) + `alt_name`/`old_name`/`name:en` | Oui |
| `tags` | Générés depuis tags OSM (`historic`, `outdoor`, …) | Oui |

## Usage CLI

```bash
# Singapour (bbox intégrée)
dart tool/poi/extract_osm_pois.dart --destination singapore --country SG > singapore_osm.json

# Paris (bbox intégrée)
dart tool/poi/extract_osm_pois.dart --destination paris --country FR > paris_osm.json

# Bbox manuelle
dart tool/poi/extract_osm_pois.dart --destination mycity --country XX \
  --bbox 48.81,2.22,48.90,2.47 > mycity.json

# Avec source_id fixe (pour reproductibilité)
dart tool/poi/extract_osm_pois.dart --destination singapore --country SG \
  --source-id aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa > singapore_osm.json
```

## Tests

### Offline (par défaut)

```bash
flutter test test/poi/osm_poi_mapping_test.dart
```

Tests du mapping des tags OSM → catégories Lunao, de la structuration du fixture, des heuristiques (score, prix, durée), et de la validation via `PoiFixtureValidator`.

### Live (opt-in explicite)

```bash
flutter test test/poi/osm_poi_mapping_test.dart --dart-define=RUN_LIVE_OVERPASS=true
```

Ce test appelle réellement `overpass-api.de` pour Singapour et valide le fixture généré. **Ne pas exécuter en CI sans rate-limiting.**

## Limites connues

1. **Qualité des données OSM** : la couverture et la précision varient énormément selon la ville. Singapour est bien cartographiée ; d'autres destinations peuvent être pauvres.
2. **Pas de nettoyage sémantique** : les noms OSM peuvent contenir des préfixes/suffixes indésirables (ex: "The National Museum of Singapore — Main Building").
3. **Pas de déduplication sémantique** : un même lieu peut apparaître comme node + way + relation. Seul le dédoublonnage par ID OSM est fait.
4. **Scores éditoriaux artificiels** : les scores sont des heuristiques (wiki=+15, wikidata=+10). Ils ne remplacent pas une évaluation manuelle.
5. **Pas de tags riches** : les tags Lunao générés sont basiques. Une passe manuelle d'enrichissement est recommandée.
6. **Pas d'image / photo** : OSM ne fournit pas systématiquement d'images.
7. **Opening hours** : les horaires OSM (`opening_hours`) ne sont pas parsés (format trop complexe).

## Licence et attribution

Les données OpenStreetMap sont sous licence **[ODbL 1.0](https://opendatacommons.org/licenses/odbl/1.0/)**.

Tout fixture généré par cet outil :
- Doit conserver l'attribution "OpenStreetMap" dans `sources[].name`
- Doit mentionner la licence ODbL dans `sources[].license_name` et `sources[].license_url`
- Doit inclure l'URL de base `https://www.openstreetmap.org`
- Le `_comment` du fixture rappelle automatiquement la licence

## Throttling et fair-use Overpass

- **URL** : `https://overpass-api.de/api/interpreter`
- **Limite** : ~1 requête / seconde (fair-use non officiel)
- **Timeout** : 90s côté requête, 2 min côté client
- **Conseil** : pour des extractions massives, héberger une instance Overpass privée ou utiliser l'API export d'OSM (`https://export.hotosm.org/`).

## Extension future

- **UUID déterministes** : baser les `poi_id` sur un hash de l'ID OSM pour la reproductibilité.
- **Filtre post-extraction** : rejeter les POI avec un score éditorial < 50 ou sans coordonnées précises.
- **Enrichissement Wikidata** : récupérer les descriptions multilingues et images via l'API Wikidata (REST).
- **Multi-source merge** : fusionner OSM + Wikidata + données officiles pour un même POI.
