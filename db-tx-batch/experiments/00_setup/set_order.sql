-- MySQL 8 recursive CTE default recursion depth is 1000; raise for bulk seed.
SET SESSION cte_max_recursion_depth = 200000;

TRUNCATE TABLE orders;

INSERT INTO orders (amount, status, created_at, updated_at)
WITH RECURSIVE seq AS (
  SELECT 1 AS n
  UNION ALL
  SELECT n + 1 FROM seq WHERE n < 100000
)
SELECT
  (n % 1000) + 1,
  CASE WHEN n % 5 = 0 THEN 'CANCEL' ELSE 'PAID' END,
  NOW() - INTERVAL (n % 30) DAY,
  NOW()
FROM seq;
