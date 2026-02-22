-- Bench tables for queue-claim correctness/perf experiments (no-drop).
-- This does not touch work_queue/processed_log.

CREATE TABLE IF NOT EXISTS bench_queue (
  id BIGINT PRIMARY KEY AUTO_INCREMENT,
  state ENUM('READY','PROCESSING','DONE') NOT NULL,
  payload VARCHAR(100) NOT NULL,
  owner VARCHAR(50) NULL,
  locked_at DATETIME NULL,
  updated_at DATETIME NOT NULL,
  INDEX idx_state_id (state, id)
) ENGINE=InnoDB;

CREATE TABLE IF NOT EXISTS bench_processed_log (
  dedupe_key VARCHAR(100) PRIMARY KEY,
  processed_at DATETIME NOT NULL
) ENGINE=InnoDB;

