# POI-1.4 — First Real Supabase Import Validation

## Objective
Validate the end-to-end Supabase import flow for a single pilot destination
(Lisbon, 10 POIs) using the existing POI-1.3 importer.

## 1. Constraint Safety Review — `poi_source_links`

The SQL unique constraint on `poi_source_links` is:

```sql
unique (poi_id, source_id, coalesce(source_poi_identifier, ''))
```

**Verdict: SAFE.**

Because `poi_id` is the first column in the constraint, every POI gets its own
unique row even when multiple POIs share the same `source_id` and have an empty
`source_poi_identifier`. The staging importer sets `source_poi_identifier = ''`
for all primary source links, and this does not cause collisions.

A regression test (`test/poi/poi_staging_import_test.dart`) confirms that a
fixture with 3 POIs sharing the same `source_primary_id` produces zero blocking
errors.

## 2. Pilot Fixture

File: `test/fixtures/poi/pilot_pois_lisbon.json`

- 1 source (Lunao Pilot Lisbon, editorial)
- 10 POIs covering monuments, museums, neighborhoods, food, viewpoints, family
- Stable UUID v5 ids
- Manually curated, no scraping

### Validate the fixture (dry-run)

```bash
dart run tool/poi/import_poi_to_supabase.dart \
  test/fixtures/poi/pilot_pois_lisbon.json
```

Expected output: `canProceed: true`, zero blocking errors.

## 3. Real Import Procedure

### Prerequisites
- `SUPABASE_URL` and `SUPABASE_ANON_KEY` set via `--dart-define`
- `ALLOW_POI_SUPABASE_WRITE=true` for real writes

### Step 1 — Dry-run

```bash
dart run tool/poi/import_poi_to_supabase.dart \
  test/fixtures/poi/pilot_pois_lisbon.json
```

### Step 2 — Real write

```bash
dart run --define=ALLOW_POI_SUPABASE_WRITE=true \
         --define=SUPABASE_URL=<your-url> \
         --define=SUPABASE_ANON_KEY=<your-key> \
         tool/poi/import_poi_to_supabase.dart \
         test/fixtures/poi/pilot_pois_lisbon.json --write
```

### Step 3 — Post-import verification

Use the `PoiSupabaseImportChecker` programmatically, or run manual SQL queries.

**Programmatic check (Dart snippet):**

```dart
import 'package:supabase/supabase.dart';
import 'package:voyage/features/poi/tools/poi_supabase_import_checker.dart';

void main() async {
  final client = SupabaseClient(url, anonKey);
  final reader = SupabasePoiImportCheckReader(client);
  final checker = PoiSupabaseImportChecker(reader);
  final report = await checker.checkDestination('lisbon');
  print(report);
  await client.dispose();
}
```

**Manual SQL verification queries:**

```sql
-- Count POIs for the pilot destination
SELECT count(*) FROM public.pois WHERE destination_key = 'lisbon';
-- Expected: 10

-- Count child rows linked to Lisbon POIs
SELECT count(*) FROM public.poi_aliases a
JOIN public.pois p ON a.poi_id = p.poi_id
WHERE p.destination_key = 'lisbon';

SELECT count(*) FROM public.poi_source_links l
JOIN public.pois p ON l.poi_id = p.poi_id
WHERE p.destination_key = 'lisbon';

SELECT count(*) FROM public.poi_tags t
JOIN public.pois p ON t.poi_id = p.poi_id
WHERE p.destination_key = 'lisbon';

-- Detect duplicate aliases (should return 0 rows)
SELECT a.poi_id, a.alias_normalized, count(*)
FROM public.poi_aliases a
JOIN public.pois p ON a.poi_id = p.poi_id
WHERE p.destination_key = 'lisbon'
GROUP BY a.poi_id, a.alias_normalized
HAVING count(*) > 1;

-- Detect duplicate tags (should return 0 rows)
SELECT t.poi_id, t.tag, count(*)
FROM public.poi_tags t
JOIN public.pois p ON t.poi_id = p.poi_id
WHERE p.destination_key = 'lisbon'
GROUP BY t.poi_id, t.tag
HAVING count(*) > 1;

-- Detect duplicate quality flags (should return 0 rows)
SELECT f.poi_id, f.flag_type, f.flag_reason, count(*)
FROM public.poi_quality_flags f
JOIN public.pois p ON f.poi_id = p.poi_id
WHERE p.destination_key = 'lisbon'
GROUP BY f.poi_id, f.flag_type, f.flag_reason
HAVING count(*) > 1;

-- Detect duplicate source links (should return 0 rows)
SELECT l.poi_id, l.source_id, coalesce(l.source_poi_identifier, ''), count(*)
FROM public.poi_source_links l
JOIN public.pois p ON l.poi_id = p.poi_id
WHERE p.destination_key = 'lisbon'
GROUP BY l.poi_id, l.source_id, coalesce(l.source_poi_identifier, '')
HAVING count(*) > 1;
```

### Step 4 — Idempotence check

Run the **same** import command a second time. The `upsert` strategy in
`SupabasePoiStagingWriteExecutor` updates existing rows instead of creating
duplicates.

Verify that counts from Step 3 remain unchanged.

## 4. Rollback / Cleanup

To remove the pilot data if needed:

```sql
-- Delete child rows first (FK on delete cascade handles most,
-- but explicit deletes are safer for audit)
DELETE FROM public.poi_quality_flags
WHERE poi_id IN (SELECT poi_id FROM public.pois WHERE destination_key = 'lisbon');

DELETE FROM public.poi_tags
WHERE poi_id IN (SELECT poi_id FROM public.pois WHERE destination_key = 'lisbon');

DELETE FROM public.poi_source_links
WHERE poi_id IN (SELECT poi_id FROM public.pois WHERE destination_key = 'lisbon');

DELETE FROM public.poi_aliases
WHERE poi_id IN (SELECT poi_id FROM public.pois WHERE destination_key = 'lisbon');

DELETE FROM public.pois WHERE destination_key = 'lisbon';

-- Optional: remove the pilot source if it was the only one
-- DELETE FROM public.poi_sources WHERE source_id = '1ba6e190-7222-5c97-b7f1-b7cc2775473e';
```

**Warning:** Only run cleanup on the pilot destination. Do not delete data from
other destinations.

## 5. Test Results

All POI tests must pass before and after POI-1.4:

```bash
flutter test test/poi/
```

Expected: 260+ passing, 5 skipped (live tests).
