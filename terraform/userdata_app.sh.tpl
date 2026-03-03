#!/usr/bin/env bash
###############################################################################
# userdata_app.sh.tpl — Minimal bootstrap for the App Instance
#
# Only installs Docker + Python so that Ansible can take over provisioning.
# All service configuration (node_exporter, redis_exporter, Docker Compose)
# is handled by Ansible roles — NOT by this script.
###############################################################################
set -euo pipefail
exec > >(tee /var/log/userdata-app.log) 2>&1

echo "=========================================="
echo " App Instance Bootstrap — $(date -u)"
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
#  2. Install Docker CE
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
#  3. Prepare project directory
# -------------------------------------------------------------------
mkdir -p /opt/voting-app
echo "MONITORING_HOST=${monitoring_private_ip}" > /opt/voting-app/.env
echo "AWS_REGION=${aws_region}" >> /opt/voting-app/.env

# -------------------------------------------------------------------
#  4. Signal readiness
# -------------------------------------------------------------------
echo "READY" > /var/log/userdata-app-complete
echo "=========================================="
echo " App Instance Bootstrap Complete — ready for Ansible"
echo "=========================================="
