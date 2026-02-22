-- Bench orders table for aggregation/chunk demos without touching real `orders`.

CREATE TABLE IF NOT EXISTS bench_orders (
  id BIGINT PRIMARY KEY AUTO_INCREMENT,
  amount INT NOT NULL,
  status VARCHAR(20) NOT NULL,
  created_at DATETIME NOT NULL,
  updated_at DATETIME NOT NULL,
  INDEX idx_created_at (created_at),
  INDEX idx_status (status)
) ENGINE=InnoDB;

