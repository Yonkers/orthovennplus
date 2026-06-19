<p align="center">
  <a href="https://orthovenn.com" target="_blank">
    <img src="assets/orthovennplus-logo.svg" alt="OrthoVennPlus" width="88" />
  </a>
</p>

<h1 align="center">OrthoVennPlus Docker 本地部署</h1>

<p align="center">
  OrthoVennPlus 本地 Docker 部署包。
</p>

<p align="center">
  <a href="README.md">English</a>
  ·
  <a href="README.zh-CN.md"><strong>中文</strong></a>
  ·
  <a href="https://orthovenn.com" target="_blank">官方网站</a>
  ·
  <a href="https://orthovenn.com/document?lang=cn" target="_blank">用户手册</a>
</p>

---



# OrthoVennPlus 安装指南

本指南适用于使用部署包安装 OrthoVennPlus 的常规场景。内容包括准备部署目录、配置环境变量、安装参考数据库、启动服务、创建管理员账号，以及可选的 SonicParanoid2 Pfam 数据库安装。

## 环境要求

安装前请准备：

- Docker 和 Docker Compose
- Linux、macOS 或服务器主机
- 足够的 CPU、内存和磁盘空间

小规模测试部署建议配置：

| 资源 | 建议配置 |
| --- | --- |
| CPU | 8 核 |
| 内存 | 16 GB |
| 磁盘 | 100 GB 可用空间 |

## 快速开始

### 推荐：一键安装

新服务器推荐使用一键安装脚本。脚本默认会将部署包安装到 `~/orthovennplus`，准备 `.env`，安装参考数据库，并启动 Docker 服务。

海外或 GitHub 访问正常的服务器：

```bash
curl -fsSL https://raw.githubusercontent.com/Yonkers/orthovennplus/main/tools/install_bootstrap.sh | bash -s -- --region global
```

中国大陆服务器：

```bash
curl -fsSL https://gitee.com/leeoluo/orthovennplus-docker/raw/main/tools/install_bootstrap.sh | bash -s -- --region cn
```

如果不传 `--region`，安装脚本会检测 GitHub 和 Gitee 的连接情况，并自动选择默认区域。

安装完成后，在浏览器中打开：

```text
http://<server-ip>:5920
```

### 手动安装

如果你需要先检查或自定义部署包内容，再启动服务，可以使用下面的手动安装步骤。

#### 1. 获取部署包

在服务器上克隆或解压部署包。可以选择 GitHub 或 Gitee：

```bash
# GitHub
git clone https://github.com/Yonkers/orthovennplus.git orthovennplus-docker
cd orthovennplus-docker
```

```bash
# Gitee 镜像，推荐中国大陆服务器使用
git clone https://gitee.com/leeoluo/orthovennplus-docker.git orthovennplus-docker
cd orthovennplus-docker
```

部署目录结构应类似如下：

```text
orthovennplus-docker/
|-- run.sh
|-- docker-compose.yaml
|-- .env
|-- .env.example
|-- install_refdb.sh
|-- install_sonic_pfam_profiles.sh
|-- setup_uniprot_refdb.py
|-- docker/
|   |-- nginx/
|   |   |-- default.conf
|   |   |-- frontend.conf.template
|-- tools/
|   |-- install.sh
|   |-- install_bootstrap.sh
|-- data/                     # 安装或运行时创建
|   |-- refdb/                # install_refdb.sh 安装的参考数据库
|   |-- projects/
|   |-- uploads/
|   |-- logs/
|-- README.md
```

`data/refdb` 中的文件用于 GO 注释和基于 DIAMOND 的功能注释。这些参考数据通过 release 资源分发，不直接提交到 Git 仓库，以减少仓库体积并保证安装过程可复现。

如果克隆或解压后脚本没有执行权限，请在运行任何安装或启动脚本前执行：

```bash
chmod +x run.sh install_refdb.sh install_sonic_pfam_profiles.sh tools/install*.sh
```

#### 2. 检查可选配置

部署包中已经包含可直接使用的 `.env` 文件。标准单服务器部署通常可以保留默认配置，继续下一步。

如果需要调整 Web 端口、存储策略、上传域名、邮件服务或其他部署细节，再编辑 `.env`。详细说明见 [高级配置](#高级配置)。

如果 `.env` 文件不存在，可以从示例文件生成： `cp .env.example .env` 

#### 3. 安装参考数据库

安装必要的参考数据库。安装脚本会根据区域选择默认下载源：global 安装优先使用 GitHub，中国大陆安装优先使用 Gitee；如果默认源不可用，都会回退到 OrthoVennPlus 官方源：

```bash
./install_refdb.sh
```

如果需要强制使用 GitHub release：

```bash
./install_refdb.sh --source github
```

中国大陆服务器可以直接使用 Gitee release 源：

```bash
./install_refdb.sh --source gitee
```

如果 release 资源不可用，并且你需要手动生成 UniProt 参考文件，可以运行：

```bash
python setup_uniprot_refdb.py
```

SonicParanoid2 默认使用 graph-only 模式，此模式不需要 Pfam profile 数据库。如果计划启用完整的结构域/架构分析模式，请稍后参考 [可选：SonicParanoid2 Pfam Profile 数据库](#可选sonicparanoid2-pfam-profile-数据库)。

#### 4. 使用 run.sh 启动

推荐使用 `run.sh` 启动。服务器上通常使用 `sudo` 执行。脚本会创建必要的数据目录、拉取镜像、执行数据库迁移、整理可写数据目录权限，并启动 Docker Compose 服务：

```bash
sudo ./run.sh
```

默认情况下，`run.sh` 会从 Docker Hub 拉取镜像。如果服务器在中国大陆，或者 Docker Hub 访问较慢，可以使用阿里云镜像仓库：

```bash
sudo ./run.sh --registry aliyun
```

查看可用参数：

```bash
./run.sh --help
```

#### 5. 打开网站

服务启动后，在浏览器中打开：

```text
http://<server-ip>:5920
```

需要检查服务状态时，可以运行：

```bash
sudo docker compose ps
```

#### 手动使用 Docker Compose 启动

仅当你不想使用 `run.sh` 时，再使用以下方式手动启动：

```bash
mkdir -p data/projects data/uploads data/uploads/tus data/tmp data/logs data/refdb data/builtin_db data/postgres
mkdir -p data/refdb/sonicparanoid2
docker compose up -d postgres redis
docker compose run --rm backend alembic upgrade head
docker compose up -d
```

## 高级配置

大多数部署可以直接使用默认 `.env` 文件。只有在需要调整端口、密码密钥、上传行为、资源使用、清理策略或邮件服务时，才需要编辑它。

常用配置说明：

| 配置项 | 作用 |
| --- | --- |
| `WEB_PORT` | 用户在浏览器中访问 Web 界面的端口。 |
| `API_PORT`、`NGINX_PORT`、`POSTGRES_PORT`、`REDIS_PORT` | 后端服务映射到宿主机的端口。仅在端口冲突时修改。 |
| `POSTGRES_PASSWORD`、`SECRET_KEY` | 安全敏感配置。公开部署或长期运行时应使用强密码和随机密钥。 |
| `CELERY_CONCURRENCY`、`INTERACTIVE_WORKER_CONCURRENCY`、`SELECTION_WORKER_CONCURRENCY` | Worker 并发数。只有服务器 CPU 和内存充足时才建议调大。 |
| `MODULE_DEFAULT_THREADS` | 分析模块默认使用的 CPU 线程数。 |
| `UPLOAD_MAX_FILE_SIZE`、`PUBLIC_TUS_ENDPOINT`、`TUSD_CORS_ALLOW_ORIGIN` | 上传大小、TUS 上传入口和跨域规则。 |
| `PROJECT_SPECIES_LIMIT`、`PROJECT_VERSION_LIMIT` | 项目物种数和版本数限制。 |
| `PROJECT_RETENTION_DAYS`、`PROJECT_CLEANUP_STALE_ACTIVE_HOURS` | 项目保留时间和异常任务清理策略。 |
| `MAIL_ENABLED`、`MAIL_SMTP_*` | 可选的邮箱验证和找回密码服务。 |
| `ORTHOVENN_IMAGE_TAG` | `run.sh` 使用的 Docker 镜像版本。 |

如果服务已经启动，修改 `.env` 后需要重启：

```bash
sudo ./run.sh --skip-pull --skip-migrate
```

## 管理员账号

系统需要一个管理员账号，用于管理用户、系统设置、任务 worker、项目清理和 gallery 项目。

默认情况下，第一个注册的用户会自动成为管理员：

```dotenv
FIRST_REGISTERED_USER_AS_ADMIN=true
```

你也可以使用后端 CLI 创建管理员账号：

```bash
docker compose exec backend \
  env ORTHOVENN_ADMIN_PASSWORD='your-strong-password' \
  python -m app.cli create-admin \
  --username admin \
  --email admin@example.com
```

如果需要将已有用户提升为管理员：

```bash
docker compose exec backend \
  env ORTHOVENN_ADMIN_PASSWORD='your-strong-password' \
  python -m app.cli create-admin \
  --username existing-user \
  --email existing@example.com \
  --promote-existing
```

## 可选：SonicParanoid2 Pfam Profile 数据库

SonicParanoid2 默认使用 `graph-only` 模式，不需要 Pfam profile 数据库。只有在你计划关闭 graph-only 模式，并启用完整的结构域/架构分析流程时，才需要安装 Pfam MMseqs profile 数据库。

在部署目录中检查当前状态：

```bash
./install_sonic_pfam_profiles.sh status
```

该脚本只会使用以下路径：

```text
data/refdb/sonicparanoid2/downloads/
data/refdb/sonicparanoid2/pfam_profile_db/
```

推荐先手动下载，再从本地安装。

手动下载地址：

```text
https://drive.google.com/file/d/1eV3t2FINOUPJI1132w3bmBrHnO3_bpfJ/view?usp=sharing
```

请将压缩包保存为：

```text
data/refdb/sonicparanoid2/downloads/sonicparanoid2_pfam_mmseqs_profile_db.tar.gz
```

然后校验并安装：

```bash
mkdir -p data/refdb/sonicparanoid2/downloads
tar -tzf data/refdb/sonicparanoid2/downloads/sonicparanoid2_pfam_mmseqs_profile_db.tar.gz >/dev/null
./install_sonic_pfam_profiles.sh install
```

如果压缩包下载到了其他位置：

```bash
./install_sonic_pfam_profiles.sh install /path/to/sonicparanoid2_pfam_mmseqs_profile_db.tar.gz
```

如果服务器可以直接访问 Google Drive，也可以尝试使用 curl 下载：

```bash
mkdir -p data/refdb/sonicparanoid2/downloads
curl -L \
  'https://drive.google.com/uc?id=1eV3t2FINOUPJI1132w3bmBrHnO3_bpfJ' \
  -o data/refdb/sonicparanoid2/downloads/sonicparanoid2_pfam_mmseqs_profile_db.tar.gz
./install_sonic_pfam_profiles.sh install
```

如果关闭 graph-only 模式但 Pfam profile 数据库缺失，SonicParanoid2 任务会提前停止，并提示缺失的数据库路径。
