-- Session 2: try to insert into a gap inside the locked range and measure wait time.
--
-- Parameters:
--   @isolation: 'READ COMMITTED' | 'REPEATABLE READ' | 'SERIALIZABLE'
--   @insert_k: should be an odd number within the seeded even-key range (gap key)

SET @isolation := IFNULL(@isolation, 'READ COMMITTED');
SET @insert_k := IFNULL(@insert_k, 101);

SET @sql := CONCAT('SET SESSION TRANSACTION ISOLATION LEVEL ', @isolation);
PREPARE s FROM @sql;
EXECUTE s;
DEALLOCATE PREPARE s;

SET @t0 := NOW(6);

START TRANSACTION;
INSERT INTO bench_gap (k, payload, updated_at)
VALUES (@insert_k, CONCAT('ins-', @insert_k), NOW());
COMMIT;

SET @t1 := NOW(6);

SELECT
  'INSERTER_DONE' AS tag,
  @isolation AS isolation_level,
  @insert_k AS insert_k,
  TIMESTAMPDIFF(MICROSECOND, @t0, @t1) / 1000.0 AS waited_ms,
  @t0 AS started_at,
  @t1 AS finished_at;

