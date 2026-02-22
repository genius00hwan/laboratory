-- Seed bench_gap with even keys 2..20000 (10000 rows).
-- Prereq: nums_1m exists (tools/bootstrap_sequences.sql).
-- Note: runner should call this only when bench_gap is empty.

INSERT INTO bench_gap (k, payload, updated_at)
SELECT
  n * 2 AS k,
  CONCAT('seed-', n * 2) AS payload,
  NOW()
FROM nums_1m
WHERE n <= 10000;
