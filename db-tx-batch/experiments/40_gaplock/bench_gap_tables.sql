-- Bench table for demonstrating gap/next-key locking differences (RC vs RR vs SERIALIZABLE).
-- We seed even keys so odd keys are "gaps".

CREATE TABLE IF NOT EXISTS bench_gap (
  id BIGINT PRIMARY KEY AUTO_INCREMENT,
  k INT NOT NULL,
  payload VARCHAR(50) NOT NULL,
  updated_at DATETIME NOT NULL,
  KEY idx_k (k)
) ENGINE=InnoDB;

