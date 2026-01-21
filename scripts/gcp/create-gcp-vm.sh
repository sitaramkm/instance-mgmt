#!/usr/bin/env bash
set -euo pipefail

MODE="${1:-}"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"
COMMON_ENV="${ROOT_DIR}/common.env"

# shellcheck disable=SC1090
source "${COMMON_ENV}"

# ---------- Validation ----------
command -v gcloud >/dev/null || { echo "ERROR: gcloud not installed"; exit 1; }
gcloud auth list --filter=status:ACTIVE --format="value(account)" | grep -q . || {
  echo "ERROR: gcloud not authenticated"
  exit 1
}

: "${GCP_PROJECT_ID:?Missing GCP_PROJECT_ID}"
: "${GCP_REGION:?Missing GCP_REGION}"
: "${GCP_ZONES:?Missing GCP_ZONES}"

# ---------- Mode handling ----------
USE_GPU=false
AI_MODE=false

case "${MODE}" in
  --ai) AI_MODE=true ;;
  --gpu) USE_GPU=true ;;
  "" ) ;;
  *) echo "Usage: create-gcp-vm.sh [--ai|--gpu]"; exit 1 ;;
esac

AGENT_MACHINE_TYPE="${GCP_INSTANCE_TYPE}"
AGENT_DISK_FLAG=""

if ${USE_GPU}; then
  AGENT_MACHINE_TYPE="${GCP_AGENT_INSTANCE_TYPE_GPU}"
elif ${AI_MODE}; then
  AGENT_MACHINE_TYPE="${GCP_AGENT_INSTANCE_TYPE_AI}"
  AGENT_DISK_FLAG="--boot-disk-size=${GCP_AGENT_DISK_GB}GB"
fi

detect_gcp_image_family() {
  [[ "$1" =~ t2a|arm ]] && echo "${GCP_IMAGE_FAMILY_ARM64}" || echo "${GCP_IMAGE_FAMILY_AMD64}"
}

is_gpu_machine_type() {
  [[ "$1" =~ ^(g2-|a2-|a3-) ]]
}

gcp_scheduling_flags() {
  is_gpu_machine_type "$1" && echo "--maintenance-policy=TERMINATE --restart-on-failure"
}

# ---------- SSH ----------
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

# ---------- Userdata composition ----------
compose_userdata() {
  cat \
    "${ROOT_DIR}/userdata/common.yaml" \
    "$1"
}

UD_AGENT="$(mktemp)"
UD_SERVER="$(mktemp)"

compose_userdata "${ROOT_DIR}/userdata/agent.yaml" > "${UD_AGENT}"
compose_userdata "${ROOT_DIR}/userdata/server.yaml" > "${UD_SERVER}"

# ---------- Create agent FIRST ----------
SELECTED_ZONE=""

for ZONE in ${GCP_ZONES}; do
  echo "==> Creating agent in zone ${ZONE}"
  set +e
  gcloud compute instances create "${AGENT_NAME}" \
    --project="${GCP_PROJECT_ID}" \
    --zone="${ZONE}" \
    --machine-type="${AGENT_MACHINE_TYPE}" \
    --image-family="$(detect_gcp_image_family "${AGENT_MACHINE_TYPE}")" \
    --image-project="${GCP_IMAGE_PROJECT}" \
    --tags="${AGENT_TAG}" \
    --metadata="ssh-keys=${SSH_METADATA}" \
    --metadata-from-file=user-data="${UD_AGENT}" \
    ${AGENT_DISK_FLAG} \
    $(gcp_scheduling_flags "${AGENT_MACHINE_TYPE}") \
    --quiet
  if [[ $? -eq 0 ]]; then
    SELECTED_ZONE="${ZONE}"
    set -e
    break
  fi
  set -e
done

[[ -n "${SELECTED_ZONE}" ]] || {
  echo "ERROR: Failed to create agent in any zone"
  exit 1
}

# ---------- Create server ----------
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
SERVER_IP="$(gcloud compute instances describe "${SERVER_NAME}" --zone="${SELECTED_ZONE}" --format='value(networkInterfaces[0].networkIP)')"
SERVER_PUBLIC_IP="$(gcloud compute instances describe "${SERVER_NAME}" --zone="${SELECTED_ZONE}" --format='value(networkInterfaces[0].accessConfigs[0].natIP)')"

AGENT_IP="$(gcloud compute instances describe "${AGENT_NAME}" --zone="${SELECTED_ZONE}" --format='value(networkInterfaces[0].networkIP)')"
AGENT_PUBLIC_IP="$(gcloud compute instances describe "${AGENT_NAME}" --zone="${SELECTED_ZONE}" --format='value(networkInterfaces[0].accessConfigs[0].natIP)')"

# ---------- Write env ----------
ENV_FILE="${ROOT_DIR}/gcp-instances.env"

cat > "${ENV_FILE}" <<EOF
export PROVIDER="gcp"

export GCP_PROJECT_ID="${GCP_PROJECT_ID}"
export GCP_REGION="${GCP_REGION}"
export GCP_ZONE="${SELECTED_ZONE}"

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

echo "Wrote ${ENV_FILE}"

# ---------- Ingress (lock SSH to local IP) ----------
LOCAL_CIDR="$(curl -fsS https://ifconfig.me)/32"
"${SCRIPT_DIR}/gcp-allow.sh" "${LOCAL_CIDR}"

echo
echo "================ SSH ACCESS ================"
echo "Server:"
echo "  ssh -i '${SSH_KEY_ABS}' ${SSH_USER}@${SERVER_PUBLIC_IP}"
echo
echo "Agent:"
echo "  ssh -i '${SSH_KEY_ABS}' ${SSH_USER}@${AGENT_PUBLIC_IP}"
echo "============================================"
echo "Instance environment written to ${ENV_FILE}"
