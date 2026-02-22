-- Capture key experiment parameters (MySQL)
SELECT
  @@version AS mysql_version,
  @@version_comment AS version_comment,
  @@autocommit AS autocommit,
  @@transaction_isolation AS transaction_isolation,
  @@innodb_lock_wait_timeout AS innodb_lock_wait_timeout,
  @@innodb_deadlock_detect AS innodb_deadlock_detect,
  @@max_connections AS max_connections,
  @@wait_timeout AS wait_timeout,
  @@interactive_timeout AS interactive_timeout;

