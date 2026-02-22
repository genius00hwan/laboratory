-- Bench-only tables (safe to run on large datasets; no DROP/TRUNCATE).

CREATE TABLE IF NOT EXISTS bench_kv (
  id INT PRIMARY KEY,
  v INT NOT NULL,
  updated_at DATETIME NOT NULL,
  KEY idx_updated_at (updated_at)
) ENGINE=InnoDB;

INSERT INTO bench_kv (id, v, updated_at)
VALUES
  (1, 0, NOW()),
  (2, 0, NOW())
ON DUPLICATE KEY UPDATE
  updated_at = VALUES(updated_at);

