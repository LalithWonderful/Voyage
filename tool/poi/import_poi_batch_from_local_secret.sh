#!/usr/bin/env bash
# POI-OPS-0.1 — Batch Supabase POI import from local secret.
#
# Usage:
#   tool/poi/import_poi_batch_from_local_secret.sh london amsterdam marrakech
#   tool/poi/import_poi_batch_from_local_secret.sh --all
#
# Pre-requisites:
#   1. Create .secrets.local in the repo root with:
#        export SUPABASE_URL="https://..."
#        export SUPABASE_SECRET_KEY="sb_secret_..."
#   2. Add .secrets.local to .git/info/exclude so it is never committed:
#        echo ".secrets.local" >> .git/info/exclude
#   3. Add .local/ to .git/info/exclude if you want reports ignored:
#        echo ".local/" >> .git/info/exclude
#
# Safety:
#   - Never prints SUPABASE_SECRET_KEY.
#   - Stops on blocking import error.
#   - Dry-run precedes every real import.

set -euo pipefail

# The script operates from the current working directory.
# Real imports must be run from the main worktree (/Users/lalith/Projets/Voyage).
# .secrets.local is expected in the directory where the script is invoked.

SECRETS_FILE=".secrets.local"
if [[ ! -f "$SECRETS_FILE" ]]; then
  echo "ERROR: .secrets.local not found in current directory."
  echo "Run this script from /Users/lalith/Projets/Voyage or create a local .secrets.local."
  echo ""
  echo "Create $SECRETS_FILE in the current working directory with:"
  echo '  export SUPABASE_URL="https://..."'
  echo '  export SUPABASE_SECRET_KEY="sb_secret_..."'
  echo ""
  echo "Then exclude it from git:"
  echo "  echo '.secrets.local' >> .git/info/exclude"
  echo ""
  echo "Note: real imports should be run from the main worktree,"
  echo "      e.g. cd /Users/lalith/Projets/Voyage before running this script."
  exit 1
fi

# shellcheck source=/dev/null
source "$SECRETS_FILE"

if [[ -z "${SUPABASE_URL:-}" ]]; then
  echo "ERROR: SUPABASE_URL is not set in $SECRETS_FILE"
  exit 1
fi

if [[ -z "${SUPABASE_SECRET_KEY:-}" ]]; then
  echo "ERROR: SUPABASE_SECRET_KEY is not set in $SECRETS_FILE"
  exit 1
fi

echo "[batch] Secrets loaded from $SECRETS_FILE"
echo "[batch] SUPABASE_URL is set"
echo "[batch] SUPABASE_SECRET_KEY is set (hidden)"
echo ""

# ─── Resolve city list ───
CITIES=()

if [ $# -gt 0 ]; then
  # Explicit city keys passed as arguments
  CITIES=("$@")
else
  # Read city keys from the manifest file
  CITY_LIST_FILE="tool/poi/import_city_list.txt"

  if [ ! -f "$CITY_LIST_FILE" ]; then
    echo "ERROR: city import list not found: $CITY_LIST_FILE"
    echo "Create the file or pass city keys as arguments."
    exit 1
  fi

  while IFS= read -r line || [ -n "$line" ]; do
    city="$(echo "$line" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"

    if [ -z "$city" ]; then
      continue
    fi

    case "$city" in
      \#*) continue ;;
    esac

    CITIES+=("$city")
  done < "$CITY_LIST_FILE"

  if [ ${#CITIES[@]} -eq 0 ]; then
    echo "ERROR: no city keys found in $CITY_LIST_FILE"
    echo "Add one city key per line or pass city keys as arguments."
    exit 1
  fi
fi

echo "[batch] Cities to import: ${CITIES[*]}"
echo ""

# ─── Helpers ───

parse_verify() {
  local output="$1"
  local key="$2"
  echo "$output" | grep "^${key}" | sed 's/.*: *//' | tr -d '\r'
}

run_dry_import() {
  local city="$1"
  local fixture="test/fixtures/poi/pilot_pois_${city}.json"
  echo "[batch] [$city] Step 1/6 — dry-run import..."
  dart run tool/poi/run_pilot_import.dart "$fixture"
}

run_real_import() {
  local city="$1"
  local fixture="test/fixtures/poi/pilot_pois_${city}.json"
  echo "[batch] [$city] Step 2/6 — real import..."
  dart run \
    --define=ALLOW_LIVE_SUPABASE=true \
    --define=ALLOW_POI_SUPABASE_WRITE=true \
    --define=SUPABASE_URL="$SUPABASE_URL" \
    --define=SUPABASE_SECRET_KEY="$SUPABASE_SECRET_KEY" \
    tool/poi/run_pilot_import.dart "$fixture" --write
}

run_verify() {
  local city="$1"
  echo "[batch] [$city] Step 3/6 — post-import verification..."
  dart run \
    --define=ALLOW_LIVE_SUPABASE=true \
    --define=SUPABASE_URL="$SUPABASE_URL" \
    --define=SUPABASE_SECRET_KEY="$SUPABASE_SECRET_KEY" \
    tool/poi/verify_import.dart --destination "$city" 2>&1 || true
}

run_idempotence_import() {
  local city="$1"
  local fixture="test/fixtures/poi/pilot_pois_${city}.json"
  echo "[batch] [$city] Step 4/6 — idempotence re-import..."
  dart run \
    --define=ALLOW_LIVE_SUPABASE=true \
    --define=ALLOW_POI_SUPABASE_WRITE=true \
    --define=SUPABASE_URL="$SUPABASE_URL" \
    --define=SUPABASE_SECRET_KEY="$SUPABASE_SECRET_KEY" \
    tool/poi/run_pilot_import.dart "$fixture" --write
}

# ─── Batch loop ───

REPORT_DIR=".local"
REPORT_FILE="${REPORT_DIR}/poi_batch_import_report.md"
TIMESTAMP=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

mkdir -p "$REPORT_DIR"

{
  echo "# POI Batch Import Report"
  echo ""
  echo "Generated: ${TIMESTAMP}"
  echo "Command: $0 $*"
  echo ""
  echo "## Summary"
  echo ""
  echo "| City | POIs | Aliases | Links | Tags | Flags | Healthy | Idempotent |"
  echo "|------|------|---------|-------|------|-------|---------|------------|"
} > "$REPORT_FILE"

ANY_FAILURE=0

for city in "${CITIES[@]}"; do
  fixture="test/fixtures/poi/pilot_pois_${city}.json"

  echo "========================================"
  echo "[batch] Processing city: $city"
  echo "========================================"

  if [[ ! -f "$fixture" ]]; then
    echo "ERROR: Fixture not found: $fixture"
    exit 1
  fi

  run_dry_import "$city"
  run_real_import "$city"

  VERIFY1=$(run_verify "$city")
  echo "$VERIFY1"

  V1_POIS=$(parse_verify "$VERIFY1" "POIs")
  V1_ALIASES=$(parse_verify "$VERIFY1" "Aliases")
  V1_LINKS=$(parse_verify "$VERIFY1" "Links")
  V1_TAGS=$(parse_verify "$VERIFY1" "Tags")
  V1_FLAGS=$(parse_verify "$VERIFY1" "Flags")
  V1_HEALTHY=$(parse_verify "$VERIFY1" "Healthy")

  run_idempotence_import "$city"

  VERIFY2=$(run_verify "$city")
  echo "$VERIFY2"

  V2_POIS=$(parse_verify "$VERIFY2" "POIs")
  V2_ALIASES=$(parse_verify "$VERIFY2" "Aliases")
  V2_LINKS=$(parse_verify "$VERIFY2" "Links")
  V2_TAGS=$(parse_verify "$VERIFY2" "Tags")
  V2_FLAGS=$(parse_verify "$VERIFY2" "Flags")
  V2_HEALTHY=$(parse_verify "$VERIFY2" "Healthy")

  IDEMPOTENT="false"
  if [[ "$V1_POIS" == "$V2_POIS" && "$V1_ALIASES" == "$V2_ALIASES" && "$V1_LINKS" == "$V2_LINKS" && "$V1_TAGS" == "$V2_TAGS" && "$V1_FLAGS" == "$V2_FLAGS" && "$V1_HEALTHY" == "true" && "$V2_HEALTHY" == "true" ]]; then
    IDEMPOTENT="true"
  fi

  if [[ "$V1_HEALTHY" != "true" || "$V2_HEALTHY" != "true" ]]; then
    ANY_FAILURE=1
  fi

  printf "| %s | %s | %s | %s | %s | %s | %s | %s |\n" \
    "$city" "$V1_POIS" "$V1_ALIASES" "$V1_LINKS" "$V1_TAGS" "$V1_FLAGS" "$V1_HEALTHY" "$IDEMPOTENT" \
    >> "$REPORT_FILE"

  echo ""
  echo "[batch] [$city] Results: POIs=$V1_POIS Aliases=$V1_ALIASES Links=$V1_LINKS Tags=$V1_TAGS Flags=$V1_FLAGS Healthy=$V1_HEALTHY Idempotent=$IDEMPOTENT"
  echo ""
done

{
  echo ""
  echo "## Details"
  echo ""
  echo "- Total cities processed: ${#CITIES[@]}"
  echo "- Report file: $REPORT_FILE"
  echo ""
  if [[ $ANY_FAILURE -eq 0 ]]; then
    echo "Status: ALL PASSED"
  else
    echo "Status: SOME FAILURES DETECTED (see table above)"
  fi
} >> "$REPORT_FILE"

echo "========================================"
echo "[batch] Batch complete."
echo "[batch] Report written to: $REPORT_FILE"
if [[ $ANY_FAILURE -eq 0 ]]; then
  echo "[batch] Status: ALL PASSED"
else
  echo "[batch] Status: SOME FAILURES DETECTED"
fi
echo "========================================"

exit $ANY_FAILURE
