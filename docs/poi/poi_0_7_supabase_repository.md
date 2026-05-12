# POI-0.7 — SupabasePoiRepository (read-only, offline-testable)

## Objectif

Préparer l'implémentation Supabase du repository POI sans jamais toucher à
une base live. Le code reste testable offline grâce à un adapter/client
injectable.

## Livrables

| Fichier | Description |
|---------|-------------|
| `lib/features/poi/data/poi_supabase_client.dart` | Interface `PoiSupabaseClient` + `PoiSupabaseQuery` |
| `lib/features/poi/data/supabase_poi_repository.dart` | `SupabasePoiRepository` implémentant `PoiRepository` |
| `test/poi/supabase_poi_repository_test.dart` | 33 tests avec `FakePoiSupabaseClient` |
| `docs/poi/poi_0_7_supabase_repository.md` | Ce document |

## Architecture

```
lib/features/poi/
├── domain/
│   ├── poi_repository.dart         ← POI-0.6 (contrat)
│   └── poi.dart                    ← POI-0.5 (modèles)
└── data/
    ├── poi_supabase_client.dart    ← POI-0.7 (adapter abstrait)
    ├── supabase_poi_repository.dart ← POI-0.7 (implémentation)
    └── fake_poi_repository.dart    ← POI-0.6 (fake simple)
```

### Pourquoi un adapter abstrait ?

`supabase_flutter` est un package lourd avec des dépendances natives
(`url_launcher`, `app_links`, etc.). En créant `PoiSupabaseClient` comme
interface pure Dart :
- On **ne dépend pas** de `supabase_flutter` dans `lib/features/poi/`.
- On peut tester `SupabasePoiRepository` avec un fake en mémoire.
- La transition vers le live consiste juste à implémenter l'interface avec
  un wrapper autour de `SupabaseClient`.

## Interface PoiSupabaseClient

### PoiSupabaseClient

```dart
abstract class PoiSupabaseClient {
  PoiSupabaseQuery from(String table);
}
```

### PoiSupabaseQuery (builder PostgREST minimal)

| Méthode | PostgREST équivalent | Usage dans SupabasePoiRepository |
|---------|---------------------|----------------------------------|
| `select([columns])` | `SELECT cols` | Projection de colonnes |
| `eq(column, value)` | `column = value` | Filtre destination_key, poi_id, category, is_must_see |
| `ilike(column, pattern)` | `column ILIKE pattern` | Recherche textuelle sur name, normalized_name, alias_normalized |
| `or(conditions)` | `OR(col.op.val, ...)` | Recherche nom OU normalized_name |
| `inFilter(column, values)` | `column IN (values)` | Intersection de poi_ids (tags, aliases, query) |
| `order(column, ascending)` | `ORDER BY col ASC/DESC` | Tri par editorial_score, name |
| `limit(count)` | `LIMIT count` | Limite de résultats |
| `execute()` | Exécute la requête | Retourne `List<Map<String, dynamic>>` |
| `maybeSingle()` | Exécute + limite 1 | Retourne `Map?` |

## SupabasePoiRepository

### Mapping méthodes → requêtes

#### `listPoisByDestination(destinationKey)`
```sql
SELECT * FROM pois
WHERE destination_key = 'singapore'
ORDER BY editorial_score DESC, name ASC
```

#### `getPoiById(poiId)`
```sql
SELECT * FROM pois
WHERE poi_id = 'poi-001'
LIMIT 1
```

#### `searchPois({destinationKey, query, tags, category, mustSeeOnly, limit})`

Algorithme en 4 étapes :

1. **Résoudre les poi_ids candidats par recherche textuelle** (si `query`):
   - Requête sur `pois.name ILIKE %query% OR pois.normalized_name ILIKE %query%`
   - Requête sur `poi_aliases.alias_normalized ILIKE %query%`
   - Union des `poi_id` trouvés. Si vide → retourne `[]`.

2. **Résoudre les poi_ids par tags** (si `tags` non vide):
   - Requête sur `poi_tags` avec `tag IN (tags)`
   - Intersection avec les candidats de l'étape 1 (si présents).
   - Si intersection vide → retourne `[]`.

3. **Requête principale sur `pois`** :
   - `destination_key = destinationKey`
   - `category = category` (si fourni)
   - `is_must_see = true` (si `mustSeeOnly`)
   - `poi_id IN (candidateIds)` (si des candidats ont été résolus)
   - `ORDER BY editorial_score DESC, name ASC`

4. **Appliquer `limit`** sur le résultat final.

### Aucun write

`SupabasePoiRepository` n'expose aucune méthode d'écriture. Les seules
opérations sont `SELECT`-like. C'est cohérent avec le schéma SQL où les
policies RLS n'autorisent que la lecture publique côté client.

## Tests offline

Le fichier `test/poi/supabase_poi_repository_test.dart` contient **33 tests** :

### FakePoiSupabaseClient / FakePoiSupabaseQuery

Implémentation en mémoire du client et du query builder. Supporte :
- `eq`, `ilike` (avec `%` wildcard), `or`, `inFilter`
- `order` multi-colonne stable (nulls last correctement gérés en ASC et DESC)
- `limit`, `select` (projection de colonnes), `maybeSingle`

### Tests de contrat repository (30 tests)

Mêmes scénarios que POI-0.6 mais passant par `SupabasePoiRepository` +
`FakePoiSupabaseClient` :
- `listPoisByDestination` — lecture, ordre, destination inconnue
- `getPoiById` — hit et miss
- `searchPois` — query (nom, normalized_name, alias), catégorie, tags (OR),
  mustSeeOnly, limit, combinaisons
- Edge cases — repo vide, idempotence, contrat async

### Tests unitaires du fake query builder (10 tests)

Valident que le fake client se combine correctement :
- `eq`, `ilike`, `or`, `inFilter`, `order` (ASC/DESC/nulls), `limit`,
  projection, `maybeSingle`

## Transition vers le live (future phase)

L'implémentation live sera un thin wrapper :

```dart
import 'package:supabase_flutter/supabase_flutter.dart';

class LivePoiSupabaseClient implements PoiSupabaseClient {
  final SupabaseClient _client;
  LivePoiSupabaseClient(this._client);

  @override
  PoiSupabaseQuery from(String table) => LivePoiSupabaseQuery(
    _client.from(table),
  );
}

class LivePoiSupabaseQuery implements PoiSupabaseQuery {
  final PostgrestQueryBuilder _builder;
  LivePoiSupabaseQuery(this._builder);

  @override
  PoiSupabaseQuery eq(String column, dynamic value) {
    _builder = _builder.eq(column, value);
    return this;
  }
  // ... etc.
}
```

Aucune modification de `SupabasePoiRepository` ni des tests n'est nécessaire.
Le contrat est stable.

## Limites connues

1. **Pas de jointure SQL** : la recherche par alias/tag fait 2-3 requêtes
   séparées puis intersecte en Dart. C'est acceptable pour le fake et pour
   des volumes < 10k POIs. À grande échelle, une vue matérialisée ou une
   requête SQL avec `JOIN` sera préférable.

2. **Pas de pagination** : `limit` existe mais pas de `offset` ni de
   cursor-based pagination. À ajouter plus tard sans breaking change.

3. **Pas de recherche géographique** : pas de `ST_DWithin` ou bbox filter.

4. **Pas de full-text search** : `ilike` sur `%query%` est une recherche
   par substring, pas un vrai FTS (tsvector / tsquery PostgreSQL).

## Contraintes respectées

- ✅ Aucun `supabase_flutter` importé dans `lib/features/poi/`
- ✅ Aucun credential, aucun appel réseau
- ✅ Aucun write (insert/update/delete)
- ✅ Aucun provider Riverpod
- ✅ Aucune UI, aucun moteur planning
- ✅ 100 % offline testable
