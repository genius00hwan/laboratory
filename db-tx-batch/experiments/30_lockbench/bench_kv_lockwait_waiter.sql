-- Session 2: lock waiter for bench_kv (blocks on id=1 until holder commits)

SET @isolation := IFNULL(@isolation, 'READ COMMITTED');

SET @sql := CONCAT('SET SESSION TRANSACTION ISOLATION LEVEL ', @isolation);
PREPARE s FROM @sql;
EXECUTE s;
DEALLOCATE PREPARE s;

SET @t0 := NOW(6);

START TRANSACTION;
UPDATE bench_kv SET v = v + 1, updated_at = NOW() WHERE id = 1;
COMMIT;

SET @t1 := NOW(6);

SELECT
  'WAITER_DONE' AS tag,
  @isolation AS isolation_level,
  TIMESTAMPDIFF(MICROSECOND, @t0, @t1) / 1000.0 AS waited_ms,
  @t0 AS started_at,
  @t1 AS finished_at;

