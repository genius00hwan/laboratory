-- BAD pattern: SELECT (no lock/claim) -> external work (sleep) -> write
-- Run this in Terminal A first, then run bad_b.sql while A is sleeping.
-- Note: do NOT run mysql with --force; you want the script to stop on error.

SET SESSION TRANSACTION ISOLATION LEVEL READ COMMITTED;
START TRANSACTION;

-- Barrier: give B time to start, then release so B selects during A's sleep window.
SELECT GET_LOCK('bad_claim_demo', 30) AS got_lock;
DO SLEEP(8);

SET @id := NULL;
SET @payload := NULL;

SELECT id, payload INTO @id, @payload
FROM work_queue
WHERE id = 1 AND state = 'READY'
LIMIT 1;

SELECT 'A_SELECTED' AS tag, @id AS id, @payload AS payload;

DO RELEASE_LOCK('bad_claim_demo');

-- Simulate long external work
DO SLEEP(5);

-- Dedup log written after work => another worker can do the same work concurrently
INSERT INTO processed_log(dedupe_key, processed_at)
VALUES (@payload, NOW());

UPDATE work_queue
SET state = 'DONE', owner = 'batchA', updated_at = NOW()
WHERE id = @id;

COMMIT;

SELECT 'A_DONE' AS tag;
