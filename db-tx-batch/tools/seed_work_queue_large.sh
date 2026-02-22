#!/usr/bin/env bash
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${here}/env.sh"

rows="${1:-1000000}"
chunk="${2:-1000000}"

if ! [[ "$rows" =~ ^[0-9]+$ && "$chunk" =~ ^[0-9]+$ ]]; then
  echo "usage: $0 <rows:int> [chunk:int]" >&2
  exit 2
fi

if (( chunk <= 0 || chunk > 1000000 )); then
  echo "chunk must be 1..1,000,000 (got $chunk)" >&2
  exit 2
fi

echo "# seed_work_queue_large $(date -u +"%Y-%m-%dT%H:%M:%SZ")"
echo "rows=${rows} chunk=${chunk}"

${MYSQL} < "${here}/tools/bootstrap_sequences.sql" >/dev/null

iter=0
offset=0

while (( offset < rows )); do
  iter=$((iter + 1))
  remaining=$((rows - offset))
  take=$chunk
  if (( remaining < take )); then take=$remaining; fi

  echo "iter=${iter} offset=${offset} take=${take}"

  ${MYSQL} -e "
    INSERT INTO work_queue (state, payload, owner, locked_at, updated_at)
    SELECT
      'READY',
      CONCAT('job-', n + ${offset}),
      NULL,
      NULL,
      NOW()
    FROM nums_1m
    WHERE n <= ${take};
  " >/dev/null

  offset=$((offset + take))

  if (( iter % 10 == 0 )); then
    size_mb="$(${MYSQL} -e "
      SELECT ROUND((data_length + index_length)/1024/1024,1)
      FROM information_schema.tables
      WHERE table_schema = DATABASE() AND table_name = 'work_queue';
    ")"
    now_count="$(${MYSQL} -e "SELECT COUNT(*) FROM work_queue;")"
    echo "progress: work_queue_rows=${now_count} approx_size_mb=${size_mb}"
  fi
done

echo "done"
