#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ALIYUN_REGISTRY="crpi-d7tubu0e345ls62u.cn-chengdu.personal.cr.aliyuncs.com"
REGISTRY="${ORTHOVENN_REGISTRY:-dockerhub}"
NAMESPACE="${ORTHOVENN_IMAGE_NAMESPACE:-leeoluo}"
TAG="${ORTHOVENN_IMAGE_TAG:-latest}"
SKIP_PULL=0
SKIP_MIGRATE=0

usage() {
  cat <<EOF
Usage: ./run.sh [options] [docker compose up args...]

Options:
  --tag TAG           Image tag to pull and run. Default: ${TAG}
  --registry VALUE    Image registry: dockerhub, aliyun, or registry host. Default: ${REGISTRY}
  --namespace NAME    Image namespace. Default: ${NAMESPACE}
  --skip-pull         Skip image pull/tag and only run docker compose up
  --skip-migrate      Skip database migration before starting services
  -h, --help          Show this help

Examples:
  ./run.sh
  ./run.sh --tag latest
  ./run.sh --registry dockerhub
  ./run.sh --registry aliyun
  ./run.sh --registry ${ALIYUN_REGISTRY}
  ./run.sh --skip-pull backend celery_worker interactive_worker selection_worker

When using aliyun/custom registry, publish base images as:
  ${NAMESPACE}/postgres:15-alpine      -> postgres:15-alpine
  ${NAMESPACE}/redis:8.6.2             -> redis:8.6.2
  ${NAMESPACE}/tusd:v2                -> tusproject/tusd:v2
  ${NAMESPACE}/nginx:1.27-alpine      -> nginx:1.27-alpine
EOF
}

resolve_registry_host() {
  case "${1}" in
    dockerhub|"")
      echo ""
      ;;
    aliyun)
      echo "${ALIYUN_REGISTRY}"
      ;;
    *)
      echo "${1}"
      ;;
  esac
}

app_image_ref() {
  local registry_host="$1"
  local image="$2"
  if [[ -n "${registry_host}" ]]; then
    echo "${registry_host}/${NAMESPACE}/${image}:${TAG}"
  else
    echo "${NAMESPACE}/${image}:${TAG}"
  fi
}

base_image_ref() {
  local registry_host="$1"
  local remote_repo="$2"
  local image_tag="$3"
  local local_ref="$4"
  if [[ -n "${registry_host}" ]]; then
    echo "${registry_host}/${NAMESPACE}/${remote_repo}:${image_tag}"
  else
    echo "${local_ref}"
  fi
}

pull_and_tag_image() {
  local remote_ref="$1"
  local local_ref="$2"
  docker pull "${remote_ref}"
  if [[ "${remote_ref}" != "${local_ref}" ]]; then
    docker tag "${remote_ref}" "${local_ref}"
  fi
}

read_dotenv_value() {
  local key="$1"
  local line
  [[ -f "${ROOT_DIR}/.env" ]] || return 0
  line="$(grep -E "^${key}=" "${ROOT_DIR}/.env" | tail -n 1 || true)"
  [[ -n "${line}" ]] || return 0
  line="${line#*=}"
  line="${line%\"}"
  line="${line#\"}"
  line="${line%\'}"
  line="${line#\'}"
  echo "${line}"
}

frontend_port() {
  local port="${WEB_PORT:-}"
  if [[ -z "${port}" ]]; then
    port="$(read_dotenv_value WEB_PORT)"
  fi
  port="${port:-5920}"
  echo "${port}"
}

frontend_url() {
  echo "http://localhost:$(frontend_port)"
}

server_ip() {
  local ip=""
  ip="$(hostname -I 2>/dev/null | awk '{print $1}' || true)"
  if [[ -z "${ip}" ]]; then
    ip="$(ip route get 1.1.1.1 2>/dev/null | awk '{for (i = 1; i <= NF; i++) if ($i == "src") { print $(i + 1); exit }}' || true)"
  fi
  if [[ -z "${ip}" ]]; then
    ip="$(ipconfig getifaddr en0 2>/dev/null || true)"
  fi
  if [[ -z "${ip}" ]]; then
    ip="$(ifconfig 2>/dev/null | awk '/inet / && $2 != "127.0.0.1" { print $2; exit }' || true)"
  fi
  echo "${ip:-}"
}

COMPOSE_CMD=()

detect_compose_command() {
  if docker compose version >/dev/null 2>&1; then
    COMPOSE_CMD=(docker compose)
    return
  fi
  if command -v docker-compose >/dev/null 2>&1; then
    COMPOSE_CMD=(docker-compose)
    return
  fi
  echo "Docker Compose is required. Install Docker Compose v2 plugin or docker-compose." >&2
  exit 1
}

docker_compose() {
  ORTHOVENN_IMAGE_TAG="${TAG}" "${COMPOSE_CMD[@]}" "$@"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --tag)
      TAG="${2:?Missing value for --tag}"
      shift 2
      ;;
    --registry)
      REGISTRY="${2:?Missing value for --registry}"
      shift 2
      ;;
    --namespace)
      NAMESPACE="${2:?Missing value for --namespace}"
      shift 2
      ;;
    --skip-pull)
      SKIP_PULL=1
      shift
      ;;
    --skip-migrate)
      SKIP_MIGRATE=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    --)
      shift
      break
      ;;
    *)
      break
      ;;
  esac
done

app_images=(
  "orthovennplus-backend"
  "orthovennplus-worker-biobase"
  "orthovennplus-frontend"
)

base_images=(
  "postgres|15-alpine|postgres:15-alpine"
  "redis|8.6.2|redis:8.6.2"
  "tusd|v2|tusproject/tusd:v2"
  "nginx|1.27-alpine|nginx:1.27-alpine"
)

cd "${ROOT_DIR}"
detect_compose_command
echo "Using Docker Compose command: ${COMPOSE_CMD[*]}"

data_dirs=(
  "data/projects"
  "data/uploads"
  "data/uploads/tus"
  "data/tmp"
  "data/logs"
  "data/postgres"
  "data/refdb"
  "data/builtin_db"
)

for dir in "${data_dirs[@]}"; do
  if [[ -d "${dir}" ]]; then
    continue
  fi
  mkdir -p "${dir}"
done

if [[ "${SKIP_PULL}" -eq 0 ]]; then
  REGISTRY_HOST="$(resolve_registry_host "${REGISTRY}")"
  if [[ -n "${REGISTRY_HOST}" ]]; then
    echo "Pulling images from ${REGISTRY_HOST}/${NAMESPACE}..."
  else
    echo "Pulling images from Docker Hub..."
  fi

  echo "Pulling application images with tag ${TAG}..."
  for image in "${app_images[@]}"; do
    remote_ref="$(app_image_ref "${REGISTRY_HOST}" "${image}")"
    local_ref="${NAMESPACE}/${image}:${TAG}"
    pull_and_tag_image "${remote_ref}" "${local_ref}"
  done

  echo "Pulling base images..."
  for item in "${base_images[@]}"; do
    IFS="|" read -r remote_repo image_tag local_ref <<< "${item}"
    remote_ref="$(base_image_ref "${REGISTRY_HOST}" "${remote_repo}" "${image_tag}" "${local_ref}")"
    pull_and_tag_image "${remote_ref}" "${local_ref}"
  done
fi

if [[ "${SKIP_MIGRATE}" -eq 0 ]]; then
  echo "Starting database dependencies..."
  docker_compose up -d postgres redis

  echo "Running database migrations..."
  docker_compose run --rm backend alembic upgrade head
fi

echo "Starting Docker Compose services..."
docker_compose up -d "$@"

FRONTEND_PORT="$(frontend_port)"
SERVER_IP="$(server_ip)"
echo ""
echo "Web URL:"
echo "  $(frontend_url)"
if [[ -n "${SERVER_IP}" ]]; then
  echo "  http://${SERVER_IP}:${FRONTEND_PORT}"
else
  echo "  http://<server-ip>:${FRONTEND_PORT}"
fi
echo "Done."
