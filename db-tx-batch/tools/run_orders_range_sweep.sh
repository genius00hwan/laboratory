#!/usr/bin/env bash
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${here}/env.sh"

sizes_csv="${1:-1000000,10000000,50000000,100000000,200000000}"
lo_id="${2:-1}"
isos_csv="${3:-READ COMMITTED,REPEATABLE READ,SERIALIZABLE}"

sleep_seconds="${SLEEP_SECONDS:-0}"          # extra sleep after OLTP completion (batch)
pre_sleep_seconds="${PRE_SLEEP_SECONDS:-2}"  # give OLTP time to start and block
done_timeout_seconds="${DONE_TIMEOUT_SECONDS:-3600}"

split_csv() {
  local s="$1"
  local item
  local -a items
  IFS=',' read -r -a items <<<"$s"
  for item in "${items[@]}"; do
    # trim leading/trailing whitespace (pure bash)
    item="${item#"${item%%[!$' \t\r\n']*}"}"
    item="${item%"${item##*[!$' \t\r\n']}"}"
    [[ -n "$item" ]] && printf "%s\n" "$item"
  done
}

get_ps_report() {
  # captured_at, deadlocks_total, lock_wait_timeouts_total, current_row_lock_waits, current_mdl_waits, max_row_lock_wait_age_secs
  ${MYSQL_ROOT} < "${here}/experiments/30_lockbench/ps_report.sql"
}

run_once() {
  local iso="$1"
  local lo="$2"
  local hi="$3"

  local tmpdir
  tmpdir="$(mktemp -d)"

  local before after
  before="$(get_ps_report)"
  local before_deadlocks before_timeouts
  before_deadlocks="$(awk -F'\t' '{print $2}' <<<"$before")"
  before_timeouts="$(awk -F'\t' '{print $3}' <<<"$before")"

  local batch_out="${tmpdir}/batch.out"
  local oltp_out="${tmpdir}/oltp.out"

  local t0 t1
  t0="$(date +%s)"

  (
    printf "SET @isolation='%s'; SET @lo_id=%s; SET @hi_id=%s; SET @sleep_seconds=%s; SET @pre_sleep_seconds=%s; SET @done_timeout_seconds=%s;\n" \
      "$iso" "$lo" "$hi" "$sleep_seconds" "$pre_sleep_seconds" "$done_timeout_seconds"
    cat "${here}/experiments/20_agg_snapshot/agg_range_demo_batch.sql"
  ) | ${MYSQL} >"$batch_out" 2>&1 &
  batch_pid=$!

  sleep 0.5

  set +e
  (
    printf "SET @lo_id=%s; SET @hi_id=%s;\n" "$lo" "$hi"
    cat "${here}/experiments/20_agg_snapshot/agg_range_demo_oltp.sql"
  ) | ${MYSQL} >"$oltp_out" 2>&1
  oltp_rc=$?
  set -e

  set +e
  wait "$batch_pid"
  batch_rc=$?
  set -e

  t1="$(date +%s)"
  wall_s="$((t1 - t0))"

  after="$(get_ps_report)"
  local after_deadlocks after_timeouts
  after_deadlocks="$(awk -F'\t' '{print $2}' <<<"$after")"
  after_timeouts="$(awk -F'\t' '{print $3}' <<<"$after")"

  local deadlocks_delta timeouts_delta
  deadlocks_delta="$((after_deadlocks - before_deadlocks))"
  timeouts_delta="$((after_timeouts - before_timeouts))"

  local sum_diff rows_updated waited_ms error_code
  sum_diff="$(awk -F'\t' '$1=="BATCH_RANGE_DIFF"{print $4}' "$batch_out" | tail -n 1)"
  rows_updated="$(awk -F'\t' '$1=="OLTP_RANGE_UPDATED"{print $4}' "$oltp_out" | tail -n 1)"
  waited_ms="$(awk -F'\t' '$1=="OLTP_RANGE_UPDATED"{print $5}' "$oltp_out" | tail -n 1)"
  error_code="$(awk '/ERROR [0-9]+/{print $2}' "$oltp_out" | tr -d '()' | tail -n 1)"

  sum_diff="${sum_diff:-NA}"
  rows_updated="${rows_updated:-NA}"
  waited_ms="${waited_ms:-NA}"
  error_code="${error_code:-}"

  rm -rf "$tmpdir"

  printf "%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n" \
    "$iso" "$lo" "$hi" "$wall_s" "$sum_diff" "$rows_updated" "$waited_ms" "${error_code:-OK}" "$deadlocks_delta" "$timeouts_delta"
}

echo "# orders_range_sweep $(date -u +"%Y-%m-%dT%H:%M:%SZ")"
echo "sizes=${sizes_csv}"
echo "lo_id=${lo_id}"
echo "isos=${isos_csv}"
echo "notes: modifies orders.amount in the tested ranges; do NOT run on production data."
echo

max_id="$(${MYSQL} -e "SELECT IFNULL(MAX(id),0) FROM orders;")"
if ! [[ "$max_id" =~ ^[0-9]+$ ]] || (( max_id == 0 )); then
  echo "ERROR: orders table empty or MAX(id) invalid (max_id=${max_id})" >&2
  exit 2
fi

echo "orders_max_id=${max_id}"
echo

echo "| range_size | isolation | lo_id | hi_id | wall_s | batch_sum_diff | oltp_rows_updated | oltp_waited_ms | oltp_status | deadlocks_delta | lock_wait_timeouts_delta |"
echo "|---:|---|---:|---:|---:|---:|---:|---:|---|---:|---:|"

while IFS= read -r size; do
  if ! [[ "$size" =~ ^[0-9]+$ ]] || (( size <= 0 )); then
    echo "skip invalid size: $size" >&2
    continue
  fi
  hi_id=$((lo_id + size - 1))
  if (( hi_id > max_id )); then
    echo "skip size=${size} (hi_id=${hi_id} > orders_max_id=${max_id})" >&2
    continue
  fi

  while IFS= read -r iso; do
    out="$(run_once "$iso" "$lo_id" "$hi_id")"
    IFS=$'\t' read -r iso2 lo hi wall_s sum_diff rows_updated waited_ms status deadlocks_delta timeouts_delta <<<"$out"
    printf "| %s | %s | %s | %s | %s | %s | %s | %s | %s | %s | %s |\n" \
      "$size" "$iso2" "$lo" "$hi" "$wall_s" "$sum_diff" "$rows_updated" "$waited_ms" "$status" "$deadlocks_delta" "$timeouts_delta"
  done < <(split_csv "$isos_csv")

done < <(split_csv "$sizes_csv")
