-- No-drop OLTP updater for agg_range_demo_batch.sql
-- Parameters:
--   @lo_id, @hi_id
-- Waits until batch releases the gate lock, then bumps all rows in the range by +1.

SET @lo_id := IFNULL(@lo_id, 1);
SET @hi_id := IFNULL(@hi_id, 100000);

-- Acquire done lock first and hold it until commit so batch can wait for completion.
DO GET_LOCK('agg_range_done', 30);

-- Wait until batch has acquired the gate lock and released the start signal.
DO GET_LOCK('agg_range_start', 30);
DO RELEASE_LOCK('agg_range_start');

-- Now wait for the gate to open (batch releases after first read)
DO GET_LOCK('agg_range_gate', 30);
DO RELEASE_LOCK('agg_range_gate');

SET @t0 := NOW(6);

START TRANSACTION;
UPDATE orders
SET amount = amount + 1,
    updated_at = NOW()
WHERE id BETWEEN @lo_id AND @hi_id
  AND status = 'PAID';

SET @rows_updated := ROW_COUNT();

COMMIT;

SET @t1 := NOW(6);

SELECT
  'OLTP_RANGE_UPDATED' AS tag,
  @lo_id AS lo_id,
  @hi_id AS hi_id,
  @rows_updated AS rows_updated,
  TIMESTAMPDIFF(MICROSECOND, @t0, @t1) / 1000.0 AS waited_ms,
  @t0 AS started_at,
  @t1 AS finished_at;

DO RELEASE_LOCK('agg_range_done');
