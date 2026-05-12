# POI-1.6 — First Real Supabase Pilot Import Execution Report

## Date
2026-05-12

## Pilot Fixture
`test/fixtures/poi/pilot_pois_lisbon.json`
- Destination: `lisbon`
- 1 source, 10 POIs, 20 aliases, 10 source_links, 40 tags, 0 quality_flags

## 1. Schema State

Schema `supabase/sql/poi_knowledge_base.sql` applied successfully in Supabase SQL Editor.
All 6 POI tables verified present before first write attempt.

## 2. First Real Write

**Target host:** `qfadipkbhuohujxlgrnn.supabase.co`
**Command (secrets redacted):**
```bash
dart run \
  --define=ALLOW_POI_SUPABASE_WRITE=true \
  --define=SUPABASE_URL=https://qfadipkbhuohujxlgrnn.supabase.co \
  --define=SUPABASE_SECRET_KEY=<YOUR_SECRET_KEY> \
  tool/poi/run_pilot_import.dart \
  test/fixtures/poi/pilot_pois_lisbon.json \
  --write
```

(If `SUPABASE_SECRET_KEY` is unavailable, `SUPABASE_SERVICE_ROLE_KEY` is accepted as a fallback.)

**Result:** ✅ COMPLETED
- Validation passed: true
- Can proceed: true
- Write executed: true
- Inserted counts: {poi_sources: 1, pois: 10, poi_aliases: 20, poi_source_links: 10, poi_tags: 40, poi_quality_flags: 0}

**Note:** The first write attempt failed at `poi_source_links` with `column "poi_source_links_unique_link" does not exist` (code: 42703). This was caused by PostgREST treating the unique expression index name as a column name. The fix (generated stored column + unique constraint on column list) was applied before the successful first write documented here.

## 3. First Verification

**Command:**
```bash
dart run \
  --define=SUPABASE_URL=https://qfadipkbhuohujxlgrnn.supabase.co \
  --define=SUPABASE_SECRET_KEY=<YOUR_SECRET_KEY> \
  tool/poi/verify_import.dart \
  --destination lisbon
```

(If `SUPABASE_SECRET_KEY` is unavailable, `SUPABASE_ANON_KEY` is accepted as a fallback.)

**Result:** ✅ HEALTHY
- POIs: 10
- Aliases: 20
- Links: 10
- Tags: 40
- Flags: 0
- Anomalies: 0
- isHealthy: true

## 4. Idempotence Test (Second Import)

**Command:** Same as step 2.

**Result:** ✅ COMPLETED
- No duplicates created
- Counts unchanged
- All upserts behaved idempotently

## 5. Final Verification

**Command:** Same as step 3.

**Result:** ✅ HEALTHY
- POIs: 10
- Aliases: 20
- Links: 10
- Tags: 40
- Flags: 0
- Anomalies: 0
- isHealthy: true

## 6. Schema Fix Applied During POI-1.6

A PostgREST compatibility issue was discovered and fixed before the successful import:

**Problem:** `poi_source_links` used a `CREATE UNIQUE INDEX` on an expression (`coalesce(source_poi_identifier, '')`). PostgREST `upsert onConflict` rejected the index name `poi_source_links_unique_link` with code 42703 (column does not exist).

**Fix in `supabase/sql/poi_knowledge_base.sql`:**
- Added generated stored column: `source_poi_identifier_key text generated always as (coalesce(source_poi_identifier, '')) stored`
- Replaced expression index with table-level `UNIQUE` constraint on `(poi_id, source_id, source_poi_identifier_key)`
- Added idempotent migration block for existing tables (ALTER TABLE ADD COLUMN IF NOT EXISTS + DROP INDEX IF EXISTS + DO $$ with pg_constraint check)

**Fix in `lib/features/poi/tools/poi_supabase_importer.dart`:**
- Changed `onConflict` for `poi_source_links` from index name `poi_source_links_unique_link` to PostgREST-compatible column list: `poi_id,source_id,source_poi_identifier_key`

## 7. CLI Changes

- `tool/poi/run_pilot_import.dart`: Updated to accept `SUPABASE_SECRET_KEY` (preferred) or `SUPABASE_SERVICE_ROLE_KEY` (fallback) for real writes, since POI tables have RLS write = service_role only.
- `tool/poi/verify_import.dart`: New read-only verification CLI using `PoiSupabaseImportChecker`.

## 8. Test Results

All POI tests pass: **267 passing, 5 skipped (live tests)**.

## 9. Security

- No service_role key is stored in source code or committed.
- Credentials are passed exclusively via `--define` at runtime.
- The existing hardcoded anon key in `lib/core/constants/supabase_constants.dart` is used only for read-only verification and schema checks.

## 10. Final State

| Table | Rows (Lisbon) | Status |
|-------|---------------|--------|
| `poi_sources` | 1 | ✅ |
| `pois` | 10 | ✅ |
| `poi_aliases` | 20 | ✅ |
| `poi_source_links` | 10 | ✅ |
| `poi_tags` | 40 | ✅ |
| `poi_quality_flags` | 0 | ✅ |

**Idempotence validated. Import pipeline is production-ready for pilot destinations.**
