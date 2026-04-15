-- Nginx 集群配置管理系统 数据库初始化脚本
-- 版本: 2.0
-- 创建时间: 2026-04-15
SET NAMES utf8mb4;
SET FOREIGN_KEY_CHECKS = 0;

CREATE TABLE users (
  id INT PRIMARY KEY AUTO_INCREMENT,
  username VARCHAR(50) NOT NULL UNIQUE,
  password VARCHAR(255) NOT NULL,  -- bcrypt 哈希
  role ENUM('admin', 'user') DEFAULT 'user',
  failed_login_count INT DEFAULT 0,
  locked_until TIMESTAMP NULL,
  created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_bin;

CREATE TABLE clusters (
  id INT PRIMARY KEY AUTO_INCREMENT,
  cluster_name VARCHAR(100) NOT NULL UNIQUE,  -- 英文名
  cluster_zh_name VARCHAR(128) NOT NULL,       -- 中文名
  local_path VARCHAR(256) NOT NULL DEFAULT '/data/nginx-configs/',
  created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_bin;

CREATE TABLE hosts (
  id INT PRIMARY KEY AUTO_INCREMENT,
  cluster_id INT NOT NULL,
  hostname VARCHAR(100) NOT NULL,
  ip VARCHAR(50) NOT NULL,
  ssh_port INT DEFAULT 22,
  username VARCHAR(50) NOT NULL DEFAULT 'nginx-mgr',
  key_path VARCHAR(256) NOT NULL DEFAULT '/etc/nginx-manager/ssh/id_ed25519',
  nginx_dir VARCHAR(256) NOT NULL DEFAULT '/etc/nginx',
  backup_dir VARCHAR(256) NOT NULL DEFAULT '/etc/nginx-backups',
  sbin_nginx VARCHAR(256) NOT NULL DEFAULT '/usr/sbin/nginx',
  created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
  FOREIGN KEY (cluster_id) REFERENCES clusters(id) ON DELETE RESTRICT
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_bin;

CREATE TABLE nginx_config (
  id INT PRIMARY KEY AUTO_INCREMENT,
  cluster_id INT NOT NULL,
  file_path VARCHAR(512) NOT NULL,       -- 相对路径，如 conf.d/api.conf
  current_version INT NOT NULL DEFAULT 1,
  last_modify_time TIMESTAMP DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
  created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
  UNIQUE KEY uk_cluster_path (cluster_id, file_path),
  FOREIGN KEY (cluster_id) REFERENCES clusters(id) ON DELETE RESTRICT
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_bin;

CREATE TABLE nginx_config_versions (
  id INT PRIMARY KEY AUTO_INCREMENT,
  config_id INT NOT NULL,
  version INT NOT NULL,
  content MEDIUMTEXT NOT NULL,
  created_by VARCHAR(50) NOT NULL,
  created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
  comment VARCHAR(512),
  UNIQUE KEY uk_config_version (config_id, version),
  FOREIGN KEY (config_id) REFERENCES nginx_config(id) ON DELETE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_bin;

CREATE TABLE user_cluster_permissions (
  id INT PRIMARY KEY AUTO_INCREMENT,
  user_id INT NOT NULL,
  cluster_id INT NOT NULL,
  can_view TINYINT(1) DEFAULT 1,
  can_edit TINYINT(1) DEFAULT 0,
  can_deploy TINYINT(1) DEFAULT 0,
  UNIQUE KEY uk_user_cluster (user_id, cluster_id),
  FOREIGN KEY (user_id) REFERENCES users(id) ON DELETE CASCADE,
  FOREIGN KEY (cluster_id) REFERENCES clusters(id) ON DELETE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_bin;

CREATE TABLE oplog (
  id INT PRIMARY KEY AUTO_INCREMENT,
  user_id INT NOT NULL,
  cluster_id INT,
  hostname VARCHAR(100),
  file_path VARCHAR(512),
  operation VARCHAR(512) NOT NULL,
  created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
  INDEX idx_user_id (user_id),
  INDEX idx_cluster_id (cluster_id),
  INDEX idx_created_at (created_at),
  FOREIGN KEY (user_id) REFERENCES users(id) ON DELETE RESTRICT
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_bin;

CREATE TABLE tasklog (
  id INT PRIMARY KEY AUTO_INCREMENT,
  task_id VARCHAR(64) NOT NULL,
  cluster_id INT NOT NULL,
  host_id INT NOT NULL,
  config_id INT NOT NULL,
  config_version INT NOT NULL,
  hostname VARCHAR(100) NOT NULL,
  status ENUM('pending','running','success','failed') DEFAULT 'pending',
  result TEXT,
  push_time TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
  finish_time TIMESTAMP NULL,
  INDEX idx_task_id (task_id),
  INDEX idx_cluster_id (cluster_id),
  INDEX idx_push_time (push_time),
  FOREIGN KEY (cluster_id) REFERENCES clusters(id) ON DELETE RESTRICT,
  FOREIGN KEY (host_id) REFERENCES hosts(id) ON DELETE RESTRICT,
  FOREIGN KEY (config_id) REFERENCES nginx_config(id) ON DELETE RESTRICT
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_bin;

SET FOREIGN_KEY_CHECKS = 1;
