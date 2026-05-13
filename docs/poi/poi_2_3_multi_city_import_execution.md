# POI-2.3 — Multi-City POI Coverage Pack Import Execution

## Context

- **Jira:** POI-2.3
- **Depends on:** POI-2.2 (fixtures created), POI-1.6 (schema + Lisbon proven pipeline)
- **Scope:** Import Paris (25), Rome (25), Barcelona (25) curated POIs into Supabase staging.

## Pre-conditions

| Check | Status |
|-------|--------|
| Schema `poi_knowledge_base.sql` applied | ✅ (POI-1.6) |
| PostgREST compatibility fix active | ✅ (source_poi_identifier_key) |
| Lisbon import proven pipeline | ✅ (10 POIs) |
| All 3 fixtures ready | ✅ |
| Pre-check: 0 POIs for all 3 cities | ✅ |
| `SUPABASE_SECRET_KEY` available locally | ⚠️ Required for real writes |

## Dry-Run Results (All Clean)

### Paris
```
POIs: 25, Aliases: 49, Tags: 100, Source links: 25
Must-see: 8, Free: 11, Family-friendly: 25
Warnings: 7 (missing official_url for public spaces — expected)
Blocking errors: 0
```

### Rome
```
POIs: 25, Aliases: 52, Tags: 100, Source links: 25
Must-see: 8, Free: 11, Family-friendly: 25
Warnings: 9 (missing official_url — expected)
Blocking errors: 0
```

### Barcelona
```
POIs: 25, Aliases: 54, Tags: 100, Source links: 25
Must-see: 4, Free: 11, Family-friendly: 25
Warnings: 9 (missing official_url — expected)
Blocking errors: 0
```

## Manual Real Import Commands

> ⚠️ **Security:** The commands below reference `$SUPABASE_SECRET_KEY` as a shell variable. Do **not** paste the key value into any chat, document, or commit. Set it in your shell environment first (e.g. `export SUPABASE_SECRET_KEY=sb_secret_xxx`).

### 1. Import Paris

```bash
cd /Users/lalith/Projets/Voyage && \
dart run \
  --define=SUPABASE_URL="$SUPABASE_URL" \
  --define=SUPABASE_SECRET_KEY="$SUPABASE_SECRET_KEY" \
  tool/poi/run_pilot_import.dart \
  test/fixtures/poi/pilot_pois_paris.json \
  --write
```

### 2. Import Rome

```bash
cd /Users/lalith/Projets/Voyage && \
dart run \
  --define=SUPABASE_URL="$SUPABASE_URL" \
  --define=SUPABASE_SECRET_KEY="$SUPABASE_SECRET_KEY" \
  tool/poi/run_pilot_import.dart \
  test/fixtures/poi/pilot_pois_rome.json \
  --write
```

### 3. Import Barcelona

```bash
cd /Users/lalith/Projets/Voyage && \
dart run \
  --define=SUPABASE_URL="$SUPABASE_URL" \
  --define=SUPABASE_SECRET_KEY="$SUPABASE_SECRET_KEY" \
  tool/poi/run_pilot_import.dart \
  test/fixtures/poi/pilot_pois_barcelona.json \
  --write
```

## Post-Import Verification Commands

Run after each real import (or all at once after all three are done):

```bash
cd /Users/lalith/Projets/Voyage && \
dart run \
  --define=SUPABASE_URL="$SUPABASE_URL" \
  --define=SUPABASE_SECRET_KEY="$SUPABASE_SECRET_KEY" \
  tool/poi/verify_import.dart --destination paris && \
dart run \
  --define=SUPABASE_URL="$SUPABASE_URL" \
  --define=SUPABASE_SECRET_KEY="$SUPABASE_SECRET_KEY" \
  tool/poi/verify_import.dart --destination rome && \
dart run \
  --define=SUPABASE_URL="$SUPABASE_URL" \
  --define=SUPABASE_SECRET_KEY="$SUPABASE_SECRET_KEY" \
  tool/poi/verify_import.dart --destination barcelona
```

## Idempotence Test Commands

Re-run any import a second time; counts should remain unchanged (all rows use `upsert` with `onConflict` on natural keys):

```bash
cd /Users/lalith/Projets/Voyage && \
dart run \
  --define=SUPABASE_URL="$SUPABASE_URL" \
  --define=SUPABASE_SECRET_KEY="$SUPABASE_SECRET_KEY" \
  tool/poi/run_pilot_import.dart \
  test/fixtures/poi/pilot_pois_paris.json \
  --write
```

Then re-run verification and confirm counts are identical to the first run.

## Expected Final State

| Destination | POIs | Aliases | Tags | Source Links | Flags |
|-------------|------|---------|------|--------------|-------|
| Lisbon (existing) | 10 | 20 | 40 | 10 | 0 |
| **Paris** | **25** | **49** | **100** | **25** | **0** |
| **Rome** | **25** | **52** | **100** | **25** | **0** |
| **Barcelona** | **25** | **54** | **100** | **25** | **0** |
| **Total** | **85** | **175** | **340** | **85** | **0** |

## Execution Status

| Date | Action | Result |
|------|--------|--------|
| 2026-05-12 | Dry-run Paris, Rome, Barcelona | All clean (0 blocking errors) |
| 2026-05-12 | Pre-check Supabase counts | 0 POIs for all 3 cities |
| 2026-05-12 | Prepare manual commands | Committed to docs |
| 2026-05-13 | Re-check Supabase counts | **Still 0 POIs for all 3 cities** — real imports not yet executed |

## Checklist

- [ ] Paris real import executed
- [ ] Rome real import executed
- [ ] Barcelona real import executed
- [ ] Post-import verification passed for all 3 cities
- [ ] Idempotence test passed (re-run + counts unchanged)
