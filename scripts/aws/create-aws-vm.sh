#!/usr/bin/env bash
set -euo pipefail

FLAG="${1:-}"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"

COMMON_ENV="${ROOT_DIR}/common.env"
[[ -f "${COMMON_ENV}" ]] || { echo "ERROR: common.env not found"; exit 1; }
# shellcheck disable=SC1090
source "${COMMON_ENV}"

# ---------- AWS CLI sanity check ----------
aws --profile "${AWS_PROFILE}" sts get-caller-identity >/dev/null 2>&1 || {
  echo "ERROR: AWS CLI is not authenticated."
  echo "Run: aws configure or aws sso login"
  exit 1
}

# ---------- AI mode ----------
AI_MODE=false
[[ "${FLAG}" == "--ai" ]] && AI_MODE=true

AGENT_INSTANCE_TYPE="${INSTANCE_TYPE}"
$AI_MODE && AGENT_INSTANCE_TYPE="${AGENT_INSTANCE_TYPE_AI}"

# ---------- AWS helpers ----------
aws_ec2() {
  aws ec2 --region "${AWS_REGION}" --profile "${AWS_PROFILE}" "$@"
}

# ---------- SSH key ----------
SSH_DIR="${ROOT_DIR}/.ssh"
KEY_NAME="instance-mgmt-ec2-key"
KEY_PRIV="${SSH_DIR}/ec2_rsa"
KEY_PUB="${KEY_PRIV}.pub"

mkdir -p "${SSH_DIR}"
if [[ ! -f "${KEY_PRIV}" ]]; then
  ssh-keygen -t rsa -b 4096 -N "" -f "${KEY_PRIV}"
fi
SSH_KEY_ABS="$(cd "$(dirname "${KEY_PRIV}")" && pwd)/$(basename "${KEY_PRIV}")"

ensure_keypair() {
  aws_ec2 describe-key-pairs --key-names "${KEY_NAME}" >/dev/null 2>&1 || \
  aws_ec2 import-key-pair \
    --key-name "${KEY_NAME}" \
    --public-key-material "fileb://${KEY_PUB}" >/dev/null
}

# ---------- Networking (create-only) ----------
find_default_vpc() {
  aws_ec2 describe-vpcs \
    --filters Name=isDefault,Values=true \
    --query 'Vpcs[0].VpcId' \
    --output text
}

ensure_sg() {
  local name="$1" vpc="$2"
  local sg
  sg="$(aws_ec2 describe-security-groups \
    --filters Name=group-name,Values="${name}" Name=vpc-id,Values="${vpc}" \
    --query 'SecurityGroups[0].GroupId' \
    --output text 2>/dev/null || true)"

  if [[ -z "${sg}" || "${sg}" == "None" ]]; then
    sg="$(aws_ec2 create-security-group \
      --group-name "${name}" \
      --description "${name}" \
      --vpc-id "${vpc}" \
      --query 'GroupId' \
      --output text)"
  fi
  echo "${sg}"
}

# ---------- User data ----------
userdata_server() {
cat <<'EOF'
#cloud-config
package_update: true
packages: [ufw, openssh-server]
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
packages: [ufw, openssh-server, curl]
runcmd:
- systemctl enable --now ssh
- ufw allow OpenSSH
- ufw allow 11434/tcp
- ufw --force enable
EOF
}

# ---------- EC2 helpers ----------
launch_instance() {
  aws_ec2 run-instances \
    --image-id "${AMI_ID}" \
    --instance-type "$1" \
    --key-name "${KEY_NAME}" \
    --security-group-ids "$2" \
    --associate-public-ip-address \
    --block-device-mappings "DeviceName=/dev/sda1,Ebs={VolumeSize=${DISK_GB}}" \
    --user-data "file://$3" \
    --count 1 \
    --tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=$4}]" \
    --query 'Instances[0].InstanceId' \
    --output text
}

instance_ip() {
  aws_ec2 describe-instances \
    --instance-ids "$1" \
    --query 'Reservations[0].Instances[0].PublicIpAddress' \
    --output text
}

# ===================== CREATE =====================

ensure_keypair

VPC_ID="$(find_default_vpc)"
[[ -n "${VPC_ID}" && "${VPC_ID}" != "None" ]] || { echo "No default VPC"; exit 1; }

SERVER_SG="$(ensure_sg "${SERVER_NAME}-sg" "${VPC_ID}")"
AGENT_SG="$(ensure_sg "${AGENT_NAME_PREFIX}-sg" "${VPC_ID}")"

UD_SERVER="$(mktemp)"; userdata_server > "${UD_SERVER}"
UD_AGENT="$(mktemp)"; userdata_agent > "${UD_AGENT}"

SERVER_ID="$(launch_instance "${INSTANCE_TYPE}" "${SERVER_SG}" "${UD_SERVER}" "${SERVER_NAME}")"

AGENT_IDS=()
for i in $(seq 1 "${NUM_AGENTS}"); do
  AGENT_IDS+=( "$(launch_instance "${AGENT_INSTANCE_TYPE}" "${AGENT_SG}" "${UD_AGENT}" "${AGENT_NAME_PREFIX}-${i}")" )
done

aws_ec2 wait instance-running --instance-ids "${SERVER_ID}" "${AGENT_IDS[@]}"

SERVER_IP="$(instance_ip "${SERVER_ID}")"
AGENT_IPS=()
for id in "${AGENT_IDS[@]}"; do
  AGENT_IPS+=( "$(instance_ip "${id}")" )
done

# ---------- Write instances.env ----------
ENV_FILE="${ROOT_DIR}/instances.env"

cat > "${ENV_FILE}" <<EOF
export PROVIDER="aws"

export SERVER_INSTANCE_ID="${SERVER_ID}"
export SERVER_NAME="${SERVER_NAME}"
export SERVER_IP="${SERVER_IP}"

export AGENT_INSTANCE_IDS=(${AGENT_IDS[*]})
export AGENT_NAMES=($(seq 1 "${NUM_AGENTS}" | sed "s/^/${AGENT_NAME_PREFIX}-/"))
export AGENT_IPS=(${AGENT_IPS[*]})

export SSH_USER="${SSH_USER}"
export SSH_KEY_PRIVATE="${SSH_KEY_ABS}"
EOF

echo "Wrote ${ENV_FILE}"

{
  echo
  echo "# ================= SSH ACCESS ================="
  echo "# Server:"
  echo "#   ssh -i '${SSH_KEY_ABS}' ${SSH_USER}@${SERVER_IP}"
  echo "#"
  for i in "${!AGENT_IPS[@]}"; do
    echo "# Agent ${AGENT_NAME_PREFIX[$i]}:"
    echo "#   ssh -i '${SSH_KEY_ABS}' ${SSH_USER}@${AGENT_IPS[$i]}"
  done
  echo "# =============================================="
} >> "${ENV_FILE}"

# ---------- Initial ingress (call ec2-allow.sh ) ----------
echo "==> Applying default ingress using ec2-allow.sh"
"${SCRIPT_DIR}/ec2-allow.sh" "$(curl -fsS https://ifconfig.me)/32"

# ---------- SSH OUTPUT ----------
echo
echo "================ SSH ACCESS ================"
echo "Server:"
echo "  ssh -i '${SSH_KEY_ABS}' ${SSH_USER}@${SERVER_IP}"
echo
for i in "${!AGENT_IPS[@]}"; do
  echo "Agent ${AGENT_NAME_PREFIX}-$((i+1)) :"
  echo "  ssh -i '${SSH_KEY_ABS}' ${SSH_USER}@${AGENT_IPS[$i]}"
done
echo "============================================"
