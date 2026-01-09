#!/usr/bin/env bash
set -euo pipefail

# cleanup.sh — stop/delete Multipass VMs using names from instances.env

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"
ENV_FILE="${ROOT_DIR}/mp-instances.env"

command -v multipass >/dev/null || {
  echo "ERROR: multipass not installed"
  exit 1
}

[[ -f "${ENV_FILE}" ]] || {
  echo "ERROR: ${ENV_FILE} not found. Refusing to delete anything."
  exit 1
}

# shellcheck disable=SC1090
source "${ENV_FILE}"

# ---------- Validation ----------
[[ -n "${SERVER_NAME:-}" ]] || {
  echo "ERROR: SERVER_NAME not set in instances.env"
  exit 1
}

[[ -n "${AGENT_NAMES[*]:-}" ]] || {
  echo "ERROR: AGENT_NAMES not set in instances.env"
  exit 1
}

echo "Destroying Multipass instances (scoped to instances.env):"
echo "  SERVER_NAME=${SERVER_NAME}"
echo "  AGENT_NAMES=${AGENT_NAMES[*]}"
echo

stop_and_delete() {
  local name="$1"

  if multipass info "${name}" >/dev/null 2>&1; then
    echo "--> Stopping ${name} (ignore errors if already stopped)…"
    multipass stop "${name}" 2>/dev/null || true

    echo "--> Deleting ${name}…"
    multipass delete "${name}" || true
  else
    echo "--> ${name} not found; skipping."
  fi
}

# ---------- Delete server ----------
stop_and_delete "${SERVER_NAME}"

# ---------- Delete agents ----------
for agent in "${AGENT_NAMES[@]}"; do
  stop_and_delete "${agent}"
done

echo "--> Purging deleted instances…"
multipass purge || true

echo "Done."
