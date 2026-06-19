<p align="center">
  <a href="https://orthovenn.com" target="_blank">
    <img src="assets/orthovennplus-logo.svg" alt="OrthoVennPlus" width="88" />
  </a>
</p>

<h1 align="center">OrthoVennPlus Docker Deployment</h1>

<p align="center">
  Local Docker deployment package for OrthoVennPlus.
</p>

<p align="center">
  <a href="README.md"><strong>English</strong></a>
  ·
  <a href="README.zh-CN.md">中文</a>
  ·
  <a href="https://orthovenn.com" target="_blank">Official Website</a>
  ·
  <a href="https://orthovenn.com/document" target="_blank">User Manual</a>
</p>

---



# OrthoVennPlus Installation

This guide covers the normal installation path for OrthoVennPlus from the deployment package. It focuses on preparing the deployment directory, starting the platform, creating the administrator account, and checking that the workflow service is ready.

## Requirements

Before installation, prepare:

- Docker and Docker Compose
- A Linux, macOS, or server host with enough CPU, memory, and disk space

Recommended minimum for a small test deployment:

| Resource | Recommendation |
| --- | --- |
| CPU | 8 cores |
| Memory | 16 GB |
| Disk | 100 GB free space |

## Quick Start

### Recommended: One-command Installation

For a new server, use the installer script. It downloads the deployment package to `~/orthovennplus` by default, prepares `.env`, installs the reference database, and starts the Docker services.

Global source:

```bash
curl -fsSL https://raw.githubusercontent.com/Yonkers/orthovennplus/main/tools/install_bootstrap.sh | bash -s -- --region global
```

Mainland China source:

```bash
curl -fsSL https://gitee.com/leeoluo/orthovennplus-docker/raw/main/tools/install_bootstrap.sh | bash -s -- --region cn
```

If `--region` is omitted, the installer tests GitHub and Gitee connectivity and chooses a default region automatically.

After installation, open:

```text
http://<server-ip>:5920
```

### Manual Installation

Use the manual steps below when you need to inspect or customize the deployment package before starting services.

#### 1. Get the Deployment Package

Clone or unpack the deployment package on the server. Choose one source:

```bash
# GitHub
git clone https://github.com/Yonkers/orthovennplus.git orthovennplus-docker
cd orthovennplus-docker
```

```bash
# Gitee mirror, recommended for mainland China
git clone https://gitee.com/leeoluo/orthovennplus-docker.git orthovennplus-docker
cd orthovennplus-docker
```

The deployment directory should use this layout:

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
|-- data/                     # created during installation/runtime
|   |-- refdb/                # reference data installed by install_refdb.sh
|   |-- projects/
|   |-- uploads/
|   |-- logs/
|-- README.md
```

The files under `data/refdb` are used by GO annotation and DIAMOND-based annotation. They are distributed as release assets instead of Git-tracked files, so the repository stays small while installation remains reproducible.

If the scripts are not executable after cloning or unpacking a release package, set the executable bit before running any installer or startup script:

```bash
chmod +x run.sh install_refdb.sh install_sonic_pfam_profiles.sh tools/install*.sh
```

#### 2. Review Optional Configuration

The deployment package includes a ready-to-use `.env` file. For a standard single-server deployment, you can keep the defaults and continue.

Optional: edit `.env` if you need to change the web port, storage policy, upload domain, email service, or other deployment details. See [Advanced Configuration](#advanced-configuration).

If `.env` is missing, create it from the example file: `cp .env.example .env` 


#### 3. Install Reference Data

Install the required reference data. The installer chooses the default download source by region: global installations use GitHub first, mainland China installations use Gitee first, and both fall back to the official OrthoVennPlus web source if needed:

```bash
./install_refdb.sh
```

To force GitHub release downloads:

```bash
./install_refdb.sh --source github
```

For servers in mainland China, you can use the Gitee release source:

```bash
./install_refdb.sh --source gitee
```

If the release asset is unavailable and you need to generate the UniProt reference files manually, run:

```bash
python setup_uniprot_refdb.py
```

SonicParanoid2 works in graph-only mode by default. If you plan to use full SonicParanoid2 architecture/domain mode, install the optional Pfam profile database later from [Optional SonicParanoid2 Pfam Profile DB](#optional-sonicparanoid2-pfam-profile-db).

#### 4. Start with run.sh

The recommended startup command is `run.sh`. On most servers, run it with `sudo`. The script creates required data directories, pulls images, runs database migrations, normalizes writable data directory permissions, and starts the Docker Compose services:

Start the services:

```bash
sudo ./run.sh
```

By default, `run.sh` pulls images from Docker Hub. If the server is in mainland China or Docker Hub access is slow, use the Aliyun mirror registry:

```bash
sudo ./run.sh --registry aliyun
```

Check the available options:

```bash
./run.sh --help
```

#### 5. Open the Website

After the services start, open:

```text
http://<server-ip>:5920
```

Check service status when needed:

```bash
sudo docker compose ps
```

#### Manual Docker Compose Startup

Use this only when you do not want to use `run.sh`:

```bash
mkdir -p data/projects data/uploads data/uploads/tus data/tmp data/logs data/refdb data/builtin_db data/postgres
mkdir -p data/refdb/sonicparanoid2
docker compose up -d postgres redis
docker compose run --rm backend alembic upgrade head
docker compose up -d
```

## Advanced Configuration

Most deployments can keep the default `.env` file. Edit it only when you need to adapt ports, credentials, upload behavior, resource usage, cleanup policy, or email service.

Common settings:

| Setting | Purpose |
| --- | --- |
| `WEB_PORT` | Browser access port for the web UI. |
| `API_PORT`, `NGINX_PORT`, `POSTGRES_PORT`, `REDIS_PORT` | Host ports exposed by backend services. Change them only when ports conflict. |
| `POSTGRES_PASSWORD`, `SECRET_KEY` | Security-sensitive values. Use strong values for public or long-running deployments. |
| `CELERY_CONCURRENCY`, `INTERACTIVE_WORKER_CONCURRENCY`, `SELECTION_WORKER_CONCURRENCY` | Worker concurrency. Increase only when the server has enough CPU and memory. |
| `MODULE_DEFAULT_THREADS` | Default CPU threads used by analysis modules. |
| `UPLOAD_MAX_FILE_SIZE`, `PUBLIC_TUS_ENDPOINT`, `TUSD_CORS_ALLOW_ORIGIN` | Upload size and TUS upload endpoint/CORS behavior. |
| `PROJECT_SPECIES_LIMIT`, `PROJECT_VERSION_LIMIT` | Project and version limits. |
| `PROJECT_RETENTION_DAYS`, `PROJECT_CLEANUP_STALE_ACTIVE_HOURS` | Project retention and stale-task cleanup policy. |
| `MAIL_ENABLED`, `MAIL_SMTP_*` | Optional email verification and password reset service. |
| `ORTHOVENN_IMAGE_TAG` | Docker image version used by `run.sh`. |

If you change `.env` after services are already running, restart the stack:

```bash
sudo ./run.sh --skip-pull --skip-migrate
```

## Administrator Account

You need one administrator account to manage users, settings, workers, project cleanup, and gallery projects.

By default, the first registered user becomes the administrator:

```dotenv
FIRST_REGISTERED_USER_AS_ADMIN=true
```

You can also create an administrator with the backend CLI:

```bash
docker compose exec backend \
  env ORTHOVENN_ADMIN_PASSWORD='your-strong-password' \
  python -m app.cli create-admin \
  --username admin \
  --email admin@example.com
```

To promote an existing user:

```bash
docker compose exec backend \
  env ORTHOVENN_ADMIN_PASSWORD='your-strong-password' \
  python -m app.cli create-admin \
  --username existing-user \
  --email existing@example.com \
  --promote-existing
```

## Optional SonicParanoid2 Pfam Profile DB

SonicParanoid2 uses `graph-only` mode by default and does not need the Pfam profile database. Install the Pfam MMseqs profile database only if you plan to disable graph-only mode and run the full architecture/domain workflow.

Check the current status from the deployment directory:

```bash
./install_sonic_pfam_profiles.sh status
```

The script only uses these paths:

```text
data/refdb/sonicparanoid2/downloads/
data/refdb/sonicparanoid2/pfam_profile_db/
```

The recommended path is manual download first, then local install.

Manual download address:

```text
https://drive.google.com/file/d/1eV3t2FINOUPJI1132w3bmBrHnO3_bpfJ/view?usp=sharing
```

Save the archive as:

```text
data/refdb/sonicparanoid2/downloads/sonicparanoid2_pfam_mmseqs_profile_db.tar.gz
```

Then verify and install:

```bash
mkdir -p data/refdb/sonicparanoid2/downloads
tar -tzf data/refdb/sonicparanoid2/downloads/sonicparanoid2_pfam_mmseqs_profile_db.tar.gz >/dev/null
./install_sonic_pfam_profiles.sh install
```

If the archive was downloaded to another location:

```bash
./install_sonic_pfam_profiles.sh install /path/to/sonicparanoid2_pfam_mmseqs_profile_db.tar.gz
```

If the server can access Google Drive directly, you can try downloading with curl:

```bash
mkdir -p data/refdb/sonicparanoid2/downloads
curl -L \
  'https://drive.google.com/uc?id=1eV3t2FINOUPJI1132w3bmBrHnO3_bpfJ' \
  -o data/refdb/sonicparanoid2/downloads/sonicparanoid2_pfam_mmseqs_profile_db.tar.gz
./install_sonic_pfam_profiles.sh install
```

If graph-only mode is disabled but the profile database is missing, the SonicParanoid2 task will stop early and report the missing profile database path.
