#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ "$(basename "${SCRIPT_DIR}")" == "tools" ]]; then
  BASE_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
else
  BASE_DIR="${SCRIPT_DIR}"
fi

MODE="install"
REFDB_DIR="${ORTHOVENN_REFDB_DIR:-${BASE_DIR}/data/refdb}"
DOWNLOAD_DIR="${ORTHOVENN_REFDB_DOWNLOAD_DIR:-${REFDB_DIR}/downloads}"
REFDB_RELEASE_TAG="${ORTHOVENN_REFDB_RELEASE_TAG:-refdb-latest}"
ARCHIVE_NAME="${ORTHOVENN_REFDB_ARCHIVE_NAME:-orthovennplus-refdb.tar.gz}"
CHECKSUM_NAME="${ORTHOVENN_REFDB_CHECKSUM_NAME:-${ARCHIVE_NAME}.sha256}"
SOURCE="${ORTHOVENN_REFDB_SOURCE:-github}"
ARCHIVE_SOURCE=""
ARCHIVE_URL="${ORTHOVENN_REFDB_URL:-}"
CHECKSUM_URL="${ORTHOVENN_REFDB_SHA256_URL:-}"
FORCE=0
SKIP_CHECKSUM=0

GITHUB_BASE_URL="https://github.com/Yonkers/orthovennplus/releases/download/${REFDB_RELEASE_TAG}"
GITEE_BASE_URL="https://gitee.com/leeoluo/orthovennplus-docker/releases/download/${REFDB_RELEASE_TAG}"

REQUIRED_REFDB_FILES=(
  "go-basic.obo"
  "go_terms.tsv"
  "uniprot_sprot_annotation.dmnd"
  "uniprot_sprot_annotation.tsv"
)

usage() {
  cat <<EOF
Usage: ./install_refdb.sh [status|install] [options]

Install OrthoVennPlus reference data into data/refdb from a release asset.
Run this script from the deployment directory.

Options:
  --source github|gitee  Download source. Default: ${SOURCE}
  --tag TAG              Release tag containing refdb assets. Default: ${REFDB_RELEASE_TAG}
  --url URL              Direct archive URL. Overrides --source/--tag
  --sha256-url URL       Direct sha256 URL. Default: archive URL + .sha256
  --archive PATH         Use a local archive instead of downloading
  --dest DIR             Reference DB directory. Default: ${REFDB_DIR}
  --force                Reinstall even if required files already exist
  --skip-checksum        Do not require or verify the sha256 file
  -h, --help             Show this help

Expected release assets:
  ${ARCHIVE_NAME}
  ${CHECKSUM_NAME}

Examples:
  ./install_refdb.sh
  ./install_refdb.sh --source gitee
  ./install_refdb.sh --tag refdb-2026-06-16
  ./install_refdb.sh --url https://example.com/${ARCHIVE_NAME}
  ./install_refdb.sh --archive /path/to/${ARCHIVE_NAME}
EOF
}

fail() {
  echo "ERROR: $*" >&2
  exit 1
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    status|install)
      MODE="$1"
      shift
      ;;
    --source)
      SOURCE="${2:?Missing value for --source}"
      shift 2
      ;;
    --tag)
      REFDB_RELEASE_TAG="${2:?Missing value for --tag}"
      GITHUB_BASE_URL="https://github.com/Yonkers/orthovennplus/releases/download/${REFDB_RELEASE_TAG}"
      GITEE_BASE_URL="https://gitee.com/leeoluo/orthovennplus-docker/releases/download/${REFDB_RELEASE_TAG}"
      shift 2
      ;;
    --url)
      ARCHIVE_URL="${2:?Missing value for --url}"
      shift 2
      ;;
    --sha256-url)
      CHECKSUM_URL="${2:?Missing value for --sha256-url}"
      shift 2
      ;;
    --archive)
      ARCHIVE_SOURCE="${2:?Missing value for --archive}"
      shift 2
      ;;
    --dest)
      REFDB_DIR="${2:?Missing value for --dest}"
      DOWNLOAD_DIR="${REFDB_DIR}/downloads"
      shift 2
      ;;
    --force)
      FORCE=1
      shift
      ;;
    --skip-checksum)
      SKIP_CHECKSUM=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      fail "Unknown argument: $1"
      ;;
  esac
done

archive_path="${DOWNLOAD_DIR}/${ARCHIVE_NAME}"
checksum_path="${DOWNLOAD_DIR}/${CHECKSUM_NAME}"

resolve_base_url() {
  case "${SOURCE}" in
    github)
      echo "${GITHUB_BASE_URL}"
      ;;
    gitee)
      echo "${GITEE_BASE_URL}"
      ;;
    *)
      fail "Unknown source: ${SOURCE}. Use github, gitee, or --url."
      ;;
  esac
}

resolve_archive_url() {
  if [[ -n "${ARCHIVE_URL}" ]]; then
    echo "${ARCHIVE_URL}"
    return
  fi
  echo "$(resolve_base_url)/${ARCHIVE_NAME}"
}

resolve_checksum_url() {
  if [[ -n "${CHECKSUM_URL}" ]]; then
    echo "${CHECKSUM_URL}"
    return
  fi
  echo "$(resolve_archive_url).sha256"
}

has_refdb() {
  local missing=0
  for file in "${REQUIRED_REFDB_FILES[@]}"; do
    [[ -f "${REFDB_DIR}/${file}" ]] || missing=1
  done
  return "${missing}"
}

status_refdb() {
  echo "Reference DB: ${REFDB_DIR}"
  if has_refdb; then
    echo "  status: complete"
  else
    echo "  status: missing or incomplete"
    for file in "${REQUIRED_REFDB_FILES[@]}"; do
      [[ -f "${REFDB_DIR}/${file}" ]] || echo "  missing: ${file}"
    done
  fi
  if [[ -f "${archive_path}" ]]; then
    echo "Archive: ${archive_path}"
  fi
}

download_file() {
  local url="$1"
  local output="$2"
  command -v curl >/dev/null 2>&1 || fail "curl command not found"
  mkdir -p "$(dirname "${output}")"
  echo "Downloading ${url}"
  curl -fL --retry 3 --retry-delay 2 -C - -o "${output}" "${url}"
}

prepare_archive() {
  mkdir -p "${DOWNLOAD_DIR}"
  if [[ -n "${ARCHIVE_SOURCE}" ]]; then
    [[ -f "${ARCHIVE_SOURCE}" ]] || fail "Archive not found: ${ARCHIVE_SOURCE}"
    archive_path="${ARCHIVE_SOURCE}"
    return
  fi
  if [[ -f "${archive_path}" && "${FORCE}" -eq 0 ]]; then
    echo "Archive already present: ${archive_path}"
    return
  fi
  download_file "$(resolve_archive_url)" "${archive_path}"
}

prepare_checksum() {
  [[ "${SKIP_CHECKSUM}" -eq 0 ]] || return 0
  if [[ -n "${ARCHIVE_SOURCE}" && -z "${CHECKSUM_URL}" ]]; then
    local local_checksum="${ARCHIVE_SOURCE}.sha256"
    if [[ -f "${local_checksum}" ]]; then
      checksum_path="${local_checksum}"
      echo "Using local checksum: ${checksum_path}"
    else
      echo "Local checksum not found: ${local_checksum}"
      echo "Skipping checksum verification for local archive."
      SKIP_CHECKSUM=1
    fi
    return
  fi
  if [[ -f "${checksum_path}" && "${FORCE}" -eq 0 ]]; then
    echo "Checksum already present: ${checksum_path}"
    return
  fi
  download_file "$(resolve_checksum_url)" "${checksum_path}"
}

verify_checksum() {
  [[ "${SKIP_CHECKSUM}" -eq 0 ]] || return 0
  [[ -f "${checksum_path}" ]] || fail "Checksum file not found: ${checksum_path}"
  local expected
  local actual
  expected="$(awk '{print $1; exit}' "${checksum_path}")"
  [[ -n "${expected}" ]] || fail "Checksum file is empty: ${checksum_path}"
  actual="$(shasum -a 256 "${archive_path}" | awk '{print $1}')"
  if [[ "${expected}" != "${actual}" ]]; then
    fail "Checksum mismatch for ${archive_path}"
  fi
  echo "Checksum verified: ${archive_path}"
}

extract_archive() {
  local tmp_dir
  local source_dir
  tmp_dir="$(mktemp -d "${TMPDIR:-/tmp}/orthovenn-refdb.XXXXXX")"
  trap "rm -rf '${tmp_dir}'" EXIT

  echo "Extracting ${archive_path}"
  tar -xzf "${archive_path}" -C "${tmp_dir}"

  if [[ -d "${tmp_dir}/data/refdb" ]]; then
    source_dir="${tmp_dir}/data/refdb"
  elif [[ -d "${tmp_dir}/refdb" ]]; then
    source_dir="${tmp_dir}/refdb"
  else
    source_dir="${tmp_dir}"
  fi

  mkdir -p "${REFDB_DIR}"
  cp -R "${source_dir}/." "${REFDB_DIR}/"
}

install_refdb() {
  if has_refdb && [[ "${FORCE}" -eq 0 ]]; then
    echo "Reference DB already complete. Use --force to reinstall."
    status_refdb
    return
  fi
  prepare_archive
  prepare_checksum
  verify_checksum
  extract_archive
  has_refdb || fail "Reference DB is still incomplete after extraction."
  status_refdb
}

case "${MODE}" in
  status)
    status_refdb
    ;;
  install)
    install_refdb
    ;;
  *)
    fail "Unknown mode: ${MODE}"
    ;;
esac
