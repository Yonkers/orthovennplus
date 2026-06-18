#!/usr/bin/env bash
set -Eeuo pipefail

REGION="${ORTHOVENN_INSTALL_REGION:-global}"
DEFAULT_INSTALL_DIR="${HOME:-$(pwd)}/orthovennplus"
INSTALL_DIR="${ORTHOVENN_INSTALL_DIR:-${DEFAULT_INSTALL_DIR}}"
TAG="${ORTHOVENN_IMAGE_TAG:-latest}"
YES=0
INSTALL_REFDB=1
START_SERVICES=1
SKIP_PULL=0
WEB_PORT=""
REGISTRY=""

GLOBAL_REPO_URL="${ORTHOVENN_DEPLOY_GLOBAL_REPO:-https://github.com/Yonkers/orthovennplus.git}"
CN_REPO_URL="${ORTHOVENN_DEPLOY_CN_REPO:-https://gitee.com/leeoluo/orthovennplus-docker.git}"

usage() {
  cat <<EOF
Usage: install_bootstrap.sh [options]

Download the OrthoVennPlus deployment package and hand off to tools/install.sh.

Options:
  --region cn|global  Installation region preset. Default: ${REGION}
  --dir DIR           Installation directory. Default: ${INSTALL_DIR}
  --tag TAG           Docker image tag. Default: ${TAG}
  --registry VALUE    Override Docker registry preset
  --web-port PORT     Forward Web UI port to tools/install.sh
  --skip-refdb        Skip reference database installation
  --skip-pull         Skip Docker image pull when starting services
  --no-start          Prepare files only; do not start Docker services
  -y, --yes           Non-interactive mode; accept defaults
  -h, --help          Show this help

Examples:
  curl -fsSL https://example.com/install-cn.sh | bash
  curl -fsSL https://example.com/install.sh | bash
  curl -fsSL https://example.com/install-cn.sh | bash -s -- --dir /data/orthovennplus
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --region)
      REGION="${2:?Missing value for --region}"
      shift 2
      ;;
    --dir)
      INSTALL_DIR="${2:?Missing value for --dir}"
      shift 2
      ;;
    --tag)
      TAG="${2:?Missing value for --tag}"
      shift 2
      ;;
    --registry)
      REGISTRY="${2:?Missing value for --registry}"
      shift 2
      ;;
    --web-port)
      WEB_PORT="${2:?Missing value for --web-port}"
      shift 2
      ;;
    --skip-refdb)
      INSTALL_REFDB=0
      shift
      ;;
    --skip-pull)
      SKIP_PULL=1
      shift
      ;;
    --no-start)
      START_SERVICES=0
      shift
      ;;
    -y|--yes)
      YES=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown option: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

is_interactive() {
  [[ "${YES}" -eq 0 && -t 0 ]]
}

line() {
  printf '%s\n' '──────────────────────────────────────────────────────────────────────'
}

step() {
  local number="$1"
  local total="$2"
  local title="$3"
  printf '\n%s\n' '━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━'
  printf '第 %s 步 / %s：%s\n' "${number}" "${total}" "${title}"
  printf '%s\n' '━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━'
}

info() {
  printf '→ %s\n' "$*"
}

ok() {
  printf '✓ %s\n' "$*"
}

warn() {
  printf '⚠ %s\n' "$*"
}

fail() {
  printf '✗ %s\n' "$*" >&2
  exit 1
}

prompt_default() {
  local prompt="$1"
  local default="$2"
  local value=""
  if is_interactive; then
    read -r -p "${prompt} [${default}]: " value
  fi
  echo "${value:-${default}}"
}

repo_url_for_region() {
  if [[ "${REGION}" == "cn" ]]; then
    echo "${CN_REPO_URL}"
  else
    echo "${GLOBAL_REPO_URL}"
  fi
}

registry_for_region() {
  if [[ -n "${REGISTRY}" ]]; then
    echo "${REGISTRY}"
  elif [[ "${REGION}" == "cn" ]]; then
    echo "aliyun"
  else
    echo "dockerhub"
  fi
}

line
if [[ "${REGION}" == "cn" ]]; then
  echo "  OrthoVennPlus 安装器 · 中国大陆镜像"
else
  echo "  OrthoVennPlus Installer · Global"
fi
line
echo "  这个脚本只负责下载部署包，然后交给部署包内的 tools/install.sh。"
line

step 1 3 "准备部署目录"
command -v git >/dev/null 2>&1 || fail "未找到 git。请先安装 git 后重新运行。"
ok "已找到 git：$(git --version)"
if is_interactive; then
  INSTALL_DIR="$(prompt_default "安装目录" "${INSTALL_DIR}")"
fi
INSTALL_DIR="${INSTALL_DIR%/}"
info "安装目录：${INSTALL_DIR}"

step 2 3 "获取部署包"
REPO_URL="$(repo_url_for_region)"
info "部署包来源：${REPO_URL}"
mkdir -p "${INSTALL_DIR}" || fail "无法创建安装目录：${INSTALL_DIR}。请换一个当前用户可写的目录，或使用 --dir 指定。"
if [[ -z "$(find "${INSTALL_DIR}" -mindepth 1 -maxdepth 1 2>/dev/null)" ]]; then
  git clone "${REPO_URL}" "${INSTALL_DIR}"
elif [[ -d "${INSTALL_DIR}/.git" ]]; then
  info "目录已存在，尝试更新部署包..."
  git -C "${INSTALL_DIR}" pull --ff-only
else
  fail "安装目录已存在且不是空目录或 Git 仓库：${INSTALL_DIR}"
fi
ok "部署包已就绪"

step 3 3 "进入安装流程"
REGISTRY="$(registry_for_region)"
export ORTHOVENN_INSTALL_REGION="${REGION}"
if [[ "${REGION}" == "cn" ]]; then
  export ORTHOVENN_REFDB_SOURCE="${ORTHOVENN_REFDB_SOURCE:-official}"
  export ORTHOVENN_REFDB_FALLBACK_SOURCE="${ORTHOVENN_REFDB_FALLBACK_SOURCE:-gitee,github}"
else
  export ORTHOVENN_REFDB_SOURCE="${ORTHOVENN_REFDB_SOURCE:-official}"
  export ORTHOVENN_REFDB_FALLBACK_SOURCE="${ORTHOVENN_REFDB_FALLBACK_SOURCE:-github,gitee}"
fi
INSTALL_ARGS=(
  --registry "${REGISTRY}"
  --tag "${TAG}"
)
if [[ -n "${WEB_PORT}" ]]; then
  INSTALL_ARGS+=(--web-port "${WEB_PORT}")
fi
if [[ "${YES}" -eq 1 ]]; then
  INSTALL_ARGS+=(--yes)
fi
if [[ "${INSTALL_REFDB}" -eq 0 ]]; then
  INSTALL_ARGS+=(--skip-refdb)
fi
if [[ "${SKIP_PULL}" -eq 1 ]]; then
  INSTALL_ARGS+=(--skip-pull)
fi
if [[ "${START_SERVICES}" -eq 0 ]]; then
  INSTALL_ARGS+=(--no-start)
fi

INSTALL_SCRIPT="${INSTALL_DIR}/tools/install.sh"
if [[ ! -f "${INSTALL_SCRIPT}" ]]; then
  fail "部署包缺少 tools/install.sh。请先运行 tools/sync_deploy_repo.sh 同步并推送部署仓库，然后重新执行安装。"
fi

bash "${INSTALL_SCRIPT}" "${INSTALL_ARGS[@]}"
