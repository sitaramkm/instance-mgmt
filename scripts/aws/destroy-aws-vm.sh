#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"
ENV_FILE="${ROOT_DIR}/instances.env"

[[ -f "${ENV_FILE}" ]] || {
  echo "ERROR: ${ENV_FILE} not found. Nothing to clean up."
  exit 1
}

# shellcheck disable=SC1090
source "${ENV_FILE}"

aws_ec2() {
  aws ec2 --region "${AWS_REGION}" --profile "${AWS_PROFILE}" "$@"
}

echo "==> Destroying EC2 instances from instances.env"

if [[ -n "${SERVER_INSTANCE_ID:-}" ]]; then
  echo "--> Terminating server: ${SERVER_INSTANCE_ID}"
  aws_ec2 terminate-instances --instance-ids "${SERVER_INSTANCE_ID}" >/dev/null
fi

if [[ -n "${AGENT_INSTANCE_IDS[*]:-}" ]]; then
  echo "--> Terminating agents: ${AGENT_INSTANCE_IDS[*]}"
  aws_ec2 terminate-instances --instance-ids "${AGENT_INSTANCE_IDS[@]}" >/dev/null
fi

echo "==> Waiting for termination"
aws_ec2 wait instance-terminated \
  --instance-ids "${SERVER_INSTANCE_ID}" "${AGENT_INSTANCE_IDS[@]}" 2>/dev/null || true

echo "==> Cleanup complete"
