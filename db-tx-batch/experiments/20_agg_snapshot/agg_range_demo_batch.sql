-- No-drop aggregation demo over a bounded PK range (fast even with huge orders table).
-- RC vs RR behavior:
--  - READ COMMITTED: second SELECT can see OLTP commits (diff > 0 possible).
--  - REPEATABLE READ: consistent snapshot inside tx (diff = 0 inside tx).
--
-- Parameters (set before running):
--   @isolation: 'READ COMMITTED' | 'REPEATABLE READ' | 'SERIALIZABLE'
--   @lo_id, @hi_id: inclusive range on orders.id
-- Uses GET_LOCK barrier so the OLTP update happens between the two reads.

SET @isolation := IFNULL(@isolation, 'READ COMMITTED');
SET @lo_id := IFNULL(@lo_id, 1);
SET @hi_id := IFNULL(@hi_id, 100000);
SET @sleep_seconds := IFNULL(@sleep_seconds, 5);
SET @pre_sleep_seconds := IFNULL(@pre_sleep_seconds, 2);
SET @done_timeout_seconds := IFNULL(@done_timeout_seconds, 3600);
-- When SERIALIZABLE, plain SELECTs behave like locking reads and can block OLTP updates.
-- Waiting for OLTP completion here can form a wait cycle, so default to not waiting.
SET @wait_for_oltp := IFNULL(@wait_for_oltp, IF(@isolation = 'SERIALIZABLE', 0, 1));

SET @sql := CONCAT('SET SESSION TRANSACTION ISOLATION LEVEL ', @isolation);
PREPARE s FROM @sql;
EXECUTE s;
DEALLOCATE PREPARE s;

START TRANSACTION;

-- Handshake locks:
-- - agg_range_start: ensures OLTP has started and is waiting before our first read.
-- - agg_range_gate: ensures OLTP update lands between read #1 and read #2.
-- - agg_range_done: batch can wait for OLTP commit (important when update takes minutes).
DO GET_LOCK('agg_range_start', 30);
DO GET_LOCK('agg_range_gate', 30);
DO RELEASE_LOCK('agg_range_start');

DO SLEEP(@pre_sleep_seconds);

SELECT SUM(amount), COUNT(*) INTO @sum1, @cnt1
FROM orders
WHERE id BETWEEN @lo_id AND @hi_id
  AND status = 'PAID';

SELECT 'BATCH_RANGE_1' AS tag, @isolation AS isolation_level, @lo_id AS lo_id, @hi_id AS hi_id, @cnt1 AS cnt, @sum1 AS sum_amount;

DO RELEASE_LOCK('agg_range_gate');

-- Wait until OLTP finishes (so RC can observe the committed change even for huge ranges)
-- Skip by default in SERIALIZABLE to avoid a wait cycle (batch holds read locks; OLTP can't update).
DO IF(@wait_for_oltp = 1, GET_LOCK('agg_range_done', @done_timeout_seconds), 1);
DO IF(@wait_for_oltp = 1, RELEASE_LOCK('agg_range_done'), 1);

DO SLEEP(@sleep_seconds);

SELECT SUM(amount), COUNT(*) INTO @sum2, @cnt2
FROM orders
WHERE id BETWEEN @lo_id AND @hi_id
  AND status = 'PAID';

SELECT 'BATCH_RANGE_2' AS tag, @isolation AS isolation_level, @lo_id AS lo_id, @hi_id AS hi_id, @cnt2 AS cnt, @sum2 AS sum_amount;

COMMIT;

DO RELEASE_LOCK('agg_range_gate');

SELECT 'BATCH_RANGE_DIFF' AS tag, @isolation AS isolation_level, (@cnt2-@cnt1) AS cnt_diff, (@sum2-@sum1) AS sum_diff;
