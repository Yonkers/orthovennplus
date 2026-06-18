#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
YES=0
REGISTRY="auto"
REGION="${ORTHOVENN_INSTALL_REGION:-auto}"
TAG="${ORTHOVENN_IMAGE_TAG:-latest}"
INSTALL_REFDB=1
START_SERVICES=1
SKIP_PULL=0
WEB_PORT=""
GLOBAL_PROBE_URL="${ORTHOVENN_GLOBAL_PROBE_URL:-https://raw.githubusercontent.com/Yonkers/orthovennplus/main/.env.example}"
CN_PROBE_URL="${ORTHOVENN_CN_PROBE_URL:-https://gitee.com/leeoluo/orthovennplus-docker/raw/main/.env.example}"

usage() {
  cat <<EOF
Usage: tools/install.sh [options]

Install OrthoVennPlus from an already downloaded deployment package.

Options:
  --registry VALUE    Image registry: auto, dockerhub, aliyun, or registry host. Default: ${REGISTRY}
  --tag TAG           Docker image tag. Default: ${TAG}
  --web-port PORT     Web UI port. Default: value from .env or 5920
  --skip-refdb        Skip reference database installation
  --skip-pull         Skip Docker image pull when starting services
  --no-start          Prepare files only; do not start Docker services
  -y, --yes           Non-interactive mode; accept defaults
  -h, --help          Show this help
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --registry)
      REGISTRY="${2:?Missing value for --registry}"
      shift 2
      ;;
    --tag)
      TAG="${2:?Missing value for --tag}"
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
  [[ "${YES}" -eq 0 && -r /dev/tty && -w /dev/tty ]]
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
    read -r -p "${prompt} [${default}]: " value </dev/tty
  fi
  echo "${value:-${default}}"
}

confirm_default_yes() {
  local prompt="$1"
  local value=""
  if ! is_interactive; then
    return 0
  fi
  read -r -p "${prompt} [Y/n]: " value </dev/tty
  [[ -z "${value}" || "${value}" =~ ^[Yy]$ ]]
}

sudo_cmd() {
  if [[ "${EUID}" -eq 0 ]]; then
    "$@"
  else
    sudo "$@"
  fi
}

ensure_sudo() {
  if [[ "${EUID}" -eq 0 ]]; then
    return 0
  fi
  if sudo -n true 2>/dev/null; then
    return 0
  fi
  if is_interactive; then
    info "需要 sudo 权限来启动 Docker 服务。请输入当前用户的 sudo 密码；不是 root 密码。"
    sudo -v || fail "sudo 验证失败。请确认当前用户有 sudo 权限，或改用 root 用户执行。"
    return 0
  fi
  fail "需要 sudo 权限，但当前是非交互模式，无法输入密码。请先执行 sudo -v，或使用 root 用户运行脚本。"
}

compose_available() {
  docker compose version >/dev/null 2>&1 || command -v docker-compose >/dev/null 2>&1
}

read_env_value() {
  local key="$1"
  local file="${ROOT_DIR}/.env"
  local line
  [[ -f "${file}" ]] || return 0
  line="$(grep -E "^${key}=" "${file}" | tail -n 1 || true)"
  [[ -n "${line}" ]] || return 0
  line="${line#*=}"
  line="${line%\"}"
  line="${line#\"}"
  line="${line%\'}"
  line="${line#\'}"
  echo "${line}"
}

set_env_value() {
  local key="$1"
  local value="$2"
  local file="${ROOT_DIR}/.env"
  if grep -qE "^${key}=" "${file}"; then
    sed -i.bak "s|^${key}=.*|${key}=${value}|" "${file}"
    rm -f "${file}.bak"
  else
    printf '%s=%s\n' "${key}" "${value}" >> "${file}"
  fi
}

random_hex() {
  local bytes="$1"
  if command -v openssl >/dev/null 2>&1; then
    openssl rand -hex "${bytes}"
  else
    LC_ALL=C tr -dc 'a-f0-9' < /dev/urandom | head -c $((bytes * 2))
    echo
  fi
}

is_placeholder_secret() {
  local value="$1"
  [[ -z "${value}" || "${value}" == change-* || "${value}" == *change* || "${value}" == replace-* ]]
}

resolve_registry() {
  local value="$1"
  if [[ "${value}" != "auto" ]]; then
    echo "${value}"
    return
  fi
  if [[ "${REGION}" == "global" ]]; then
    echo "dockerhub"
    return
  fi
  echo "aliyun"
}

probe_url() {
  local url="$1"
  local output
  command -v curl >/dev/null 2>&1 || return 1
  output="$(curl -fL \
    --max-time 6 \
    --connect-timeout 3 \
    -o /dev/null \
    -w '%{time_total}' \
    "${url}" 2>/dev/null)" || return 1
  [[ -n "${output}" ]] || return 1
  echo "${output}"
}

detect_region() {
  [[ "${REGION}" == "auto" ]] || return 0

  local global_time=""
  local cn_time=""
  info "未指定 region，正在检测 GitHub/Gitee 连接..."
  global_time="$(probe_url "${GLOBAL_PROBE_URL}" || true)"
  cn_time="$(probe_url "${CN_PROBE_URL}" || true)"

  if [[ -n "${global_time}" && -n "${cn_time}" ]]; then
    if awk "BEGIN { exit !(${global_time} <= ${cn_time}) }"; then
      REGION="global"
    else
      REGION="cn"
    fi
  elif [[ -n "${global_time}" ]]; then
    REGION="global"
  elif [[ -n "${cn_time}" ]]; then
    REGION="cn"
  else
    warn "GitHub/Gitee 连接检测都失败，默认使用 cn 策略。"
    REGION="cn"
  fi

  if [[ "${REGION}" == "global" ]]; then
    ok "自动选择 region：global"
  else
    ok "自动选择 region：cn"
  fi
  export ORTHOVENN_INSTALL_REGION="${REGION}"
}

configure_refdb_defaults() {
  if [[ "${REGION}" == "cn" ]]; then
    export ORTHOVENN_REFDB_SOURCE="${ORTHOVENN_REFDB_SOURCE:-gitee}"
    export ORTHOVENN_REFDB_FALLBACK_SOURCE="${ORTHOVENN_REFDB_FALLBACK_SOURCE:-official}"
  else
    export ORTHOVENN_REFDB_SOURCE="${ORTHOVENN_REFDB_SOURCE:-github}"
    export ORTHOVENN_REFDB_FALLBACK_SOURCE="${ORTHOVENN_REFDB_FALLBACK_SOURCE:-official}"
  fi
}

refdb_script() {
  if [[ -x "${ROOT_DIR}/install_refdb.sh" || -f "${ROOT_DIR}/install_refdb.sh" ]]; then
    echo "${ROOT_DIR}/install_refdb.sh"
  else
    echo "${ROOT_DIR}/tools/install_refdb.sh"
  fi
}

run_script() {
  echo "${ROOT_DIR}/run.sh"
}

line
echo "  OrthoVennPlus 安装器"
line
echo "  部署目录：${ROOT_DIR}"
echo "  安装目标：准备配置、参考数据库、Docker 服务"
line

cd "${ROOT_DIR}"

step 1 7 "识别系统环境"
OS_NAME="$(uname -s | tr '[:upper:]' '[:lower:]')"
ARCH_NAME="$(uname -m)"
ok "系统：${OS_NAME} (${ARCH_NAME})"
if command -v df >/dev/null 2>&1; then
  info "当前目录磁盘空间：$(df -h "${ROOT_DIR}" | awk 'NR == 2 { print $4 " available" }')"
fi
detect_region

step 2 7 "检查 Docker 环境"
command -v docker >/dev/null 2>&1 || fail "未找到 docker。请先安装 Docker 后重新运行。"
ok "已找到 Docker：$(docker --version)"
compose_available || fail "未找到 Docker Compose。请安装 Docker Compose v2 plugin 或 docker-compose。"
ok "Docker Compose 可用"
ensure_sudo

step 3 7 "确认安装计划"
REGISTRY="$(resolve_registry "${REGISTRY}")"
if is_interactive; then
  REGISTRY="$(prompt_default "请选择镜像源（aliyun/dockerhub/registry host）" "${REGISTRY}")"
  WEB_PORT="$(prompt_default "Web 访问端口" "${WEB_PORT:-$(read_env_value WEB_PORT || true)}")"
  if confirm_default_yes "是否安装参考数据库"; then
    INSTALL_REFDB=1
  else
    INSTALL_REFDB=0
  fi
fi
WEB_PORT="${WEB_PORT:-$(read_env_value WEB_PORT || true)}"
WEB_PORT="${WEB_PORT:-5920}"
echo "将执行以下操作："
echo "  1. 准备 .env 配置文件，并生成默认密码/密钥"
echo "  2. 设置 Web 端口：${WEB_PORT}"
echo "  3. 使用镜像源：${REGISTRY}"
echo "  4. Docker 镜像版本：${TAG}"
if [[ "${INSTALL_REFDB}" -eq 1 ]]; then
  echo "  5. 安装参考数据库"
else
  echo "  5. 跳过参考数据库安装"
fi
if [[ "${START_SERVICES}" -eq 1 ]]; then
  echo "  6. 启动 Docker Compose 服务"
  if [[ "${SKIP_PULL}" -eq 1 ]]; then
    echo "     - 跳过镜像拉取"
  fi
else
  echo "  6. 不启动服务"
fi
if is_interactive; then
  confirm_default_yes "确认继续安装" || fail "用户取消安装"
fi

step 4 7 "准备环境配置"
if [[ ! -f "${ROOT_DIR}/.env" ]]; then
  [[ -f "${ROOT_DIR}/.env.example" ]] || fail "未找到 .env 或 .env.example"
  cp "${ROOT_DIR}/.env.example" "${ROOT_DIR}/.env"
  ok "已从 .env.example 创建 .env"
else
  ok ".env 已存在，将保留并补全必要默认值"
fi
set_env_value WEB_PORT "${WEB_PORT}"
set_env_value ORTHOVENN_IMAGE_TAG "${TAG}"
POSTGRES_PASSWORD="$(read_env_value POSTGRES_PASSWORD || true)"
if is_placeholder_secret "${POSTGRES_PASSWORD}"; then
  set_env_value POSTGRES_PASSWORD "$(random_hex 16)"
  ok "已生成 POSTGRES_PASSWORD"
fi
SECRET_KEY="$(read_env_value SECRET_KEY || true)"
if is_placeholder_secret "${SECRET_KEY}"; then
  set_env_value SECRET_KEY "$(random_hex 32)"
  ok "已生成 SECRET_KEY"
fi

step 5 7 "准备脚本权限"
chmod +x "${ROOT_DIR}/run.sh" 2>/dev/null || true
chmod +x "$(refdb_script)" 2>/dev/null || true
if [[ -f "${ROOT_DIR}/install_sonic_pfam_profiles.sh" ]]; then
  chmod +x "${ROOT_DIR}/install_sonic_pfam_profiles.sh" 2>/dev/null || true
fi
ok "脚本权限已检查"

step 6 7 "安装参考数据库"
if [[ "${INSTALL_REFDB}" -eq 1 ]]; then
  configure_refdb_defaults
  REFDB_SCRIPT="$(refdb_script)"
  [[ -f "${REFDB_SCRIPT}" ]] || fail "未找到参考数据库安装脚本：${REFDB_SCRIPT}"
  bash "${REFDB_SCRIPT}"
  ok "参考数据库安装流程完成"
else
  warn "已跳过参考数据库安装"
fi

step 7 7 "启动服务并检查结果"
if [[ "${START_SERVICES}" -eq 1 ]]; then
  RUN_SCRIPT="$(run_script)"
  [[ -f "${RUN_SCRIPT}" ]] || fail "未找到 run.sh"
  RUN_ARGS=(--registry "${REGISTRY}" --tag "${TAG}")
  if [[ "${SKIP_PULL}" -eq 1 ]]; then
    RUN_ARGS+=(--skip-pull)
  fi
  sudo_cmd "${RUN_SCRIPT}" "${RUN_ARGS[@]}"
  ok "服务启动命令已完成"
else
  warn "已按参数跳过服务启动"
fi

line
echo "  安装流程结束"
line
echo "如需重新启动："
echo "  sudo ./run.sh --skip-pull --skip-migrate"
echo "如需查看服务："
echo "  sudo docker compose ps"
