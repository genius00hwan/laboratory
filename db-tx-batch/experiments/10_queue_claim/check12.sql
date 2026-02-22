SELECT id, state, owner, locked_at, updated_at
FROM work_queue
WHERE id IN (1, 2)
ORDER BY id;

SELECT dedupe_key, processed_at
FROM processed_log
WHERE dedupe_key IN ('job-1', 'job-2')
ORDER BY dedupe_key;

