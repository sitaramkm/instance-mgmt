#!/usr/bin/env bash
set -euo pipefail

IP="${1:?Usage: ./install-ollama.sh <agent-ip>}"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="${SCRIPT_DIR}"
ENV_FILE="${ROOT_DIR}/instances.env"

# ---------- Pre-flight ----------
[[ -f "${ENV_FILE}" ]] || {
  echo "ERROR: ${ENV_FILE} not found. Run create-vm first."
  exit 1
}

# shellcheck disable=SC1090
source "${ENV_FILE}"

[[ -f "${SSH_KEY_PRIVATE}" ]] || {
  echo "ERROR: SSH key not found at ${SSH_KEY_PRIVATE}"
  exit 1
}

echo "==> Installing Ollama on agent ${IP}"

ssh -i "${SSH_KEY_PRIVATE}" -t \
  -o StrictHostKeyChecking=no \
  "${SSH_USER}@${IP}" \
  bash -s <<'EOF'
set -euo pipefail

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
echo "Agent IP: ${IP}"
echo "Local API endpoint:"
echo "  http://${IP}:11434"
echo
echo "Test:"
echo "  curl http://${IP}:11434/api/tags"
echo "================================================"
