#!/usr/bin/env bash
set -Eeuo pipefail

REGION="${ORTHOVENN_INSTALL_REGION:-auto}"
DEFAULT_INSTALL_DIR="${HOME:-$(pwd)}/orthovennplus"
INSTALL_DIR="${ORTHOVENN_INSTALL_DIR:-${DEFAULT_INSTALL_DIR}}"
TAG="${ORTHOVENN_IMAGE_TAG:-latest}"
YES=0
INSTALL_REFDB=1
START_SERVICES=1
SKIP_PULL=0
SKIP_DEPLOY_PULL=0
WEB_PORT=""
REGISTRY=""

GLOBAL_REPO_URL="${ORTHOVENN_DEPLOY_GLOBAL_REPO:-https://github.com/Yonkers/orthovennplus.git}"
CN_REPO_URL="${ORTHOVENN_DEPLOY_CN_REPO:-https://gitee.com/leeoluo/orthovennplus-docker.git}"
GLOBAL_RELEASE_ARCHIVE_URL="${ORTHOVENN_DEPLOY_GLOBAL_RELEASE_ARCHIVE_URL:-https://github.com/Yonkers/orthovennplus/archive/refs/heads/main.zip}"
CN_RELEASE_ARCHIVE_URL="${ORTHOVENN_DEPLOY_CN_RELEASE_ARCHIVE_URL:-https://gitee.com/leeoluo/orthovennplus-docker/releases/download/latest/orthovennplus-docker.zip}"
CN_SOURCE_ARCHIVE_URL="${ORTHOVENN_DEPLOY_CN_SOURCE_ARCHIVE_URL:-https://gitee.com/leeoluo/orthovennplus-docker/repository/archive/main.zip}"
GLOBAL_PROBE_URL="${ORTHOVENN_GLOBAL_PROBE_URL:-https://raw.githubusercontent.com/Yonkers/orthovennplus/main/.env.example}"
CN_PROBE_URL="${ORTHOVENN_CN_PROBE_URL:-https://gitee.com/leeoluo/orthovennplus-docker/raw/main/.env.example}"

usage() {
  cat <<EOF
Usage: install_bootstrap.sh [options]

Download the OrthoVennPlus deployment package and hand off to tools/install.sh.

Options:
  --region cn|global|auto
                       Installation region preset. Default: ${REGION}
  --dir DIR           Installation directory. Default: ${INSTALL_DIR}
  --tag TAG           Docker image tag. Default: ${TAG}
  --registry VALUE    Override Docker registry preset
  --web-port PORT     Forward Web UI port to tools/install.sh
  --skip-refdb        Skip reference database installation
  --skip-pull         Skip Docker image pull when starting services
  --skip-deploy-pull  Skip git pull when the deployment directory already exists
  --no-start          Prepare files only; do not start Docker services
  -y, --yes           Non-interactive mode; accept defaults
  -h, --help          Show this help

Examples:
  curl -fsSL https://gitee.com/leeoluo/orthovennplus-docker/raw/main/tools/install_bootstrap.sh | bash -s -- --region cn
  curl -fsSL https://raw.githubusercontent.com/Yonkers/orthovennplus/main/tools/install_bootstrap.sh | bash -s -- --region global
  curl -fsSL https://gitee.com/leeoluo/orthovennplus-docker/raw/main/tools/install_bootstrap.sh | bash -s -- --region cn --dir /data/orthovennplus
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --region)
      REGION="${2:?Missing value for --region}"
      case "${REGION}" in
        cn|global|auto) ;;
        *)
          echo "Invalid --region: ${REGION}. Use cn, global, or auto." >&2
          exit 2
          ;;
      esac
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
    --skip-deploy-pull)
      SKIP_DEPLOY_PULL=1
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

repo_url_for_region() {
  if [[ "${REGION}" == "cn" ]]; then
    echo "${CN_REPO_URL}"
  else
    echo "${GLOBAL_REPO_URL}"
  fi
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
}

archive_urls_for_region() {
  if [[ "${REGION}" == "cn" ]]; then
    printf '%s\n' "${CN_RELEASE_ARCHIVE_URL}" "${CN_SOURCE_ARCHIVE_URL}"
  else
    printf '%s\n' "${GLOBAL_RELEASE_ARCHIVE_URL}"
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

download_file() {
  local url="$1"
  local output="$2"
  if command -v curl >/dev/null 2>&1; then
    curl -fL --retry 3 --connect-timeout 15 -o "${output}" "${url}"
  elif command -v wget >/dev/null 2>&1; then
    wget -O "${output}" "${url}"
  else
    fail "$(text "未找到 curl 或 wget，无法下载部署包压缩包。请先安装其中一个工具。" "curl or wget was not found, so the deployment archive cannot be downloaded. Install one of them and rerun.")"
  fi
}

extract_archive() {
  local archive="$1"
  local dest="$2"
  case "${archive}" in
    *.zip)
      if command -v unzip >/dev/null 2>&1; then
        unzip -q "${archive}" -d "${dest}"
      elif command -v python3 >/dev/null 2>&1; then
        python3 -m zipfile -e "${archive}" "${dest}"
      else
        fail "$(text "未找到 unzip 或 python3，无法解压 zip 部署包。" "unzip or python3 was not found, so the zip deployment package cannot be extracted.")"
      fi
      ;;
    *.tar.gz|*.tgz)
      tar -xzf "${archive}" -C "${dest}"
      ;;
    *)
      fail "$(text "不支持的部署包格式：${archive}" "Unsupported deployment archive format: ${archive}")"
      ;;
  esac
}

clear_install_dir() {
  find "${INSTALL_DIR}" -mindepth 1 -maxdepth 1 -exec rm -rf {} +
}

download_deploy_archive() {
  local tmp_dir
  local archive_path
  local extract_dir
  local install_script
  local package_dir
  tmp_dir="$(mktemp -d)"
  archive_path="${tmp_dir}/orthovennplus-deploy.zip"
  extract_dir="${tmp_dir}/extract"
  mkdir -p "${extract_dir}"

  while IFS= read -r archive_url; do
    [[ -n "${archive_url}" ]] || continue
    info "$(text "尝试下载部署包压缩包：${archive_url}" "Trying deployment archive: ${archive_url}")"
    if download_file "${archive_url}" "${archive_path}"; then
      extract_archive "${archive_path}" "${extract_dir}"
      install_script="$(find "${extract_dir}" -type f -path '*/tools/install.sh' -print -quit)"
      if [[ -n "${install_script}" ]]; then
        package_dir="${install_script%/tools/install.sh}"
        clear_install_dir
        cp -R "${package_dir}/." "${INSTALL_DIR}/"
        ok "$(text "已从压缩包准备部署包" "Deployment package prepared from archive")"
        rm -rf "${tmp_dir}"
        return 0
      fi
      warn "$(text "压缩包中未找到 tools/install.sh，继续尝试下一个来源。" "tools/install.sh was not found in the archive; trying the next source.")"
      rm -rf "${extract_dir}"
      mkdir -p "${extract_dir}"
    else
      warn "$(text "压缩包下载失败，继续尝试下一个来源。" "Archive download failed; trying the next source.")"
    fi
  done < <(archive_urls_for_region)

  rm -rf "${tmp_dir}"
  fail "$(text "无法通过 Git 或压缩包获取部署包。请检查网络，或手动下载 Gitee Release 压缩包后解压安装。" "Could not get the deployment package via Git or archive. Check the network, or download and extract the release archive manually.")"
}

line
case "${REGION}" in
  cn)
    echo "  OrthoVennPlus 安装器 · 中国大陆镜像"
    ;;
  global)
    echo "  OrthoVennPlus Installer · Global"
    ;;
  *)
    echo "  $(text "OrthoVennPlus 安装器 · 自动选择区域" "OrthoVennPlus Installer · Auto region")"
    ;;
esac
line
echo "  $(text "这个脚本只负责下载部署包，然后交给部署包内的 tools/install.sh。" "This script only downloads the deployment package, then hands off to tools/install.sh inside it.")"
line

step 1 3 "准备部署目录" "Prepare deployment directory"
if command -v git >/dev/null 2>&1; then
  ok "$(text "已找到 git：$(git --version)" "Found git: $(git --version)")"
else
  warn "$(text "未找到 git，将在获取部署包时尝试使用压缩包下载。" "git was not found; archive download will be used when getting the deployment package.")"
fi
detect_region
if is_interactive; then
  INSTALL_DIR="$(prompt_default "$(text "安装目录" "Install directory")" "${INSTALL_DIR}")"
fi
INSTALL_DIR="${INSTALL_DIR%/}"
info "$(text "安装目录：${INSTALL_DIR}" "Install directory: ${INSTALL_DIR}")"

step 2 3 "获取部署包" "Get deployment package"
REPO_URL="$(repo_url_for_region)"
info "$(text "部署包来源：${REPO_URL}" "Deployment package source: ${REPO_URL}")"
mkdir -p "${INSTALL_DIR}" || fail "$(text "无法创建安装目录：${INSTALL_DIR}。请换一个当前用户可写的目录，或使用 --dir 指定。" "Could not create install directory: ${INSTALL_DIR}. Choose a writable directory, or pass --dir.")"
if [[ -z "$(find "${INSTALL_DIR}" -mindepth 1 -maxdepth 1 2>/dev/null)" ]]; then
  if command -v git >/dev/null 2>&1 && git clone "${REPO_URL}" "${INSTALL_DIR}"; then
    ok "$(text "已通过 Git 获取部署包" "Deployment package downloaded via Git")"
  else
    warn "$(text "Git 获取部署包失败，尝试下载部署包压缩包。" "Git failed to get the deployment package; trying archive download.")"
    download_deploy_archive
  fi
elif [[ -d "${INSTALL_DIR}/.git" ]]; then
  if [[ "${SKIP_DEPLOY_PULL}" -eq 1 ]]; then
    info "$(text "目录已存在，已跳过部署包 git pull。" "Directory already exists; skipped deployment package git pull.")"
  elif command -v git >/dev/null 2>&1; then
    info "$(text "目录已存在，尝试更新部署包..." "Directory already exists; trying to update deployment package...")"
    git -C "${INSTALL_DIR}" pull --ff-only || warn "$(text "更新部署包失败，将继续使用当前目录中的文件。" "Deployment package update failed; continuing with current files.")"
  else
    warn "$(text "未找到 git，将继续使用当前目录中的文件。" "git was not found; continuing with current files.")"
  fi
else
  fail "$(text "安装目录已存在且不是空目录或 Git 仓库：${INSTALL_DIR}" "Install directory already exists and is neither empty nor a Git repository: ${INSTALL_DIR}")"
fi
ok "$(text "部署包已就绪" "Deployment package is ready")"

step 3 3 "进入安装流程" "Enter installation flow"
REGISTRY="$(registry_for_region)"
export ORTHOVENN_INSTALL_REGION="${REGION}"
if [[ "${REGION}" == "cn" ]]; then
  export ORTHOVENN_REFDB_SOURCE="${ORTHOVENN_REFDB_SOURCE:-gitee}"
  export ORTHOVENN_REFDB_FALLBACK_SOURCE="${ORTHOVENN_REFDB_FALLBACK_SOURCE:-official}"
else
  export ORTHOVENN_REFDB_SOURCE="${ORTHOVENN_REFDB_SOURCE:-github}"
  export ORTHOVENN_REFDB_FALLBACK_SOURCE="${ORTHOVENN_REFDB_FALLBACK_SOURCE:-official}"
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
  fail "$(text "部署包不完整，缺少安装脚本。请删除当前安装目录后重新运行安装命令。" "The deployment package is incomplete and the installer script is missing. Delete the current install directory and rerun the installation command.")"
fi

bash "${INSTALL_SCRIPT}" "${INSTALL_ARGS[@]}"
