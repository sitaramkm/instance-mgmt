#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
ENV_FILE="${ROOT_DIR}/gcp-instances.env"

# shellcheck disable=SC1090
source "${ENV_FILE}"

for name in "${SERVER_NAME}" "${AGENT_NAMES[@]}"; do
  gcloud compute instances delete "${name}" \
    --zone="${GCP_ZONE}" \
    --quiet || true
done

echo "==> GCP cleanup complete"
