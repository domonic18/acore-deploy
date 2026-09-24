# AzerothCore 部署仓库

本仓库用于快速部署 AzerothCore（魔兽世界 3.3.5a 版本）的认证服务器（authserver）和世界服务器（worldserver），支持通过 Docker Compose 在测试环境或小型生产环境（约 10 人规模）中运行。

## 主要功能

- 使用 Docker Compose 统一部署 `ac-authserver` 和 `ac-worldserver`
- 配置与数据分离：数据库连接、Webhook、密钥等敏感信息通过 `.env` 注入
- 支持远程 SOAP 管理端口（7878）
- 模块配置集中管理（反作弊、飞书聊天转发、幻化等）
- 日志外发：每日归档前一日日志上传 COS，供 acore-manager AI 巡检分析

## 目录结构

```text
.
├── .env.example              # 环境变量模板（敏感信息占位符）
├── .gitignore                # 排除日志、数据、密钥等文件
├── README.md                 # 本说明文件
├── docker-compose.yml        # 部署用 compose（拉取远程镜像）
├── docker-compose.local.yml  # 本地构建用 compose（使用本地镜像）
├── configs/                  # 服务端与模块配置文件
│   ├── authserver.conf
│   ├── worldserver.conf
│   └── modules/              # 各模块配置
├── scripts/                  # 部署、运维与日志外发脚本
│   ├── acore-build-deploy.sh        # 本地构建 server 镜像并部署
│   ├── acore-deploy-prod.sh         # 拉取预构建镜像并部署到生产环境
│   ├── acore-update-db.sh           # 更新远程数据库
│   ├── acore-update-dbc.sh          # 从 acore-resouces 同步 DBC 到 data/dbc/
│   ├── ac-worldserver-watchdog.sh   # worldserver 看门狗（cron，执行 healthcheck 判决）
│   ├── soap-probe.sh                # SOAP 应用级健康探针（docker healthcheck 调用）
│   └── acore-upload-logs.sh         # 日志外发：归档前一日日志并上传 COS（cron）
├── lua_scripts/              # 自定义 Lua 脚本
└── logs/                     # 运行日志与上传结果（不提交到仓库）
    └── upload-result-*.json  # acore-upload-logs.sh 每日执行结果
```

## 快速开始

### 1. 克隆仓库

```bash
git clone https://github.com/domonic18/acore-deploy.git
cd acore-deploy
```

### 2. 准备环境变量

```bash
cp .env.example .env
# 编辑 .env，填入实际的数据库连接、镜像标签、模块密钥等
```

### 3. 启动服务

```bash
docker-compose --env-file .env up -d
```

服务启动后：

- 认证服务器：`0.0.0.0:3724`
- 世界服务器：`0.0.0.0:8086`
- SOAP 管理接口：`0.0.0.0:7878`

### 4. 本地构建镜像时使用

```bash
docker-compose -f docker-compose.local.yml --env-file .env up -d
```

## 敏感信息管理

- **不要将 `.env` 提交到仓库**，它已在 `.gitignore` 中排除。
- 模块中的敏感字段（如 `FeishuChat.WebhookUrl`、`FeishuChat.Secret`）在配置文件中保持为空，实际值通过 `.env` 的环境变量注入。
- 仓库已配置 Husky pre-commit hook，提交前会自动扫描敏感信息；如果命中规则，commit 将被阻止。

## 脚本工具

项目根目录下的 `scripts/` 目录封装了常用的部署和数据库更新脚本。

### 生产环境部署（拉取预构建镜像）

`scripts/acore-deploy-prod.sh` 用于从镜像仓库拉取已构建好的 server 镜像并部署，适合 CI/CD 发布流程。

```bash
# 使用 .env 中的 TAG 部署
./scripts/acore-deploy-prod.sh

# 预览将要执行的命令
./scripts/acore-deploy-prod.sh --dry-run

# 临时指定镜像标签（不修改 .env）
./scripts/acore-deploy-prod.sh --tag master-4eb3baf

# 指定其他环境文件
./scripts/acore-deploy-prod.sh --env-file ./.env.prod
```

### 本地构建并部署

`scripts/acore-build-deploy.sh` 用于在本地编译 AzerothCore 源码并部署，适合开发调试。

```bash
# 构建 develop-local 镜像并部署
./scripts/acore-build-deploy.sh

# 只构建不部署
./scripts/acore-build-deploy.sh --no-deploy

# 指定标签
./scripts/acore-build-deploy.sh --tag feature-xyz
```

### 数据库更新

`scripts/acore-update-db.sh` 用于将 AzerothCore 的 SQL updates 同步到远程数据库。

```bash
# 自动应用所有 pending updates
./scripts/acore-update-db.sh

# 预览模式
./scripts/acore-update-db.sh --dry-run

# 单独导入指定 SQL 文件
./scripts/acore-update-db.sh --sql-file /path/to/file.sql --database acore_characters
```

### DBC 同步

`acore-deploy` 本身**不维护**原始 DBC 文件。原始 DBC 文件的唯一真相源已迁移到 [`acore-resouces`](https://github.com/domonic18/acore-resouces) 项目的 `data/wow-dbc` 子模块中。

`scripts/acore-update-dbc.sh` 用于将 `acore-resouces/data/wow-dbc/src/dbc/` 同步到本仓库的 `data/dbc/`。

```bash
# 默认从 acore-resouces 的相对路径 ../acore-resouces/data/wow-dbc/src/dbc 同步
./scripts/acore-update-dbc.sh

# 指定 acore-resouces 的绝对路径
./scripts/acore-update-dbc.sh --local-path /path/to/acore-resouces/data/wow-dbc/src/dbc

# 预览模式
./scripts/acore-update-dbc.sh --dry-run

# 生产环境手动放置 wow-dbc 后，指定本地路径同步
./scripts/acore-update-dbc.sh --local-path /opt/wow-dbc/src/dbc
```

也可以通过 `.env` 中的 `WOW_DBC` 环境变量指定源目录：

```bash
WOW_DBC=/path/to/acore-resouces/data/wow-dbc/src/dbc
```

同步后会生成 `configs/dbc-version.json`，记录当前使用的 wow-dbc commit 和同步时间，建议提交到仓库。

### worldserver 存活检测与看门狗

worldserver 的 healthcheck 采用 **SOAP 应用级探针**（`scripts/soap-probe.sh`，容器内执行）：通过 SOAP 向本机发送只读命令 `server info`，AC 会把命令排队到世界线程执行、应答等待执行完成才返回，因此拿到 200 应答即代表世界线程真实存活。凭证复用 `.env` 的 `AC_SOAP_HEALTHCHECK_AUTH`（现有 SOAP 账号，gmlevel>=3，与 acore-manager 共用，改密需同步两处）。

`scripts/ac-worldserver-watchdog.sh`（宿主机 cron 每分钟）职责唯一：执行 Docker healthcheck 的判决——只有进程存活但世界线程卡死（unhealthy）才 `docker compose restart`。进程退出类故障（崩溃、每日 04:00 定时关服）由 `restart: unless-stopped` 原生拉起，看门狗不插手；也没有「容器不存在则拉起」分支，因此**停服检修只需 `docker compose stop`，无需额外处理**。

## 日志外发（COS 上传）

生产日志每日自动归档上传腾讯云 COS，供 acore-manager 的 AI 巡检 Job 拉取分析。

### 背景：Appender 配置变更

`configs/worldserver.conf` 与 `configs/authserver.conf` 的 Appender 模式由 `w`（每次重启清空）改为 `a`（追加），并使用 flags 39（含时间戳/级别/来源 + 0x20 USE_DATE）。USE_DATE 使日志进程内零点自动按日滚动为 `<name>_YYYY-MM-DD.log`（如 `Server_2026-09-25.log`），解决两个问题：

- 重启不丢日志（M1 验收项）
- 产生按日文件供上传脚本确定性取用，无需 copytruncate 轮转

注意：改为追加后文件按日累积——本地只保留 1 周（脚本在上传全部成功后自动清理更早的按日文件，防止上传失败期间误删；`logs/upload-result-*.json` 结果文件同样按 1 周保留），COS 侧靠生命周期过期清理。回滚配置用 `configs/*.conf.bak-20260924` 备份。

### 上传管线

```text
宿主机 cron 04:30
  └─ scripts/acore-upload-logs.sh        归档前一日（CST）四类日志
       ├─ worldserver: Server/Errors/gm 按日文件（logs/ 目录）
       ├─ authserver:  Auth 按日文件
       ├─ anticheat:   anticheat 按日文件
       ├─ crash:       docker logs ac-worldserver 按当日时间窗导出
       ├─ 每类打包 <type>.tar.gz + manifest.json（md5/size/行数）
       └─ coscli 上传 COS: acore-logs/realm3/{date}/   失败重试 3 次
SCF 巡检 Job（acore-manager 侧）每日 06:00 拉取 → 解析 → AI 分析 → 飞书日报
```

- 幂等：COS 上当日 `manifest.json` 已存在则整批跳过，`--force` 强制重传
- manifest 缺失或四类不全时，消费端会发飞书断传告警
- 执行结果落 `logs/upload-result-<date>.json`，退出码 0 成功 / 1 有失败

```bash
./scripts/acore-upload-logs.sh                        # 归档昨日并上传
./scripts/acore-upload-logs.sh --date=2026-09-24      # 补传指定日期
./scripts/acore-upload-logs.sh --date=2026-09-24 --force   # 覆盖重传
./scripts/acore-upload-logs.sh --dry-run              # 只打包不上传，工作目录保留供检查
```

crontab 样例：

```cron
# 日志外发（每日 04:30，避开 05:00 既有任务）
30 4 * * * /workspace/acore-deploy/scripts/acore-upload-logs.sh >> /workspace/acore-deploy/logs/upload-cron.log 2>&1
```

### 相关配置

`.env` 新增（非密钥项；coscli 凭证在宿主机 `~/.cos.yaml`，不入仓库）：

```bash
COS_UPLOAD_BUCKET=your-bucket-1250000000   # 桶全称（含 APPID 后缀）
COS_UPLOAD_REALM=realm3                    # COS key 中的 realm 段
```

coscli 首次部署需在宿主机安装并执行 `coscli config init` 写入凭证（子账号仅需对 `acore-logs/realm3/*` 的 Put/Head/Get 权限）。

## 常用操作

```bash
# 查看日志
docker-compose logs -f ac-worldserver

# 重启世界服务器
docker-compose restart ac-worldserver

# 停止所有服务
docker-compose down
```

## 注意事项

- 首次部署前请确保目标服务器已安装 Docker 和 Docker Compose。
- 数据库需提前创建好 `acore_auth`、`acore_world`、`acore_characters` 三个库。
- 如需通过公网访问，请开放对应的安全组端口（3724、8086、7878）。
