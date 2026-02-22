#!/usr/bin/env bash
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${here}/env.sh"

rows="${1:-10000}"

echo "# run_chunk_demo_bench $(date -u +"%Y-%m-%dT%H:%M:%SZ") rows=${rows}"
echo

${MYSQL} < "${here}/tools/bootstrap_sequences.sql" >/dev/null
${MYSQL} < "${here}/experiments/50_chunk_demo/bench_orders_tables.sql" >/dev/null

# Seed deterministic baseline (safe: bench_orders only)
${MYSQL} -e "
  TRUNCATE TABLE bench_orders;
  INSERT INTO bench_orders (amount, status, created_at, updated_at)
  SELECT 100, 'PAID', NOW() - INTERVAL 1 DAY, NOW()
  FROM nums_1m
  WHERE n <= ${rows};
" >/dev/null

half=$((rows / 2))

echo "## Chunked (2 transactions, mixed snapshot)"
sum1="$(${MYSQL} -e "
  SET SESSION TRANSACTION ISOLATION LEVEL READ COMMITTED;
  START TRANSACTION;
  SELECT SUM(amount) FROM bench_orders WHERE id <= ${half};
  COMMIT;
")"
echo "chunk1_sum=${sum1}"

echo "apply OLTP update between chunks..."
${MYSQL} -e "
  UPDATE bench_orders
  SET amount = amount + 1, updated_at = NOW()
  WHERE status = 'PAID';
" >/dev/null

sum2="$(${MYSQL} -e "
  SET SESSION TRANSACTION ISOLATION LEVEL READ COMMITTED;
  START TRANSACTION;
  SELECT SUM(amount) FROM bench_orders WHERE id > ${half};
  COMMIT;
")"
echo "chunk2_sum=${sum2}"

mixed_total=$((sum1 + sum2))
echo "mixed_total=${mixed_total}"
echo

echo "## Truth (single statement after OLTP update)"
truth="$(${MYSQL} -e "SELECT SUM(amount) FROM bench_orders;")"
echo "truth_sum=${truth}"
echo "diff(mixed-truth)=$((mixed_total - truth))"
echo

echo "## Single-tx snapshot (REPEATABLE READ)"
snap="$(${MYSQL} -e "
  SET SESSION TRANSACTION ISOLATION LEVEL REPEATABLE READ;
  START TRANSACTION;
  SELECT SUM(amount) FROM bench_orders;
  DO SLEEP(2);
  SELECT SUM(amount) FROM bench_orders;
  COMMIT;
")"
printf "snapshot_reads:\n%s\n" "$snap"
