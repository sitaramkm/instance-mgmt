#!/usr/bin/env bash
set -euo pipefail

MODE="${1:-}"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"
COMMON_ENV="${ROOT_DIR}/common.env"

# shellcheck disable=SC1090
source "${COMMON_ENV}"

# ---------- GCP auth ----------
command -v gcloud >/dev/null || { echo "ERROR: gcloud not installed"; exit 1; }
gcloud auth list --filter=status:ACTIVE --format="value(account)" | grep -q . || {
  echo "ERROR: gcloud not authenticated"
  exit 1
}

: "${GCP_PROJECT_ID:?Missing GCP_PROJECT_ID}"
: "${GCP_REGION:?Missing GCP_REGION}"
: "${GCP_ZONES:?Missing GCP_ZONES}"

# ---------- Determine machine type to use for agent vm. gpu type is difficult to find on GCP ----------
# ---------- keep running to resource quota issues. using --ai will use a bigger machine type ----------
USE_GPU=false
AI_MODE=false

case "${MODE}" in
  --ai) AI_MODE=true ;;
  --gpu) USE_GPU=true ;;
  "" ) ;;
  *) echo "Usage: create-vm.sh gcp [--ai|--gpu]"; exit 1 ;;
esac

AGENT_DISK_SIZE_GB=""
if [[ "${MODE}" == "--ai" || "${MODE}" == "--gpu" ]]; then
  AGENT_DISK_SIZE_GB="${GCP_AGENT_DISK_GB}"
fi

AGENT_MACHINE_TYPE="${GCP_INSTANCE_TYPE}"
if ${USE_GPU}; then
  AGENT_MACHINE_TYPE="${GCP_AGENT_INSTANCE_TYPE_GPU}"
elif ${AI_MODE}; then
  AGENT_MACHINE_TYPE="${GCP_AGENT_INSTANCE_TYPE_AI}"
fi

# ---------- Image family detection ----------
detect_gcp_image_family() {
  local machine_type="$1"
  if [[ "${machine_type}" =~ t2a|arm ]]; then
    echo "${GCP_IMAGE_FAMILY_ARM64}"
  else
    echo "${GCP_IMAGE_FAMILY_AMD64}"
  fi
}

is_gpu_machine_type() {
  [[ "$1" =~ ^(g2-|a2-|a3-) ]]
}

gcp_scheduling_flags() {
  if is_gpu_machine_type "$1"; then
    echo "--maintenance-policy=TERMINATE --restart-on-failure"
  fi
}

# ---------- SSH key ----------
SSH_DIR="${ROOT_DIR}/.ssh"
KEY_PRIV="${SSH_DIR}/gcp_rsa"
KEY_PUB="${KEY_PRIV}.pub"

mkdir -p "${SSH_DIR}"
[[ -f "${KEY_PRIV}" ]] || ssh-keygen -t rsa -b 4096 -N "" -f "${KEY_PRIV}"

SSH_KEY_ABS="$(cd "$(dirname "${KEY_PRIV}")" && pwd)/$(basename "${KEY_PRIV}")"
SSH_METADATA="${SSH_USER}:$(cat "${KEY_PUB}")"

# ---------- Network tags ----------
SERVER_TAG="swa-server"
AGENT_TAG="swa-agent"

# ==================================================================================
# Installing AGENTS VM's first (can fail when using GPUs and resource quota issues)
# ==================================================================================

userdata_server() {
cat <<'EOF'
#cloud-config
package_update: true
packages:
  - ufw
  - openssh-server
  - net-tools

runcmd:
  - systemctl enable --now ssh
  - ufw allow OpenSSH
  - ufw allow 8081/tcp
  - ufw --force enable
EOF
}

userdata_agent() {
cat <<'EOF'
#cloud-config
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
      ARCH="$(uname -m)"
      if [[ "${ARCH}" == "aarch64" || "${ARCH}" == "arm64" ]]; then
        AWSCLI_ZIP_URL="https://awscli.amazonaws.com/awscli-exe-linux-aarch64.zip"
      else
        AWSCLI_ZIP_URL="https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip"
      fi
      curl -fsSL "${AWSCLI_ZIP_URL}" -o "/tmp/awscliv2.zip"
      rm -rf /tmp/awscliv2
      unzip -q /tmp/awscliv2.zip -d /tmp/awscliv2
      sudo /tmp/awscliv2/aws/install || sudo /tmp/awscliv2/aws/install --update
      aws --version
      rm -rf /tmp/awscliv2 /tmp/awscliv2.zip

  - echo "==> Installing Python packages for agent demo"
  - pip3 install --no-cache-dir requests boto3
EOF
}
# ============================================================
AGENT_NAMES=()
AGENT_IPS=()
AGENT_PUBLIC_IPS=()
SELECTED_ZONE=""
DISK_FLAG=""
if [[ -n "${AGENT_DISK_SIZE_GB}" ]]; then
  DISK_FLAG="--boot-disk-size=${AGENT_DISK_SIZE_GB}GB"
fi
echo "==> Creating ${NUM_AGENTS} agent VMs of type ${AGENT_MACHINE_TYPE}"
UD_AGENT="$(mktemp)"
userdata_agent > "${UD_AGENT}"

for ZONE in ${GCP_ZONES}; do
  echo "==> Creating VMs in zone ${ZONE}"

  set +e
  for i in $(seq 1 "${NUM_AGENTS}"); do
    NAME="${AGENT_NAME_PREFIX}-${i}"
    AGENT_NAMES+=("${NAME}")

    gcloud compute instances create "${NAME}" \
      --project="${GCP_PROJECT_ID}" \
      --zone="${ZONE}" \
      --machine-type="${AGENT_MACHINE_TYPE}" \
      --image-family="$(detect_gcp_image_family "${AGENT_MACHINE_TYPE}")" \
      --image-project="${GCP_IMAGE_PROJECT}" \
      --tags="${AGENT_TAG}" \
      --metadata="ssh-keys=${SSH_METADATA}" \
      --metadata-from-file=user-data="${UD_AGENT}" \
      ${DISK_FLAG} \
      $(gcp_scheduling_flags "${AGENT_MACHINE_TYPE}") \
      --quiet || break
  done

  if [[ "${#AGENT_NAMES[@]}" -eq "${NUM_AGENTS}" ]]; then
    SELECTED_ZONE="${ZONE}"
    set -e
    break
  fi

  echo "!! VM creation failed in ${ZONE}, cleaning up"
  for name in "${AGENT_NAMES[@]}"; do
    gcloud compute instances delete "${name}" --zone="${ZONE}" --quiet || true
  done
  AGENT_NAMES=()
  set -e
done

[[ -n "${SELECTED_ZONE}" ]] || {
  echo "ERROR: Failed to create agents in any zone: ${GCP_ZONES}"
  exit 1
}

echo "==> VMs created in ${SELECTED_ZONE}"

# ============================================================
# SERVER (only after agent vms succeed)
# ============================================================
UD_SERVER="$(mktemp)"
userdata_server > "${UD_SERVER}"

echo "==> Creating server in ${SELECTED_ZONE}"

gcloud compute instances create "${SERVER_NAME}" \
  --project="${GCP_PROJECT_ID}" \
  --zone="${SELECTED_ZONE}" \
  --machine-type="${GCP_INSTANCE_TYPE}" \
  --image-family="$(detect_gcp_image_family "${GCP_INSTANCE_TYPE}")" \
  --image-project="${GCP_IMAGE_PROJECT}" \
  --tags="${SERVER_TAG}" \
  --metadata="ssh-keys=${SSH_METADATA}" \
  --metadata-from-file=user-data="${UD_SERVER}" \
  --quiet

# ---------- Capture IPs ----------
SERVER_IP="$(gcloud compute instances describe "${SERVER_NAME}" \
  --zone="${SELECTED_ZONE}" \
  --format='value(networkInterfaces[0].networkIP)')"

SERVER_PUBLIC_IP="$(gcloud compute instances describe "${SERVER_NAME}" \
  --zone="${SELECTED_ZONE}" \
  --format='value(networkInterfaces[0].accessConfigs[0].natIP)')"

for name in "${AGENT_NAMES[@]}"; do
  AGENT_IPS+=( "$(gcloud compute instances describe "${name}" \
    --zone="${SELECTED_ZONE}" \
    --format='value(networkInterfaces[0].networkIP)')" )
  AGENT_PUBLIC_IPS+=( "$(gcloud compute instances describe "${name}" \
    --zone="${SELECTED_ZONE}" \
    --format='value(networkInterfaces[0].accessConfigs[0].natIP)')" )
done

# ---------- Write gcp-instances.env ----------
ENV_FILE="${ROOT_DIR}/gcp-instances.env"

cat > "${ENV_FILE}" <<EOF
export PROVIDER="gcp"

export GCP_PROJECT_ID="${GCP_PROJECT_ID}"
export GCP_REGION="${GCP_REGION}"
export GCP_ZONE="${SELECTED_ZONE}"

export SERVER_NAME="${SERVER_NAME}"
export SERVER_IP="${SERVER_IP}"
export SERVER_PUBLIC_IP="${SERVER_PUBLIC_IP}"

export AGENT_NAME_PREFIX="${AGENT_NAME_PREFIX}"
export AGENT_NAMES=(${AGENT_NAMES[*]})
export AGENT_IPS=(${AGENT_IPS[*]})
export AGENT_PUBLIC_IPS=(${AGENT_PUBLIC_IPS[*]})

export SERVER_NETWORK_TAG="${SERVER_TAG}"
export AGENT_NETWORK_TAG="${AGENT_TAG}"

export SSH_USER="${SSH_USER}"
export SSH_KEY_PRIVATE="${SSH_KEY_ABS}"
EOF

{
  echo
  echo "# ================= SSH ACCESS ================="
  echo "#               For quick copy/paste"
  echo "# Server:"
  echo "#   ssh -i '${SSH_KEY_ABS}' ${SSH_USER}@${SERVER_PUBLIC_IP}"
  echo "#"
  for i in "${!AGENT_PUBLIC_IPS[@]}"; do
    echo "# Agent ${AGENT_NAME_PREFIX}-$((i+1)):"
    echo "#   ssh -i '${SSH_KEY_ABS}' ${SSH_USER}@${AGENT_PUBLIC_IPS[$i]}"
  done
  echo "# =============================================="
} >> "${ENV_FILE}"

# ---------- Ingress ----------
"${SCRIPT_DIR}/gcp-allow.sh" "$(curl -fsS https://ifconfig.me)/32"

# ---------- SSH OUTPUT ----------
echo
echo "================ SSH ACCESS ================"
echo "Server:"
echo "  ssh -i '${SSH_KEY_ABS}' ${SSH_USER}@${SERVER_PUBLIC_IP}"
echo
for i in "${!AGENT_PUBLIC_IPS[@]}"; do
  echo "Agent ${AGENT_NAME_PREFIX}-$((i+1)):"
  echo "  ssh -i '${SSH_KEY_ABS}' ${SSH_USER}@${AGENT_PUBLIC_IPS[$i]}"
done
echo "============================================"
echo "Wrote ${ENV_FILE}"