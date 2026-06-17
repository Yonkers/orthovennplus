---
title: OrthoVennPlus Installation
description: Install OrthoVennPlus with run.sh or Docker Compose, create the first administrator account, and verify the deployment.
navigation:
  title: Installation
  order: 1
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

### 1. Get the Deployment Package

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
|-- data/
|   |-- refdb/
|   |   |-- go-basic.obo
|   |   |-- go_terms.tsv
|   |   |-- uniprot_sprot_annotation.dmnd
|   |   |-- uniprot_sprot_annotation.tsv
|   |   |-- sonicparanoid2/     # optional
|-- run.sh
|-- docker-compose.yaml
|-- .env.example
|-- install_refdb.sh
|-- install_sonic_pfam_profiles.sh
|-- setup_uniprot_refdb.py
|-- README.md
```

The files under `data/refdb` are used by GO annotation and DIAMOND-based annotation. They are distributed as release assets instead of Git-tracked files, so the repository stays small while installation remains reproducible.

If the scripts are not executable after cloning or unpacking a release package, set the executable bit before running any installer or startup script:

```bash
chmod +x run.sh install_refdb.sh install_sonic_pfam_profiles.sh
```

### 2. Create the Environment File

The deployment package includes `.env.example`. Copy it to `.env`:

```bash
cp .env.example .env
```

Then replace passwords, and the secret key. Review these key startup settings:

```dotenv
ORTHOVENN_IMAGE_TAG=latest

API_PORT=18008
# Web port opened by users in the browser.
NGINX_PORT=18088
POSTGRES_PORT=15435
REDIS_PORT=16379

POSTGRES_USER=orthovennplus
# Replace with a strong database password.
POSTGRES_PASSWORD=change-this-postgres-password
POSTGRES_DB=orthovennplus

# Required for login tokens. Use a long random value.
SECRET_KEY=change-this-secret-key
ACCESS_TOKEN_EXPIRE_MINUTES=4320
FIRST_REGISTERED_USER_AS_ADMIN=true

CELERY_CONCURRENCY=3
INTERACTIVE_WORKER_CONCURRENCY=2
SELECTION_WORKER_CONCURRENCY=1
# Default CPU threads used by analysis modules.
MODULE_DEFAULT_THREADS=16
MODULE_THREAD_EDITABLE=true

UPLOAD_MAX_FILE_SIZE=10737418240
# 0 means no species count limit.
PROJECT_SPECIES_LIMIT=20
```

### 3. Install Reference Data

Install the required reference data. By default, the installer downloads from the official OrthoVennPlus web source and falls back to GitHub or Gitee if the official source is unavailable:

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

### 4. Start with run.sh

The recommended startup command is `run.sh`. It creates required data directories, pulls images, runs database migrations, and starts the Docker Compose services:

Start the services:

```bash
./run.sh
```

By default, `run.sh` pulls images from Docker Hub. If the server is in mainland China or Docker Hub access is slow, use the Aliyun mirror registry:

```bash
./run.sh --registry aliyun
```

Check the available options:

```bash
./run.sh --help
```

### 5. Open the Website

After the services start, open:

```text
http://<server-ip>:5920
```

Check service status when needed:

```bash
docker compose ps
```

### Manual Docker Compose Startup

Use this only when you do not want to use `run.sh`:

```bash
mkdir -p data/projects data/uploads data/uploads/tus data/tmp data/logs data/refdb data/builtin_db data/postgres
mkdir -p data/refdb/sonicparanoid2
docker compose up -d postgres redis
docker compose run --rm backend alembic upgrade head
docker compose up -d
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
