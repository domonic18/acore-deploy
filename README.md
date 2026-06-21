# AzerothCore 部署仓库

本仓库用于快速部署 AzerothCore（魔兽世界 3.3.5a 版本）的认证服务器（authserver）和世界服务器（worldserver），支持通过 Docker Compose 在测试环境或小型生产环境（约 10 人规模）中运行。

## 主要功能

- 使用 Docker Compose 统一部署 `ac-authserver` 和 `ac-worldserver`
- 配置与数据分离：数据库连接、Webhook、密钥等敏感信息通过 `.env` 注入
- 支持远程 SOAP 管理端口（7878）
- 模块配置集中管理（反作弊、飞书聊天转发、幻化等）

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
├── scripts/                  # 部署与数据库更新脚本
│   ├── acore-build-deploy.sh # 本地构建 server 镜像并部署
│   ├── acore-deploy-prod.sh  # 拉取预构建镜像并部署到生产环境
│   └── acore-update-db.sh    # 更新远程数据库
├── lua_scripts/              # 自定义 Lua 脚本
└── logs/                     # 运行日志（不提交到仓库）
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
