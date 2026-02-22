-- Utilities for fast bulk data generation without recursive CTE limits.
-- Creates:
--  - digits: 0..9
--  - nums_1m: 1..1,000,000

CREATE TABLE IF NOT EXISTS digits (
  d TINYINT UNSIGNED PRIMARY KEY
) ENGINE=InnoDB;

INSERT IGNORE INTO digits (d) VALUES
  (0),(1),(2),(3),(4),(5),(6),(7),(8),(9);

CREATE TABLE IF NOT EXISTS nums_1m (
  n INT UNSIGNED NOT NULL PRIMARY KEY
) ENGINE=InnoDB;

-- If already populated, don't duplicate work.
INSERT IGNORE INTO nums_1m (n)
SELECT
  1
  + a.d
  + 10*b.d
  + 100*c.d
  + 1000*d.d
  + 10000*e.d
  + 100000*f.d AS n
FROM digits a
CROSS JOIN digits b
CROSS JOIN digits c
CROSS JOIN digits d
CROSS JOIN digits e
CROSS JOIN digits f;

