-- Session 1: lock holder for bench_kv (creates row lock wait on id=1)

SET @isolation := IFNULL(@isolation, 'READ COMMITTED');
SET @hold_seconds := IFNULL(@hold_seconds, 5);

SET @sql := CONCAT('SET SESSION TRANSACTION ISOLATION LEVEL ', @isolation);
PREPARE s FROM @sql;
EXECUTE s;
DEALLOCATE PREPARE s;

START TRANSACTION;

UPDATE bench_kv SET v = v WHERE id = 1;
SELECT 'HOLDER_LOCKED' AS tag, @isolation AS isolation_level, NOW(6) AS ts;

DO SLEEP(@hold_seconds);

COMMIT;
SELECT 'HOLDER_COMMIT' AS tag, @isolation AS isolation_level, NOW(6) AS ts;

