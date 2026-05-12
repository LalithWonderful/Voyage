# POI-1.5 — First Real Supabase Pilot Import Execution Report

## Date
2026-05-12

## Pilot Fixture
`test/fixtures/poi/pilot_pois_lisbon.json`
- Destination: `lisbon`
- 1 source, 10 POIs, 20 aliases, 10 source_links, 40 tags, 0 quality_flags

## 1. Git Working Tree
Modified files present (non-POI changes in planning/profile/trips screens).
All POI-1.4 deliverables are present and tracked:
- `lib/features/poi/tools/poi_supabase_import_checker.dart`
- `test/fixtures/poi/pilot_pois_lisbon.json`
- `test/poi/poi_supabase_import_checker_test.dart`
- `docs/poi/poi_1_4_first_supabase_import.md`

## 2. Dry-Run

**Command:**
```bash
dart run tool/poi/import_poi_to_supabase.dart \
  test/fixtures/poi/pilot_pois_lisbon.json
```

**Result:** ✅ CLEAN
- Validation passed: true
- Can proceed: true
- Blocking errors: 0
- Warnings: 3 (missing official_url for Alfama, Miradouro, Praça do Comércio)
- Expected counts: {poi_sources: 1, pois: 10, poi_aliases: 20, poi_source_links: 10, poi_tags: 40, poi_quality_flags: 0}

## 3. Real Write Attempt

**Target host:** `qfadipkbhuohujxlgrnn.supabase.co`
**Command template (secrets redacted):**
```bash
dart run --define=ALLOW_POI_SUPABASE_WRITE=true \
         tool/poi/import_poi_to_supabase.dart \
         test/fixtures/poi/pilot_pois_lisbon.json --write
```

**Result:** ❌ BLOCKED — Schema not applied

Error:
```
PostgrestException: Could not find the table 'public.poi_sources'
in the schema cache (code: PGRST205)
```

**Table verification performed:**
| Table | Status |
|-------|--------|
| `public.pois` | Missing |
| `public.poi_sources` | Missing |
| `public.poi_aliases` | Missing |
| `public.trip_documents` | Exists |

## 4. Post-Import Verification

**Not executed** — No data was written because the schema is missing.

## 5. Idempotence Check

**Not executed** — No data was written.

## 6. Rollback

**Not executed** — No data was written.

Rollback SQL is pre-documented in `docs/poi/poi_1_4_first_supabase_import.md` and remains ready for use after the first successful import.

## 7. CLI Fix Applied

During POI-1.5 execution a bug was discovered in `tool/poi/import_poi_to_supabase.dart`:
the CLI required `SUPABASE_URL` and `SUPABASE_ANON_KEY` even in dry-run mode.
A minimal fix was applied so that credentials are only required when `--write` is used.

## 8. Final Recommendation

**STOP — Apply schema before proceeding.**

The Supabase project `qfadipkbhuohujxlgrnn.supabase.co` does not have the POI
schema deployed. Before re-attempting the real import:

1. Open the Supabase SQL Editor for the target project.
2. Run the full contents of `supabase/sql/poi_knowledge_base.sql`.
3. Verify the 6 tables exist (`poi_sources`, `pois`, `poi_aliases`, `poi_source_links`, `poi_tags`, `poi_quality_flags`).
4. Re-run the dry-run: `dart run tool/poi/import_poi_to_supabase.dart test/fixtures/poi/pilot_pois_lisbon.json`
5. If clean, execute the real write with `--write`.
6. Run post-import verification.
7. Re-run the same import to validate idempotence.
8. Run verification again and confirm counts are unchanged.
9. Document results in a follow-up to this report.

**No schema modification, importer logic change, or fixture change is required.**
The only blocker is missing database schema deployment.
