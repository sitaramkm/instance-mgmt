#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")" && pwd)"
SCRIPT_DIR="${ROOT_DIR}/scripts"

TARGET="${1:-}"
FLAG="${2:-}"

confirm() {
  echo
  echo "⚠️  You are about to DESTROY infrastructure created by this repo."
  echo "    This action is NOT reversible."
  echo
  read -r -p "Type 'yes' to continue: " answer
  [[ "${answer}" == "yes" ]]
}

case "${TARGET}" in
  multipass)
    [[ "${FLAG:-}" == "--yes" ]] || confirm || exit 1
    echo "==> Cleaning up Multipass instances (scoped to instances.env)"
    "${SCRIPT_DIR}/multipass/destroy-multipass-vm.sh"
    ;;
  aws)
    [[ "${FLAG:-}" == "--yes" ]] || confirm || exit 1
    echo "==> Cleaning up EC2 instances (scoped to instances.env)"
    "${SCRIPT_DIR}/aws/destroy-aws-vm.sh"
    ;;
  *)
    echo "Usage:"
    echo "  $0 multipass [--yes]"
    echo "  $0 aws [--yes]"
    exit 1
    ;;
esac
