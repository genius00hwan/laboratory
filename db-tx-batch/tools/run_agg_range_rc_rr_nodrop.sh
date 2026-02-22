#!/usr/bin/env bash
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${here}/env.sh"

lo_id="${1:-1}"
hi_id="${2:-100000}"
only_iso="${3:-}"  # optional: run only this isolation level
any_fail=0

run_one() {
  local iso="$1"
  echo "## agg_range_nodrop: ${iso} (id ${lo_id}..${hi_id})"
  echo

  oltp_out="$(mktemp)"
  batch_out="$(mktemp)"

  # Start batch first: it acquires the gate lock and holds briefly so OLTP can start and block.
  (
    printf "SET @isolation='%s'; SET @lo_id=%s; SET @hi_id=%s;\n" "$iso" "$lo_id" "$hi_id"
    cat "${here}/experiments/20_agg_snapshot/agg_range_demo_batch.sql"
  ) | ${MYSQL} >"$batch_out" 2>&1 &
  batch_pid=$!

  sleep 0.5

  set +e
  (
    printf "SET @lo_id=%s; SET @hi_id=%s;\n" "$lo_id" "$hi_id"
    cat "${here}/experiments/20_agg_snapshot/agg_range_demo_oltp.sql"
  ) | ${MYSQL} >"$oltp_out" 2>&1
  oltp_rc=$?
  set -e

  set +e
  wait "$batch_pid"
  batch_rc=$?
  set -e

  echo "Batch output:"
  echo "\`\`\`text"
  cat "$batch_out"
  echo "\`\`\`"
  echo

  echo "OLTP output:"
  echo "\`\`\`text"
  cat "$oltp_out"
  echo "\`\`\`"
  echo
  echo "Exit codes: batch=${batch_rc} oltp=${oltp_rc}"
  if (( batch_rc != 0 || oltp_rc != 0 )); then
    any_fail=1
  fi
  echo

  rm -f "$oltp_out" "$batch_out"
}

echo "# run_agg_range_rc_rr_nodrop $(date -u +"%Y-%m-%dT%H:%M:%SZ")"
echo "range: lo_id=${lo_id} hi_id=${hi_id}"
if [[ -n "${only_iso}" ]]; then
  echo "only_isolation: ${only_iso}"
fi
echo

if [[ -n "${only_iso}" ]]; then
  run_one "${only_iso}"
else
  run_one "READ COMMITTED"
  run_one "REPEATABLE READ"
  run_one "SERIALIZABLE"
fi

exit "${any_fail}"
