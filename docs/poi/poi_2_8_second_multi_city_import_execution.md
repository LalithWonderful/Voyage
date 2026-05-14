# POI-2.8 — Second Multi-City POI Coverage Pack Import Execution

## Context

- **Jira:** POI-2.8
- **Depends on:** POI-2.7 (fixtures created for London, Amsterdam, Marrakech)
- **Scope:** Import London (26), Amsterdam (26), Marrakech (26) curated POIs into Supabase.

## Pre-conditions

| Check | Status |
|-------|--------|
| Schema `poi_knowledge_base.sql` applied | ✅ (POI-1.6) |
| Lisbon + Paris + Rome + Barcelona imports proven | ✅ (POI-2.3) |
| All 3 fixtures ready and validated | ✅ (POI-2.7) |
| Pre-check: 0 POIs for all 3 cities in Supabase | ⚠️ Run verification command below |
| `SUPABASE_SECRET_KEY` available locally | ⚠️ Required for real writes |

## Dry-Run Results (All Clean)

### London
```
POIs: 26, Aliases: 53, Tags: 104, Source links: 26
Must-see: 6, Free: 16, Family-friendly: 25
Warnings: 5 (missing official_url for public spaces — expected)
Blocking errors: 0
Can proceed: true
```

### Amsterdam
```
POIs: 26, Aliases: 53, Tags: 104, Source links: 26
Must-see: 7, Free: 11, Family-friendly: 24
Warnings: 10 (missing official_url for public spaces — expected)
Blocking errors: 0
Can proceed: true
```

### Marrakech
```
POIs: 26, Aliases: 54, Tags: 104, Source links: 26
Must-see: 7, Free: 8, Family-friendly: 26
Warnings: 21 (missing official_url for public spaces — expected)
Blocking errors: 0
Can proceed: true
```

## Pre-Import Verification (Read-Only)

Run this first to confirm the 3 cities have **zero** existing POIs in Supabase:

```bash
cd /Users/lalith/Projets/Voyage-kimi && \
dart run \
  --define=ALLOW_LIVE_SUPABASE=true \
  --define=SUPABASE_URL="$SUPABASE_URL" \
  --define=SUPABASE_SECRET_KEY="$SUPABASE_SECRET_KEY" \
  tool/poi/verify_import.dart --destination london && \
dart run \
  --define=ALLOW_LIVE_SUPABASE=true \
  --define=SUPABASE_URL="$SUPABASE_URL" \
  --define=SUPABASE_SECRET_KEY="$SUPABASE_SECRET_KEY" \
  tool/poi/verify_import.dart --destination amsterdam && \
dart run \
  --define=ALLOW_LIVE_SUPABASE=true \
  --define=SUPABASE_URL="$SUPABASE_URL" \
  --define=SUPABASE_SECRET_KEY="$SUPABASE_SECRET_KEY" \
  tool/poi/verify_import.dart --destination marrakech
```

> Expected: all 3 report `POIs: 0` and `isHealthy: true` (empty is healthy).

## Manual Real Import Commands

> ⚠️ **Security:** The commands below reference `$SUPABASE_SECRET_KEY` as a shell variable. Do **not** paste the key value into any chat, document, or commit. Set it in your shell environment first (e.g. `export SUPABASE_SECRET_KEY=sb_secret_xxx`).

### 1. Import London

```bash
cd /Users/lalith/Projets/Voyage-kimi && \
dart run \
  --define=ALLOW_LIVE_SUPABASE=true \
  --define=ALLOW_POI_SUPABASE_WRITE=true \
  --define=SUPABASE_URL="$SUPABASE_URL" \
  --define=SUPABASE_SECRET_KEY="$SUPABASE_SECRET_KEY" \
  tool/poi/run_pilot_import.dart \
  test/fixtures/poi/pilot_pois_london.json \
  --write
```

### 2. Import Amsterdam

```bash
cd /Users/lalith/Projets/Voyage-kimi && \
dart run \
  --define=ALLOW_LIVE_SUPABASE=true \
  --define=ALLOW_POI_SUPABASE_WRITE=true \
  --define=SUPABASE_URL="$SUPABASE_URL" \
  --define=SUPABASE_SECRET_KEY="$SUPABASE_SECRET_KEY" \
  tool/poi/run_pilot_import.dart \
  test/fixtures/poi/pilot_pois_amsterdam.json \
  --write
```

### 3. Import Marrakech

```bash
cd /Users/lalith/Projets/Voyage-kimi && \
dart run \
  --define=ALLOW_LIVE_SUPABASE=true \
  --define=ALLOW_POI_SUPABASE_WRITE=true \
  --define=SUPABASE_URL="$SUPABASE_URL" \
  --define=SUPABASE_SECRET_KEY="$SUPABASE_SECRET_KEY" \
  tool/poi/run_pilot_import.dart \
  test/fixtures/poi/pilot_pois_marrakech.json \
  --write
```

## Post-Import Verification Commands

Run after all three imports are complete:

```bash
cd /Users/lalith/Projets/Voyage-kimi && \
dart run \
  --define=ALLOW_LIVE_SUPABASE=true \
  --define=SUPABASE_URL="$SUPABASE_URL" \
  --define=SUPABASE_SECRET_KEY="$SUPABASE_SECRET_KEY" \
  tool/poi/verify_import.dart --destination london && \
dart run \
  --define=ALLOW_LIVE_SUPABASE=true \
  --define=SUPABASE_URL="$SUPABASE_URL" \
  --define=SUPABASE_SECRET_KEY="$SUPABASE_SECRET_KEY" \
  tool/poi/verify_import.dart --destination amsterdam && \
dart run \
  --define=ALLOW_LIVE_SUPABASE=true \
  --define=SUPABASE_URL="$SUPABASE_URL" \
  --define=SUPABASE_SECRET_KEY="$SUPABASE_SECRET_KEY" \
  tool/poi/verify_import.dart --destination marrakech
```

## Idempotence Test Commands

Re-run any import a second time; counts should remain unchanged (all rows use `upsert` with `onConflict` on natural keys):

```bash
cd /Users/lalith/Projets/Voyage-kimi && \
dart run \
  --define=ALLOW_LIVE_SUPABASE=true \
  --define=ALLOW_POI_SUPABASE_WRITE=true \
  --define=SUPABASE_URL="$SUPABASE_URL" \
  --define=SUPABASE_SECRET_KEY="$SUPABASE_SECRET_KEY" \
  tool/poi/run_pilot_import.dart \
  test/fixtures/poi/pilot_pois_london.json \
  --write
```

Then re-run the verification commands above and confirm counts are identical to the first run.

## Expected Final State

| Destination | POIs | Aliases | Tags | Source Links | Flags |
|-------------|------|---------|------|--------------|-------|
| Lisbon (existing) | 10 | 20 | 40 | 10 | 0 |
| Paris (existing) | 25 | 49 | 100 | 25 | 0 |
| Rome (existing) | 25 | 52 | 100 | 25 | 0 |
| Barcelona (existing) | 25 | 54 | 100 | 25 | 0 |
| **London** | **26** | **53** | **104** | **26** | **0** |
| **Amsterdam** | **26** | **53** | **104** | **26** | **0** |
| **Marrakech** | **26** | **54** | **104** | **26** | **0** |
| **Total** | **163** | **335** | **652** | **163** | **0** |

## Execution Status

| Date | Action | Result |
|------|--------|--------|
| 2026-05-13 | Dry-run London, Amsterdam, Marrakech | All clean (0 blocking errors) |
| 2026-05-13 | Prepare manual commands | Committed to docs |

## Live Execution Results

> To be filled after running the manual commands above. Copy the verification output into the sections below.

### London

```
POIs: __, Aliases: __, Links: __, Tags: __, Flags: __
Healthy: __
Idempotence: __
```

### Amsterdam

```
POIs: __, Aliases: __, Links: __, Tags: __, Flags: __
Healthy: __
Idempotence: __
```

### Marrakech

```
POIs: __, Aliases: __, Links: __, Tags: __, Flags: __
Healthy: __
Idempotence: __
```

## Checklist

- [x] London dry-run clean
- [x] Amsterdam dry-run clean
- [x] Marrakech dry-run clean
- [ ] London real import executed
- [ ] Amsterdam real import executed
- [ ] Marrakech real import executed
- [ ] Post-import verification passed for all 3 cities
- [ ] Idempotence test passed (re-run + counts unchanged)
