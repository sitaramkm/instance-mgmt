#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"
COMMON_ENV="${ROOT_DIR}/common.env"

# shellcheck disable=SC1090
source "${COMMON_ENV}"

multipass delete "${AGENT_NAME}" || true
multipass delete "${SERVER_NAME}" || true
multipass purge || true

echo "Multipass VMs deleted"
