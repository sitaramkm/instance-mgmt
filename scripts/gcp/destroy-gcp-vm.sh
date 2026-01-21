#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"
ENV_FILE="${ROOT_DIR}/gcp-instances.env"

[[ -f "${ENV_FILE}" ]] || {
  echo "ERROR: ${ENV_FILE} not found"
  exit 1
}

# shellcheck disable=SC1090
source "${ENV_FILE}"

command -v gcloud >/dev/null || {
  echo "ERROR: gcloud not installed"
  exit 1
}

gcloud auth list --filter=status:ACTIVE --format="value(account)" | grep -q . || {
  echo "ERROR: gcloud not authenticated"
  exit 1
}

: "${GCP_PROJECT_ID:?Missing GCP_PROJECT_ID}"

# ---------- Delete VMs ----------
echo "==> Deleting GCP VMs"

if [[ -n "${GCP_ZONE:-}" ]]; then
  gcloud compute instances delete "${AGENT_NAME}" \
    --project="${GCP_PROJECT_ID}" \
    --zone="${GCP_ZONE}" \
    --quiet || true

  gcloud compute instances delete "${SERVER_NAME}" \
    --project="${GCP_PROJECT_ID}" \
    --zone="${GCP_ZONE}" \
    --quiet || true
else
  for ZONE in $(gcloud compute zones list \
    --project="${GCP_PROJECT_ID}" \
    --format='value(name)'); do
    gcloud compute instances delete "${AGENT_NAME}" --zone="${ZONE}" --quiet || true
    gcloud compute instances delete "${SERVER_NAME}" --zone="${ZONE}" --quiet || true
  done
fi

# ---------- Delete firewall rules ----------
echo "==> Cleaning up GCP firewall rules (swa-managed)"

RULES="$(
  gcloud compute firewall-rules list \
    --project="${GCP_PROJECT_ID}" \
    --filter="name~^swa-" \
    --format='value(name)'
)"

if [[ -z "${RULES}" ]]; then
  echo "--> No swa-managed firewall rules found"
else
  for rule in ${RULES}; do
    echo "--> Deleting firewall rule: ${rule}"
    gcloud compute firewall-rules delete "${rule}" \
      --project="${GCP_PROJECT_ID}" \
      --quiet || true
  done
fi

echo "==> GCP cleanup complete"
