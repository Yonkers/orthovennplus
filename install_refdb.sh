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
SOURCE="${ORTHOVENN_REFDB_SOURCE:-official}"
FALLBACK_SOURCE="${ORTHOVENN_REFDB_FALLBACK_SOURCE:-github}"
ARCHIVE_SOURCE=""
ARCHIVE_URL="${ORTHOVENN_REFDB_URL:-}"
CHECKSUM_URL="${ORTHOVENN_REFDB_SHA256_URL:-}"
FORCE=0
SKIP_CHECKSUM=0

OFFICIAL_BASE_URL="${ORTHOVENN_REFDB_OFFICIAL_BASE_URL:-https://orthovenn.com/downloads/refdb}"
GITHUB_BASE_URL="https://github.com/Yonkers/orthovennplus/releases/download/${REFDB_RELEASE_TAG}"
GITEE_BASE_URL="https://gitee.com/leeoluo/orthovennplus-docker/releases/download/${REFDB_RELEASE_TAG}"
OFFICIAL_BASE_URL="${OFFICIAL_BASE_URL%/}"

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
  --source official|github|gitee
                        Download source. Default: ${SOURCE}
  --fallback-source github|gitee|none
                        Fallback source used when --source official fails. Default: ${FALLBACK_SOURCE}
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

Optional split archive assets:
  ${ARCHIVE_NAME}.parts
  ${ARCHIVE_NAME}.part-aa
  ${ARCHIVE_NAME}.part-ab

Examples:
  ./install_refdb.sh
  ./install_refdb.sh --source github
  ./install_refdb.sh --source gitee
  ./install_refdb.sh --fallback-source none
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
    --fallback-source)
      FALLBACK_SOURCE="${2:?Missing value for --fallback-source}"
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
ARCHIVE_DOWNLOAD_SOURCE=""
LAST_DOWNLOAD_SOURCE=""

resolve_base_url() {
  local source="$1"
  case "${source}" in
    official)
      echo "${OFFICIAL_BASE_URL}"
      ;;
    github)
      echo "${GITHUB_BASE_URL}"
      ;;
    gitee)
      echo "${GITEE_BASE_URL}"
      ;;
    *)
      fail "Unknown source: ${source}. Use official, github, gitee, or --url."
      ;;
  esac
}

resolve_asset_url_for_source() {
  local source="$1"
  local asset_name="$2"
  echo "$(resolve_base_url "${source}")/${asset_name}"
}

resolve_archive_url() {
  if [[ -n "${ARCHIVE_URL}" ]]; then
    echo "${ARCHIVE_URL}"
    return
  fi
  echo "$(resolve_asset_url_for_source "${SOURCE}" "${ARCHIVE_NAME}")"
}

resolve_checksum_url() {
  if [[ -n "${CHECKSUM_URL}" ]]; then
    echo "${CHECKSUM_URL}"
    return
  fi
  echo "$(resolve_archive_url).sha256"
}

download_release_asset() {
  local output="$1"
  local asset_name="$2"
  local preferred_source="${3:-}"
  local candidates=()
  local source

  add_candidate() {
    local candidate="$1"
    local existing
    [[ -n "${candidate}" && "${candidate}" != "none" ]] || return 0
    if [[ "${#candidates[@]}" -gt 0 ]]; then
      for existing in "${candidates[@]}"; do
        [[ "${existing}" == "${candidate}" ]] && return 0
      done
    fi
    candidates+=("${candidate}")
  }

  add_candidate "${preferred_source}"
  if [[ "${SOURCE}" == "official" ]]; then
    add_candidate "official"
    add_candidate "${FALLBACK_SOURCE}"
  else
    add_candidate "${SOURCE}"
  fi

  for source in "${candidates[@]}"; do
    if [[ "${asset_name}" == "${ARCHIVE_NAME}" ]]; then
      if download_archive_asset_from_source "${source}" "${output}"; then
        LAST_DOWNLOAD_SOURCE="${source}"
        return 0
      fi
    elif download_file "$(resolve_asset_url_for_source "${source}" "${asset_name}")" "${output}"; then
      LAST_DOWNLOAD_SOURCE="${source}"
      return 0
    fi
    echo "Download failed from source '${source}', trying next source if available." >&2
    rm -f "${output}"
  done

  fail "Failed to download ${asset_name} from configured sources."
}

download_archive_asset_from_source() {
  local source="$1"
  local output="$2"

  if download_file "$(resolve_asset_url_for_source "${source}" "${ARCHIVE_NAME}")" "${output}"; then
    return 0
  fi

  echo "Single archive was not available from source '${source}', trying split archive parts." >&2
  rm -f "${output}"
  download_split_archive_from_source "${source}" "${output}"
}

download_split_archive_from_source() {
  local source="$1"
  local output="$2"
  local manifest_path="${DOWNLOAD_DIR}/${ARCHIVE_NAME}.parts"
  local tmp_output="${output}.tmp"
  local part_name
  local part_path
  local part_count=0

  rm -f "${manifest_path}" "${tmp_output}"
  if ! download_file "$(resolve_asset_url_for_source "${source}" "${ARCHIVE_NAME}.parts")" "${manifest_path}"; then
    rm -f "${manifest_path}" "${tmp_output}"
    return 1
  fi

  while IFS= read -r part_name || [[ -n "${part_name}" ]]; do
    part_name="${part_name%$'\r'}"
    [[ -n "${part_name}" ]] || continue
    [[ "${part_name}" != \#* ]] || continue
    case "${part_name}" in
      */*|*..*)
        fail "Invalid split archive part name in manifest: ${part_name}"
        ;;
    esac

    part_path="${DOWNLOAD_DIR}/${part_name}"
    if ! download_file "$(resolve_asset_url_for_source "${source}" "${part_name}")" "${part_path}"; then
      rm -f "${tmp_output}"
      return 1
    fi
    cat "${part_path}" >> "${tmp_output}"
    part_count=$((part_count + 1))
  done < "${manifest_path}"

  [[ "${part_count}" -gt 0 ]] || fail "Split archive manifest has no parts: ${manifest_path}"
  mv "${tmp_output}" "${output}"
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
  curl -fL \
    --retry 3 \
    --retry-delay 2 \
    --connect-timeout 15 \
    --speed-time 60 \
    --speed-limit 1024 \
    -C - \
    -o "${output}" \
    "${url}"
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
  if [[ -n "${ARCHIVE_URL}" ]]; then
    download_file "$(resolve_archive_url)" "${archive_path}"
  else
    download_release_asset "${archive_path}" "${ARCHIVE_NAME}"
    ARCHIVE_DOWNLOAD_SOURCE="${LAST_DOWNLOAD_SOURCE}"
  fi
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
  if [[ -n "${CHECKSUM_URL}" || -n "${ARCHIVE_URL}" ]]; then
    download_file "$(resolve_checksum_url)" "${checksum_path}"
  else
    download_release_asset "${checksum_path}" "${CHECKSUM_NAME}" "${ARCHIVE_DOWNLOAD_SOURCE}"
  fi
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
