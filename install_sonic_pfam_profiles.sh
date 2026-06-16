#!/usr/bin/env bash
set -euo pipefail

MODE="${1:-status}"
if [ "$#" -gt 0 ]; then
  shift
fi

ALLOW_DOWNLOAD=false
ARCHIVE_SOURCE=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --download)
      ALLOW_DOWNLOAD=true
      ;;
    -h|--help)
      MODE="help"
      ;;
    *)
      if [ -z "${ARCHIVE_SOURCE}" ]; then
        ARCHIVE_SOURCE="$1"
      else
        printf 'ERROR: Unknown argument: %s\n' "$1" >&2
        exit 1
      fi
      ;;
  esac
  shift
done

BASE_DIR="$(pwd)"
SCRIPT_CMD="$0"
REFDB_DIR="${BASE_DIR}/data/refdb"
SONIC_DIR="${REFDB_DIR}/sonicparanoid2"
PROFILE_DIR="${SONIC_DIR}/pfam_profile_db"
DOWNLOAD_DIR="${SONIC_DIR}/downloads"
ARCHIVE_NAME="sonicparanoid2_pfam_mmseqs_profile_db.tar.gz"
ARCHIVE_PATH="${DOWNLOAD_DIR}/${ARCHIVE_NAME}"
WORKER_IMAGE="leeoluo/orthovennplus-worker-biobase:${ORTHOVENN_IMAGE_TAG:-latest}"

PROFILE_FILES=(
  "pfama.mmseqs"
  "pfama.mmseqs.dbtype"
  "pfama.mmseqs.version"
  "pfama.mmseqs.index"
  "pfama.mmseqs_h"
  "pfama.mmseqs_h.dbtype"
  "pfama.mmseqs_h.index"
  "pfama.mmseqs.idx"
  "pfama.mmseqs.idx.dbtype"
  "pfama.mmseqs.idx.index"
)

usage() {
  cat <<EOF
Usage: ${SCRIPT_CMD} [status|download|install] [archive|--download]

Run this script from the OrthovennPlus deployment directory.

Paths:
  Profile DB: ${PROFILE_DIR}
  Downloads:  ${DOWNLOAD_DIR}

Examples:
  ${SCRIPT_CMD} status
  ${SCRIPT_CMD} download
  ${SCRIPT_CMD} install /path/to/${ARCHIVE_NAME}
  ${SCRIPT_CMD} install
  ${SCRIPT_CMD} install --download

Notes:
  install extracts the archive on the host. Docker is only used by download mode.
EOF
}

fail() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

check_profile_dir() {
  local dir="$1"
  local missing=0
  [ -d "${dir}" ] || return 1
  for file in "${PROFILE_FILES[@]}"; do
    [ -f "${dir}/${file}" ] || missing=1
  done
  return "${missing}"
}

status_profiles() {
  printf 'Profile DB: %s\n' "${PROFILE_DIR}"
  if check_profile_dir "${PROFILE_DIR}"; then
    printf '  status: complete\n'
  else
    printf '  status: missing or incomplete\n'
  fi

  printf 'Archive: %s\n' "${ARCHIVE_PATH}"
  if [ -f "${ARCHIVE_PATH}" ]; then
    printf '  archive: present\n'
  else
    printf '  archive: missing\n'
  fi
}

copy_archive_if_needed() {
  if [ -z "${ARCHIVE_SOURCE}" ]; then
    return 0
  fi
  [ -f "${ARCHIVE_SOURCE}" ] || fail "Archive not found: ${ARCHIVE_SOURCE}"
  mkdir -p "${DOWNLOAD_DIR}"
  if [ "$(cd "$(dirname "${ARCHIVE_SOURCE}")" && pwd)/$(basename "${ARCHIVE_SOURCE}")" = "${ARCHIVE_PATH}" ]; then
    return 0
  fi
  printf 'Copying archive to %s\n' "${ARCHIVE_PATH}"
  cp "${ARCHIVE_SOURCE}" "${ARCHIVE_PATH}"
}

download_archive() {
  command -v docker >/dev/null 2>&1 || fail "docker command not found"
  mkdir -p "${REFDB_DIR}"
  docker run --rm \
    -v "${REFDB_DIR}:/data/refdb" \
    "${WORKER_IMAGE}" \
    bash -lc '
      set -euo pipefail
      BIN=/opt/conda/envs/biobase/bin/sonicparanoid-get-profiles
      DIR=/data/refdb/sonicparanoid2/downloads
      ARCHIVE="${DIR}/sonicparanoid2_pfam_mmseqs_profile_db.tar.gz"
      [ -x "${BIN}" ] || { echo "sonicparanoid-get-profiles not found: ${BIN}" >&2; exit 1; }
      mkdir -p "${DIR}"
      if [ -f "${ARCHIVE}" ]; then
        echo "Archive already present: ${ARCHIVE}"
      else
        "${BIN}" -o "${DIR}"
      fi
      [ -f "${ARCHIVE}" ] || { echo "Archive was not downloaded: ${ARCHIVE}" >&2; exit 1; }
    '
}

extract_archive() {
  [ -f "${ARCHIVE_PATH}" ] || fail "Archive not found: ${ARCHIVE_PATH}"
  if check_profile_dir "${PROFILE_DIR}"; then
    printf 'Profile DB already complete: %s\n' "${PROFILE_DIR}"
    return
  fi

  local tmp_dir
  local staging_dir
  local source_file
  local source_dir
  local backup_dir
  tmp_dir="$(mktemp -d /tmp/sonic-pfam-extract.XXXXXX)"
  staging_dir="${PROFILE_DIR}.staging.$$"

  rm -rf "${staging_dir}"
  find "${SONIC_DIR}" -maxdepth 1 -type d -name 'pfam_profile_db.staging.*' -exec rm -rf {} + 2>/dev/null || true
  mkdir -p "$(dirname "${PROFILE_DIR}")" "${staging_dir}"

  printf 'Extracting archive on host: %s\n' "${ARCHIVE_PATH}"
  tar -xzf "${ARCHIVE_PATH}" -C "${tmp_dir}"
  source_file="$(find "${tmp_dir}" -type f -name 'pfama.mmseqs' -print -quit)"
  [ -n "${source_file}" ] || fail "Could not locate pfama.mmseqs inside archive: ${ARCHIVE_PATH}"
  source_dir="$(dirname "${source_file}")"

  cp -R "${source_dir}/." "${staging_dir}/"
  check_profile_dir "${staging_dir}" || fail "Extracted profile DB is incomplete: ${staging_dir}"

  if [ -e "${PROFILE_DIR}" ] || [ -L "${PROFILE_DIR}" ]; then
    backup_dir="${PROFILE_DIR}.bak.$(date +%Y%m%d%H%M%S)"
    printf 'Moving existing profile DB to %s\n' "${backup_dir}"
    mv "${PROFILE_DIR}" "${backup_dir}"
  fi
  mv "${staging_dir}" "${PROFILE_DIR}"
  rm -rf "${tmp_dir}"
  printf 'Installed profile DB: %s\n' "${PROFILE_DIR}"
}

install_profiles() {
  copy_archive_if_needed
  if [ ! -f "${ARCHIVE_PATH}" ]; then
    if [ "${ALLOW_DOWNLOAD}" = "true" ]; then
      download_archive
    else
      fail "Archive not found: ${ARCHIVE_PATH}. Run download first, pass an archive path, or use install --download."
    fi
  fi
  extract_archive
  status_profiles
}

case "${MODE}" in
  -h|--help|help)
    usage
    ;;
  status)
    status_profiles
    ;;
  download)
    download_archive
    status_profiles
    ;;
  install)
    install_profiles
    ;;
  *)
    usage >&2
    fail "Unknown mode: ${MODE}"
    ;;
esac
