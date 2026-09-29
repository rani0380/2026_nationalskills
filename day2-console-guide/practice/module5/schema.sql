CREATE DATABASE IF NOT EXISTS shgold
  CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
USE shgold;
CREATE TABLE IF NOT EXISTS readings (
  id CHAR(36) PRIMARY KEY,
  device_id VARCHAR(64),
  metric VARCHAR(64),
  value DOUBLE,
  recorded_at DATETIME,
  created_at DATETIME DEFAULT CURRENT_TIMESTAMP
);
-- Create the application DB user separately with a private password.
-- GRANT SELECT, INSERT ON shgold.readings TO 'shgold_app'@'%';
