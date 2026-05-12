# POI-1.7 — Supabase Secret API Key Hardening

## Objective

Harden secret management for the POI import pipeline and document safe operational procedures.

## Status

✅ Completed — all POI scripts support `SUPABASE_SECRET_KEY` with legacy fallback.

---

## Recommended Key Hierarchy

### For write operations (real imports)

1. **`SUPABASE_SECRET_KEY`** (preferred, recommended)
   - New Supabase Secret API key format: `sb_secret_...`
   - Full database access, scoped per project
   - Rotate independently from anon/service_role keys

2. **`SUPABASE_SERVICE_ROLE_KEY`** (legacy fallback only)
   - Legacy `service_role` JWT key
   - Supported for backward compatibility during transition
   - Should be phased out in favor of `SUPABASE_SECRET_KEY`

3. **`SUPABASE_ANON_KEY`** (must NOT be used for writes)
   - Public anonymous key
   - POI tables have RLS policies: write = `service_role` only
   - Using anon key for writes will fail with RLS error 42501
   - The legacy `import_poi_to_supabase.dart` still accepts it as a last-resort fallback for backward compatibility, but this is deprecated and will be removed.

### For read-only operations (verification, schema checks)

1. **`SUPABASE_SECRET_KEY`** (preferred if available)
   - Can be reused for read-only scripts when the same terminal session already has it set
   - Avoids mixing different keys in the same workflow

2. **`SUPABASE_ANON_KEY`** (fallback)
   - Sufficient for `SELECT` operations
   - POI tables have RLS: read = public

---

## Safe Terminal Procedure

### 1. Set the secret (interactive, hidden input)

```bash
read -s SUPABASE_SECRET_KEY
# paste key, press Enter
export SUPABASE_SECRET_KEY
```

The `-s` flag hides the key from terminal history and screen output.

### 2. Verify the key is set (show prefix only)

```bash
echo "Key prefix: ${SUPABASE_SECRET_KEY:0:12}..."
```

### 3. Run read-only verification

```bash
cd /Users/lalith/Projets/Voyage

dart run \
  --define=SUPABASE_URL=https://qfadipkbhuohujxlgrnn.supabase.co \
  --define=SUPABASE_SECRET_KEY="$SUPABASE_SECRET_KEY" \
  tool/poi/verify_import.dart \
  --destination lisbon
```

### 4. Run real write (with explicit opt-in)

```bash
cd /Users/lalith/Projets/Voyage

dart run \
  --define=ALLOW_POI_SUPABASE_WRITE=true \
  --define=SUPABASE_URL=https://qfadipkbhuohujxlgrnn.supabase.co \
  --define=SUPABASE_SECRET_KEY="$SUPABASE_SECRET_KEY" \
  tool/poi/run_pilot_import.dart \
  test/fixtures/poi/pilot_pois_lisbon.json \
  --write
```

### 5. Unset when done

```bash
unset SUPABASE_SECRET_KEY
```

---

## Script Credential Priority Reference

| Script | Type | Priority |
|--------|------|----------|
| `tool/poi/run_pilot_import.dart` | Write | `SUPABASE_SECRET_KEY` → `SUPABASE_SERVICE_ROLE_KEY` |
| `tool/poi/import_poi_to_supabase.dart` | Write | `SUPABASE_SECRET_KEY` → `SUPABASE_SERVICE_ROLE_KEY` → `SUPABASE_ANON_KEY` (deprecated) |
| `tool/poi/verify_import.dart` | Read-only | `SUPABASE_SECRET_KEY` → `SUPABASE_ANON_KEY` |
| `tool/poi/verify_schema.dart` | Read-only | `SUPABASE_SECRET_KEY` → `SUPABASE_ANON_KEY` → `SupabaseConstants` (hardcoded fallback) |

---

## What Must Never Be Done

- **Never paste `service_role` or `sb_secret_...` keys into ChatGPT, Kimi, Claude, Jira, docs, or GitHub.**
- **Never commit secrets to git.** If a secret is accidentally committed, rotate it immediately.
- **Never put secret keys in Flutter app code.** The mobile app only needs the anon key (read-only). Secret keys must stay in admin/CI contexts only.
- **Never print secrets in logs.** All POI scripts use `String.fromEnvironment()` — the key is never logged or echoed.
- **Never share terminal history containing keys.** Use `read -s` and `unset` to keep keys out of `.bash_history` / `.zsh_history`.
- **Never reuse a Supabase secret key across projects.** Each project should have its own key.

---

## Compromise Response Procedure

If a secret key is suspected compromised:

1. **Stop using it immediately.** Do not run any imports or verification with the compromised key.
2. **Create a new Supabase Secret API key** in the Supabase Dashboard → Project Settings → Data API → Secret API Keys.
3. **Revoke the old key** in the same dashboard section.
4. **Update local/CI secret manager** with the new key.
5. **Scan the repository for secrets:**
   ```bash
   git log --all --patch --grep="secret\|key\|token" | grep -E "(sb_secret_|eyJ)"
   ```
   Or use a tool like [git-secrets](https://github.com/awslabs/git-secrets) or [truffleHog](https://github.com/trufflesecurity/truffleHog).
6. **Do not commit any new code until the scan is clean.**
7. **Document the rotation** in the team log.

---

## Secret Scan Results (POI-1.7)

Scan performed on `lib/features/poi/`, `test/poi/`, `tool/poi/`, `docs/poi/`, `supabase/sql/`, `test/fixtures/poi/`:

| Pattern | Result |
|---------|--------|
| JWT values (`eyJ...`) | ❌ None found in POI scope |
| `sb_secret_` | ❌ None found in POI scope |
| `SUPABASE_SERVICE_ROLE_KEY` values | ❌ None found — only variable names in code |
| `SUPABASE_SECRET_KEY` values | ❌ None found — only variable names in code |
| `SUPABASE_ANON_KEY` values | ❌ None found in POI scope |

**Note:** The file `lib/core/constants/supabase_constants.dart` (outside POI scope) contains a hardcoded anon key. This is a pre-existing issue tracked separately. The POI scripts `verify_import.dart` and `verify_schema.dart` prefer env vars and only fall back to this constant when no env var is provided.

---

## Test Results

All POI tests pass after POI-1.7 changes:
- **267 passing**
- **5 skipped** (live Overpass/Supabase tests)
- **0 failures**

---

## Deliverables

- `docs/poi/poi_1_7_secret_key_hardening.md` (this document)
- `tool/poi/verify_schema.dart` — updated to prefer env vars over hardcoded constants
