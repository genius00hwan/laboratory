-- BAD pattern (concurrent worker): does the same "work" and collides on dedupe
-- Start this while bad_a.sql is sleeping.
-- Note: sleep is intentionally longer than A's sleep so B fails deterministically.

SET SESSION TRANSACTION ISOLATION LEVEL READ COMMITTED;
START TRANSACTION;

-- Barrier: wait until A has selected and is about to sleep (A releases this lock)
SELECT GET_LOCK('bad_claim_demo', 30) AS got_lock;
DO RELEASE_LOCK('bad_claim_demo');

SET @id := NULL;
SET @payload := NULL;

SELECT id, payload INTO @id, @payload
FROM work_queue
WHERE id = 1 AND state = 'READY'
LIMIT 1;

SELECT 'B_SELECTED' AS tag, @id AS id, @payload AS payload;

-- Simulate external work (longer than A)
DO SLEEP(6);

-- Expect: Duplicate entry 'job-1' for key 'PRIMARY'
INSERT INTO processed_log(dedupe_key, processed_at)
VALUES (@payload, NOW());

UPDATE work_queue
SET state = 'DONE', owner = 'batchB', updated_at = NOW()
WHERE id = @id;

COMMIT;

SELECT 'B_DONE' AS tag;
