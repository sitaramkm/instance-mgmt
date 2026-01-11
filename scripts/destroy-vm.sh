#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

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
    echo "==> Cleaning up Multipass instances (scoped to mp-instances.env)"
    "${SCRIPT_DIR}/multipass/destroy-multipass-vm.sh"
    ;;
  aws)
    [[ "${FLAG:-}" == "--yes" ]] || confirm || exit 1
    echo "==> Cleaning up EC2 instances (scoped to ec2-instances.env)"
    "${SCRIPT_DIR}/aws/destroy-aws-vm.sh"
    ;;
  gcp)
    [[ "${FLAG:-}" == "--yes" ]] || confirm || exit 1
    echo "==> Cleaning up GCP instances (scoped to gcp-instances.env)"
    "${SCRIPT_DIR}/gcp/destroy-gcp-vm.sh"
    ;;

  *)
    echo "Usage:"
    echo "  $0 multipass [--yes]"
    echo "  $0 aws [--yes]"
    echo "  $0 gcp [--yes]"
    exit 1
    ;;
esac
