# POI-0.6 — Repository Contract + Fake Offline

## Objectif

Définir le contrat de lecture POI côté application sans aucune infrastructure
live (pas de Supabase, pas de réseau, pas de credentials). Valider comment
Lunao consommera les POI avant de brancher une vraie source de données.

## Livrables

| Fichier | Description |
|---------|-------------|
| `lib/features/poi/domain/poi_repository.dart` | Interface abstraite `PoiRepository` |
| `lib/features/poi/data/fake_poi_repository.dart` | Implémentation `FakePoiRepository` 100 % offline |
| `test/poi/poi_repository_contract_test.dart` | 30 tests de contrat repository |
| `docs/poi/poi_0_6_repository_contract.md` | Ce document |

## Architecture

```
lib/features/poi/
├── domain/
│   ├── poi.dart                    (POI-0.5)
│   ├── poi_source.dart             (POI-0.5)
│   ├── poi_alias.dart              (POI-0.5)
│   ├── poi_tag.dart                (POI-0.5)
│   ├── poi_source_link.dart        (POI-0.5)
│   ├── poi_quality_flag.dart       (POI-0.5)
│   └── poi_repository.dart         ← POI-0.6 (contrat)
└── data/
    └── fake_poi_repository.dart    ← POI-0.6 (fake)
```

## Contrat PoiRepository

### Méthodes MVP

| Méthode | Signature | Comportement |
|---------|-----------|--------------|
| `listPoisByDestination` | `Future<List<Poi>> listPoisByDestination(String destinationKey)` | Tous les POIs de la destination. Ordre déterministe (score desc, nom asc). Destination inconnue → liste vide. |
| `getPoiById` | `Future<Poi?> getPoiById(String poiId)` | POI par UUID ou `null`. |
| `searchPois` | `Future<List<Poi>> searchPois({required String destinationKey, String? query, List<String>? tags, PoiCategory? category, bool mustSeeOnly = false, int? limit})` | Recherche filtrée. Filtres combinables par ET (sauf tags = OR interne). |

### Règles de `searchPois`

1. **Destination obligatoire** : `destinationKey` est toujours requis.
2. **Query** (optionnel) : recherche insensible à la casse dans :
   - `Poi.name`
   - `Poi.normalizedName`
   - `PoiAlias.alias` et `PoiAlias.aliasNormalized`
3. **Tags** (optionnel) : logique **OR** — un POI match s'il possède au moins un
des tags listés. La comparaison est insensible à la casse.
4. **Category** (optionnel) : filtre exact sur `Poi.category`.
5. **mustSeeOnly** (défaut `false`) : ne garde que `Poi.isMustSee == true`.
6. **Limit** (optionnel) : coupe le résultat après le tri.
7. **Ordre** : `editorialScore` décroissant (nulls en dernier), puis `name`
croissant. Strictement déterministe.

### Ce qui est volontairement hors scope

- Pagination (cursor-based) — ajoutable sans breaking change.
- Recherche géographique (bbox, radius) — nécessite un index spatial.
- Lecture des sous-ressources (aliases, tags, links, flags) par POI —
  `PoiRepository` retourne des `Poi` uniquement. Les détails viendront
  avec des méthodes additionnelles (`getPoiAliases`, etc.).
- Écriture (insert/update/delete) — réservé au `service_role` côté
  Supabase ; pas de contrat côté client pour l'instant.

## FakePoiRepository

### Implémentation

- Stockage 100 % en mémoire via 3 listes injectées en constructeur :
  - `List<Poi> pois`
  - `List<PoiAlias> aliases`
  - `List<PoiTag> tags`
- Les jointures sont résolues par scan linéaire (acceptable pour les fixtures
  et les tests unitaires).
- Toutes les méthodes retournent des `Future` (cohérent avec le contrat async),
  mais résolues immédiatement avec `Future.value`.

### Usage dans les tests

```dart
final fixture = _singaporeFixture();
final repo = FakePoiRepository(
  pois: fixture.pois,
  aliases: fixture.aliases,
  tags: fixture.tags,
);

final results = await repo.searchPois(
  destinationKey: 'singapore',
  query: 'gardens',
  mustSeeOnly: true,
  limit: 5,
);
```

## Tests

Le fichier `test/poi/poi_repository_contract_test.dart` contient **30 tests**
répartis en :

1. **listPoisByDestination** — lecture destination, ordre déterministe,
   destination inconnue, POIs sans score.
2. **getPoiById** — hit et miss.
3. **searchPois by query** — vide, match nom, match normalized_name,
   match alias, match alias display name, no match, destination inconnue,
   blank query.
4. **searchPois by category** — filtre exact, no match.
5. **searchPois by tags** — single tag, OR logic, unknown tag, empty list.
6. **searchPois mustSeeOnly** — true et false.
7. **searchPois limit** — coupe à N, supérieur au set, zéro.
8. **searchPois combined filters** — query + category + mustSeeOnly,
   tags + limit.
9. **Edge cases** — repo vide, appels idempotents, contrat async.

## Transition vers Supabase (POI-0.7)

Le contrat `PoiRepository` est conçu pour que l'implémentation Supabase soit
un drop-in replacement :

```dart
class SupabasePoiRepository implements PoiRepository {
  final SupabaseClient _client;
  SupabasePoiRepository(this._client);

  @override
  Future<List<Poi>> listPoisByDestination(String destinationKey) async {
    final response = await _client
        .from('pois')
        .select()
        .eq('destination_key', destinationKey)
        .order('editorial_score', ascending: false);
    return response.map((r) => Poi.fromJson(r)).toList();
  }
  // ... etc.
}
```

Aucune modification du contrat n'est nécessaire. Les tests POI-0.6 peuvent
être réutilisés avec une implémentation Supabase de test (container local ou
project de staging) en POI-0.7.
