---
name: acore-update-db
description: 在本地构建 AzerothCore db-import 镜像，并使用当前 acore-deploy 项目的 .env 和 dbimport.conf 更新远程数据库（测试/生产环境）。
---

# AzerothCore 数据库更新技能

## 适用场景

- AzerothCore 代码仓库有新的 SQL update 需要同步到测试/生产数据库
- 需要初始化或更新 `acore_auth` / `acore_characters` / `acore_world` 三个数据库
- 不想把源码拷贝到生产环境，希望在开发机直接对远程数据库执行导入

## 前置要求

当前工作目录应为 `acore-deploy` 项目根目录。本技能使用相对路径读取 `./.env`、`./configs/dbimport.conf` 和 `./scripts/update-db.sh`。

## 参数

- `dry-run`（可选）：是否只预览不真正执行，默认 `false`
- `env-file`（可选）：环境变量文件路径，默认 `./.env`
- `tag`（可选）：本地镜像标签，默认使用 AzerothCore 源码当前 git short sha
- `acore-dir`（可选）：AzerothCore 源码目录。优先级为 `--acore-dir` 参数 > `.env` 中的 `ACORE_DIR` 变量。**必须在 `.env` 中或命令行指定，脚本不内置任何默认绝对路径。**

## 一键脚本

本技能对应一个可直接运行的脚本：

```bash
./scripts/update-db.sh
```

该脚本会自动根据所在位置定位 `acore-deploy` 项目根目录，并默认从该目录读取 `.env` 和 `configs/dbimport.conf`。

## 执行步骤

### 1. 确认工作目录

确保当前工作目录是 `acore-deploy` 项目根目录。必要时切换：

```bash
cd <acore-deploy-root>
```

### 2. 前置检查

确认以下文件/配置存在：

- `./.env`（包含 `ACORE_DIR`、`AC_LOGIN_DATABASE_INFO`、`AC_WORLD_DATABASE_INFO`、`AC_CHARACTER_DATABASE_INFO`）
- `./configs/dbimport.conf`

如果 `dbimport.conf` 不存在但 `dbimport.conf.dist` 存在，`scripts/update-db.sh` 会自动复制。

### 3. 运行更新脚本

根据参数调用 `./scripts/update-db.sh`：

```bash
# 默认执行
./scripts/update-db.sh

# 预览模式
./scripts/update-db.sh --dry-run

# 指定其他环境文件（如生产环境）
./scripts/update-db.sh --env-file ./.env.prod

# 指定 AzerothCore 源码目录
./scripts/update-db.sh --acore-dir /path/to/azerothcore-wotlk
```

组合示例：

```bash
./scripts/update-db.sh --dry-run --env-file ./.env.prod
```

### 4. 验证结果

检查脚本退出码和日志输出：

- `Applied N queries` — 成功应用了 N 个 SQL 更新
- `database is up-to-date` — 当前数据库已经是最新状态
- `ERROR` / `FATAL` 或退出码非 0 — 向用户报告错误并停止

## 注意事项

- 执行导入前建议先停止目标环境的 `ac-worldserver` 和 `ac-authserver`，避免运行中的服务读到中间状态的数据库。
- 本技能只在本地构建镜像，不会把镜像推送到仓库；数据库连接直接指向远程 MySQL。
- 如果需要更新模块 SQL，构建前请确保 AzerothCore 源码目录下的 `modules/` 已经包含对应模块代码。
- 不要在仓库中提交包含本地绝对路径或敏感信息的 `.env` 文件。
