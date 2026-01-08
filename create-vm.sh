#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")" && pwd)"
SCRIPT_DIR="${ROOT_DIR}/scripts"

PROVIDER="${1:-}"
shift || true

case "${PROVIDER}" in
  multipass)
    "${SCRIPT_DIR}/multipass/create-multipass-vm.sh" "$@"
    ;;
  aws)
    "${SCRIPT_DIR}/aws/create-aws-vm.sh" "$@"
    ;;
  *)
    echo "Usage:"
    echo "  $0 multipass"
    echo "  $0 aws [--ai]"
    exit 1
    ;;
esac
