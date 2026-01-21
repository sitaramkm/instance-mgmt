#!/usr/bin/env bash
set -euo pipefail

RAW_INPUT="${1:?Usage: ./scripts/aws/ec2-allow.sh <ip-or-cidr>}"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"
ENV_FILE="${ROOT_DIR}/aws-instances.env"

[[ -f "${ENV_FILE}" ]] || {
  echo "ERROR: ${ENV_FILE} not found"
  exit 1
}

# shellcheck disable=SC1090
source "${ENV_FILE}"
: "${AWS_PROFILE:?Missing AWS_PROFILE in ${ENV_FILE}}"
: "${AWS_REGION:?Missing AWS_REGION in ${ENV_FILE}}"
: "${SERVER_SECURITY_GROUP_ID:?Missing SERVER_SECURITY_GROUP_ID}"
: "${AGENT_SECURITY_GROUP_ID:?Missing AGENT_SECURITY_GROUP_ID}"

command -v aws >/dev/null || {
  echo "ERROR: aws cli not installed"
  exit 1
}

aws --profile "${AWS_PROFILE}" sts get-caller-identity >/dev/null || {
  echo "ERROR: AWS CLI not authenticated"
  exit 1
}

awscli() {
 aws ec2 --region "${AWS_REGION}" --profile "${AWS_PROFILE}" "$@"
}

# ---------- Normalize IP / CIDR ----------
normalize_cidr() {
  local input="$1"

  if [[ "${input}" == */* ]]; then
    echo "${input}"
    return
  fi

  if [[ ! "${input}" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
    echo "ERROR: Invalid IP address: ${input}"
    exit 1
  fi

  IFS='.' read -r a b c d <<< "${input}"
  for octet in "$a" "$b" "$c" "$d"; do
    ((octet >= 0 && octet <= 255)) || {
      echo "ERROR: Invalid IP address: ${input}"
      exit 1
    }
  done

  echo "${input}/32"
}

CIDR="$(normalize_cidr "${RAW_INPUT}")"
echo "==> Applying ingress for ${CIDR}"

SERVER_SG="${SERVER_SECURITY_GROUP_ID}"
AGENT_SG="${AGENT_SECURITY_GROUP_ID}"

echo "--> Server SG: ${SERVER_SG}"
echo "--> Agent  SG: ${AGENT_SG}"

# ---------- Helper: CIDR ingress ----------
apply_cidr_rule() {
  local sg="$1"
  local port="$2"

  local err=""
  err="$(awscli authorize-security-group-ingress \
    --group-id "${sg}" \
    --protocol tcp \
    --port "${port}" \
    --cidr "${CIDR}" 2>&1 >/dev/null || true)"

  if [[ -z "${err}" ]]; then
    echo "--> Added ${sg}: tcp/${port} from ${CIDR}"
    return
  fi

  if echo "${err}" | grep -qi "InvalidPermission.Duplicate"; then
    echo "--> Already present ${sg}: tcp/${port} from ${CIDR}"
    return
  fi

  echo "ERROR: Failed to add rule to ${sg} port ${port}"
  echo "${err}"
  exit 1
}

# ---------- Helper: SG → SG ----------
authorize_sg_to_sg() {
  local target_sg="$1"
  local source_sg="$2"
  local port="$3"

  local err=""
  err="$(awscli authorize-security-group-ingress \
    --group-id "${target_sg}" \
    --ip-permissions "IpProtocol=tcp,FromPort=${port},ToPort=${port},UserIdGroupPairs=[{GroupId=${source_sg}}]" \
    2>&1 >/dev/null || true)"

  if [[ -z "${err}" ]]; then
    echo "--> Added SG->SG rule: tcp/${port} (${source_sg} → ${target_sg})"
    return
  fi

  if echo "${err}" | grep -qi "InvalidPermission.Duplicate"; then
    echo "--> SG->SG rule already present: tcp/${port}"
    return
  fi

  echo "ERROR: Failed to add SG->SG rule tcp/${port}"
  echo "${err}"
  exit 1
}

# ---------- Apply ingress ----------
# SSH from local IP
apply_cidr_rule "${SERVER_SG}" 22
apply_cidr_rule "${AGENT_SG}" 22

# Agent-only service (example: Ollama)
apply_cidr_rule "${AGENT_SG}" 11434

# Agent → Server internal API
authorize_sg_to_sg "${SERVER_SG}" "${AGENT_SG}" 8081

echo "==> Ingress rules successfully applied"
