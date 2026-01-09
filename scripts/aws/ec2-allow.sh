#!/usr/bin/env bash
set -euo pipefail

RAW_INPUT="${1:?Usage: ./scripts/aws/ec2-allow.sh <ip-or-cidr>}"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"
ENV_FILE="${ROOT_DIR}/ec2-instances.env"

[[ -f "${ENV_FILE}" ]] || { echo "ERROR: ${ENV_FILE} not found"; exit 1; }

# shellcheck disable=SC1090
source "${ENV_FILE}"

# ---------- AWS auth check ----------
aws --profile "${AWS_PROFILE}" sts get-caller-identity >/dev/null 2>&1 || {
  echo "ERROR: AWS CLI not authenticated"
  exit 1
}

aws_ec2() {
  aws ec2 --region "${AWS_REGION}" --profile "${AWS_PROFILE}" "$@"
}

# ---------- Normalize IP / CIDR ----------
normalize_cidr() {
  local input="$1"

  # If it already contains /, assume CIDR
  if [[ "${input}" == */* ]]; then
    echo "${input}"
    return
  fi

  # Validate IPv4
  if [[ ! "${input}" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
    echo "ERROR: Invalid IP address: ${input}"
    exit 1
  fi

  IFS='.' read -r a b c d <<< "${input}"
  for octet in "$a" "$b" "$c" "$d"; do
    if ((octet < 0 || octet > 255)); then
      echo "ERROR: Invalid IP address: ${input}"
      exit 1
    fi
  done

  echo "${input}/32"
}

CIDR="$(normalize_cidr "${RAW_INPUT}")"

echo "==> Applying ingress for ${CIDR}"

# ---------- Locate security groups ----------
VPC_ID="$(aws_ec2 describe-vpcs \
  --filters Name=isDefault,Values=true \
  --query 'Vpcs[0].VpcId' \
  --output text)"

SERVER_SG="$(aws_ec2 describe-security-groups \
  --filters Name=group-name,Values="${SERVER_NAME}-sg" Name=vpc-id,Values="${VPC_ID}" \
  --query 'SecurityGroups[0].GroupId' \
  --output text)"

AGENT_SG="$(aws_ec2 describe-security-groups \
  --filters Name=group-name,Values="${AGENT_NAME_PREFIX}-sg" Name=vpc-id,Values="${VPC_ID}" \
  --query 'SecurityGroups[0].GroupId' \
  --output text)"

echo "--> Server SG: ${SERVER_SG}"
echo "--> Agent  SG: ${AGENT_SG}"

# ---------- Apply ingress (fail on error) ----------
apply_rule() {
  local sg="$1"
  local port="$2"

  aws_ec2 authorize-security-group-ingress \
    --group-id "${sg}" \
    --protocol tcp \
    --port "${port}" \
    --cidr "${CIDR}" || {
      echo "ERROR: Failed to add rule to ${sg} port ${port}"
      exit 1
    }
}

# SSH
apply_rule "${SERVER_SG}" 22
apply_rule "${AGENT_SG}" 22

# Ollama (agents only)
apply_rule "${AGENT_SG}" 11434

echo "==> Ingress rules successfully applied"
