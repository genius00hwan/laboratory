#!/usr/bin/env bash
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${here}/env.sh"

lo_k="${1:-100}"
hi_k="${2:-200}"
insert_k="${3:-101}"
hold_seconds="${4:-5}"

iso_levels=(
  "READ COMMITTED"
  "REPEATABLE READ"
  "SERIALIZABLE"
)

echo "# gaplock_bench_nodrop $(date -u +"%Y-%m-%dT%H:%M:%SZ")"
echo "range: k ${lo_k}..${hi_k} insert_k=${insert_k} hold_seconds=${hold_seconds}"
echo
echo "This runner does NOT touch orders/work_queue. It uses bench_gap only."
echo

${MYSQL} < "${here}/tools/bootstrap_sequences.sql" >/dev/null
${MYSQL} < "${here}/experiments/40_gaplock/bench_gap_tables.sql" >/dev/null
${MYSQL_ROOT} < "${here}/experiments/30_lockbench/grant_perf_schema.sql" >/dev/null

seeded="$(${MYSQL} -e "SELECT COUNT(*) FROM bench_gap;")"
if [[ "${seeded}" == "0" ]]; then
  ${MYSQL} < "${here}/experiments/40_gaplock/bench_gap_seed.sql" >/dev/null
fi

get_ps_report() {
  ${MYSQL_ROOT} < "${here}/experiments/30_lockbench/ps_report.sql"
}

echo "| isolation | inserter_waited_ms | ps_row_lock_waits_during | ps_max_wait_age_secs_during | deadlocks_delta | lock_wait_timeouts_delta |"
echo "|---|---:|---:|---:|---:|---:|"

for iso in "${iso_levels[@]}"; do
  before="$(get_ps_report)"
  before_deadlocks="$(awk -F'\t' '{print $2}' <<<"$before")"
  before_timeouts="$(awk -F'\t' '{print $3}' <<<"$before")"

  holder_out="$(mktemp)"
  inserter_out="$(mktemp)"

  (
    printf "SET @isolation='%s'; SET @lo_k=%s; SET @hi_k=%s; SET @hold_seconds=%s;\n" "$iso" "$lo_k" "$hi_k" "$hold_seconds"
    cat "${here}/experiments/40_gaplock/bench_gap_holder.sql"
  ) | ${MYSQL} >"$holder_out" 2>&1 &
  holder_pid=$!

  sleep 0.3

  (
    printf "SET @isolation='%s'; SET @insert_k=%s;\n" "$iso" "$insert_k"
    cat "${here}/experiments/40_gaplock/bench_gap_inserter.sql"
  ) | ${MYSQL} >"$inserter_out" 2>&1 &
  inserter_pid=$!

  sleep 1.2
  during="$(get_ps_report)"
  during_row_waits="$(awk -F'\t' '{print $4}' <<<"$during")"
  during_max_age_secs="$(awk -F'\t' '{print $6}' <<<"$during")"

  wait "$holder_pid" || true
  wait "$inserter_pid" || true

  waited_ms="$(awk -F'\t' '$1=="INSERTER_DONE"{print $4}' "$inserter_out" | tail -n 1)"
  waited_ms="${waited_ms:-NA}"

  after="$(get_ps_report)"
  after_deadlocks="$(awk -F'\t' '{print $2}' <<<"$after")"
  after_timeouts="$(awk -F'\t' '{print $3}' <<<"$after")"

  deadlocks_delta="$((after_deadlocks - before_deadlocks))"
  timeouts_delta="$((after_timeouts - before_timeouts))"

  printf "| %s | %s | %s | %s | %s | %s |\n" \
    "$iso" "$waited_ms" "${during_row_waits:-NA}" "${during_max_age_secs:-NA}" "$deadlocks_delta" "$timeouts_delta"

  rm -f "$holder_out" "$inserter_out"
done
