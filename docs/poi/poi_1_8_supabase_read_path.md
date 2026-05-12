# POI-1.8 — Supabase POI Read Path

## Objective

Implement the minimal read path that allows Lunao to load POIs from Supabase by `destination_key`.

## Status

✅ Completed.

## Read Methods

The `PoiRepository` interface now exposes these read methods:

| Method | Description |
|--------|-------------|
| `listPoisByDestination(destinationKey)` | All POIs for a destination, ordered by editorial score desc, then name asc |
| `getPoiById(poiId)` | Single POI by UUID, or `null` |
| `getTopPoisForDestination(destinationKey, limit)` | Top-N POIs for a destination, same ordering |
| `getPoisByCategories(destinationKey, categories)` | POIs filtered by one or more categories (OR logic), same ordering |
| `searchPois({destinationKey, query, tags, category, mustSeeOnly, limit})` | Full-text + tag + category + must-see search |

## Implementations

### `SupabasePoiRepository` (`lib/features/poi/data/supabase_poi_repository.dart`)

Reads from Supabase via the abstract `PoiSupabaseClient` adapter.
- Uses PostgREST `.eq()`, `.inFilter()`, `.order()`, `.limit()`
- No direct `supabase_flutter` dependency — injectable for testing

### `FakePoiRepository` (`lib/features/poi/data/fake_poi_repository.dart`)

In-memory implementation for offline tests and local development.
- Resolves aliases and tags by linear scan
- Deterministic ordering matching Supabase behavior

## Mapping Supabase → Domain

Supabase rows are mapped to existing domain models via `fromJson()` factories:

- `public.pois` → `Poi`
- `public.poi_aliases` → `PoiAlias`
- `public.poi_tags` → `PoiTag`

Aliases and tags are queried during `searchPois` but remain separate models (not embedded in `Poi`).

## Usage Example

```dart
import 'package:voyage/features/poi/data/supabase_poi_repository.dart';
import 'package:voyage/features/poi/data/live_poi_supabase_client.dart';

final client = LivePoiSupabaseClient(supabase.instance.client);
final repo = SupabasePoiRepository(client);

// List all Lisbon POIs
final allPois = await repo.listPoisByDestination('lisbon');

// Top 5 Lisbon POIs
final top5 = await repo.getTopPoisForDestination('lisbon', 5);

// Museums and monuments in Lisbon
final museums = await repo.getPoisByCategories(
  'lisbon',
  [PoiCategory.museum, PoiCategory.monument],
);

// Search with filters
final results = await repo.searchPois(
  destinationKey: 'lisbon',
  query: 'castle',
  mustSeeOnly: true,
  limit: 10,
);
```

## Test Results

All POI tests pass:
- **267+ passing** (including new read-path tests)
- **5 skipped** (live Overpass/Supabase tests)
- **0 failures**

## Files Changed

- `lib/features/poi/domain/poi_repository.dart` — added `getTopPoisForDestination` and `getPoisByCategories`
- `lib/features/poi/data/supabase_poi_repository.dart` — implemented new methods
- `lib/features/poi/data/fake_poi_repository.dart` — implemented new methods
- `test/poi/poi_repository_contract_test.dart` — added contract tests
- `test/poi/supabase_poi_repository_test.dart` — added Supabase adapter tests
