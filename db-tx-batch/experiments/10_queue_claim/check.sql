SELECT id, state, owner, locked_at, updated_at
FROM work_queue
WHERE id = 1;

SELECT dedupe_key, processed_at
FROM processed_log
WHERE dedupe_key = 'job-1';

