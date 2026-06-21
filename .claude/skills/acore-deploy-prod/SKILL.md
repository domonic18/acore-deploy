---
name: acore-deploy-prod
description: 从镜像仓库拉取预构建的 AzerothCore server 镜像并部署到生产环境（支持 --dry-run 预览，不修改 .env）。
---

# AzerothCore 生产环境部署技能

## 适用场景

- 生产服务器需要部署 CI/CD 已构建好的 AzerothCore server 镜像
- 本地构建完成后，需要将镜像发布到生产/测试服务器运行
- 快速切换到指定镜像标签（如回滚到旧版本）
- 不想在目标服务器上本地编译，只拉取并运行

## 前置要求

当前工作目录应为 `acore-deploy` 项目根目录。本技能使用相对路径读取 `./.env` 和 `./docker-compose.yml`。

部署前请确保：

- 目标服务器已安装 Docker 和 docker-compose
- 目标服务器可访问镜像仓库（如腾讯云 TCR）
- `.env` 中已配置 `REGISTRY`、`NAMESPACE`、`TAG`
- 数据库已更新到当前镜像所需的版本（建议使用 `acore-update-db` 技能先更新数据库）

## 参数

- `dry-run`（可选）：是否只预览不真正执行，默认 `false`
- `env-file`（可选）：环境变量文件路径，默认 `./.env`
- `tag`（可选）：镜像标签，**默认使用 `.env` 中的 `TAG`**。指定后仅临时覆盖，**不会修改 `.env` 文件**
- `no-pull`（可选）：跳过 `docker pull`，使用本地已有的镜像，默认 `false`
- `no-recreate`（可选）：不强制重建容器，仅做启动/更新，默认 `false`

## 一键脚本

本技能对应一个可直接运行的脚本：

```bash
./scripts/acore-deploy-prod.sh
```

该脚本会自动根据所在位置定位 `acore-deploy` 项目根目录，并默认从 `./.env` 读取 `REGISTRY`、`NAMESPACE`、`TAG`。

## 执行步骤

### 1. 确认工作目录

确保当前工作目录是 `acore-deploy` 项目根目录。必要时切换：

```bash
cd <acore-deploy-root>
```

### 2. 前置检查

确认 `./.env` 中包含以下配置：

- `REGISTRY`：Docker 仓库地址
- `NAMESPACE`：Docker 命名空间
- `TAG`：要部署的镜像标签（如 CI 生成的 `master-4eb3baf`）

### 3. 运行部署脚本

```bash
# 默认：读取 .env 中的 TAG 并部署
./scripts/acore-deploy-prod.sh

# 预览模式
./scripts/acore-deploy-prod.sh --dry-run

# 指定标签（不修改 .env）
./scripts/acore-deploy-prod.sh --tag master-4eb3baf

# 指定其他环境文件（如生产环境专用 .env）
./scripts/acore-deploy-prod.sh --env-file ./.env.prod

# 跳过 pull（使用本地已有镜像）
./scripts/acore-deploy-prod.sh --no-pull

# 不强制重建容器
./scripts/acore-deploy-prod.sh --no-recreate
```

组合示例：

```bash
./scripts/acore-deploy-prod.sh --dry-run --tag develop-4eb3baf --env-file ./.env.prod
```

### 4. 验证结果

脚本执行完毕后会提示查看状态：

```bash
docker-compose ps
docker-compose logs --tail=50 -f ac-worldserver
```

成功标志：

- `docker pull` 成功（或 `--no-pull` 跳过）
- `docker-compose up -d --force-recreate` 成功
- `ac-worldserver` 和 `ac-authserver` 容器状态为 `Up`
- worldserver 日志无 `ERROR` / `FATAL`，并最终显示世界加载完成

## 注意事项

- **本脚本不会修改 `.env` 文件**。`--tag` 仅作为临时覆盖；若需固定新标签，请手动编辑 `.env` 或通过 CI/CD 更新。
- 与 `acore-build-deploy` 的关键区别：`build-deploy` 在本地编译并回写 `.env` 的 `TAG`；`deploy-prod` 只拉取预构建镜像，不编译、不回写。
- 生产环境建议先 `--dry-run` 确认将要拉取的镜像和执行的命令。
- 部署前建议先使用 `acore-update-db` 技能更新数据库，避免 worldserver 因数据库版本不匹配而启动失败。
- 若需要回滚，只需指定旧标签重新部署：`./scripts/acore-deploy-prod.sh --tag <old-tag>`。
- 不要在仓库中提交包含本地绝对路径或敏感信息的 `.env` 文件。
