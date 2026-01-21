#!/usr/bin/env bash
set -euo pipefail

MODE="${1:-}"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"
COMMON_ENV="${ROOT_DIR}/common.env"

# shellcheck disable=SC1090
source "${COMMON_ENV}"

# ---------- Preconditions ----------
command -v aws >/dev/null || { echo "ERROR: aws cli not installed"; exit 1; }
command -v curl >/dev/null || { echo "ERROR: curl not installed"; exit 1; }

: "${AWS_PROFILE:?Missing AWS_PROFILE}"
: "${AWS_REGION:?Missing AWS_REGION}"
: "${AMI_ID:?Missing AMI_ID}"
: "${INSTANCE_TYPE:?Missing INSTANCE_TYPE}"
: "${SSH_USER:?Missing SSH_USER}"

aws sts get-caller-identity \
  --profile "${AWS_PROFILE}" \
  --region "${AWS_REGION}" >/dev/null || {
  echo "ERROR: AWS CLI not authenticated for profile ${AWS_PROFILE}"
  exit 1
}

# ---------- AWS helper (authoritative) ----------
awscli() {
  aws ec2 \
    --region "${AWS_REGION}" \
    --profile "${AWS_PROFILE}" \
    "$@"
}

# ============================================================
# AI MODE (agent only)
# ============================================================
AI_MODE=false
[[ "${MODE}" == "--ai" ]] && AI_MODE=true

AGENT_INSTANCE_TYPE="${INSTANCE_TYPE}"
AGENT_DISK_ARGS=()

if ${AI_MODE}; then
  : "${AGENT_INSTANCE_TYPE_AI:?Missing AGENT_INSTANCE_TYPE_AI}"
  AGENT_INSTANCE_TYPE="${AGENT_INSTANCE_TYPE_AI}"

  if [[ -n "${AGENT_DISK_GB:-}" ]]; then
    AGENT_DISK_ARGS=(
      --block-device-mappings
      "DeviceName=/dev/sda1,Ebs={VolumeSize=${AGENT_DISK_GB}}"
    )
  fi

  echo "==> AI mode enabled"
  echo "    Agent instance type: ${AGENT_INSTANCE_TYPE}"
  [[ -n "${AGENT_DISK_GB:-}" ]] && echo "    Agent disk size: ${AGENT_DISK_GB} GB"
fi

# ============================================================
# Subnet resolution
# ============================================================
if [[ -z "${SUBNET_ID:-}" ]]; then
  echo "==> SUBNET_ID not set, discovering default public subnet"

  DEFAULT_VPC_ID="$(
    awscli describe-vpcs \
      --filters Name=isDefault,Values=true \
      --query 'Vpcs[0].VpcId' \
      --output text
  )"

  [[ -n "${DEFAULT_VPC_ID}" && "${DEFAULT_VPC_ID}" != "None" ]] || {
    echo "ERROR: No default VPC found; set SUBNET_ID explicitly"
    exit 1
  }

  SUBNET_ID="$(
    awscli describe-subnets \
      --filters \
        Name=vpc-id,Values="${DEFAULT_VPC_ID}" \
        Name=map-public-ip-on-launch,Values=true \
      --query 'Subnets[0].SubnetId' \
      --output text
  )"

  [[ -n "${SUBNET_ID}" && "${SUBNET_ID}" != "None" ]] || {
    echo "ERROR: No public subnet found in default VPC"
    exit 1
  }

  echo "==> Using subnet ${SUBNET_ID}"
else
  echo "==> Using provided SUBNET_ID=${SUBNET_ID}"
fi

VPC_ID="$(
  awscli describe-subnets \
    --subnet-ids "${SUBNET_ID}" \
    --query 'Subnets[0].VpcId' \
    --output text
)"

# ============================================================
# SSH key
# ============================================================
SSH_DIR="${ROOT_DIR}/.ssh"
KEY_NAME="instance-mgmt-ec2-key"
KEY_PRIV="${SSH_DIR}/ec2_rsa"
KEY_PUB="${KEY_PRIV}.pub"

mkdir -p "${SSH_DIR}"
chmod 700 "${SSH_DIR}"

if [[ ! -f "${KEY_PRIV}" ]]; then
  echo "==> Generating EC2 SSH key"
  ssh-keygen -t rsa -b 4096 -N "" -f "${KEY_PRIV}"
fi

SSH_KEY_ABS="$(cd "$(dirname "${KEY_PRIV}")" && pwd)/$(basename "${KEY_PRIV}")"

awscli describe-key-pairs --key-names "${KEY_NAME}" >/dev/null 2>&1 || \
awscli import-key-pair \
  --key-name "${KEY_NAME}" \
  --public-key-material "fileb://${KEY_PUB}" >/dev/null

# ============================================================
# Userdata
# ============================================================
compose_userdata() {
  cat "${ROOT_DIR}/userdata/common.yaml" "$1"
}

SERVER_USERDATA="$(compose_userdata "${ROOT_DIR}/userdata/server.yaml" | base64 -w0)"
AGENT_USERDATA="$(compose_userdata "${ROOT_DIR}/userdata/agent.yaml" | base64 -w0)"

# ============================================================
# Security groups
# ============================================================
create_sg() {
  awscli create-security-group \
    --group-name "$1" \
    --description "$2" \
    --vpc-id "${VPC_ID}" \
    --tag-specifications \
      "ResourceType=security-group,Tags=[{Key=Name,Value=$1},{Key=owner,Value=swa}]" \
    --query 'GroupId' \
    --output text
}

SERVER_SG_ID="$(create_sg "${SERVER_NAME}-sg" "SWA server SG")"
AGENT_SG_ID="$(create_sg "${AGENT_NAME}-sg" "SWA agent SG")"

# ============================================================
# Create Agent
# ============================================================
echo "==> Creating agent EC2 instance: ${AGENT_NAME}"

AGENT_INSTANCE_ID="$(
  awscli run-instances \
    --image-id "${AMI_ID}" \
    --instance-type "${AGENT_INSTANCE_TYPE}" \
    --key-name "${KEY_NAME}" \
    --subnet-id "${SUBNET_ID}" \
    --security-group-ids "${AGENT_SG_ID}" \
    --user-data "${AGENT_USERDATA}" \
    ${AGENT_DISK_ARGS:+${AGENT_DISK_ARGS[@]}} \
    --tag-specifications \
      "ResourceType=instance,Tags=[{Key=Name,Value=${AGENT_NAME}},{Key=owner,Value=swa}]" \
    --query 'Instances[0].InstanceId' \
    --output text
)"

awscli wait instance-running --instance-ids "${AGENT_INSTANCE_ID}"

# ============================================================
# Create Server
# ============================================================
echo "==> Creating server EC2 instance: ${SERVER_NAME}"

SERVER_INSTANCE_ID="$(
  awscli run-instances \
    --image-id "${AMI_ID}" \
    --instance-type "${INSTANCE_TYPE}" \
    --key-name "${KEY_NAME}" \
    --subnet-id "${SUBNET_ID}" \
    --security-group-ids "${SERVER_SG_ID}" \
    --user-data "${SERVER_USERDATA}" \
    --tag-specifications \
      "ResourceType=instance,Tags=[{Key=Name,Value=${SERVER_NAME}},{Key=owner,Value=swa}]" \
    --query 'Instances[0].InstanceId' \
    --output text
)"

awscli wait instance-running --instance-ids "${SERVER_INSTANCE_ID}"

# ============================================================
# Capture IPs
# ============================================================
AGENT_IP="$(awscli describe-instances \
  --instance-ids "${AGENT_INSTANCE_ID}" \
  --query 'Reservations[0].Instances[0].PrivateIpAddress' \
  --output text)"

AGENT_PUBLIC_IP="$(awscli describe-instances \
  --instance-ids "${AGENT_INSTANCE_ID}" \
  --query 'Reservations[0].Instances[0].PublicIpAddress' \
  --output text)"

SERVER_IP="$(awscli describe-instances \
  --instance-ids "${SERVER_INSTANCE_ID}" \
  --query 'Reservations[0].Instances[0].PrivateIpAddress' \
  --output text)"

SERVER_PUBLIC_IP="$(awscli describe-instances \
  --instance-ids "${SERVER_INSTANCE_ID}" \
  --query 'Reservations[0].Instances[0].PublicIpAddress' \
  --output text)"

# ============================================================
# Write env
# ============================================================
ENV_FILE="${ROOT_DIR}/aws-instances.env"

cat > "${ENV_FILE}" <<EOF
export PROVIDER="aws"

export AWS_PROFILE="${AWS_PROFILE}"
export AWS_REGION="${AWS_REGION}"

export SERVER_NAME="${SERVER_NAME}"
export SERVER_IP="${SERVER_IP}"
export SERVER_PUBLIC_IP="${SERVER_PUBLIC_IP}"

export AGENT_NAME="${AGENT_NAME}"
export AGENT_IP="${AGENT_IP}"
export AGENT_PUBLIC_IP="${AGENT_PUBLIC_IP}"

export SERVER_SECURITY_GROUP_ID="${SERVER_SG_ID}"
export AGENT_SECURITY_GROUP_ID="${AGENT_SG_ID}"

export SSH_USER="${SSH_USER}"
export SSH_KEY_NAME="${KEY_NAME}"
export SSH_KEY_PRIVATE="${SSH_KEY_ABS}"
EOF

# ---------- Lock down ingress ----------
echo "==> Restricting SSH access to local IP"
LOCAL_CIDR="$(curl -fsS https://ifconfig.me)/32"
"${SCRIPT_DIR}/ec2-allow.sh" "${LOCAL_CIDR}"

# ---------- SSH quick access ----------
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
