#!/usr/bin/env bash
set -euo pipefail

# ------------------------------------------------------------
# Cleanup EC2 instances and security groups created by this repo
# Scoped strictly to instances.env
# ------------------------------------------------------------

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"


INSTANCES_ENV="${ROOT_DIR}/ec2-instances.env"

[[ -f "${INSTANCES_ENV}" ]] || {
  echo "ERROR: ec2-instances.env not found. Nothing to clean up."
  exit 1
}

# shellcheck disable=SC1090
source "${INSTANCES_ENV}"

: "${AWS_REGION:?Missing AWS_REGION in ${INSTANCES_ENV}}"
: "${AWS_PROFILE:?Missing AWS_PROFILE in ${INSTANCES_ENV}}"
: "${SERVER_INSTANCE_ID:?Missing SERVER_INSTANCE_ID in ${INSTANCES_ENV}}"
: "${SERVER_SECURITY_GROUP_ID:?Missing SERVER_SECURITY_GROUP_ID in ${INSTANCES_ENV}}"
: "${AGENT_SECURITY_GROUP_ID:?Missing AGENT_SECURITY_GROUP_ID in ${INSTANCES_ENV}}"

aws --profile "${AWS_PROFILE}" sts get-caller-identity >/dev/null 2>&1 || {
  echo "ERROR: AWS CLI not authenticated"
  exit 1
}

aws_ec2() {
  aws ec2 --region "${AWS_REGION}" --profile "${AWS_PROFILE}" "$@"
}

echo "==> Destroying EC2 instances (using ${INSTANCES_ENV})"

# ------------------------------------------------------------
# Terminate instances
# ------------------------------------------------------------
echo "--> Terminating server: ${SERVER_INSTANCE_ID}"
aws_ec2 terminate-instances \
  --instance-ids "${SERVER_INSTANCE_ID}" >/dev/null

if [[ -n "${AGENT_INSTANCE_IDS[*]:-}" ]]; then
  echo "--> Terminating agents: ${AGENT_INSTANCE_IDS[*]}"
  aws_ec2 terminate-instances \
    --instance-ids "${AGENT_INSTANCE_IDS[@]}" >/dev/null
fi

# ------------------------------------------------------------
# Wait for termination
# ------------------------------------------------------------
echo "==> Waiting for instances to terminate"

IDS_TO_WAIT=("${SERVER_INSTANCE_ID}")
if [[ -n "${AGENT_INSTANCE_IDS[*]:-}" ]]; then
  IDS_TO_WAIT+=("${AGENT_INSTANCE_IDS[@]}")
fi

aws_ec2 wait instance-terminated \
  --instance-ids "${IDS_TO_WAIT[@]}"

# ------------------------------------------------------------
# Delete security groups
# ------------------------------------------------------------
echo "==> Deleting security groups"

echo "--> Deleting server SG: ${SERVER_SECURITY_GROUP_ID}"
aws_ec2 delete-security-group \
  --group-id "${SERVER_SECURITY_GROUP_ID}" 

echo "--> Deleting agent SG: ${AGENT_SECURITY_GROUP_ID}"
aws_ec2 delete-security-group \
  --group-id "${AGENT_SECURITY_GROUP_ID}"

echo "==> EC2 cleanup complete"
