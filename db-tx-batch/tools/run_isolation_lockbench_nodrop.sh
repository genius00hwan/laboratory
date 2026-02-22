#!/usr/bin/env bash
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${here}/env.sh"

iso_levels=(
  "READ COMMITTED"
  "REPEATABLE READ"
  "SERIALIZABLE"
)

echo "# lockbench_nodrop $(date -u +"%Y-%m-%dT%H:%M:%SZ")"
echo
echo "This runner does NOT run settings.sql. It only creates bench tables and runs lock scenarios."
echo

echo "## Setup"
echo "\`\`\`bash"
echo "\$MYSQL_ROOT < experiments/30_lockbench/grant_perf_schema.sql"
echo "\$MYSQL < experiments/30_lockbench/bench_tables.sql"
echo "\`\`\`"
echo

${MYSQL_ROOT} < "${here}/experiments/30_lockbench/grant_perf_schema.sql" >/dev/null
${MYSQL} < "${here}/experiments/30_lockbench/bench_tables.sql" >/dev/null

get_ps_report() {
  ${MYSQL_ROOT} < "${here}/experiments/30_lockbench/ps_report.sql"
}

echo "## Results (deltas from performance_schema)"
echo
echo "| isolation | lockwait_waited_ms | ps_row_lock_waits_during | ps_max_wait_age_secs_during | deadlocks_delta | lock_wait_timeouts_delta |"
echo "|---|---:|---:|---:|---:|---:|"

for iso in "${iso_levels[@]}"; do
  before="$(get_ps_report)"
  before_deadlocks="$(awk -F'\t' '{print $2}' <<<"$before")"
  before_timeouts="$(awk -F'\t' '{print $3}' <<<"$before")"

  holder_out="$(mktemp)"
  waiter_out="$(mktemp)"

  (
    printf "SET @isolation='%s'; SET @hold_seconds=5;\n" "$iso"
    cat "${here}/experiments/30_lockbench/bench_kv_lockwait_holder.sql"
  ) | ${MYSQL} >"$holder_out" 2>&1 &
  holder_pid=$!

  sleep 0.3

  (
    printf "SET @isolation='%s';\n" "$iso"
    cat "${here}/experiments/30_lockbench/bench_kv_lockwait_waiter.sql"
  ) | ${MYSQL} >"$waiter_out" 2>&1 &
  waiter_pid=$!

  sleep 1.2
  during="$(get_ps_report)"
  during_row_waits="$(awk -F'\t' '{print $4}' <<<"$during")"
  during_max_age_secs="$(awk -F'\t' '{print $6}' <<<"$during")"

  wait "$holder_pid" || true
  wait "$waiter_pid" || true

  waited_ms="$(awk -F'\t' '$1=="WAITER_DONE"{print $3}' "$waiter_out" | tail -n 1)"
  waited_ms="${waited_ms:-}"

  dl_a="$(mktemp)"
  dl_b="$(mktemp)"

  (
    printf "SET @isolation='%s';\n" "$iso"
    cat "${here}/experiments/30_lockbench/bench_kv_deadlock_a.sql"
  ) | ${MYSQL} >"$dl_a" 2>&1 &
  pida=$!

  (
    printf "SET @isolation='%s';\n" "$iso"
    cat "${here}/experiments/30_lockbench/bench_kv_deadlock_b.sql"
  ) | ${MYSQL} >"$dl_b" 2>&1 &
  pidb=$!

  wait "$pida" || true
  wait "$pidb" || true

  after="$(get_ps_report)"
  after_deadlocks="$(awk -F'\t' '{print $2}' <<<"$after")"
  after_timeouts="$(awk -F'\t' '{print $3}' <<<"$after")"

  deadlocks_delta="$((after_deadlocks - before_deadlocks))"
  timeouts_delta="$((after_timeouts - before_timeouts))"

  printf "| %s | %s | %s | %s | %s | %s |\n" \
    "$iso" "${waited_ms:-NA}" "${during_row_waits:-NA}" "${during_max_age_secs:-NA}" "$deadlocks_delta" "$timeouts_delta"

  rm -f "$holder_out" "$waiter_out" "$dl_a" "$dl_b"
done
