-- MySQL 8 recursive CTE default recursion depth is 1000; raise for bulk seed.
SET SESSION cte_max_recursion_depth = 100000;

TRUNCATE TABLE work_queue;

INSERT INTO work_queue (state, payload, owner, locked_at, updated_at)
WITH RECURSIVE seq AS (
  SELECT 1 AS n
  UNION ALL
  SELECT n + 1 FROM seq WHERE n < 50000
)
SELECT
  'READY',
  CONCAT('job-', n),
  NULL,
  NULL,
  NOW()
FROM seq;
