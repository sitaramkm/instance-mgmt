#!/usr/bin/env bash
set -euo pipefail

PROVIDER="${1:?Usage: install-llm.sh <aws|gcp|azure>}"

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"

case "${PROVIDER}" in
  aws)   ENV_FILE="${ROOT_DIR}/aws-instances.env" ;;
  gcp)   ENV_FILE="${ROOT_DIR}/gcp-instances.env" ;;
  azure) ENV_FILE="${ROOT_DIR}/azure-instances.env" ;;
  *)
    echo "ERROR: Unknown provider: ${PROVIDER}"
    exit 1
    ;;
esac

[[ -f "${ENV_FILE}" ]] || {
  echo "ERROR: State file not found: ${ENV_FILE}"
  exit 1
}

# shellcheck disable=SC1090
source "${ENV_FILE}"

[[ -n "${AGENT_PUBLIC_IP}" ]] || {
  echo "ERROR: Invalid agent public ip for provider ${PROVIDER}"
  exit 1
}

echo "==> Installing LLM on ${PROVIDER} agent (${AGENT_PUBLIC_IP})"

ssh -i "${SSH_KEY_PRIVATE}" \
  -o StrictHostKeyChecking=no \
  "${SSH_USER}@${AGENT_PUBLIC_IP}" <<'EOF'
set -e
echo "==> Installing dependencies"
sudo apt update
sudo apt install -y curl ca-certificates

echo "==> Installing Ollama"
curl -fsSL https://ollama.com/install.sh | sh

echo "==> Enabling Ollama service"
sudo systemctl daemon-reload
sudo systemctl enable --now ollama

echo "==> Verifying Ollama"
ollama --version

echo "==> Pulling model (small, fast default)"
ollama pull llama3.1:8b

echo
echo "==> Ollama status:"
sudo systemctl status ollama --no-pager
EOF

echo
echo "================================================"
echo "Ollama installed successfully"
echo "Agent IP: ${AGENT_PUBLIC_IP}"
echo "Local API endpoint:"
echo "  http://${AGENT_PUBLIC_IP}:11434"
echo
echo "Test:"
echo "  curl http://${AGENT_PUBLIC_IP}:11434/api/tags"
echo "================================================"
