-- Quick table stats for large data runs
SELECT
  table_name,
  table_rows,
  ROUND((data_length + index_length) / 1024 / 1024, 1) AS size_mb,
  ROUND(index_length / 1024 / 1024, 1) AS index_mb
FROM information_schema.tables
WHERE table_schema = DATABASE()
ORDER BY (data_length + index_length) DESC;

