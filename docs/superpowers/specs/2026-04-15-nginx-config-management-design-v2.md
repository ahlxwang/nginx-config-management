# Nginx 集群配置管理系统 — 架构设计文档 v2.0

**文档版本：** 2.0（根据安全评审意见修订）  
**创建日期：** 2026-04-15  
**设计方案：** 传统三层架构 + 树形配置管理

---

## 1. 系统概述

### 1.1 核心功能

- 配置文件集中管理（树形目录结构 + 版本控制）
- 在线编辑器（语法高亮、冲突检测）
- 配置下发（SSH 密钥认证 + rsync，含备份和回滚）
- 配置校验（`nginx -t`）和重载（`nginx -s reload`）
- 集群/主机/用户管理
- 操作日志审计

### 1.2 技术栈

| 层级     | 技术选型                          |
|----------|-----------------------------------|
| 前端     | HTML + CSS + JavaScript           |
| 后端     | Flask (Python 3.11+), Gunicorn    |
| 数据库   | MySQL 8.0+                        |
| 任务队列 | Celery + Redis                    |
| 部署工具 | paramiko + rsync（SSH 密钥认证）  |
| 反向代理 | Nginx（HTTPS 强制）               |

---

## 2. 安全设计（修订版）

### 2.1 SSH 认证方案

**使用 SSH 密钥认证，禁止密码认证：**

```
管理服务器生成专用 SSH 密钥对（ED25519）
→ 公钥分发到所有 Nginx 服务器的 ~/.ssh/authorized_keys
→ 私钥存储在管理服务器本地 /etc/nginx-manager/ssh/id_ed25519（权限 600）
→ hosts 表只存储 key_path，不存密码
```

hosts 表不再存储 password 字段，改为：
```sql
`key_path` VARCHAR(256) NOT NULL DEFAULT '/etc/nginx-manager/ssh/id_ed25519'
```

### 2.2 命令注入防护

所有 SSH/rsync 命令使用列表参数，禁止 `shell=True`：

```python
# 正确：列表参数 + shell=False
cmd = ["rsync", "-avz", "--delete", local_dir,
       f"{host.username}@{host.ip}:{host.nginx_dir}/"]
subprocess.run(cmd, shell=False, timeout=60)

# 必须校验 IP 格式
import ipaddress
ipaddress.ip_address(host.ip)  # 非法 IP 抛出 ValueError

# 必须校验路径在白名单内
base = "/data/nginx-configs/"
full = os.path.realpath(os.path.join(base, file_path))
assert full.startswith(base), "路径遍历攻击"
```

### 2.3 rsync --delete 保护机制

下发前执行三重保护：

1. **源目录非空检查**：文件数量低于阈值（默认 1）则拒绝下发
2. **目标服务器备份**：下发前执行 `cp -r /etc/nginx /etc/nginx.bak.$(date +%Y%m%d%H%M%S)`
3. **二次确认**：前端展示将要变更的文件列表，用户确认后才执行

```python
def deploy_with_protection(host, local_dir):
    # 1. 源目录非空检查
    files = list(Path(local_dir).rglob("*.conf"))
    if len(files) == 0:
        raise ValueError("源目录为空，拒绝下发")

    # 2. 目标服务器备份
    ssh_exec(host, f"cp -r {host.nginx_dir} {host.backup_dir}/nginx.bak.$(date +%Y%m%d%H%M%S)")

    # 3. 执行 rsync
    cmd = ["rsync", "-avz", "--delete", local_dir,
           f"{host.username}@{host.ip}:{host.nginx_dir}/"]
    subprocess.run(cmd, shell=False, timeout=120)
```

### 2.4 CSRF 防护

使用 Flask-WTF 的 CSRF 保护，所有 POST/PUT/DELETE 请求校验 CSRF Token：

```python
from flask_wtf.csrf import CSRFProtect
csrf = CSRFProtect(app)
```

### 2.5 HTTPS 强制

Nginx 反向代理配置强制 HTTPS：

```nginx
server {
    listen 80;
    return 301 https://$host$request_uri;
}
server {
    listen 443 ssl;
    ssl_certificate /etc/ssl/nginx-manager.crt;
    ssl_certificate_key /etc/ssl/nginx-manager.key;
}
```

### 2.6 SSH 最小权限

目标服务器使用专用低权限用户 + sudoers 精确授权：

```
# /etc/sudoers.d/nginx-manager
nginx-mgr ALL=(root) NOPASSWD: /usr/sbin/nginx -t
nginx-mgr ALL=(root) NOPASSWD: /usr/sbin/nginx -s reload
```

### 2.7 登录防暴力破解

- 连续失败 5 次锁定账号 15 分钟
- 使用 Flask-Limiter 限制登录接口频率（10次/分钟）

---

## 3. 核心功能设计

### 3.1 配置管理（树形结构 + 版本控制）

#### 3.1.1 版本控制数据模型

```sql
CREATE TABLE nginx_config (
  id INT PRIMARY KEY AUTO_INCREMENT,
  cluster_id INT NOT NULL,
  file_path VARCHAR(512) NOT NULL,       -- 相对路径，如 conf.d/api.conf
  current_version INT NOT NULL DEFAULT 1,
  last_modify_time TIMESTAMP DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
  FOREIGN KEY (cluster_id) REFERENCES clusters(id)
);

CREATE TABLE nginx_config_versions (
  id INT PRIMARY KEY AUTO_INCREMENT,
  config_id INT NOT NULL,
  version INT NOT NULL,
  content MEDIUMTEXT NOT NULL,           -- 配置文件内容快照
  created_by VARCHAR(50) NOT NULL,
  created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
  comment VARCHAR(512),
  INDEX idx_config_version (config_id, version),
  FOREIGN KEY (config_id) REFERENCES nginx_config(id)
);
```

#### 3.1.2 并发编辑冲突检测（乐观锁）

```python
def save_config(config_id, content, client_version, username):
    config = db.get("SELECT * FROM nginx_config WHERE id = ?", config_id)
    if config.current_version != client_version:
        raise ConflictError("文件已被他人修改，请刷新后重试")

    new_version = config.current_version + 1
    db.insert("nginx_config_versions", {
        "config_id": config_id,
        "version": new_version,
        "content": content,
        "created_by": username,
    })
    db.update("nginx_config", {"current_version": new_version}, id=config_id)
    # 同时写入本地文件系统
    write_to_disk(config.file_path, content)
```

#### 3.1.3 回滚操作

```python
def rollback_config(config_id, target_version, username):
    version = db.get("SELECT * FROM nginx_config_versions WHERE config_id=? AND version=?",
                     config_id, target_version)
    save_config(config_id, version.content, get_current_version(config_id), username)
```

### 3.2 配置下发（异步任务）

#### 3.2.1 任务状态机

```
pending → running → success
                 ↘ partial_failed（部分主机失败）
                 ↘ failed（全部失败）
```

#### 3.2.2 tasklog 表（完整版）

```sql
CREATE TABLE tasklog (
  id INT PRIMARY KEY AUTO_INCREMENT,
  task_id VARCHAR(64) NOT NULL,          -- Celery task ID
  cluster_id INT NOT NULL,
  host_id INT NOT NULL,
  config_id INT NOT NULL,
  config_version INT NOT NULL,
  hostname VARCHAR(100) NOT NULL,
  status ENUM('pending','running','success','failed') DEFAULT 'pending',
  result TEXT,                           -- 执行输出或错误信息
  push_time TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
  finish_time TIMESTAMP NULL,
  INDEX idx_task_id (task_id),
  INDEX idx_cluster_id (cluster_id),
  INDEX idx_push_time (push_time),
  FOREIGN KEY (cluster_id) REFERENCES clusters(id),
  FOREIGN KEY (host_id) REFERENCES hosts(id)
);
```

#### 3.2.3 异步下发流程

```python
@celery.task(bind=True)
def deploy_task(self, cluster_id, config_id):
    hosts = db.query("SELECT * FROM hosts WHERE cluster_id = ?", cluster_id)
    for host in hosts:
        tasklog_id = db.insert("tasklog", {"status": "running", ...})
        try:
            deploy_with_protection(host, local_dir)
            db.update("tasklog", {"status": "success"}, id=tasklog_id)
        except Exception as e:
            db.update("tasklog", {"status": "failed", "result": str(e)}, id=tasklog_id)
```

前端通过轮询 `/api/task/{task_id}/status` 获取进度。

### 3.3 集群权限控制

增加基于集群的权限表，支持细粒度权限：

```sql
CREATE TABLE user_cluster_permissions (
  id INT PRIMARY KEY AUTO_INCREMENT,
  user_id INT NOT NULL,
  cluster_id INT NOT NULL,
  can_view TINYINT(1) DEFAULT 1,
  can_edit TINYINT(1) DEFAULT 0,
  can_deploy TINYINT(1) DEFAULT 0,
  UNIQUE KEY uk_user_cluster (user_id, cluster_id),
  FOREIGN KEY (user_id) REFERENCES users(id),
  FOREIGN KEY (cluster_id) REFERENCES clusters(id)
);
```

---

## 4. 数据库设计（修订版）

### 4.1 完整表清单

| 表名                       | 说明                     |
|----------------------------|--------------------------|
| users                      | 用户表                   |
| clusters                   | 集群表                   |
| hosts                      | 主机表（SSH 密钥认证）   |
| nginx_config               | 配置文件元数据表         |
| nginx_config_versions      | 配置文件版本历史表       |
| user_cluster_permissions   | 用户集群权限表           |
| oplog                      | 操作日志表               |
| tasklog                    | 下发任务日志表（含状态） |

### 4.2 关键修订

- `hosts.password` → `hosts.key_path`（SSH 密钥认证）
- `oplog.cluster_zh_name` → `oplog.cluster_id`（避免反范式）
- 所有外键关系显式定义 `FOREIGN KEY` 约束
- `users.password VARCHAR(255)`（兼容未来哈希算法）

---

## 5. 部署方案（修订版）

```
浏览器（HTTPS）
    ↓
Nginx 反向代理（强制 HTTPS + 静态文件）
    ↓
Gunicorn（Flask 应用，4 workers）
    ↓
MySQL 8.0+
    ↓
Redis（Celery 任务队列）
    ↓
Celery Worker（异步下发任务）
    ↓
目标 Nginx 服务器（SSH 密钥认证）
```

### 5.1 配置文件备份

管理服务器的 `/data/nginx-configs/` 目录定期备份到对象存储：

```bash
# 每日凌晨 2 点备份到 OSS
0 2 * * * tar -czf /tmp/nginx-configs-$(date +%Y%m%d).tar.gz /data/nginx-configs/ && ossutil cp /tmp/nginx-configs-*.tar.gz oss://backup-bucket/nginx-configs/
```

### 5.2 环境要求

- Python 3.11+
- MySQL 8.0+
- Redis 6.0+
- 操作系统：Linux (CentOS 7+ / Ubuntu 20.04+)

---

## 6. 附录

### 6.1 v1.0 → v2.0 主要变更

| 问题 | v1.0 | v2.0 |
|------|------|------|
| SSH 认证 | 密码存数据库 | SSH 密钥认证 |
| 命令执行 | shell=True + 字符串拼接 | shell=False + 列表参数 |
| rsync 保护 | 无 | 备份 + 非空检查 + 二次确认 |
| 版本控制 | 无 | nginx_config_versions 表 |
| 并发冲突 | 无 | 乐观锁 |
| 下发任务 | 同步 | Celery 异步 + 状态机 |
| CSRF | 无 | Flask-WTF |
| HTTPS | 未提及 | Nginx 强制跳转 |
| 权限粒度 | admin/user | 基于集群的细粒度权限 |
| Python 版本 | 3.7~3.10 | 3.11+ |
| 生产部署 | Flask 内置 | Gunicorn |
