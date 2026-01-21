#!/usr/bin/env bash
set -euo pipefail

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

# ---------- Terminate instances ----------
echo "==> Terminating EC2 instances"

INSTANCE_IDS=()

collect_instance_ids() {
  local NAME="$1"
  awscli describe-instances \
    --filters "Name=tag:Name,Values=${NAME}" \
    --query 'Reservations[*].Instances[*].InstanceId' \
    --output text
}

INSTANCE_IDS+=( $(collect_instance_ids "${AGENT_NAME}") )
INSTANCE_IDS+=( $(collect_instance_ids "${SERVER_NAME}") )

if [[ "${#INSTANCE_IDS[@]}" -gt 0 ]]; then
  echo "--> Terminating instances: ${INSTANCE_IDS[*]}"
  awscli terminate-instances --instance-ids "${INSTANCE_IDS[@]}"
else
  echo "--> No instances found to terminate"
fi

# ---------- Wait for termination ----------
if [[ "${#INSTANCE_IDS[@]}" -gt 0 ]]; then
  echo "==> Waiting for EC2 instances to fully terminate"
  awscli wait instance-terminated --instance-ids "${INSTANCE_IDS[@]}"
fi

# ---------- Delete security groups (retry-aware) ----------
echo "==> Deleting security groups"

delete_sg_with_retry() {
  local SG_ID="$1"
  local retries=12
  local delay=5

  for ((i=1; i<=retries; i++)); do
    ERR="$(
      awscli delete-security-group \
        --group-id "${SG_ID}" 2>&1 >/dev/null || true
    )"

    # Success
    if [[ -z "${ERR}" ]]; then
      echo "--> Deleted security group: ${SG_ID}"
      return 0
    fi

    # Already deleted = success (idempotent)
    if echo "${ERR}" | grep -q "InvalidGroup.NotFound"; then
      echo "--> Security group ${SG_ID} already deleted"
      return 0
    fi

    # Still attached → retry
    if echo "${ERR}" | grep -q "DependencyViolation"; then
      echo "--> SG ${SG_ID} still in use (attempt ${i}/${retries}), retrying in ${delay}s"
      sleep "${delay}"
      continue
    fi

    # Anything else is a real error
    echo "ERROR: Failed to delete security group ${SG_ID}"
    echo "${ERR}"
    return 1
  done

  echo "ERROR: Timed out deleting security group ${SG_ID}"
  return 1
}


for sg in "${AGENT_SECURITY_GROUP_ID:-}" "${SERVER_SECURITY_GROUP_ID:-}"; do
  [[ -n "${sg}" ]] && delete_sg_with_retry "${sg}"
done

echo "==> AWS cleanup complete"

