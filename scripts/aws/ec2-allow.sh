#!/usr/bin/env bash
set -euo pipefail

CIDR="${1:?Usage: ./scripts/aws/ec2-allow.sh <ip-or-cidr>}"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"
ENV_FILE="${ROOT_DIR}/instances.env"
COMMON_ENV="${ROOT_DIR}/common.env"

[[ -f "${ENV_FILE}" ]] || {
  echo "ERROR: ${ENV_FILE} not found. Nothing to allow."
  exit 1
}

[[ -f "${COMMON_ENV}" ]] || {
  echo "ERROR: common.env not found."
  exit 1
}

# shellcheck disable=SC1090
source "${COMMON_ENV}"
# shellcheck disable=SC1090
source "${ENV_FILE}"

# ---------- AWS CLI sanity check ----------
aws --profile "${AWS_PROFILE}" sts get-caller-identity >/dev/null 2>&1 || {
  echo "ERROR: AWS CLI is not authenticated."
  echo "Run: aws configure or aws sso login"
  exit 1
}

aws_ec2() {
  aws ec2 --region "${AWS_REGION}" --profile "${AWS_PROFILE}" "$@"
}

find_default_vpc() {
  aws_ec2 describe-vpcs \
    --filters Name=isDefault,Values=true \
    --query 'Vpcs[0].VpcId' \
    --output text
}

get_sg_id() {
  local name="$1" vpc="$2"
  aws_ec2 describe-security-groups \
    --filters Name=group-name,Values="${name}" Name=vpc-id,Values="${vpc}" \
    --query 'SecurityGroups[0].GroupId' \
    --output text
}

allow_ingress() {
  local sg="$1" port="$2"
  aws_ec2 authorize-security-group-ingress \
    --group-id "${sg}" \
    --protocol tcp \
    --port "${port}" \
    --cidr "${CIDR}" >/dev/null 2>&1 || true
}

echo "==> Applying ingress for ${CIDR}"

VPC_ID="$(find_default_vpc)"
SERVER_SG="$(get_sg_id "${SERVER_NAME}-sg" "${VPC_ID}")"
AGENT_SG="$(get_sg_id "${AGENT_NAME_PREFIX}-sg" "${VPC_ID}")"

echo "--> Server SG: ${SERVER_SG}"
echo "--> Agent  SG: ${AGENT_SG}"

# SSH (server + agents)
allow_ingress "${SERVER_SG}" 22
allow_ingress "${AGENT_SG}" 22

# (agents only)
allow_ingress "${AGENT_SG}" 11434

echo "==> Ingress rules applied successfully"
