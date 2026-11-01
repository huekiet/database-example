#!/usr/bin/env bash
#
# benchmark.sh
# Runs the index vs no-index and join vs subquery comparisons against the
# postgres:15-alpine container started by docker-compose.
#
# Requirements: docker, docker compose, psql client (for parsing timing)
#
# Usage (Git Bash / WSL2 / Linux / macOS):
#   chmod +x benchmark.sh
#   ./benchmark.sh
#
# On Windows PowerShell, run the equivalent commands listed in README.md.

set -euo pipefail

COMPOSE_FILE="docker-compose.yml"
CONTAINER="pg-benchmark"
DB="benchmark"
USER="benchmark"
PASS="benchmark"
PGPASSWORD="$PASS"

QDIR="/queries"

# Maps query file -> label for the report
declare -A QUERIES=(
  ["01-point-lookup-by-user-id.sql"]="Point lookup by user_id (equality)"
  ["02-range-scan-by-date.sql"]     ="Range scan by order_date (month)"
  ["03-join-vs-subquery.sql"]       ="JOIN vs subquery (email filter)"
  ["04-join-aggregation.sql"]       ="Aggregation JOIN (delivered orders)"
  ["05-subquery-aggregation.sql"]   ="Correlated subquery aggregation"
)

run_sql() {
  # $1 = sql file (or inline), $2 = label
  local sql="$1"
  local label="$2"
  docker exec -i "$CONTAINER" \
    psql -U "$USER" -d "$DB" -t -A -F'|' -v ON_ERROR_STOP=1 -f "$sql" 2>/dev/null \
    | grep -E 'Execution Time:' \
    | tail -n1 \
    | sed -E 's/.*Execution Time: ([0-9.]+) ms.*/\1/'
}

wait_for_db() {
  echo "==> Waiting for PostgreSQL to be ready..."
  for i in {1..60}; do
    if docker exec "$CONTAINER" pg_isready -U "$USER" -d "$DB" >/dev/null 2>&1; then
      echo "==> PostgreSQL is ready."
      return 0
    fi
    sleep 2
  done
  echo "ERROR: PostgreSQL did not become ready in time." >&2
  exit 1
}

print_header() {
  printf "\n%-60s | %12s | %12s | %12s\n" "QUERY" "NO INDEX (ms)" "WITH INDEX (ms)" "SPEEDUP"
  printf '%s\n' "--------------------------------------------------------------------------------------------------------------------------"
}

print_row() {
  local label="$1" noidx="$2" withidx="$3"
  local speedup="n/a"
  if [[ -n "$noidx" && -n "$withidx" && "$withidx" != "0" ]]; then
    speedup=$(awk -v a="$noidx" -v b="$withidx" 'BEGIN{printf "%.2fx", a/b}')
  fi
  printf "%-60s | %12s | %12s | %12s\n" "$label" "${noidx:-n/a}" "${withidx:-n/a}" "$speedup"
}

main() {
  wait_for_db

  # Confirm row counts
  echo "==> Verifying seed data..."
  docker exec -i "$CONTAINER" psql -U "$USER" -d "$DB" -t -A -c \
    "SELECT 'users', COUNT(*) FROM users UNION ALL SELECT 'orders', COUNT(*) FROM orders;"

  print_header

  for qfile in "${!QUERIES[@]}"; do
    label="${QUERIES[$qfile]}"
    qpath="$QDIR/$qfile"

    # --- WITHOUT INDEX ---
    echo "==> [NO INDEX] $label"
    noidx=$(run_sql "$qpath" "$label" || true)

    # --- WITH INDEX ---
    echo "==> Applying indexes..."
    docker exec -i "$CONTAINER" psql -U "$USER" -d "$DB" -v ON_ERROR_STOP=1 -f /docker-entrypoint-initdb.d/03-indexes.sql >/dev/null

    echo "==> [WITH INDEX] $label"
    withidx=$(run_sql "$qpath" "$label" || true)

    # --- Drop indexes again so next query starts from a clean "no index" state ---
    docker exec -i "$CONTAINER" psql -U "$USER" -d "$DB" -v ON_ERROR_STOP=1 -f /docker-entrypoint-initdb.d/04-drop-indexes.sql >/dev/null

    print_row "$label" "$noidx" "$withidx"
  done

  echo
  echo "==> Benchmark complete."
  echo "    Tip: re-run ./benchmark.sh multiple times; the first run after a restart"
  echo "    includes cold-cache cost. Lower Execution Time is better."
}

main "$@"
