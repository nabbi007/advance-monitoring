#!/usr/bin/env bash
###############################################################################
# cleanup.sh — Tear down all resources
#
# Usage:
#   ./scripts/cleanup.sh
###############################################################################
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
TERRAFORM_DIR="$PROJECT_DIR/terraform"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log()  { echo -e "${GREEN}[cleanup]${NC} $*"; }
warn() { echo -e "${YELLOW}[cleanup]${NC} $*"; }
err()  { echo -e "${RED}[cleanup]${NC} $*" >&2; }

echo -e "${YELLOW}"
echo "=========================================="
echo " WARNING: This will destroy ALL resources"
echo "=========================================="
echo -e "${NC}"
read -rp "Are you sure? (yes/no): " CONFIRM

if [[ "$CONFIRM" != "yes" ]]; then
  warn "Aborted."
  exit 0
fi

cd "$TERRAFORM_DIR"

if [[ ! -f terraform.tfstate ]]; then
  warn "No Terraform state found. Nothing to destroy."
  exit 0
fi

log "Destroying Terraform resources..."
terraform destroy -auto-approve

log "Cleaning up local temp files..."
rm -f /tmp/voting-app.tar.gz /tmp/prometheus.yml

log "=========================================="
log " All resources destroyed."
log "=========================================="
