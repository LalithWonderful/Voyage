# POI-1.2 — Pipeline de review et enrichment offline pour fixtures POI

## Objectif

Outil de curation offline permettant de transformer un fixture OSM brut (généré par POI-1.1) en fixture Lunao reviewé et enrichi, sans modifier le fichier brut et sans écrire en Supabase.

Le principe fondamental est la **séparation stricte** entre :
- **Extraction automatique** (POI-1.1) → `*_osm_raw.json`
- **Curation manuelle** (POI-1.2) → `*_overrides.json`
- **Fixture final** (POI-1.2) → `*_reviewed.json`

## Architecture

```
┌─────────────────────┐     ┌──────────────────────┐     ┌─────────────────────┐
│ singapore_osm_raw   │────▶│  PoiFixtureReviewer  │────▶│ singapore_reviewed  │
│   .json (POI-1.1)   │     │                      │     │   .json             │
└─────────────────────┘     │  - loadOverrides()   │     └─────────────────────┘
                            │  - buildReviewed()   │              │
┌─────────────────────┐     │  - generateReport()  │              ▼
│ singapore_overrides │────▶│                      │     ┌─────────────────────┐
│   .json (manuel)    │     └──────────────────────┘     │  quality_report.md  │
└─────────────────────┘                                  └─────────────────────┘
```

## Workflow de review

### 1. Extraction automatique

```bash
dart tool/poi/extract_osm_pois.dart --destination singapore --country SG \
  > singapore_osm_raw.json
```

### 2. Génération du reviewed + rapport (sans overrides)

```bash
dart tool/poi/review_poi_fixture.dart \
  --raw singapore_osm_raw.json \
  --out singapore_reviewed.json \
  --report quality_report.md \
  --json-report quality_report.json
```

### 3. Analyse du rapport

Le rapport Markdown liste les problèmes détectés :
- **Erreurs** : doublons par nom ou coordonnées
- **Warnings** : score faible, catégorie fallback, noms suspects
- **Infos** : peu de tags, pas de source secondaire

### 4. Création des overrides

Créer un fichier `singapore_overrides.json` :

```json
{
  "overrides": {
    "poi-uuid-001": {
      "name": "Gardens by the Bay",
      "category": "park",
      "editorial_score": 98,
      "is_must_see": true,
      "tags": [
        {"tag": "night_photography", "tag_category": "vibe", "confidence": 95},
        {"tag": "indoor_conservatory", "tag_category": "activity_type", "confidence": 90},
        {"tag": "wheelchair_accessible", "tag_category": "accessibility", "confidence": 85}
      ]
    },
    "poi-uuid-042": {
      "removed": true
    }
  }
}
```

### 5. Regénération avec overrides

```bash
dart tool/poi/review_poi_fixture.dart \
  --raw singapore_osm_raw.json \
  --overrides singapore_overrides.json \
  --out singapore_reviewed.json \
  --report quality_report.md
```

Le fichier `singapore_reviewed.json` est le fixture final. Le raw n'a jamais été modifié.

## Format d'override

Chaque clé est un `poi_id`. Tous les champs sont optionnels sauf `removed`.

| Champ | Type | Effet |
|-------|------|-------|
| `name` | string | Remplace le nom + recalcule `normalized_name` + met à jour l'alias canonical |
| `category` | string | Remplace la catégorie |
| `editorial_score` | int | Remplace le score |
| `touristic_importance` | int | Remplace l'importance |
| `typical_duration_minutes` | int | Remplace la durée |
| `price_level` | int | Remplace le niveau de prix |
| `is_must_see` | bool | Remplace le flag |
| `is_family_friendly` | bool | Remplace le flag |
| `is_rain_friendly` | bool | Remplace le flag |
| `is_free` | bool | Remplace le flag |
| `tags` | list | Remplace la liste de tags |
| `aliases` | list | Remplace la liste d'aliases |
| `removed` | bool | `true` = supprime le POI du fixture final |

## Détections du rapport qualité

### Erreurs (severity: error)

| Détection | Règle | Action recommandée |
|-----------|-------|-------------------|
| Doublon par nom | Deux POI ont le même `normalized_name` | Fusionner, supprimer, ou renommer |
| Doublon par proximité | Deux POI à < 100m l'un de l'autre | Vérifier s'il s'agit du même lieu |

### Warnings (severity: warning)

| Détection | Règle | Action recommandée |
|-----------|-------|-------------------|
| Score faible | `editorial_score < 50` | Rechercher des sources, enrichir |
| Catégorie fallback | `category == must_see && subcategory == attraction` | Assigner une catégorie plus précise |
| Nom suspect | Le nom contient "building", "hotel", "shop", etc. | Renommer avec un nom plus descriptif |

### Infos (severity: info)

| Détection | Règle | Action recommandée |
|-----------|-------|-------------------|
| Pas de source secondaire | `editorial_score == 60` (base, pas de wiki) | Ajouter wikidata/wikipedia si disponible |
| Peu de tags | Moins de 3 tags | Enrichir les tags manuellement |

## Paramètres configurables

```dart
PoiFixtureReviewer(
  rawFixture: rawJson,
  overrides: overrides,
  duplicateDistanceThreshold: 100.0,  // mètres
  lowScoreThreshold: 50,              // score minimum
);
```

## Fichiers

| Fichier | Description |
|---------|-------------|
| `lib/features/poi/tools/poi_fixture_reviewer.dart` | Logique de review et génération de rapport |
| `tool/poi/review_poi_fixture.dart` | Script CLI |
| `test/poi/poi_fixture_reviewer_test.dart` | Tests offline |
| `docs/poi/poi_1_2_fixture_review_pipeline.md` | Ce document |

## Extension future

- **Override template** : générer automatiquement un fichier overrides.json vide pré-rempli avec les POI ayant des warnings, pour faciliter la review manuelle.
- **Merge multi-source** : fusionner les overrides de plusieurs revieweurs.
- **Versioning des overrides** : historique git-friendly des corrections.
- **Validation interactive** : mode "dry-run" qui affiche les différences avant application.
