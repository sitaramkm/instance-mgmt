#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"
COMMON_ENV="${ROOT_DIR}/common.env"

# shellcheck disable=SC1090
source "${COMMON_ENV}"

command -v multipass >/dev/null || { echo "ERROR: multipass not installed"; exit 1; }

# ---------- SSH ----------
SSH_DIR="${ROOT_DIR}/.ssh"
KEY_PRIV="${SSH_DIR}/mp_rsa"
KEY_PUB="${KEY_PRIV}.pub"

mkdir -p "${SSH_DIR}"
[[ -f "${KEY_PRIV}" ]] || ssh-keygen -t rsa -b 4096 -N "" -f "${KEY_PRIV}"

SSH_KEY_ABS="$(cd "$(dirname "${KEY_PRIV}")" && pwd)/$(basename "${KEY_PRIV}")"

# ---------- Userdata (Multipass-specific) ----------
compose_multipass_userdata() {
  local role_yaml="$1"

  cat <<EOF
#cloud-config
users:
  - default
  - name: ${SSH_USER}
    sudo: ALL=(ALL) NOPASSWD:ALL
    shell: /bin/bash
    ssh-authorized-keys:
      - $(cat "${KEY_PUB}")

$(cat "${ROOT_DIR}/userdata/common.yaml" | sed '1d')
$(cat "${role_yaml}" | sed '1d')
EOF
}

UD_AGENT="$(mktemp)"
UD_SERVER="$(mktemp)"

compose_multipass_userdata "${ROOT_DIR}/userdata/agent.yaml" > "${UD_AGENT}"
compose_multipass_userdata "${ROOT_DIR}/userdata/server.yaml" > "${UD_SERVER}"

# ---------- Create agent ----------
echo "==> Creating agent VM: ${AGENT_NAME}"

multipass launch "${UBUNTU_VER}" \
  --name "${AGENT_NAME}" \
  --cpus "${VM_CPUS}" \
  --memory "${VM_MEM}" \
  --disk "${VM_DISK}" \
  --cloud-init "${UD_AGENT}"

# ---------- Create server ----------
echo "==> Creating server VM: ${SERVER_NAME}"

multipass launch "${UBUNTU_VER}" \
  --name "${SERVER_NAME}" \
  --cpus "${VM_CPUS}" \
  --memory "${VM_MEM}" \
  --disk "${VM_DISK}" \
  --cloud-init "${UD_SERVER}"

# ---------- IPs ----------
SERVER_IP="$(multipass info "${SERVER_NAME}" | awk '/IPv4/ {print $2}')"
AGENT_IP="$(multipass info "${AGENT_NAME}" | awk '/IPv4/ {print $2}')"

SERVER_PUBLIC_IP="${SERVER_IP}"
AGENT_PUBLIC_IP="${AGENT_IP}"

# ---------- Write env ----------
ENV_FILE="${ROOT_DIR}/mp-instances.env"

cat > "${ENV_FILE}" <<EOF
export PROVIDER="multipass"

export SERVER_NAME="${SERVER_NAME}"
export SERVER_IP="${SERVER_IP}"
export SERVER_PUBLIC_IP="${SERVER_PUBLIC_IP}"

export AGENT_NAME="${AGENT_NAME}"
export AGENT_IP="${AGENT_IP}"
export AGENT_PUBLIC_IP="${AGENT_PUBLIC_IP}"

export SSH_USER="${SSH_USER}"
export SSH_KEY_PRIVATE="${SSH_KEY_ABS}"
EOF

{
  echo
  echo "# ================= SSH ACCESS ================="
  echo "# Server:"
  echo "#   ssh -i '${SSH_KEY_ABS}' ${SSH_USER}@${SERVER_PUBLIC_IP}"
  echo "#"
  echo "# Agent:"
  echo "#   ssh -i '${SSH_KEY_ABS}' ${SSH_USER}@${AGENT_PUBLIC_IP}"
  echo "# =============================================="
} >> "${ENV_FILE}"

echo
echo "================ SSH ACCESS ================"
echo "Server:"
echo "  ssh -i '${SSH_KEY_ABS}' ${SSH_USER}@${SERVER_PUBLIC_IP}"
echo
echo "Agent:"
echo "  ssh -i '${SSH_KEY_ABS}' ${SSH_USER}@${AGENT_PUBLIC_IP}"
echo "============================================"
echo "Wrote ${ENV_FILE}"
