# POI Supabase Import - 2026-05-14

## Context

- **Scope:** Seven active cities from `tool/poi/import_city_list.txt`.
- **Runner:** `tool/poi/import_poi_batch_from_local_secret.sh`.
- **Target:** Supabase POI knowledge base.
- **Result:** `Status: ALL PASSED`.

This document records the successful live Supabase import reported after running the batch importer from the main worktree. It intentionally does not include secret values or local report contents.

## Command Executed

```bash
cd /Users/lalith/Projets/Voyage
./tool/poi/import_poi_batch_from_local_secret.sh
```

## Imported Cities

| Destination | POIs | Aliases | Source Links | Tags | Quality Flags | Healthy | Idempotent |
|-------------|------|---------|--------------|------|---------------|---------|------------|
| london | 26 | 53 | 26 | 104 | 0 | true | true |
| amsterdam | 26 | 53 | 26 | 104 | 0 | true | true |
| paris | 25 | 49 | 25 | 100 | 0 | true | true |
| rome | 25 | 52 | 25 | 100 | 0 | true | true |
| barcelona | 25 | 54 | 25 | 100 | 0 | true | true |
| lisbon | 10 | 20 | 10 | 40 | 0 | true | true |
| marrakech | 26 | 54 | 26 | 104 | 0 | true | true |
| **Total** | **163** | **335** | **163** | **652** | **0** | **true** | **true** |

## Final Status

| Check | Result |
|-------|--------|
| Batch status | ALL PASSED |
| Healthy cities | 7 / 7 |
| Idempotent cities | 7 / 7 |
| Blocking errors | 0 |
| Quality flags | 0 |

## Warnings

- Several POIs do not have `official_url`.
- The missing `official_url` warnings were non-blocking.
- Lisbon remains less covered than the other active cities: 10 POIs versus 25-26 POIs elsewhere.

## Notes

- The active import manifest was limited to cities with available fixtures before this run.
- Backlog cities remained commented out and were not imported: `istanbul`, `cairo`, `bangkok`, `tokyo`, `singapore`.
- The run used local secrets through `.secrets.local`; no secret values are recorded here.
- The local `.local/` import report is an execution artifact and should remain unversioned.
