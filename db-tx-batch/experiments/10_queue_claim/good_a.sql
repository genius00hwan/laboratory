-- GOOD pattern: SELECT ... FOR UPDATE SKIP LOCKED to claim work without collisions
-- Run this in Terminal A first, then run good_b.sql while A is sleeping.

SET SESSION TRANSACTION ISOLATION LEVEL READ COMMITTED;
START TRANSACTION;

-- Barrier: give B time to start, then release after A has locked a job row.
SELECT GET_LOCK('good_claim_demo', 30) AS got_lock;
DO SLEEP(8);

SET @id := NULL;
SET @payload := NULL;

SELECT id, payload INTO @id, @payload
FROM work_queue
WHERE id IN (1, 2) AND state = 'READY'
ORDER BY id
LIMIT 1
FOR UPDATE SKIP LOCKED;

SELECT 'A_CLAIMED' AS tag, @id AS id, @payload AS payload;

DO RELEASE_LOCK('good_claim_demo');

DO SLEEP(5);

INSERT INTO processed_log(dedupe_key, processed_at)
VALUES (@payload, NOW());

UPDATE work_queue
SET state = 'DONE', owner = 'batchA', updated_at = NOW()
WHERE id = @id;

COMMIT;

SELECT 'A_DONE' AS tag;
