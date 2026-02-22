-- Deadlock pair A: lock id=1 then id=2

SET @isolation := IFNULL(@isolation, 'READ COMMITTED');

SET @sql := CONCAT('SET SESSION TRANSACTION ISOLATION LEVEL ', @isolation);
PREPARE s FROM @sql;
EXECUTE s;
DEALLOCATE PREPARE s;

START TRANSACTION;
UPDATE bench_kv SET v = v + 1, updated_at = NOW() WHERE id = 1;
DO SLEEP(2);
UPDATE bench_kv SET v = v + 1, updated_at = NOW() WHERE id = 2;
COMMIT;

SELECT 'DEADLOCK_A_DONE' AS tag, @isolation AS isolation_level;

