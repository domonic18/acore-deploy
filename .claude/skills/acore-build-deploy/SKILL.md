---
name: acore-build-deploy
description: 在本地构建 AzerothCore server 镜像，并部署到当前 acore-deploy 项目（支持 Mac arm64 本地构建）。
---

# AzerothCore 本地编译部署技能

## 适用场景

- 修改了 AzerothCore 核心代码或 `modules/` 下的模块代码
- 修改了部署配置，需要重新打包镜像并部署到本地测试环境
- 希望在开发机完成编译、部署、验证的完整流程

## 前置要求

当前工作目录应为 `acore-deploy` 项目根目录。本技能使用相对路径读取 `./.env`、`./scripts/acore-build-deploy.sh`，并通过 `.env` 中的 `ACORE_DIR` 定位 AzerothCore 源码。

## 参数

- `tag`（可选）：本地镜像标签，默认 `develop-local`
- `deploy`（可选）：是否自动更新 `.env` 并重启容器，默认 `true`
- `platform`（可选）：Docker 构建平台，默认 `linux/arm64`
- `env-file`（可选）：环境变量文件路径，默认 `./.env`
- `acore-dir`（可选）：AzerothCore 源码目录。优先级为 `--acore-dir` 参数 > `.env` 中的 `ACORE_DIR` 变量。**必须在 `.env` 中或命令行指定，不内置任何默认绝对路径。**

## 一键脚本

本技能对应一个可直接运行的脚本：

```bash
./scripts/acore-build-deploy.sh
```

该脚本会自动根据所在位置定位 `acore-deploy` 项目根目录，并默认从 `./.env` 读取 `ACORE_DIR`、`REGISTRY`、`NAMESPACE` 等配置。

## 执行步骤

### 1. 确认工作目录

确保当前工作目录是 `acore-deploy` 项目根目录。必要时切换：

```bash
cd <acore-deploy-root>
```

### 2. 前置检查

确认 `./.env` 中包含以下配置：

- `ACORE_DIR`：AzerothCore 源码目录
- `REGISTRY`：Docker 仓库地址
- `NAMESPACE`：Docker 命名空间

### 3. 运行编译部署脚本

根据参数调用 `./scripts/acore-build-deploy.sh`：

```bash
# 默认：构建 develop-local 镜像并部署
./scripts/acore-build-deploy.sh

# 指定标签
./scripts/acore-build-deploy.sh --tag feature-xyz

# 只构建不部署
./scripts/acore-build-deploy.sh --no-deploy

# 指定其他环境文件
./scripts/acore-build-deploy.sh --env-file ./.env.local

# 指定 AzerothCore 源码目录
./scripts/acore-build-deploy.sh --acore-dir /path/to/azerothcore-wotlk
```

### 4. 验证结果

脚本执行完毕后会提示查看状态：

```bash
docker-compose ps
docker-compose logs --tail=50 -f ac-worldserver
```

成功标志：

- `docker build` 完成且退出码为 0
- `docker-compose up -d --force-recreate` 成功
- `ac-worldserver` 和 `ac-authserver` 容器状态为 `Up`
- worldserver 日志无 `ERROR` / `FATAL`，并最终显示世界加载完成

## 注意事项

- 构建过程会复制当前 AzerothCore 工作区（包括 `modules/`）进容器编译，通常需要 10~30 分钟。
- 若模块有未提交的改动，Docker build 会一并打包进去；但建议先提交/推送模块代码，便于追溯。
- 该技能默认只构建 `server` target（包含 worldserver/authserver/dbimport），不包含 `tools` target。
- 如果只需要构建镜像不部署，可设置 `--no-deploy`。
- 不要在仓库中提交包含本地绝对路径或敏感信息的 `.env` 文件。
