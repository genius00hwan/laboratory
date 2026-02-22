-- One-row snapshot of lock/deadlock related counters.
-- Requires SELECT on performance_schema (or run as root).

SELECT
  NOW(6) AS captured_at,
  -- Errors are cumulative since server start; take before/after and diff in your driver.
  (SELECT IFNULL(SUM_ERROR_RAISED, 0)
     FROM performance_schema.events_errors_summary_global_by_error
    WHERE ERROR_NAME = 'ER_LOCK_DEADLOCK') AS deadlocks_total,
  (SELECT IFNULL(SUM_ERROR_RAISED, 0)
     FROM performance_schema.events_errors_summary_global_by_error
    WHERE ERROR_NAME = 'ER_LOCK_WAIT_TIMEOUT') AS lock_wait_timeouts_total,
  (SELECT COUNT(*) FROM performance_schema.data_lock_waits) AS current_row_lock_waits,
  (SELECT COUNT(*) FROM performance_schema.metadata_locks WHERE LOCK_STATUS = 'PENDING') AS current_mdl_waits,
  (SELECT IFNULL(MAX(wait_age_secs), 0) FROM sys.innodb_lock_waits) AS max_row_lock_wait_age_secs;
