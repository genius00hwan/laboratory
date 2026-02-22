#!/usr/bin/env bash
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${here}/env.sh"

duration="${1:-60}"        # seconds to generate undo via updates
snapshot_hold="${2:-60}"   # seconds to hold a long RR snapshot open
workers="${3:-4}"
chunk="${4:-20000}"        # rows updated per tx per worker
lo_id="${5:-1}"
hi_id="${6:-1000000}"
sample_every="${7:-2}"     # seconds
cooldown="${8:-30}"        # seconds to observe purge catch-up after snapshot commits

mkdir -p "${here}/out"
ts="$(date -u +"%Y%m%dT%H%M%SZ")"
out_tsv="${here}/out/undo_history_${ts}.tsv"

echo "# undo_history_len_bench $(date -u +"%Y-%m-%dT%H:%M:%SZ")"
echo "duration=${duration}s snapshot_hold=${snapshot_hold}s cooldown=${cooldown}s workers=${workers} chunk=${chunk} range=${lo_id}..${hi_id} sample_every=${sample_every}s"
echo "out=${out_tsv}"
echo

${MYSQL} < "${here}/tools/bootstrap_sequences.sql" >/dev/null
${MYSQL_ROOT} < "${here}/experiments/30_lockbench/grant_perf_schema.sql" >/dev/null

max_id="$(${MYSQL} -e "SELECT IFNULL(MAX(id),0) FROM orders;")"
if ! [[ "$max_id" =~ ^[0-9]+$ ]] || (( max_id == 0 )); then
  echo "ERROR: orders table empty or MAX(id) invalid (max_id=${max_id})" >&2
  exit 2
fi
if (( hi_id > max_id )); then
  echo "ERROR: hi_id=${hi_id} > orders_max_id=${max_id}" >&2
  exit 2
fi

sample_metrics() {
  ${MYSQL_ROOT} < "${here}/experiments/60_undo_purge/undo_report.sql"
}

run_updater_worker() {
  local wid="$1"
  local end_ts="$2"
  while (( $(date +%s) < end_ts )); do
    # Update a deterministic-but-spread set of ids using nums_1m
    ${MYSQL} -e "
      SET SESSION TRANSACTION ISOLATION LEVEL READ COMMITTED;
      START TRANSACTION;
      UPDATE orders o
      JOIN (
        SELECT (${lo_id} + ((n + ${wid} * 97) % (${hi_id} - ${lo_id} + 1))) AS id
        FROM nums_1m
        WHERE n <= ${chunk}
      ) t USING (id)
      SET o.amount = o.amount + 1,
          o.updated_at = NOW();
      COMMIT;
    " >/dev/null 2>&1 || true
  done
}

run_phase() {
  local phase="$1"              # baseline | rr_snapshot
  local phase_seconds="$2"
  local hold_snapshot="$3"      # 0 | 1

  echo "## Phase: ${phase}"

  local end_ts
  end_ts=$(( $(date +%s) + phase_seconds ))

  local snap_pid=""
  if (( hold_snapshot == 1 )); then
    # Hold a long RR snapshot open over the same range.
    (
      ${MYSQL} -e "
        SET SESSION TRANSACTION ISOLATION LEVEL REPEATABLE READ;
        START TRANSACTION;
        SELECT COUNT(*) FROM orders WHERE id BETWEEN ${lo_id} AND ${hi_id};
        DO SLEEP(${snapshot_hold});
        COMMIT;
      " >/dev/null 2>&1
    ) &
    snap_pid=$!
    # Give the snapshot session time to start.
    sleep 1
  fi

  # Start update workers
  pids=()
  for ((i=1; i<=workers; i++)); do
    run_updater_worker "$i" "$end_ts" &
    pids+=("$!")
  done

  # Sample metrics periodically
  while (( $(date +%s) < end_ts )); do
    line="$(sample_metrics)"
    # captured_at \t history_len \t active_trx
    printf "%s\t%s\n" "$phase" "$line" >>"$out_tsv"
    sleep "$sample_every"
  done

  for p in "${pids[@]}"; do
    wait "$p" || true
  done

  if [[ -n "$snap_pid" ]]; then
    wait "$snap_pid" || true
  fi
}

echo -e "phase\tcaptured_at\tinnodb_history_list_length\ttrx_rseg_history_len\tactive_trx\toldest_trx_age_s" >"$out_tsv"

run_phase "baseline" "$duration" 0
run_phase "rr_snapshot" "$duration" 1
run_phase "cooldown" "$cooldown" 0

echo
echo "## Summary (max history len)"
baseline_hist_max="$(awk -F'\t' '$1=="baseline"{if($3>m)m=$3} END{print m+0}' "$out_tsv")"
snapshot_hist_max="$(awk -F'\t' '$1=="rr_snapshot"{if($3>m)m=$3} END{print m+0}' "$out_tsv")"
cooldown_hist_max="$(awk -F'\t' '$1=="cooldown"{if($3>m)m=$3} END{print m+0}' "$out_tsv")"

baseline_rseg_max="$(awk -F'\t' '$1=="baseline"{if($4>m)m=$4} END{print m+0}' "$out_tsv")"
snapshot_rseg_max="$(awk -F'\t' '$1=="rr_snapshot"{if($4>m)m=$4} END{print m+0}' "$out_tsv")"
cooldown_rseg_max="$(awk -F'\t' '$1=="cooldown"{if($4>m)m=$4} END{print m+0}' "$out_tsv")"

echo "| phase | max_innodb_history_list_length | max_trx_rseg_history_len |"
echo "|---|---:|---:|"
echo "| baseline (no long snapshot) | ${baseline_hist_max} | ${baseline_rseg_max} |"
echo "| rr_snapshot (long RR tx held) | ${snapshot_hist_max} | ${snapshot_rseg_max} |"
echo "| cooldown (after snapshot commit) | ${cooldown_hist_max} | ${cooldown_rseg_max} |"
echo
echo "TSV saved: ${out_tsv}"
