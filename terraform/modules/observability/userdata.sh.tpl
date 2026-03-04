#!/usr/bin/env bash
###############################################################################
# userdata_observability.sh.tpl — Minimal bootstrap for the Observability Instance
#
# Only installs Docker + Python so that Ansible can take over provisioning.
# Service configuration (Prometheus, Grafana, Jaeger) is handled by Ansible.
###############################################################################
set -euo pipefail
exec > >(tee /var/log/userdata-observability.log) 2>&1

echo "=========================================="
echo " Observability Instance Bootstrap — $(date -u)"
echo "=========================================="

export DEBIAN_FRONTEND=noninteractive

# -------------------------------------------------------------------
#  1. System updates + essential packages
# -------------------------------------------------------------------
apt-get update -y
apt-get install -y \
  ca-certificates curl gnupg lsb-release unzip jq \
  python3 python3-pip python3-venv \
  apt-transport-https software-properties-common

# -------------------------------------------------------------------
#  2. Install Docker CE (for Jaeger container)
# -------------------------------------------------------------------
install -m 0755 -d /etc/apt/keyrings
if [[ ! -f /etc/apt/keyrings/docker.gpg ]]; then
  curl -fsSL https://download.docker.com/linux/ubuntu/gpg | \
    gpg --dearmor -o /etc/apt/keyrings/docker.gpg
  chmod a+r /etc/apt/keyrings/docker.gpg
fi

echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] \
  https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" | \
  tee /etc/apt/sources.list.d/docker.list > /dev/null

apt-get update -y
apt-get install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin
systemctl enable --now docker
usermod -aG docker ubuntu

# -------------------------------------------------------------------
#  3. Signal readiness
# -------------------------------------------------------------------
echo "READY" > /var/log/userdata-observability-complete
echo "=========================================="
echo " Observability Instance Bootstrap Complete — ready for Ansible"
echo "=========================================="
