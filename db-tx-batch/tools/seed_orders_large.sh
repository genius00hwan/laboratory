#!/usr/bin/env bash
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${here}/env.sh"

usage() {
  cat >&2 <<'EOF'
usage:
  tools/seed_orders_large.sh --rows N [--chunk C] [--days-span D] [--truncate|--resume]

examples:
  # Fresh seed: 1,000,000 rows
  tools/seed_orders_large.sh --rows 1000000 --chunk 1000000 --days-span 30 --truncate

  # Resume seed up to 200,000,000 rows (continues from current COUNT(*))
  tools/seed_orders_large.sh --rows 200000000 --chunk 1000000 --days-span 30 --resume
EOF
}

rows=""
chunk="1000000"
days_span="30"
mode="error_if_exists" # truncate | resume | error_if_exists

while [[ $# -gt 0 ]]; do
  case "$1" in
    --rows) rows="${2:-}"; shift 2 ;;
    --chunk) chunk="${2:-}"; shift 2 ;;
    --days-span) days_span="${2:-}"; shift 2 ;;
    --truncate) mode="truncate"; shift ;;
    --resume) mode="resume"; shift ;;
    -h|--help) usage; exit 0 ;;
    *)
      echo "unknown arg: $1" >&2
      usage
      exit 2
      ;;
  esac
done

if [[ -z "${rows}" || ! "${rows}" =~ ^[0-9]+$ || ! "${chunk}" =~ ^[0-9]+$ || ! "${days_span}" =~ ^[0-9]+$ ]]; then
  usage
  exit 2
fi

if (( rows <= 0 )); then
  echo "--rows must be > 0" >&2
  exit 2
fi

if (( chunk <= 0 || chunk > 1000000 )); then
  echo "--chunk must be 1..1,000,000 (got $chunk)" >&2
  exit 2
fi

echo "# seed_orders_large $(date -u +"%Y-%m-%dT%H:%M:%SZ")"
echo "rows=${rows} chunk=${chunk} days_span=${days_span} mode=${mode}"

${MYSQL} < "${here}/tools/bootstrap_sequences.sql" >/dev/null

if [[ "${mode}" == "truncate" ]]; then
  ${MYSQL} -e "TRUNCATE TABLE orders;" >/dev/null
fi

existing="$(${MYSQL} -e "SELECT COUNT(*) FROM orders;")"
if ! [[ "${existing}" =~ ^[0-9]+$ ]]; then
  echo "failed to read COUNT(*) from orders (got: ${existing})" >&2
  exit 1
fi

if [[ "${mode}" == "error_if_exists" && "${existing}" != "0" ]]; then
  echo "orders already has ${existing} rows. Use --truncate or --resume." >&2
  exit 2
fi

offset=0
if [[ "${mode}" == "resume" ]]; then
  offset="${existing}"
fi

if (( offset >= rows )); then
  echo "already at target: existing=${existing} >= rows=${rows}"
  exit 0
fi

iter=0
while (( offset < rows )); do
  iter=$((iter + 1))
  remaining=$((rows - offset))
  take=$chunk
  if (( remaining < take )); then take=$remaining; fi

  echo "iter=${iter} offset=${offset} take=${take}"

  # Use deterministic values so repeated runs are comparable.
  # - amount: (n + offset) % 1000 + 1
  # - status: CANCEL every 5th row
  # - created_at: spread over days_span days
  ${MYSQL} -e "
    INSERT INTO orders (amount, status, created_at, updated_at)
    SELECT
      ((n + ${offset}) % 1000) + 1 AS amount,
      CASE WHEN ((n + ${offset}) % 5) = 0 THEN 'CANCEL' ELSE 'PAID' END AS status,
      NOW() - INTERVAL (((n + ${offset}) % ${days_span})) DAY AS created_at,
      NOW() AS updated_at
    FROM nums_1m
    WHERE n <= ${take};
  " >/dev/null

  offset=$((offset + take))

  if (( iter % 10 == 0 )); then
    size_mb="$(${MYSQL} -e "
      SELECT ROUND((data_length + index_length)/1024/1024,1)
      FROM information_schema.tables
      WHERE table_schema = DATABASE() AND table_name = 'orders';
    ")"
    now_count="$(${MYSQL} -e "SELECT COUNT(*) FROM orders;")"
    echo "progress: orders_rows=${now_count} approx_size_mb=${size_mb}"
  fi
done

echo "done"
