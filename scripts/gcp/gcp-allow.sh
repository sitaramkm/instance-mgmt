#!/usr/bin/env bash
set -euo pipefail

RAW_INPUT="${1:?Usage: gcp-allow.sh <ip-or-cidr>}"

ROOT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
ENV_FILE="${ROOT_DIR}/gcp-instances.env"

[[ -f "${ENV_FILE}" ]] || {
  echo "ERROR: gcp-instances.env not found"
  exit 1
}

# shellcheck disable=SC1090
source "${ENV_FILE}"

: "${GCP_PROJECT_ID:?Missing GCP_PROJECT_ID in gcp-instances.env}"

command -v gcloud >/dev/null || {
  echo "ERROR: gcloud not installed"
  exit 1
}

gcloud auth list --filter=status:ACTIVE --format="value(account)" | grep -q . || {
  echo "ERROR: gcloud not authenticated"
  exit 1
}

SERVER_TAG="${SERVER_NETWORK_TAG:-swa-server}"
AGENT_TAG="${AGENT_NETWORK_TAG:-swa-agent}"

# ---------- Normalize IP/CIDR ----------
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
  for o in "$a" "$b" "$c" "$d"; do
    ((o >= 0 && o <= 255)) || {
      echo "ERROR: Invalid IP address: ${input}"
      exit 1
    }
  done

  echo "${input}/32"
}

sanitize_cidr_for_name() {
  echo "$1" | tr '/.' '-' | tr '[:upper:]' '[:lower:]'
}

CIDR="$(normalize_cidr "${RAW_INPUT}")"

echo "==> Applying GCP firewall rules for ${CIDR}"
echo "--> Tags: server='${SERVER_TAG}', agent='${AGENT_TAG}'"

RULE_NAME="swa-allow-$(sanitize_cidr_for_name "${CIDR}")"

# ---------- SSH + agent access ----------
if gcloud compute firewall-rules describe "${RULE_NAME}" \
  --project="${GCP_PROJECT_ID}" >/dev/null 2>&1; then
  echo "--> Firewall rule already exists: ${RULE_NAME}"
else
  gcloud compute firewall-rules create "${RULE_NAME}" \
    --project="${GCP_PROJECT_ID}" \
    --direction=INGRESS \
    --priority=1000 \
    --network=default \
    --action=ALLOW \
    --rules=tcp:22,tcp:11434 \
    --source-ranges="${CIDR}" \
    --target-tags="${SERVER_TAG},${AGENT_TAG}" \
    --description="managed-by=swa"
  echo "==> Firewall rule created: ${RULE_NAME}"
fi

# ---------- Agent -> Server (8081) ----------
AGENT_SERVER_RULE="swa-agent-to-server-8081"

if gcloud compute firewall-rules describe "${AGENT_SERVER_RULE}" \
  --project="${GCP_PROJECT_ID}" >/dev/null 2>&1; then
  echo "--> Agent->server rule already exists: tcp/8081"
else
  echo "--> Creating agent->server rule: tcp/8081"

  gcloud compute firewall-rules create "${AGENT_SERVER_RULE}" \
    --project="${GCP_PROJECT_ID}" \
    --direction=INGRESS \
    --priority=1000 \
    --network=default \
    --action=ALLOW \
    --rules=tcp:8081 \
    --source-tags="${AGENT_TAG}" \
    --target-tags="${SERVER_TAG}" \
    --description="managed-by=swa"
fi

echo "==> Allowed IP/CIDR: ${CIDR}"
echo "==> Completed GCP firewall configuration"