-- GOOD pattern (concurrent worker): should claim the other job (id=2) without waiting

SET SESSION TRANSACTION ISOLATION LEVEL READ COMMITTED;
START TRANSACTION;

-- Barrier: wait until A locked one READY row, then attempt SKIP LOCKED
SELECT GET_LOCK('good_claim_demo', 30) AS got_lock;
DO RELEASE_LOCK('good_claim_demo');

SET @id := NULL;
SET @payload := NULL;

SELECT id, payload INTO @id, @payload
FROM work_queue
WHERE id IN (1, 2) AND state = 'READY'
ORDER BY id
LIMIT 1
FOR UPDATE SKIP LOCKED;

SELECT 'B_CLAIMED' AS tag, @id AS id, @payload AS payload;

INSERT INTO processed_log(dedupe_key, processed_at)
VALUES (@payload, NOW());

UPDATE work_queue
SET state = 'DONE', owner = 'batchB', updated_at = NOW()
WHERE id = @id;

COMMIT;

SELECT 'B_DONE' AS tag;
