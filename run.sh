#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REGISTRY="${ORTHOVENN_REGISTRY:-crpi-d7tubu0e345ls62u.cn-chengdu.personal.cr.aliyuncs.com}"
NAMESPACE="${ORTHOVENN_IMAGE_NAMESPACE:-leeoluo}"
TAG="${ORTHOVENN_IMAGE_TAG:-latest}"
SKIP_PULL=0
SKIP_MIGRATE=0

usage() {
  cat <<EOF
Usage: ./run.sh [options] [docker compose up args...]

Options:
  --tag TAG           Image tag to pull and run. Default: ${TAG}
  --registry HOST     Remote registry. Default: ${REGISTRY}
  --namespace NAME    Image namespace. Default: ${NAMESPACE}
  --skip-pull         Skip image pull/tag and only run docker compose up
  --skip-migrate      Skip database migration before starting services
  -h, --help          Show this help

Examples:
  ./run.sh
  ./run.sh --tag 2026-06-02
  ./run.sh --skip-pull backend celery_worker interactive_worker selection_worker
EOF
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

images=(
  "orthovennplus-backend"
  "orthovennplus-backend-flower"
  "orthovennplus-worker-biobase"
  "orthovennplus-frontend"
)

cd "${ROOT_DIR}"

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
  echo "Pulling images from ${REGISTRY}/${NAMESPACE} with tag ${TAG}..."
  for image in "${images[@]}"; do
    docker pull "${REGISTRY}/${NAMESPACE}/${image}:${TAG}"
  done

  echo "Tagging images locally..."
  for image in "${images[@]}"; do
    docker tag "${REGISTRY}/${NAMESPACE}/${image}:${TAG}" "${NAMESPACE}/${image}:${TAG}"
  done
fi

if [[ "${SKIP_MIGRATE}" -eq 0 ]]; then
  echo "Starting database dependencies..."
  ORTHOVENN_IMAGE_TAG="${TAG}" docker compose up -d postgres redis

  echo "Running database migrations..."
  ORTHOVENN_IMAGE_TAG="${TAG}" docker compose run --rm backend alembic upgrade head
fi

echo "Starting Docker Compose services..."
ORTHOVENN_IMAGE_TAG="${TAG}" docker compose up -d "$@"

echo "Done."
