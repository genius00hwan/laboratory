-- Root-friendly undo/purge signal snapshot for long RR transactions.
-- Primary metric: history list length (undo versions waiting to be purged).

SELECT
  NOW(6) AS captured_at,
  CAST((SELECT VARIABLE_VALUE
          FROM performance_schema.global_status
         WHERE VARIABLE_NAME = 'Innodb_history_list_length') AS UNSIGNED) AS innodb_history_list_length,
  (SELECT COUNT FROM information_schema.innodb_metrics WHERE name = 'trx_rseg_history_len') AS trx_rseg_history_len,
  (SELECT COUNT(*) FROM information_schema.innodb_trx) AS active_trx,
  IFNULL((
    SELECT MAX(TIMESTAMPDIFF(SECOND, trx_started, NOW(6)))
      FROM information_schema.innodb_trx
  ), 0) AS oldest_trx_age_s;
