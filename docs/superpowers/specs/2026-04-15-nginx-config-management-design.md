# Nginx 集群配置管理系统 — 架构设计文档

**文档版本：** 1.0  
**创建日期：** 2026-04-15  
**设计方案：** 传统三层架构 + 树形配置管理

---

## 1. 系统概述

### 1.1 目标

设计并实现一个 Nginx 集群配置管理系统，用于集中管理多个 Nginx 服务器的配置文件，支持配置编辑、版本控制、批量下发、校验和重载等功能。

### 1.2 适用范围

- 内部运维团队（2-10 人）
- 管理 10-100 台 Nginx 服务器
- 支持多集群环境（生产、测试、开发）

### 1.3 核心功能

- 配置文件的集中管理（树形目录结构）
- 配置编辑器（在线编辑 nginx.conf 等配置文件）
- 配置下发（通过 SSH/rsync 批量同步到目标服务器）
- 配置校验（远程执行 `nginx -t`）
- Nginx 重载（远程执行 `nginx -s reload`）
- 集群和主机管理
- 用户权限管理
- 操作日志审计

---

## 2. 技术架构

### 2.1 架构模式

采用**传统三层架构**（Presentation Layer → Business Logic Layer → Data Access Layer）

```
┌─────────────────────────────────────────────────────────┐
│  表示层 (Presentation Layer)                              │
│  HTML + CSS + JavaScript                                 │
│  - 登录页 / 首页 / 配置管理 / 集群管理 / 日志查询          │
└─────────────────────────────────────────────────────────┘
                          ↓ HTTP Request/Response
┌─────────────────────────────────────────────────────────┐
│  业务逻辑层 (Business Logic Layer)                        │
│  Flask (Python 3.7~3.10)                                 │
│  - 路由层: /login, /config/*, /cluster/*, /host/*        │
│  - 服务层: ConfigService, DeployService, NginxService    │
└─────────────────────────────────────────────────────────┘
                          ↓ SQL Query
┌─────────────────────────────────────────────────────────┐
│  数据访问层 (Data Access Layer)                           │
│  MySQL 8.0+                                              │
│  - users, clusters, hosts, nginx_config, oplog, tasklog │
└─────────────────────────────────────────────────────────┘
                          ↔ SSH/rsync
┌─────────────────────────────────────────────────────────┐
│  外部系统 (External Systems)                              │
│  Nginx 服务器集群 (通过 SSH 连接)                          │
└─────────────────────────────────────────────────────────┘
```

### 2.2 技术栈

| 层级       | 技术选型                          |
|------------|-----------------------------------|
| 前端       | HTML + CSS + JavaScript (原生)    |
| 后端       | Flask (Python 3.7~3.10)           |
| 数据库     | MySQL 8.0+                        |
| 部署工具   | SSH + rsync                       |
| 代码编辑器 | CodeMirror / Ace Editor (可选)    |
| 树形组件   | jsTree / Vue Tree (可选)          |

---

## 3. 核心功能设计

### 3.1 配置管理（树形结构）

#### 3.1.1 界面布局

```
┌────────────────────────────────────────────────────────┐
│  集群选择: [生产集群 ▼]   搜索: [🔍 搜索配置文件...]     │
├──────────────┬─────────────────────────────────────────┤
│              │  📄 nginx.conf                          │
│ 📁 cluster-  │  ┌─────────────────────────────────────┐│
│   prod       │  │ 1  user nginx;                      ││
│ ├─ 📄 nginx. │  │ 2  worker_processes auto;           ││
│ │   conf     │  │ 3  error_log /var/log/nginx/error...││
│ ├─ 📁 conf.d │  │ 4                                   ││
│ │  ├─ 📄 api │  │ 5  events {                         ││
│ │  │   .conf │  │ 6      worker_connections 1024;     ││
│ │  ├─ 📄 web │  │ 7  }                                ││
│ │  │   .conf │  │ ...                                 ││
│ │  └─ 📄 adm │  └─────────────────────────────────────┘│
│ │      in... │  [保存] [下发] [校验] [Reload]           │
│ └─ 📁 sites- │                                          │
│    enabled   │                                          │
└──────────────┴─────────────────────────────────────────┘
```

#### 3.1.2 核心特性

- **树形目录导航**：左侧展示完整的配置文件目录结构
- **文件搜索**：支持按文件名模糊搜索，高亮匹配结果
- **最近编辑**：顶部显示最近编辑的 5 个文件快速入口
- **多标签页**：支持同时打开多个配置文件（可选）
- **语法高亮**：代码编辑器支持 Nginx 配置语法高亮
- **实时保存**：编辑后自动保存到本地 + 数据库

#### 3.1.3 数据存储

- **本地文件系统**：配置文件以目录结构存储在服务器本地
  ```
  /data/nginx-configs/
  ├── cluster-prod/
  │   ├── nginx.conf
  │   ├── conf.d/
  │   │   ├── api.conf
  │   │   ├── web.conf
  │   │   └── admin.conf
  │   └── sites-enabled/
  │       ├── site1.conf
  │       └── site2.conf
  └── cluster-test/
      └── ...
  ```

- **数据库记录**：`nginx_config` 表存储配置文件的元数据
  ```sql
  CREATE TABLE nginx_config (
    id INT PRIMARY KEY AUTO_INCREMENT,
    cluster_id INT NOT NULL,
    file_path VARCHAR(512) NOT NULL,  -- 相对路径，如 conf.d/api.conf
    last_modify_time TIMESTAMP DEFAULT CURRENT_TIMESTAMP
  );
  ```

### 3.2 配置下发流程

#### 3.2.1 流程图

```
用户编辑配置
    ↓
保存到本地 + 数据库
    ↓
用户点击"下发"
    ↓
DeployService 启动
    ↓
查询集群下所有主机 (hosts 表)
    ↓
遍历主机列表
    ↓
SSH 连接 + rsync --delete 同步整个配置目录
    ↓
记录结果到 tasklog 表
    ↓
返回下发结果到前端
```

#### 3.2.2 关键技术点

- **全量同步**：使用 `rsync --delete` 确保目标目录与源目录完全一致
- **批量操作**：一次下发可同时更新集群内所有服务器
- **并发控制**：使用线程池或异步任务处理多台服务器的同步
- **错误处理**：记录每台服务器的同步结果（成功/失败），失败时保留错误信息

#### 3.2.3 示例代码逻辑

```python
def deploy_config(cluster_id, config_id):
    # 1. 查询集群下所有主机
    hosts = db.query("SELECT * FROM hosts WHERE cluster_id = ?", cluster_id)
    
    # 2. 获取配置文件路径
    config = db.query("SELECT * FROM nginx_config WHERE id = ?", config_id)
    local_dir = f"/data/nginx-configs/cluster-{cluster_id}/"
    
    # 3. 遍历主机，执行 rsync
    results = []
    for host in hosts:
        try:
            cmd = f"rsync -avz --delete {local_dir} {host.username}@{host.ip}:{host.nginx_dir}/"
            result = subprocess.run(cmd, shell=True, capture_output=True)
            status = "success" if result.returncode == 0 else "failed"
            results.append({"host": host.hostname, "status": status, "output": result.stdout})
            
            # 4. 记录到 tasklog
            db.insert("tasklog", {
                "cluster_id": cluster_id,
                "host_id": host.id,
                "config_id": config_id,
                "result": status,
                "push_time": datetime.now()
            })
        except Exception as e:
            results.append({"host": host.hostname, "status": "error", "output": str(e)})
    
    return results
```

### 3.3 配置校验与重载

#### 3.3.1 校验（nginx -t）

- 用户点击"校验"按钮
- 后端通过 SSH 连接到目标服务器
- 执行 `nginx -t` 命令
- 返回校验结果（成功/失败 + 错误信息）

#### 3.3.2 重载（nginx -s reload）

- 用户点击"Reload"按钮
- 后端通过 SSH 连接到目标服务器
- 执行 `nginx -s reload` 命令
- 返回执行结果

#### 3.3.3 操作解耦

- **下发、校验、reload 三个操作独立**
- 用户可以灵活控制：先下发 → 再校验 → 确认无误后 reload
- 避免配置错误导致 Nginx 服务中断

### 3.4 集群管理

#### 3.4.1 功能

- 集群的增删改查
- 集群信息：集群名称、中文名称、描述
- 关联主机列表

#### 3.4.2 数据表

```sql
CREATE TABLE clusters (
  id INT PRIMARY KEY AUTO_INCREMENT,
  cluster_name VARCHAR(100) NOT NULL UNIQUE,
  cluster_zh_name VARCHAR(128) NOT NULL,
  description TEXT,
  created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);
```

### 3.5 主机管理

#### 3.5.1 功能

- 主机的增删改查
- 主机信息：主机名、IP、SSH 端口、用户名、密码、Nginx 配置目录
- 关联到集群

#### 3.5.2 数据表

```sql
CREATE TABLE hosts (
  id INT PRIMARY KEY AUTO_INCREMENT,
  cluster_id INT NOT NULL,
  hostname VARCHAR(100) NOT NULL,
  ip VARCHAR(50) NOT NULL,
  ssh_port INT DEFAULT 22,
  username VARCHAR(50) NOT NULL,
  password VARCHAR(100) NOT NULL,  -- 建议加密存储
  nginx_dir VARCHAR(256) DEFAULT '/etc/nginx',
  created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);
```

### 3.6 用户管理

#### 3.6.1 角色

- **管理员**：所有权限
- **普通用户**：只能查看和编辑配置，不能管理用户和集群

#### 3.6.2 数据表

```sql
CREATE TABLE users (
  id INT PRIMARY KEY AUTO_INCREMENT,
  username VARCHAR(50) NOT NULL UNIQUE,
  password VARCHAR(100) NOT NULL,  -- 密码哈希存储
  role ENUM('admin', 'user') DEFAULT 'user',
  created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);
```

### 3.7 操作日志

#### 3.7.1 功能

- 记录所有关键操作：编辑、下发、校验、reload
- 支持按用户、集群、时间范围筛选
- 日志内容：用户名、集群名、主机名、操作类型、时间戳

#### 3.7.2 数据表

```sql
CREATE TABLE oplog (
  id INT PRIMARY KEY AUTO_INCREMENT,
  username VARCHAR(50) NOT NULL,
  cluster_zh_name VARCHAR(128) NOT NULL,
  hostname VARCHAR(100),
  include_config VARCHAR(256),
  operation VARCHAR(512),
  created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
  INDEX idx_username (username),
  INDEX idx_created_at (created_at)
);
```

---

## 4. 数据库设计

### 4.1 ER 图

```
┌─────────┐       ┌──────────┐       ┌─────────────┐
│  users  │       │ clusters │       │    hosts    │
├─────────┤       ├──────────┤       ├─────────────┤
│ id (PK) │       │ id (PK)  │◄──────│ cluster_id  │
│ username│       │ name     │       │ hostname    │
│ password│       │ zh_name  │       │ ip          │
│ role    │       └──────────┘       │ ssh_port    │
└─────────┘              │           │ username    │
                         │           │ password    │
                         │           └─────────────┘
                         │
                         ▼
                  ┌──────────────┐
                  │ nginx_config │
                  ├──────────────┤
                  │ id (PK)      │
                  │ cluster_id   │
                  │ file_path    │
                  │ last_modify  │
                  └──────────────┘
```

### 4.2 表清单

| 表名          | 说明                     |
|---------------|--------------------------|
| users         | 用户表                   |
| clusters      | 集群表                   |
| hosts         | 主机表                   |
| nginx_config  | 配置文件元数据表         |
| oplog         | 操作日志表               |
| tasklog       | 下发任务日志表           |

---

## 5. 安全设计

### 5.1 认证与授权

- **Session 认证**：用户登录后生成 Session，存储在服务器端
- **密码存储**：使用 bcrypt 或 PBKDF2 哈希存储密码
- **权限控制**：基于角色的访问控制（RBAC）

### 5.2 数据安全

- **SQL 注入防护**：使用参数化查询
- **XSS 防护**：前端输出时进行 HTML 转义
- **SSH 密码加密**：主机密码使用 AES 加密存储

### 5.3 操作审计

- 所有关键操作记录到 oplog 表
- 支持事后审计和问题追溯

---

## 6. 性能与扩展

### 6.1 性能优化

- **前端缓存**：静态资源使用浏览器缓存
- **数据库索引**：在 oplog 和 tasklog 表的时间字段上建立索引
- **异步任务**：配置下发使用异步任务队列（Celery 可选）

### 6.2 扩展性

- **水平扩展**：Flask 应用无状态，可部署多实例 + 负载均衡
- **数据库扩展**：MySQL 支持主从复制和读写分离

---

## 7. 部署方案

### 7.1 环境要求

- Python 3.7~3.10
- MySQL 8.0+
- 操作系统：Linux (CentOS 7+ / Ubuntu 18.04+)

### 7.2 部署架构

```
┌─────────────┐
│   Nginx     │  (反向代理)
│  (可选)     │
└──────┬──────┘
       │
       ▼
┌─────────────┐
│   Flask     │  (应用服务器)
│   App       │
└──────┬──────┘
       │
       ▼
┌─────────────┐
│   MySQL     │  (数据库)
└─────────────┘
```

### 7.3 监控与告警

- 集成 Prometheus/Zabbix 监控系统
- 监控指标：配置下发成功率、Nginx 服务状态、系统资源使用率

---

## 8. 附录

### 8.1 参考资料

- Flask 官方文档：https://flask.palletsprojects.com/
- Nginx 配置文档：https://nginx.org/en/docs/
- rsync 手册：https://linux.die.net/man/1/rsync

### 8.2 原型图

原型图文件位于：`.superpowers/brainstorm/628-1776256806/content/`

- `tree-prototype.html` - 树形配置管理界面
- `prototypes.html` - 其他核心页面原型
- `architecture-design.html` - 架构图
- `data-flow.html` - 数据流程图

---

**文档结束**
