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

installer_lang() {
  case "${REGION}" in
    cn)
      echo "zh"
      ;;
    global)
      echo "en"
      ;;
    *)
      case "${LANG:-}" in
        zh*|ZH*) echo "zh" ;;
        *) echo "en" ;;
      esac
      ;;
  esac
}

text() {
  local zh="$1"
  local en="$2"
  if [[ "$(installer_lang)" == "zh" ]]; then
    printf '%s' "${zh}"
  else
    printf '%s' "${en}"
  fi
}

line() {
  printf '%s\n' '──────────────────────────────────────────────────────────────────────'
}

step() {
  local number="$1"
  local total="$2"
  local title
  title="$(text "$3" "${4:-$3}")"
  printf '\n%s\n' '━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━'
  if [[ "$(installer_lang)" == "zh" ]]; then
    printf '第 %s 步 / %s：%s\n' "${number}" "${total}" "${title}"
  else
    printf 'Step %s / %s: %s\n' "${number}" "${total}" "${title}"
  fi
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
    info "$(text "需要 sudo 权限来启动 Docker 服务。请输入当前用户的 sudo 密码；不是 root 密码。" "sudo permission is required to start Docker services. Enter the current user's sudo password; this is not the root password.")"
    sudo -v || fail "$(text "sudo 验证失败。请确认当前用户有 sudo 权限，或改用 root 用户执行。" "sudo validation failed. Make sure the current user has sudo permission, or run as root.")"
    return 0
  fi
  fail "$(text "需要 sudo 权限，但当前是非交互模式，无法输入密码。请先执行 sudo -v，或使用 root 用户运行脚本。" "sudo permission is required, but this is non-interactive mode and no password can be entered. Run sudo -v first, or run the script as root.")"
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
  info "$(text "未指定 region，正在检测 GitHub/Gitee 连接..." "No region specified; testing GitHub/Gitee connectivity...")"
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
    warn "$(text "GitHub/Gitee 连接检测都失败，默认使用 cn 策略。" "GitHub/Gitee connectivity checks both failed; using cn strategy by default.")"
    REGION="cn"
  fi

  if [[ "${REGION}" == "global" ]]; then
    ok "$(text "自动选择 region：global" "Auto-selected region: global")"
  else
    ok "$(text "自动选择 region：cn" "Auto-selected region: cn")"
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
echo "  $(text "OrthoVennPlus 安装器" "OrthoVennPlus Installer")"
line
echo "  $(text "部署目录：${ROOT_DIR}" "Deployment directory: ${ROOT_DIR}")"
echo "  $(text "安装目标：准备配置、参考数据库、Docker 服务" "Install target: configuration, reference database, and Docker services")"
line

cd "${ROOT_DIR}"

step 1 7 "识别系统环境" "Detect system environment"
OS_NAME="$(uname -s | tr '[:upper:]' '[:lower:]')"
ARCH_NAME="$(uname -m)"
ok "$(text "系统：${OS_NAME} (${ARCH_NAME})" "System: ${OS_NAME} (${ARCH_NAME})")"
if command -v df >/dev/null 2>&1; then
  info "$(text "当前目录磁盘空间：$(df -h "${ROOT_DIR}" | awk 'NR == 2 { print $4 " available" }')" "Disk space for current directory: $(df -h "${ROOT_DIR}" | awk 'NR == 2 { print $4 " available" }')")"
fi
detect_region

step 2 7 "检查 Docker 环境" "Check Docker environment"
command -v docker >/dev/null 2>&1 || fail "$(text "未找到 docker。请先安装 Docker 后重新运行。" "docker was not found. Install Docker and rerun.")"
ok "$(text "已找到 Docker：$(docker --version)" "Found Docker: $(docker --version)")"
compose_available || fail "$(text "未找到 Docker Compose。请安装 Docker Compose v2 plugin 或 docker-compose。" "Docker Compose was not found. Install Docker Compose v2 plugin or docker-compose.")"
ok "$(text "Docker Compose 可用" "Docker Compose is available")"
ensure_sudo

step 3 7 "确认安装计划" "Confirm installation plan"
REGISTRY="$(resolve_registry "${REGISTRY}")"
if is_interactive; then
  REGISTRY="$(prompt_default "$(text "请选择镜像源（aliyun/dockerhub/registry host）" "Image registry (aliyun/dockerhub/registry host)")" "${REGISTRY}")"
  WEB_PORT="$(prompt_default "$(text "Web 访问端口" "Web port")" "${WEB_PORT:-$(read_env_value WEB_PORT || true)}")"
  if confirm_default_yes "$(text "是否安装参考数据库" "Install reference database")"; then
    INSTALL_REFDB=1
  else
    INSTALL_REFDB=0
  fi
fi
WEB_PORT="${WEB_PORT:-$(read_env_value WEB_PORT || true)}"
WEB_PORT="${WEB_PORT:-5920}"
echo "$(text "将执行以下操作：" "The installer will:")"
echo "  1. $(text "准备 .env 配置文件，并生成默认密码/密钥" "Prepare .env and generate default password/secret values")"
echo "  2. $(text "设置 Web 端口：${WEB_PORT}" "Set Web port: ${WEB_PORT}")"
echo "  3. $(text "使用镜像源：${REGISTRY}" "Use image registry: ${REGISTRY}")"
echo "  4. $(text "Docker 镜像版本：${TAG}" "Docker image tag: ${TAG}")"
if [[ "${INSTALL_REFDB}" -eq 1 ]]; then
  echo "  5. $(text "安装参考数据库" "Install reference database")"
else
  echo "  5. $(text "跳过参考数据库安装" "Skip reference database installation")"
fi
if [[ "${START_SERVICES}" -eq 1 ]]; then
  echo "  6. $(text "启动 Docker Compose 服务" "Start Docker Compose services")"
  if [[ "${SKIP_PULL}" -eq 1 ]]; then
    echo "     - $(text "跳过镜像拉取" "Skip image pulling")"
  fi
else
  echo "  6. $(text "不启动服务" "Do not start services")"
fi
if is_interactive; then
  confirm_default_yes "$(text "确认继续安装" "Continue installation")" || fail "$(text "用户取消安装" "Installation cancelled by user")"
fi

step 4 7 "准备环境配置" "Prepare environment configuration"
if [[ ! -f "${ROOT_DIR}/.env" ]]; then
  [[ -f "${ROOT_DIR}/.env.example" ]] || fail "$(text "未找到 .env 或 .env.example" ".env or .env.example was not found")"
  cp "${ROOT_DIR}/.env.example" "${ROOT_DIR}/.env"
  ok "$(text "已从 .env.example 创建 .env" "Created .env from .env.example")"
else
  ok "$(text ".env 已存在，将保留并补全必要默认值" ".env already exists; it will be preserved and required defaults will be filled")"
fi
set_env_value WEB_PORT "${WEB_PORT}"
set_env_value ORTHOVENN_IMAGE_TAG "${TAG}"
POSTGRES_PASSWORD="$(read_env_value POSTGRES_PASSWORD || true)"
if is_placeholder_secret "${POSTGRES_PASSWORD}"; then
  set_env_value POSTGRES_PASSWORD "$(random_hex 16)"
  ok "$(text "已生成 POSTGRES_PASSWORD" "Generated POSTGRES_PASSWORD")"
fi
SECRET_KEY="$(read_env_value SECRET_KEY || true)"
if is_placeholder_secret "${SECRET_KEY}"; then
  set_env_value SECRET_KEY "$(random_hex 32)"
  ok "$(text "已生成 SECRET_KEY" "Generated SECRET_KEY")"
fi

step 5 7 "准备脚本权限" "Prepare script permissions"
chmod +x "${ROOT_DIR}/run.sh" 2>/dev/null || true
chmod +x "$(refdb_script)" 2>/dev/null || true
if [[ -f "${ROOT_DIR}/install_sonic_pfam_profiles.sh" ]]; then
  chmod +x "${ROOT_DIR}/install_sonic_pfam_profiles.sh" 2>/dev/null || true
fi
ok "$(text "脚本权限已检查" "Script permissions checked")"

step 6 7 "安装参考数据库" "Install reference database"
if [[ "${INSTALL_REFDB}" -eq 1 ]]; then
  configure_refdb_defaults
  REFDB_SCRIPT="$(refdb_script)"
  [[ -f "${REFDB_SCRIPT}" ]] || fail "$(text "未找到参考数据库安装脚本：${REFDB_SCRIPT}" "Reference database installer was not found: ${REFDB_SCRIPT}")"
  bash "${REFDB_SCRIPT}"
  ok "$(text "参考数据库安装流程完成" "Reference database installation flow completed")"
else
  warn "$(text "已跳过参考数据库安装" "Reference database installation skipped")"
fi

step 7 7 "启动服务并检查结果" "Start services and check result"
if [[ "${START_SERVICES}" -eq 1 ]]; then
  RUN_SCRIPT="$(run_script)"
  [[ -f "${RUN_SCRIPT}" ]] || fail "$(text "未找到 run.sh" "run.sh was not found")"
  RUN_ARGS=(--registry "${REGISTRY}" --tag "${TAG}")
  if [[ "${SKIP_PULL}" -eq 1 ]]; then
    RUN_ARGS+=(--skip-pull)
  fi
  sudo_cmd "${RUN_SCRIPT}" "${RUN_ARGS[@]}"
  ok "$(text "服务启动命令已完成" "Service startup command completed")"
else
  warn "$(text "已按参数跳过服务启动" "Service startup skipped by option")"
fi

line
echo "  $(text "安装流程结束" "Installation finished")"
line
echo "$(text "如需重新启动：" "To restart:")"
echo "  sudo ./run.sh --skip-pull --skip-migrate"
echo "$(text "如需查看服务：" "To view services:")"
echo "  sudo docker compose ps"
