#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export ORTHOVENN_INSTALL_REGION=global
exec bash "${SCRIPT_DIR}/install_bootstrap.sh" --region global "$@"
