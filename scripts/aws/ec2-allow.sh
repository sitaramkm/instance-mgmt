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

authorize_sg_to_sg() {
  local target_sg="$1"     # SG receiving traffic (e.g., server SG)
  local source_sg="$2"     # SG allowed to send traffic (e.g., agent SG)
  local port="$3"          # e.g., 8081
  local proto="${4:-tcp}"  # default tcp

  [[ "${port}" =~ ^[0-9]+$ ]] || { echo "ERROR: port must be numeric: ${port}"; exit 1; }
  (( port >= 1 && port <= 65535 )) || { echo "ERROR: port out of range: ${port}"; exit 1; }

  local err=""
  err="$(aws_ec2 authorize-security-group-ingress \
    --group-id "${target_sg}" \
    --ip-permissions "IpProtocol=${proto},FromPort=${port},ToPort=${port},UserIdGroupPairs=[{GroupId=${source_sg}}]" \
    2>&1 >/dev/null || true)"

  if [[ -z "${err}" ]]; then
    echo "--> Added SG->SG rule: ${proto}/${port} (${source_sg} -> ${target_sg})"
    return
  fi

  # Idempotency: treat duplicates as success
  if echo "${err}" | grep -qi "InvalidPermission.Duplicate"; then
    echo "--> SG->SG rule already present: ${proto}/${port} (${source_sg} -> ${target_sg})"
    return
  fi

  echo "ERROR: Failed to add SG->SG rule: ${proto}/${port} (${source_sg} -> ${target_sg})"
  echo "${err}"
  exit 1
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

# Agents can reach server on 8081
authorize_sg_to_sg "${SERVER_SG}" "${AGENT_SG}" 8081 tcp

echo "==> Ingress rules successfully applied"
