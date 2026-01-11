#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

PROVIDER="${1:-}"
shift || true

case "${PROVIDER}" in
  multipass)
    "${SCRIPT_DIR}/multipass/create-multipass-vm.sh" "$@"
    ;;
  aws)
    "${SCRIPT_DIR}/aws/create-aws-vm.sh" "$@"
    ;;
  gcp)
    "${SCRIPT_DIR}/gcp/create-gcp-vm.sh" "$@"
    ;;
  *)
    echo "Usage:"
    echo "  $0 multipass"
    echo "  $0 aws [--ai]"
    echo "  $0 gcp [--ai]"
    exit 1
    ;;
esac
