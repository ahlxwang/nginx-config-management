# Nginx 集群配置管理系统 — 架构评审报告

**评审人：** 资深运维架构设计师  
**评审日期：** 2026-04-15  
**文档版本：** 1.0  
**评审结论：** 设计存在多处高危安全缺陷和功能性缺失，**不建议直接进入开发阶段**，需先修订设计文档。

---

## 一、安全评审（Critical）

### 1.1 命令注入漏洞 — 高危 🔴

**位置：** `3.2.3 示例代码逻辑`

```python
# 当前设计（危险）
cmd = f"rsync -avz --delete {local_dir} {host.username}@{host.ip}:{host.nginx_dir}/"
result = subprocess.run(cmd, shell=True, capture_output=True)
```

**问题：** `shell=True` + 字符串拼接 = 经典命令注入。`host.ip`、`host.username`、`host.nginx_dir` 均来自数据库，若数据库被攻破或存在越权写入，攻击者可在管理服务器上执行任意命令。

**修复方案：**
```python
# 正确做法：列表参数 + shell=False
cmd = [
    "rsync", "-avz", "--delete",
    local_dir,
    f"{host.username}@{host.ip}:{host.nginx_dir}/"
]
result = subprocess.run(cmd, shell=False, capture_output=True, timeout=60)
```

同时必须对 `host.ip` 做 IP 格式校验，对 `host.nginx_dir` 做路径白名单校验。

---

### 1.2 SSH 密码明文/弱加密存储 — 高危 🔴

**位置：** `3.5.2 hosts 表`

```sql
password VARCHAR(100) NOT NULL,  -- 建议加密存储
```

**问题：**
- "建议加密存储"只是注释，没有设计方案
- AES 加密的密钥存在哪里？若密钥和密文在同一数据库，等于没加密
- 100 台服务器的 SSH 密码集中存储，一旦数据库泄露，整个集群沦陷

**强烈建议改为 SSH 密钥认证：**
```
管理服务器生成专用 SSH 密钥对
→ 公钥分发到所有 Nginx 服务器的 authorized_keys
→ 私钥存储在管理服务器本地（权限 600，非数据库）
→ hosts 表只存储 key_path 或 key_id，不存密码
```

若业务确实需要密码认证，需设计独立的密钥管理服务（KMS），不能将加密密钥与密文放在同一存储。

---

### 1.3 `rsync --delete` 的灾难性风险 — 高危 🔴

**位置：** `3.2.1 流程图`

`rsync --delete` 会将目标服务器上不存在于源目录的文件全部删除。

**风险场景：**
- 管理服务器磁盘故障 → `/data/nginx-configs/cluster-prod/` 目录为空
- 用户点击"下发" → 100 台生产服务器的 `/etc/nginx/` 被清空
- Nginx 无法启动 → 全站宕机

**必须增加的保护机制：**
1. 下发前检查源目录文件数量，若为空或低于阈值则拒绝
2. 下发前在目标服务器做备份（`cp -r /etc/nginx /etc/nginx.bak.$(date +%Y%m%d%H%M%S)`）
3. 增加"二次确认"弹窗，展示将要变更的文件 diff

---

### 1.4 缺少 CSRF 防护 — 中危 🟡

**位置：** 第 5 章安全设计

文档提到了 XSS 防护，但完全没有提 CSRF。

"下发"、"Reload"、"删除主机"等操作均为状态变更操作，若无 CSRF Token，攻击者可构造恶意页面诱导已登录的运维人员触发这些操作。

Flask 推荐使用 `Flask-WTF` 的 CSRF 保护，或在 API 层统一校验 `X-CSRF-Token` 请求头。

---

### 1.5 缺少 HTTPS 强制 — 中危 🟡

**位置：** 第 7 章部署方案

整个部署方案没有提及 TLS/SSL。运维人员的登录凭证、SSH 密码（即使加密存储，传输时也是明文）都会在网络上裸奔。

**最低要求：** 在 Nginx 反向代理层配置 HTTPS，并强制 HTTP → HTTPS 跳转。

---

### 1.6 SSH 执行权限过大 — 中危 🟡

**位置：** `3.3 配置校验与重载`

执行 `nginx -t` 和 `nginx -s reload` 需要 root 或 nginx 用户权限。文档没有说明 SSH 用户的权限设计。

**风险：** 若 SSH 用户是 root，一旦管理系统被攻破，攻击者直接获得所有服务器的 root 权限。

**正确做法：** 使用专用低权限用户 + sudoers 精确授权：
```
# /etc/sudoers.d/nginx-manager
nginx-mgr ALL=(root) NOPASSWD: /usr/sbin/nginx -t
nginx-mgr ALL=(root) NOPASSWD: /usr/sbin/nginx -s reload
```

---

### 1.7 路径遍历风险 — 中危 🟡

**位置：** `3.1.3 数据存储`，`nginx_config.file_path`

`file_path VARCHAR(512)` 存储相对路径，若前端传入 `../../etc/passwd` 类路径，后端未做校验，可能读取或覆盖系统文件。

必须在服务层对所有文件路径做规范化处理并验证其在允许目录内：
```python
import os
base_dir = "/data/nginx-configs/"
full_path = os.path.realpath(os.path.join(base_dir, file_path))
if not full_path.startswith(base_dir):
    raise ValueError("路径遍历攻击")
```

---

### 1.8 登录接口无防暴力破解 — 中危 🟡

文档安全章节未提及：
- 登录失败次数限制
- 账号锁定机制
- 验证码
- IP 封禁

对于管理 100 台服务器的系统，这是必须项。

---

## 二、功能性评审

### 2.1 版本控制功能缺失 — 严重缺陷 🔴

**位置：** `1.3 核心功能` 提到"版本控制"，但数据库设计中完全没有实现。

`nginx_config` 表只有 `last_modify_time`，没有：
- 历史版本存储
- 版本号/commit hash
- 变更内容 diff
- 回滚操作

这是配置管理系统的核心功能，缺失后系统价值大打折扣。

**建议增加：**
```sql
CREATE TABLE nginx_config_versions (
  id INT PRIMARY KEY AUTO_INCREMENT,
  config_id INT NOT NULL,
  version INT NOT NULL,
  content TEXT NOT NULL,          -- 配置文件内容快照
  diff TEXT,                      -- 与上一版本的 diff
  created_by VARCHAR(50) NOT NULL,
  created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
  comment VARCHAR(512),
  INDEX idx_config_version (config_id, version)
);
```

---

### 2.2 并发编辑冲突 — 严重缺陷 🔴

两个运维人员同时编辑同一个配置文件，后保存的人会覆盖前者的修改，且没有任何提示。

需要实现乐观锁：
- 编辑时记录文件的 `last_modify_time`
- 保存时校验 `last_modify_time` 是否变化
- 若已被他人修改，提示冲突并展示 diff

---

### 2.3 下发操作缺乏原子性保障 — 严重缺陷 🔴

**场景：** 集群 50 台服务器，下发到第 30 台时网络中断，前 30 台是新配置，后 20 台是旧配置。

文档没有设计：
- 部分失败时的回滚策略
- 集群配置一致性检查
- 灰度发布（先下发 1 台验证，再全量）

---

### 2.4 异步任务设计不完整 — 中等缺陷 🟡

"Celery 可选"对于 100 台服务器的场景是不够的。同步下发 100 台服务器可能需要数分钟，HTTP 请求会超时。

需要明确：
- 任务队列（Celery + Redis/RabbitMQ）是必选还是可选
- 前端如何轮询任务状态
- `tasklog` 表需要增加任务状态字段（pending/running/success/failed）

---

### 2.5 权限粒度过粗 — 中等缺陷 🟡

只有 admin/user 两个角色，无法满足：
- 用户 A 只能管理生产集群，用户 B 只能管理测试集群
- 只读审计角色（只能查看日志，不能编辑）
- 下发权限与编辑权限分离

建议增加基于集群的权限控制表。

---

## 三、数据库设计评审

### 3.1 缺少外键约束

`hosts.cluster_id` 和 `nginx_config.cluster_id` 没有定义 `FOREIGN KEY` 约束，可能产生孤儿记录。

### 3.2 oplog 表设计反范式

```sql
cluster_zh_name VARCHAR(128) NOT NULL,  -- 存的是名称而非 ID
```

若集群改名，历史日志的集群名称将与实际不符。应存 `cluster_id`，查询时 JOIN。

### 3.3 tasklog 表定义缺失

文档 `4.2 表清单` 列出了 `tasklog` 表，但整个文档没有给出建表 SQL，是遗漏。

### 3.4 密码字段长度不足

`password VARCHAR(100)` — bcrypt 哈希固定 60 字符没问题，但若未来切换算法（如 Argon2），输出可能更长。建议统一用 `VARCHAR(255)`。

---

## 四、架构评审

### 4.1 管理服务器是单点故障

整个系统的配置文件存储在管理服务器的 `/data/nginx-configs/`，若该服务器磁盘损坏，所有配置丢失。

**最低要求：** 定期备份到对象存储（OSS/S3）或 Git 仓库。

### 4.2 Flask 生产部署未说明

部署图直接画的是 Flask App，没有提 Gunicorn/uWSGI。Flask 内置服务器不能用于生产。

### 4.3 Python 版本过旧

Python 3.7（EOL 2023-06）、3.8（EOL 2024-10）已停止安全更新。建议目标版本 Python 3.11+。

---

## 五、评审总结

| 类别 | 问题数 | 高危 | 中危 | 低危 |
|------|--------|------|------|------|
| 安全 | 8 | 3 | 5 | 0 |
| 功能 | 5 | 3 | 2 | 0 |
| 数据库 | 4 | 0 | 2 | 2 |
| 架构 | 3 | 1 | 2 | 0 |

**必须在开发前解决的问题（阻断项）：**

1. 命令注入漏洞（`shell=True` + 字符串拼接）
2. SSH 密码存储方案（改为密钥认证）
3. `rsync --delete` 灾难保护机制
4. 版本控制功能的完整设计
5. 下发操作的原子性/回滚设计
6. HTTPS 强制配置

**建议下一步：** 针对以上阻断项修订设计文档，重点补充版本控制数据模型、SSH 密钥管理方案、以及下发任务的状态机设计，再进入开发阶段。
