-- Session 1: take a locking read over an indexed range and hold the transaction.
-- In RR/SERIALIZABLE, InnoDB may take next-key (gap) locks on the range, which can block inserts into gaps.
-- In READ COMMITTED, gap locks for locking reads are reduced; inserts may proceed.
--
-- Parameters:
--   @isolation: 'READ COMMITTED' | 'REPEATABLE READ' | 'SERIALIZABLE'
--   @lo_k, @hi_k: range to lock
--   @hold_seconds: how long to hold locks

SET @isolation := IFNULL(@isolation, 'READ COMMITTED');
SET @lo_k := IFNULL(@lo_k, 100);
SET @hi_k := IFNULL(@hi_k, 200);
SET @hold_seconds := IFNULL(@hold_seconds, 5);

SET @sql := CONCAT('SET SESSION TRANSACTION ISOLATION LEVEL ', @isolation);
PREPARE s FROM @sql;
EXECUTE s;
DEALLOCATE PREPARE s;

START TRANSACTION;

SELECT COUNT(*) INTO @locked_rows
FROM bench_gap
WHERE k BETWEEN @lo_k AND @hi_k
FOR UPDATE;

SELECT 'HOLDER_RANGE_LOCKED' AS tag, @isolation AS isolation_level, @lo_k AS lo_k, @hi_k AS hi_k, @locked_rows AS locked_rows, NOW(6) AS ts;

DO SLEEP(@hold_seconds);

COMMIT;

SELECT 'HOLDER_COMMIT' AS tag, @isolation AS isolation_level, NOW(6) AS ts;

