#!/usr/bin/env bash
###############################################################################
# deploy.sh — Full Infrastructure & Application Deployment
#
# Usage:
#   ./scripts/deploy.sh                  # Full deploy (Terraform + Ansible)
#   ./scripts/deploy.sh --skip-terraform # Ansible only (infra already up)
#   ./scripts/deploy.sh --skip-ansible   # Terraform only
#   ./scripts/deploy.sh --tags app       # Deploy only app-tagged roles
#
# Workflow:
#   1. Validate prerequisites (terraform, ansible, ssh key)
#   2. Terraform apply (provisions EC2 infrastructure)
#   3. Generate Ansible inventory from Terraform outputs
#   4. Wait for instances to accept SSH
#   5. Run Ansible playbooks (configures everything)
#   6. Verify health endpoints
###############################################################################
set -euo pipefail

# ── Constants ───────────────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
TERRAFORM_DIR="$PROJECT_DIR/terraform"
ANSIBLE_DIR="$PROJECT_DIR/ansible"
INVENTORY_FILE="$ANSIBLE_DIR/inventory/hosts.ini"

# ── Defaults ────────────────────────────────────────────────────────────────
SKIP_TERRAFORM=false
SKIP_ANSIBLE=false
ANSIBLE_TAGS=""
ANSIBLE_EXTRA_ARGS=""

# ── Colors ──────────────────────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

# ── Logging ─────────────────────────────────────────────────────────────────
log()     { echo -e "${GREEN}[deploy]${NC} $*"; }
warn()    { echo -e "${YELLOW}[warn]${NC}  $*"; }
err()     { echo -e "${RED}[error]${NC} $*" >&2; }
section() { echo -e "\n${CYAN}${BOLD}━━━ $* ━━━${NC}"; }

# ── Cleanup ─────────────────────────────────────────────────────────────────
cleanup() {
  local exit_code=$?
  if [[ $exit_code -ne 0 ]]; then
    err "Deployment failed with exit code $exit_code"
    err "Check logs above for details."
  fi
  # Remove temp files
  rm -f /tmp/tfplan 2>/dev/null || true
  exit $exit_code
}
trap cleanup EXIT

# ── Argument Parsing ────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
  case "$1" in
    --skip-terraform) SKIP_TERRAFORM=true; shift ;;
    --skip-ansible)   SKIP_ANSIBLE=true; shift ;;
    --tags)           ANSIBLE_TAGS="$2"; shift 2 ;;
    --limit)          ANSIBLE_EXTRA_ARGS="$ANSIBLE_EXTRA_ARGS --limit $2"; shift 2 ;;
    -v|-vv|-vvv)      ANSIBLE_EXTRA_ARGS="$ANSIBLE_EXTRA_ARGS $1"; shift ;;
    -h|--help)
      echo "Usage: $0 [OPTIONS]"
      echo ""
      echo "Options:"
      echo "  --skip-terraform   Skip Terraform, run Ansible only"
      echo "  --skip-ansible     Skip Ansible, run Terraform only"
      echo "  --tags TAGS        Comma-separated Ansible tags to run"
      echo "  --limit GROUP      Limit Ansible to specific host group"
      echo "  -v, -vv, -vvv     Increase Ansible verbosity"
      echo "  -h, --help         Show this help"
      exit 0
      ;;
    *)
      err "Unknown option: $1"
      exit 1
      ;;
  esac
done

# ── Prerequisites Check ────────────────────────────────────────────────────
section "Checking Prerequisites"

check_command() {
  if ! command -v "$1" &>/dev/null; then
    err "$1 is not installed. $2"
    exit 1
  fi
  log "$1 $(command "$1" --version 2>&1 | head -1 || true)"
}

[[ "$SKIP_TERRAFORM" == false ]] && check_command terraform "Install from https://terraform.io"
[[ "$SKIP_ANSIBLE" == false ]]   && check_command ansible-playbook "Install with: pip install ansible"
check_command ssh "OpenSSH client is required"

# ── 1. Terraform ────────────────────────────────────────────────────────────
if [[ "$SKIP_TERRAFORM" == false ]]; then
  section "Terraform — Provisioning Infrastructure"
  cd "$TERRAFORM_DIR"

  if [[ ! -f terraform.tfvars ]]; then
    err "terraform.tfvars not found."
    err "Copy terraform.tfvars.example and fill in values:"
    err "  cp terraform.tfvars.example terraform.tfvars"
    exit 1
  fi

  log "Initializing..."
  terraform init -upgrade -input=false

  log "Validating..."
  terraform validate

  log "Planning..."
  terraform plan -out=/tmp/tfplan -input=false

  log "Applying..."
  terraform apply -input=false /tmp/tfplan

  log "Terraform apply complete."
fi

# ── 2. Extract Terraform Outputs ────────────────────────────────────────────
section "Reading Terraform Outputs"
cd "$TERRAFORM_DIR"

APP_PUBLIC_IP=$(terraform output -raw app_instance_public_ip)
APP_PRIVATE_IP=$(terraform output -raw app_instance_private_ip)
OBS_PUBLIC_IP=$(terraform output -raw observability_instance_public_ip)
OBS_PRIVATE_IP=$(terraform output -raw observability_instance_private_ip)
KEY_NAME=$(terraform output -raw key_name 2>/dev/null || grep key_name terraform.tfvars | awk -F'"' '{print $2}')

SSH_KEY="${SSH_KEY_PATH:-$HOME/.ssh/${KEY_NAME}.pem}"

log "App Instance:           ${BOLD}$APP_PUBLIC_IP${NC} (private: $APP_PRIVATE_IP)"
log "Observability Instance: ${BOLD}$OBS_PUBLIC_IP${NC} (private: $OBS_PRIVATE_IP)"
log "SSH Key:                $SSH_KEY"

if [[ ! -f "$SSH_KEY" ]]; then
  err "SSH key not found at: $SSH_KEY"
  err "Set SSH_KEY_PATH environment variable or place key at the expected path."
  exit 1
fi

# ── 3. Generate Ansible Inventory ───────────────────────────────────────────
section "Generating Ansible Inventory"

mkdir -p "$(dirname "$INVENTORY_FILE")"
cat > "$INVENTORY_FILE" << EOF
# Auto-generated by deploy.sh — $(date -u '+%Y-%m-%dT%H:%M:%SZ')
# Do not edit manually; re-run deploy.sh to regenerate.

[app]
app-01 ansible_host=${APP_PUBLIC_IP} private_ip=${APP_PRIVATE_IP}

[observability]
obs-01 ansible_host=${OBS_PUBLIC_IP} private_ip=${OBS_PRIVATE_IP}

[all:vars]
ansible_user=ubuntu
ansible_ssh_private_key_file=${SSH_KEY}
ansible_ssh_common_args=-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null

# Cross-instance connectivity (private IPs for internal traffic)
app_private_ip=${APP_PRIVATE_IP}
observability_private_ip=${OBS_PRIVATE_IP}
EOF

log "Inventory written to: $INVENTORY_FILE"

# ── 4. Wait for SSH ─────────────────────────────────────────────────────────
section "Waiting for Instances"

wait_for_ssh() {
  local host="$1" name="$2" max_attempts="${3:-30}"
  log "Waiting for $name ($host) to accept SSH..."
  for i in $(seq 1 "$max_attempts"); do
    if ssh -o StrictHostKeyChecking=no -o ConnectTimeout=10 \
           -o BatchMode=yes -i "$SSH_KEY" ubuntu@"$host" \
           "echo ready" &>/dev/null; then
      log "$name is reachable. (attempt $i)"
      return 0
    fi
    printf "."
    sleep 10
  done
  echo ""
  err "$name ($host) did not become reachable within $((max_attempts * 10))s."
  exit 1
}

wait_for_cloud_init() {
  local host="$1" name="$2"
  log "Waiting for cloud-init to finish on $name..."
  ssh -o StrictHostKeyChecking=no -o ConnectTimeout=10 \
      -i "$SSH_KEY" ubuntu@"$host" \
      "cloud-init status --wait" 2>/dev/null || true
  log "$name cloud-init complete."
}

wait_for_ssh "$APP_PUBLIC_IP" "App Instance"
wait_for_ssh "$OBS_PUBLIC_IP" "Observability Instance"

wait_for_cloud_init "$APP_PUBLIC_IP" "App Instance"
wait_for_cloud_init "$OBS_PUBLIC_IP" "Observability Instance"

# ── 5. Ansible Provisioning ─────────────────────────────────────────────────
if [[ "$SKIP_ANSIBLE" == false ]]; then
  section "Ansible — Configuring Instances"
  cd "$ANSIBLE_DIR"

  # Build ansible-playbook command
  ANSIBLE_CMD="ansible-playbook -i inventory/hosts.ini site.yml"

  if [[ -n "$ANSIBLE_TAGS" ]]; then
    ANSIBLE_CMD="$ANSIBLE_CMD --tags $ANSIBLE_TAGS"
  fi

  if [[ -n "$ANSIBLE_EXTRA_ARGS" ]]; then
    ANSIBLE_CMD="$ANSIBLE_CMD $ANSIBLE_EXTRA_ARGS"
  fi

  log "Running: $ANSIBLE_CMD"
  eval "$ANSIBLE_CMD"

  log "Ansible provisioning complete."
fi

# ── 6. Health Verification ──────────────────────────────────────────────────
section "Verifying Health"
sleep 10

FAILED=0
check_health() {
  local url="$1" name="$2"
  if curl -sf --max-time 15 "$url" > /dev/null 2>&1; then
    log "$name — ${GREEN}HEALTHY${NC}"
  else
    warn "$name — NOT READY (may still be starting)"
    FAILED=$((FAILED + 1))
  fi
}

check_health "http://$APP_PUBLIC_IP:3000/health"       "Frontend"
check_health "http://$APP_PUBLIC_IP:3001/health"       "Backend"
check_health "http://$APP_PUBLIC_IP:9100/metrics"      "Node Exporter (app)"
check_health "http://$APP_PUBLIC_IP:9121/metrics"      "Redis Exporter"
check_health "http://$OBS_PUBLIC_IP:9090/-/healthy"    "Prometheus"
check_health "http://$OBS_PUBLIC_IP:3000/api/health"   "Grafana"
check_health "http://$OBS_PUBLIC_IP:16686/"            "Jaeger"
check_health "http://$OBS_PUBLIC_IP:9100/metrics"      "Node Exporter (obs)"

# ── Summary ─────────────────────────────────────────────────────────────────
section "Deployment Complete"
echo ""
log " ${BOLD}App Instance${NC}"
log "   Frontend:       http://$APP_PUBLIC_IP:3000"
log "   Backend API:    http://$APP_PUBLIC_IP:3001"
log "   Node Exporter:  http://$APP_PUBLIC_IP:9100/metrics"
log "   Redis Exporter: http://$APP_PUBLIC_IP:9121/metrics"
echo ""
log " ${BOLD}Observability Instance${NC}"
log "   Prometheus:     http://$OBS_PUBLIC_IP:9090"
log "   Grafana:        http://$OBS_PUBLIC_IP:3000  (admin / admin)"
log "   Jaeger UI:      http://$OBS_PUBLIC_IP:16686"
log "   Node Exporter:  http://$OBS_PUBLIC_IP:9100/metrics"
echo ""

if [[ $FAILED -gt 0 ]]; then
  warn "$FAILED service(s) not yet healthy — they may still be starting."
  warn "Run: ./scripts/validate.sh to re-check."
fi
