# Nginx 集群配置管理系统 实施计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 实现基于 Flask + MySQL + Celery 的 Nginx 集群配置管理系统，支持树形配置管理、版本控制、SSH 密钥认证下发、异步任务队列。

**Architecture:** 三层架构（HTML/JS → Flask/Gunicorn → MySQL），Celery+Redis 处理异步下发任务，paramiko 通过 SSH 密钥认证连接远程 Nginx 服务器。配置文件存本地文件系统，数据库存元数据和版本历史。

**Tech Stack:** Python 3.11+, Flask, Flask-Login, Flask-WTF, Flask-Limiter, PyMySQL, paramiko, Celery, Redis, pytest

---

## 文件结构

```
app/
├── __init__.py          # Flask app factory，注册蓝图和扩展
├── config.py            # 配置类（Dev/Prod），读取环境变量
├── db.py                # PyMySQL 连接池 + 查询工具函数
├── extensions.py        # csrf, login_manager, limiter 实例
├── auth.py              # /login /logout 路由 + Flask-Login user_loader
├── models/
│   ├── user.py          # User dataclass + DB 查询
│   ├── cluster.py       # Cluster dataclass + DB 查询
│   ├── host.py          # Host dataclass + DB 查询
│   └── nginx_config.py  # NginxConfig + NginxConfigVersion dataclass
├── services/
│   ├── deploy.py        # DeployService: rsync 下发 + 保护机制
│   ├── nginx.py         # NginxService: nginx -t / reload via SSH
│   └── config_file.py   # 本地文件读写 + 路径安全校验
├── routes/
│   ├── config.py        # /config/* 路由（树形列表、编辑、保存、回滚）
│   ├── cluster.py       # /cluster/* 路由
│   ├── host.py          # /host/* 路由
│   ├── user.py          # /user/* 路由
│   └── log.py           # /log/* 路由
├── tasks/
│   └── deploy.py        # Celery 异步下发任务
└── templates/
    ├── base.html
    ├── login.html
    ├── config/list.html  # 树形配置管理页
    ├── config/edit.html  # 编辑器页
    ├── cluster/list.html
    ├── host/list.html
    ├── user/list.html
    └── log/list.html
migrations/init.sql       # 建表 SQL（含所有 8 张表）
tests/
├── conftest.py
├── test_auth.py
├── test_config.py
├── test_deploy.py
└── test_nginx_service.py
requirements.txt
run.py

---

## 实施步骤

### 阶段一：基础设施

- [ ] 创建项目目录结构和 `requirements.txt`
- [ ] 编写 `migrations/init.sql`（8 张表，含外键约束）
- [ ] 实现 `app/__init__.py` Flask app factory
- [ ] 实现 `app/db.py` 数据库连接池和查询工具
- [ ] 实现 `app/config.py` 配置类（读取环境变量）

### 阶段二：认证模块

- [ ] 实现 `app/models/user.py` User 模型
- [ ] 实现 `app/auth.py` 登录/登出路由 + Flask-Login
- [ ] 配置 Flask-WTF CSRF 保护
- [ ] 配置 Flask-Limiter 登录频率限制（10次/分钟，失败5次锁定15分钟）
- [ ] 实现 `templates/login.html`

### 阶段三：集群和主机管理

- [ ] 实现 `app/models/cluster.py` 和 `app/models/host.py`
- [ ] 实现 `/cluster/*` 和 `/host/*` 路由（增删改查）
- [ ] 实现集群和主机管理页面模板

### 阶段四：配置管理核心

- [ ] 实现 `app/services/config_file.py`（路径安全校验 + 本地文件读写）
- [ ] 实现 `app/models/nginx_config.py`（含版本历史）
- [ ] 实现 `/config/tree` 接口（返回目录树 JSON）
- [ ] 实现 `/config/edit` 和 `/config/save`（含乐观锁冲突检测）
- [ ] 实现 `/config/rollback` 回滚接口
- [ ] 实现树形配置管理页面（`templates/config/list.html`）
- [ ] 实现配置编辑器页面（`templates/config/edit.html`，含语法高亮）

### 阶段五：下发和 Nginx 操作

- [ ] 实现 `app/services/deploy.py`（rsync + 保护机制：备份、非空检查）
- [ ] 实现 `app/services/nginx.py`（SSH 执行 nginx -t / reload，shell=False）
- [ ] 实现 `app/tasks/deploy.py` Celery 异步下发任务（含状态机）
- [ ] 实现 `/config/deploy` 接口（触发异步任务）
- [ ] 实现 `/api/task/<task_id>/status` 轮询接口

### 阶段六：用户管理和日志

- [ ] 实现 `app/models/user.py` 用户权限模型（含集群权限表）
- [ ] 实现 `/user/*` 路由（增删改查 + 权限分配）
- [ ] 实现 `/log/*` 路由（oplog 查询，支持按用户/集群/时间筛选）
- [ ] 实现操作日志记录装饰器（自动记录关键操作到 oplog）

### 阶段七：部署配置

- [ ] 编写 Nginx 反向代理配置（强制 HTTPS）
- [ ] 编写 Gunicorn 启动配置
- [ ] 编写 Celery Worker 启动脚本
- [ ] 编写 SSH 密钥生成和分发说明文档

---

## 关键约束

1. **SSH 认证**：所有远程操作使用 SSH 密钥，禁止密码认证
2. **命令执行**：所有 subprocess 调用使用 `shell=False` + 列表参数
3. **路径安全**：所有文件路径操作前必须调用 `config_file.validate_path()`
4. **版本控制**：每次保存配置自动创建新版本，支持回滚
5. **异步下发**：下发操作必须通过 Celery 异步执行，HTTP 接口只返回 task_id
