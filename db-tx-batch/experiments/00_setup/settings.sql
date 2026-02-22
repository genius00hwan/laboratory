-- 깨끗하게 시작
DROP TABLE IF EXISTS audit_events;
DROP TABLE IF EXISTS batch_run;
DROP TABLE IF EXISTS processed_log;
DROP TABLE IF EXISTS work_queue;
DROP TABLE IF EXISTS agg_daily;
DROP TABLE IF EXISTS agg_total;
DROP TABLE IF EXISTS orders;

-- 집계 실험용
CREATE TABLE orders (
  id BIGINT PRIMARY KEY AUTO_INCREMENT,
  amount INT NOT NULL,
  status VARCHAR(20) NOT NULL,
  created_at DATETIME NOT NULL,
  updated_at DATETIME NOT NULL,
  INDEX idx_created_at (created_at),
  INDEX idx_status (status)
) ENGINE=InnoDB;

CREATE TABLE agg_total (
  k VARCHAR(20) PRIMARY KEY,
  sum_amount BIGINT NOT NULL,
  cnt BIGINT NOT NULL,
  updated_at DATETIME NOT NULL
) ENGINE=InnoDB;

INSERT INTO agg_total (k, sum_amount, cnt, updated_at)
VALUES ('ALL', 0, 0, NOW())
ON DUPLICATE KEY UPDATE updated_at = VALUES(updated_at);

CREATE TABLE agg_daily (
  k_date DATE PRIMARY KEY,
  sum_amount BIGINT NOT NULL,
  cnt BIGINT NOT NULL,
  updated_at DATETIME NOT NULL
) ENGINE=InnoDB;

-- 큐형 배치 실험용
CREATE TABLE work_queue (
  id BIGINT PRIMARY KEY AUTO_INCREMENT,
  state ENUM('READY','PROCESSING','DONE') NOT NULL,
  payload VARCHAR(100) NOT NULL,
  owner VARCHAR(50) NULL,
  locked_at DATETIME NULL,
  updated_at DATETIME NOT NULL,
  INDEX idx_state_id (state, id)
) ENGINE=InnoDB;

-- 멱등/중복탐지(중복 처리 “증거” 남기기)
CREATE TABLE processed_log (
  dedupe_key VARCHAR(100) PRIMARY KEY,
  processed_at DATETIME NOT NULL
) ENGINE=InnoDB;

-- Run metadata (각 실험 회차를 run_id로 묶기)
CREATE TABLE batch_run (
  run_id BIGINT PRIMARY KEY AUTO_INCREMENT,
  started_at DATETIME NOT NULL,
  finished_at DATETIME NULL,
  isolation_level VARCHAR(50) NOT NULL,
  notes TEXT NULL
) ENGINE=InnoDB;

-- Minimal audit trail (optional; write from batch/OLTP scripts if needed)
CREATE TABLE audit_events (
  id BIGINT PRIMARY KEY AUTO_INCREMENT,
  ts DATETIME NOT NULL,
  actor VARCHAR(20) NOT NULL,
  action VARCHAR(50) NOT NULL,
  order_id BIGINT NULL,
  before_json JSON NULL,
  after_json JSON NULL,
  txid BIGINT NULL,
  INDEX idx_ts (ts),
  INDEX idx_actor_ts (actor, ts),
  INDEX idx_order_ts (order_id, ts)
) ENGINE=InnoDB;
