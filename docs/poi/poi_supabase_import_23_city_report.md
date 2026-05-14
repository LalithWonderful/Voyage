# POI Supabase Import — 23-City Verification Report

## Metadata

- **Date**: 2026-05-14
- **Commit main utilisé**: `1c01ce2 docs(poi): document safe supabase import workflow`
- **Vérification lancée depuis**: `/Users/lalith/Projets/Voyage`
- **Outil de vérification**: `tool/poi/verify_import.dart`
- **Corrections appliquées**: pagination dans `SupabasePoiImportCheckReader`

## Status global

| Indicateur | Valeur |
|---|---|
| Villes actives | 23 |
| Villes healthy | 23 / 23 |
| Villes avec anomalies | 0 |
| Total POIs | 402 |
| Total aliases | 475 |
| Total links | 402 |
| Total tags | 1377 |
| Total flags | 0 |

## Tableau par ville

| City | POIs | Aliases | Links | Tags | Flags | Healthy | Issue |
|---|---|---|---|---|---|---|---|
| london | 26 | 53 | 26 | 104 | 0 | true | — |
| amsterdam | 26 | 53 | 26 | 104 | 0 | true | — |
| paris | 25 | 49 | 25 | 100 | 0 | true | — |
| rome | 25 | 52 | 25 | 100 | 0 | true | — |
| barcelona | 25 | 54 | 25 | 100 | 0 | true | — |
| lisbon | 10 | 20 | 10 | 40 | 0 | true | — |
| marrakech | 26 | 54 | 26 | 104 | 0 | true | — |
| istanbul | 20 | 24 | 20 | 65 | 0 | true | — |
| cairo | 15 | 17 | 15 | 50 | 0 | true | — |
| bangkok | 18 | 23 | 18 | 51 | 0 | true | — |
| tokyo | 19 | 24 | 19 | 60 | 0 | true | — |
| singapore | 18 | 18 | 18 | 54 | 0 | true | — |
| madrid | 15 | 15 | 15 | 48 | 0 | true | — |
| vienna | 15 | 15 | 15 | 48 | 0 | true | — |
| prague | 15 | 15 | 15 | 45 | 0 | true | — |
| berlin | 15 | 15 | 15 | 49 | 0 | true | — |
| dublin | 15 | 16 | 15 | 48 | 0 | true | — |
| edinburgh | 15 | 15 | 15 | 48 | 0 | true | — |
| athens | 15 | 16 | 15 | 47 | 0 | true | — |
| venice | 15 | 19 | 15 | 49 | 0 | true | — |
| florence | 15 | 17 | 15 | 48 | 0 | true | — |
| new-york | 20 | 23 | 20 | 64 | 0 | true | — |
| dubai | 17 | 17 | 17 | 51 | 0 | true | — |

## Anomalies détectées

### A1 — Sous-comptage des tags sur les villes importées en dernier
**Symptôme** : Lors de la vérification initiale, plusieurs villes affichaient `Tags: 0` ou un nombre anormalement bas (ex: dubai 0, vienna 0, prague 0, berlin 0, dublin 0, edinburgh 2, venice 0, florence 5, new-york 0, tokyo 26).

**Racine** : `SupabasePoiImportCheckReader.select()` effectuait une requête `SELECT *` sans pagination sur les tables enfants (`poi_tags`, `poi_aliases`, `poi_source_links`, `poi_quality_flags`). PostgREST limite par défaut le résultat à 1000 lignes. Avec 1377+ tags en base, seules les ~1000 premières lignes étaient retournées, excluant les villes importées en dernier du comptage.

**Impact** : Le script batch affichait `Status: ALL PASSED` car `isHealthy` ne vérifie que les anomalies (doublons, FK), pas la cohérence des counts. L'anomalie Dubai `Tags: 0` était donc un artefact de mesure, pas une perte de données.

## Corrections appliquées

1. **Pagination dans `SupabasePoiImportCheckReader.select()`** :
   - Ajout d'une boucle de pagination par blocs de 1000 lignes via `.range()`.
   - Les filtres `.eq()` sont appliqués avant `.range()` pour respecter la chaîne de méthodes PostgREST.
   - Fichier modifié : `lib/features/poi/tools/poi_supabase_import_checker.dart`.

2. **Réimport idempotent de Tokyo** (interrompu puis validé) :
   - Un réimport batch a été partiellement lancé pour Tokyo et Vienne mais interrompu par timeout.
   - L'upsert étant idempotent, aucune donnée n'a été corrompue.
   - La vérification post-correction confirme que tous les counts sont conformes aux fixtures.

## Tests lancés

| Test | Résultat |
|---|---|
| `flutter test test/poi/poi_fixture_multi_city_test.dart` | ✅ 345 tests passés |
| `flutter test test/poi/poi_staging_import_test.dart` | ✅ 23 tests passés |
| `bash -n tool/poi/import_poi_batch_from_local_secret.sh` | ✅ OK |
| Vérification Supabase live 23 villes (post-fix) | ✅ Tous les counts conformes |

## Limites connues

- `verify_import.dart` reste un outil de lecture seule ; il ne détecte toujours pas automatiquement un écart entre le count DB et le count fixture (il vérifie les anomalies structurelles uniquement).
- La requête `select('*')` sans `ORDER BY` sur les tables enfants dépend de l'ordre physique PostgreSQL ; la pagination corrige le volume mais pas l'ordre.
- Le batch importer ne logue pas le delta entre `insert_counts` du staging et les counts réels post-import.

## Actions recommandées

1. **Monitoring** : ajouter une assertion dans `PoiSupabaseImportChecker` qui compare `tagCount` (et les autres counts) avec le plan de staging, pour détecter un écart > 0 comme anomaly.
2. **Outillage** : exporter `verify_import.dart` pour qu'il accepte un `--expected-tags` ou qu'il lise le fixture pour comparaison.
3. **Future imports** : toujours valider les counts avec le reader paginé avant de marquer une ville comme `Healthy`.

## Confirmations

- ✅ Aucun secret (SUPABASE_SECRET_KEY) n'a été affiché dans les logs ou ce rapport.
- ✅ Aucun appel Google Places, Geocoding, Routes, Gemini ou Overpass n'a été effectué.
- ✅ Aucun import Supabase réel n'a été lancé hors du worktree principal.
- ✅ `.local/` est un artefact d'exécution et n'a pas été versionné.
- ✅ `.secrets.local` n'a pas été modifié.
