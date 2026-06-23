# AzerothCore DBC 同步技能

## 适用场景

- 需要把 wow-dbc 仓库中的 DBC 源文件同步到 acore-deploy 的 `data/dbc/`
- wow-dbc 中的 DBC 已更新（新增坐骑、物品、法术、成就等），需要更新到服务器
- 生产环境手动部署 DBC 文件

## 前置要求

当前工作目录应为 `acore-deploy` 项目根目录。

默认 DBC 来源为 `wow-dbc/src/dbc/`（Git submodule）。

## 参数

- `dry-run`（可选）：是否只预览不真正执行，默认 `false`
- `pull`（可选）：是否先更新 wow-dbc submodule 到最新，默认 `false`
- `local-path`（可选）：指定本地 DBC 源目录，替代 submodule

## 一键脚本

```bash
./scripts/acore-update-dbc.sh
```

## 执行步骤

### 1. 确认工作目录

```bash
cd /Users/deadwalk/Workspace/acore-deploy
```

### 2. 确认 wow-dbc submodule 已初始化

如果是首次克隆 acore-deploy，执行：

```bash
git submodule update --init
```

### 3. 同步 DBC

#### 3.1 默认同步（从 submodule）

```bash
./scripts/acore-update-dbc.sh
```

同步后 `data/dbc/` 与 `wow-dbc/src/dbc/` 完全一致，并生成 `configs/dbc-version.json`。

#### 3.2 更新 submodule 后再同步

```bash
./scripts/acore-update-dbc.sh --pull
```

先执行 `git submodule update --remote wow-dbc`，再同步。

#### 3.3 从本地其他路径同步（生产环境）

```bash
./scripts/acore-update-dbc.sh --local-path /opt/wow-dbc/src/dbc
```

#### 3.4 预览模式

```bash
./scripts/acore-update-dbc.sh --dry-run
```

### 4. 提交版本记录（推荐）

`configs/dbc-version.json` 记录了本次同步的 wow-dbc commit、分支和时间。建议提交到 acore-deploy Git：

```bash
git add configs/dbc-version.json wow-dbc
# 如果 submodule commit 发生变化，需要一起提交
```

### 5. 重启 worldserver

DBC 更新后需要重启 worldserver 才能生效：

```bash
docker-compose restart ac-worldserver
```

## 验证结果

- `data/dbc/` 中 DBC 文件数量与 `configs/dbc-version.json` 中的 `file_count` 一致
- `configs/dbc-version.json` 中的 `commit` 与 wow-dbc 当前 commit 一致
- worldserver 启动无 DBC 相关 `ERROR` / `FATAL`

## 注意事项

- `data/dbc/` 是运行时产物，已被 `.gitignore` 排除，不要手动提交。
- `acore-build-deploy.sh` 和 `acore-deploy-prod.sh` **不会自动调用** DBC 同步，需要单独执行。
- 生产环境若无法访问 GitHub，可手动将 wow-dbc 目录上传到服务器，再使用 `--local-path` 同步。
- 软链接方式不可行，因为 Docker 容器内无法解析宿主机的绝对路径软链接。
