#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"

COMMON_ENV="${ROOT_DIR}/common.env"
[[ -f "${COMMON_ENV}" ]] || { echo "ERROR: common.env not found"; exit 1; }
# shellcheck disable=SC1090
source "${COMMON_ENV}"

# ---------- SSH key (Multipass-local) ----------
SSH_DIR="${ROOT_DIR}/.ssh"
KEY_PRIV="${SSH_DIR}/mp_rsa"
KEY_PUB="${KEY_PRIV}.pub"

mkdir -p "${SSH_DIR}"
if [[ ! -f "${KEY_PRIV}" ]]; then
  ssh-keygen -t rsa -b 4096 -N "" -f "${KEY_PRIV}"
fi
SSH_KEY_ABS="$(cd "$(dirname "${KEY_PRIV}")" && pwd)/$(basename "${KEY_PRIV}")"
PUBKEY="$(cat "${KEY_PUB}")"

# ---------- Server ----------
if ! multipass info "${SERVER_NAME}" >/dev/null 2>&1; then
  multipass launch "${UBUNTU_VER}" \
    --name "${SERVER_NAME}" \
    --cpus "${VM_CPUS}" \
    --memory "${VM_MEM}" \
    --disk "${VM_DISK}" \
    --cloud-init <(cat <<EOF
#cloud-config
users:
- name: ${SSH_USER}
  sudo: ALL=(ALL) NOPASSWD:ALL
  ssh_authorized_keys:
    - ${PUBKEY}
packages: [ufw, openssh-server, net-tools]
runcmd:
- systemctl enable --now ssh
- ufw allow OpenSSH
- ufw allow 8081/tcp
- ufw --force enable
EOF
)
fi

SERVER_IP="$(multipass info "${SERVER_NAME}" | awk '/IPv4/{print $2}')"
SERVER_PUBLIC_IP="${SERVER_IP}"

# ---------- Agents ----------
AGENT_NAMES=()
AGENT_IPS=()
AGENT_PUBLIC_IPS=()

for i in $(seq 1 "${NUM_AGENTS}"); do
  NAME="${AGENT_NAME_PREFIX}-${i}"
  AGENT_NAMES+=("${NAME}")

  if ! multipass info "${NAME}" >/dev/null 2>&1; then
    multipass launch "${UBUNTU_VER}" \
      --name "${NAME}" \
      --cpus "${VM_CPUS}" \
      --memory "${VM_MEM}" \
      --disk "${VM_DISK}" \
      --cloud-init <(cat <<EOF
#cloud-config
users:
- name: ${SSH_USER}
  sudo: ALL=(ALL) NOPASSWD:ALL
  ssh_authorized_keys:
    - ${PUBKEY}
package_update: true
packages:
  - ufw
  - openssh-server
  - net-tools
  - curl
  - unzip
  - python3
  - python3-pip
  - python3-venv
  - git
  - build-essential

runcmd:
  - systemctl enable --now ssh
  - ufw allow OpenSSH
  - ufw --force enable

  - echo "==> Installing AWS CLI (arch-aware)"
  - |
      set -e
      ARCH="\$(uname -m)"
      if [[ "\${ARCH}" == "aarch64" || "\${ARCH}" == "arm64" ]]; then
        AWSCLI_ZIP_URL="https://awscli.amazonaws.com/awscli-exe-linux-aarch64.zip"
      else
        AWSCLI_ZIP_URL="https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip"
      fi
      curl -fsSL "\${AWSCLI_ZIP_URL}" -o "/tmp/awscliv2.zip"
      rm -rf /tmp/awscliv2
      unzip -q /tmp/awscliv2.zip -d /tmp/awscliv2
      sudo /tmp/awscliv2/aws/install || sudo /tmp/awscliv2/aws/install --update
      aws --version
      rm -rf /tmp/awscliv2 /tmp/awscliv2.zip

  - echo "==> Installing Python packages"
  - pip3 install --no-cache-dir requests boto3
EOF
)
  fi
  ip="$(multipass info "${NAME}" | awk '/IPv4/{print $2}')"
  AGENT_IPS+=( "${ip}" )
  AGENT_PUBLIC_IPS+=( "${ip}" )
done

# ---------- Write instances.env ----------

ENV_FILE="${ROOT_DIR}/mp-instances.env"

cat > "${ENV_FILE}" <<EOF
# ===================== Multipass =====================
# ${ENV_FILE} 
# Generated on $(date) by create-multipass-vm.sh

export PROVIDER="multipass"

# Server details
export SERVER_NAME="${SERVER_NAME}"
export SERVER_IP="${SERVER_IP}"
export SERVER_PUBLIC_IP="${SERVER_PUBLIC_IP}"

# Agent details
export AGENT_NAMES=(${AGENT_NAMES[*]})
export AGENT_IPS=(${AGENT_IPS[*]})
export AGENT_PUBLIC_IPS=(${AGENT_PUBLIC_IPS[*]})

# SSH details
export SSH_USER="${SSH_USER}"
export SSH_KEY_PRIVATE="${SSH_KEY_ABS}"
EOF

echo "Wrote ${ENV_FILE}"

{
  echo
  echo "# ================= SSH ACCESS ================="
  echo "#               For quick copy/paste"
  echo "# Server:"
  echo "#   ssh -i '${SSH_KEY_ABS}' ${SSH_USER}@${SERVER_IP}"
  echo "#"
  for i in "${!AGENT_PUBLIC_IPS[@]}"; do
    echo "# Agent ${AGENT_NAMES[$i]}:"
    echo "#   ssh -i '${SSH_KEY_ABS}' ${SSH_USER}@${AGENT_PUBLIC_IPS[$i]}"
  done
  echo "# =============================================="
} >> "${ENV_FILE}"

# ---------- SSH OUTPUT ----------
echo
echo "================ SSH ACCESS ================"
echo "Server:"
echo "  ssh -i '${SSH_KEY_ABS}' ${SSH_USER}@${SERVER_IP}"
echo
for i in "${!AGENT_PUBLIC_IPS[@]}"; do
  echo "Agent ${AGENT_NAMES[$i]}:"
  echo "  ssh -i '${SSH_KEY_ABS}' ${SSH_USER}@${AGENT_PUBLIC_IPS[$i]}"
done
echo "============================================"
