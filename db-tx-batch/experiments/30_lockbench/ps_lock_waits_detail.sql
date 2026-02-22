-- Current lock waits detail (for debugging when current_row_lock_waits > 0).
-- Requires SELECT on performance_schema (or run as root).

SELECT
  NOW(6) AS captured_at,
  dlw.REQUESTING_ENGINE_LOCK_ID,
  dlw.BLOCKING_ENGINE_LOCK_ID,
  r.OBJECT_SCHEMA AS req_schema,
  r.OBJECT_NAME AS req_object,
  r.LOCK_TYPE AS req_lock_type,
  r.LOCK_MODE AS req_lock_mode,
  r.LOCK_STATUS AS req_lock_status,
  b.LOCK_MODE AS blk_lock_mode,
  b.LOCK_STATUS AS blk_lock_status
FROM performance_schema.data_lock_waits dlw
JOIN performance_schema.data_locks r
  ON r.ENGINE_LOCK_ID = dlw.REQUESTING_ENGINE_LOCK_ID
JOIN performance_schema.data_locks b
  ON b.ENGINE_LOCK_ID = dlw.BLOCKING_ENGINE_LOCK_ID
ORDER BY r.OBJECT_SCHEMA, r.OBJECT_NAME;

