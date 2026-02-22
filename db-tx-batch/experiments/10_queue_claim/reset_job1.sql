-- Reset a single deterministic job (id=1, payload=job-1)
-- Prereq: work_queue, processed_log exist (see settings.sql, set_queue.sql)

INSERT INTO work_queue (id, state, payload, owner, locked_at, updated_at)
VALUES (1, 'READY', 'job-1', NULL, NULL, NOW())
ON DUPLICATE KEY UPDATE
  state = VALUES(state),
  payload = VALUES(payload),
  owner = NULL,
  locked_at = NULL,
  updated_at = VALUES(updated_at);

DELETE FROM processed_log WHERE dedupe_key = 'job-1';

