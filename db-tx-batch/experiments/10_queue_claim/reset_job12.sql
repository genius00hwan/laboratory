-- Reset two deterministic jobs (id=1,2) so SKIP LOCKED behavior is visible

INSERT INTO work_queue (id, state, payload, owner, locked_at, updated_at)
VALUES
  (1, 'READY', 'job-1', NULL, NULL, NOW()),
  (2, 'READY', 'job-2', NULL, NULL, NOW())
ON DUPLICATE KEY UPDATE
  state = VALUES(state),
  payload = VALUES(payload),
  owner = NULL,
  locked_at = NULL,
  updated_at = VALUES(updated_at);

DELETE FROM processed_log WHERE dedupe_key IN ('job-1', 'job-2');

