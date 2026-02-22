#!/usr/bin/env bash
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${here}/env.sh"

mode="${1:-good}"          # good | bad
workers="${2:-8}"
seconds="${3:-20}"
work_sleep="${4:-0.05}"    # seconds inside tx to simulate external work
isolation="${5:-READ COMMITTED}"
seed_jobs="${6:-50000}"

if [[ "${mode}" != "good" && "${mode}" != "bad" ]]; then
  echo "mode must be good|bad (got ${mode})" >&2
  exit 2
fi

if ! [[ "${seed_jobs}" =~ ^[0-9]+$ ]] || (( seed_jobs <= 0 || seed_jobs > 1000000 )); then
  echo "seed_jobs must be 1..1,000,000 (got ${seed_jobs})" >&2
  exit 2
fi

echo "# queue_claim_bench_nodrop $(date -u +"%Y-%m-%dT%H:%M:%SZ")"
echo "mode=${mode} workers=${workers} seconds=${seconds} work_sleep=${work_sleep} isolation=${isolation} seed_jobs=${seed_jobs}"
echo

${MYSQL} < "${here}/tools/bootstrap_sequences.sql" >/dev/null
${MYSQL} < "${here}/experiments/10_queue_claim/bench_queue_tables.sql" >/dev/null

# Ensure deterministic job count for this run.
existing_jobs="$(${MYSQL} -e "SELECT COUNT(*) FROM bench_queue;")"
if [[ "${existing_jobs}" != "${seed_jobs}" ]]; then
  ${MYSQL} -e "
    TRUNCATE TABLE bench_queue;
    TRUNCATE TABLE bench_processed_log;
    INSERT INTO bench_queue (state, payload, owner, locked_at, updated_at)
    SELECT 'READY', CONCAT('job-', n), NULL, NULL, NOW()
    FROM nums_1m
    WHERE n <= ${seed_jobs};
  " >/dev/null
else
  ${MYSQL} -e "
    UPDATE bench_queue
    SET state='READY', owner=NULL, locked_at=NULL, updated_at=NOW();
    TRUNCATE TABLE bench_processed_log;
  " >/dev/null
fi

end_ts=$(( $(date +%s) + seconds ))

tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT

run_worker() {
  local wid="$1"
  local log="${tmpdir}/w${wid}.log"
  local err="${tmpdir}/w${wid}.err"

  while (( $(date +%s) < end_ts )); do
    if [[ "${mode}" == "good" ]]; then
      # Correct pattern: lock+skip locked claim
      ${MYSQL} -e "
        SET SESSION TRANSACTION ISOLATION LEVEL ${isolation};
        START TRANSACTION;
        SET @id := NULL; SET @payload := NULL;
        SELECT id, payload INTO @id, @payload
        FROM bench_queue
        WHERE state='READY'
        ORDER BY id
        LIMIT 1
        FOR UPDATE SKIP LOCKED;
        DO SLEEP(${work_sleep});
        INSERT INTO bench_processed_log(dedupe_key, processed_at)
        SELECT @payload, NOW() WHERE @id IS NOT NULL;
        UPDATE bench_queue
        SET state='DONE', owner=CONCAT('w',${wid}), updated_at=NOW()
        WHERE id=@id;
        COMMIT;
      " >>"$log" 2>>"$err" || true
    else
      # Bad pattern: read without lock, then work, then write (race window)
      ${MYSQL} -e "
        SET SESSION TRANSACTION ISOLATION LEVEL ${isolation};
        START TRANSACTION;
        SET @id := NULL; SET @payload := NULL;
        SELECT id, payload INTO @id, @payload
        FROM bench_queue
        WHERE state='READY'
        ORDER BY id
        LIMIT 1;
        DO SLEEP(${work_sleep});
        INSERT INTO bench_processed_log(dedupe_key, processed_at)
        SELECT @payload, NOW() WHERE @id IS NOT NULL;
        UPDATE bench_queue
        SET state='DONE', owner=CONCAT('w',${wid}), updated_at=NOW()
        WHERE id=@id;
        COMMIT;
      " >>"$log" 2>>"$err" || true
    fi
  done
}

pids=()
for ((i=1; i<=workers; i++)); do
  run_worker "$i" &
  pids+=("$!")
done

for p in "${pids[@]}"; do
  wait "$p" || true
done

done_cnt="$(${MYSQL} -e "SELECT COUNT(*) FROM bench_queue WHERE state='DONE';")"
ready_cnt="$(${MYSQL} -e "SELECT COUNT(*) FROM bench_queue WHERE state='READY';")"
log_cnt="$(${MYSQL} -e "SELECT COUNT(*) FROM bench_processed_log;")"
total_cnt="$(${MYSQL} -e "SELECT COUNT(*) FROM bench_queue;")"

count_pat() {
  local pat="$1"
  if command -v rg >/dev/null 2>&1; then
    rg -c "$pat" "$tmpdir"/*.err 2>/dev/null || true
  else
    grep -E -c "$pat" "$tmpdir"/*.err 2>/dev/null || true
  fi
}

dup_errors="$(count_pat "ERROR 1062|Duplicate entry" | awk -F: '{s+=$2} END{print s+0}')"
timeouts="$(count_pat "ER_LOCK_WAIT_TIMEOUT|Lock wait timeout exceeded" | awk -F: '{s+=$2} END{print s+0}')"
deadlocks="$(count_pat "ER_LOCK_DEADLOCK|Deadlock found" | awk -F: '{s+=$2} END{print s+0}')"

echo "## Summary"
echo "| metric | value |"
echo "|---|---:|"
echo "| bench_queue.TOTAL | ${total_cnt} |"
echo "| bench_queue.DONE | ${done_cnt} |"
echo "| bench_queue.READY | ${ready_cnt} |"
echo "| bench_processed_log rows | ${log_cnt} |"
echo "| done_per_sec | $(awk -v d="${done_cnt}" -v s="${seconds}" 'BEGIN{printf "%.2f", d/s}') |"
echo "| duplicate_errors (1062) | ${dup_errors} |"
echo "| lock_wait_timeouts (text scan) | ${timeouts} |"
echo "| deadlocks (text scan) | ${deadlocks} |"
