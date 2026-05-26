#!/usr/bin/env bash
#
# Installs the Advantix deploy poller onto the live EC2 instance.
# Idempotent — re-running just refreshes the script and unit files.
#
# Run via SSM Session Manager or SSH:
#
#   sudo bash deployment/aws-demo/install-deploy-poller.sh
#
# Inputs (defaults shown):
#   APP_DIR=/opt/advantix-pretix-demo
#   AWS_REGION=us-east-1
#   ECR_REPOSITORY=advantix-pretix-demo
#
# After install, watch the loop with:
#
#   sudo systemctl status advantix-deploy-poller.timer
#   sudo journalctl -u advantix-deploy-poller.service -f
#   tail -f /var/log/advantix-deploy.log

set -euo pipefail

if [[ $EUID -ne 0 ]]; then
  echo "ERROR: must be run as root (try: sudo $0)" >&2
  exit 1
fi

APP_DIR="${APP_DIR:-/opt/advantix-pretix-demo}"
AWS_REGION="${AWS_REGION:-us-east-1}"
ECR_REPOSITORY="${ECR_REPOSITORY:-advantix-pretix-demo}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [[ ! -d "$APP_DIR" ]]; then
  echo "ERROR: APP_DIR ${APP_DIR} not found — run deploy-demo-ec2.sh first" >&2
  exit 1
fi

echo "[install] writing /etc/advantix-deploy.env"
cat > /etc/advantix-deploy.env <<EOF
APP_DIR=${APP_DIR}
AWS_REGION=${AWS_REGION}
ECR_REPOSITORY=${ECR_REPOSITORY}
LOG_FILE=/var/log/advantix-deploy.log
STATE_FILE=/var/lib/advantix-deploy-state
EOF
chmod 0644 /etc/advantix-deploy.env

echo "[install] copying poller script to ${APP_DIR}/advantix-deploy-poller.sh"
install -m 0755 "${SCRIPT_DIR}/advantix-deploy-poller.sh" "${APP_DIR}/advantix-deploy-poller.sh"

echo "[install] copying systemd unit files"
install -m 0644 "${SCRIPT_DIR}/advantix-deploy-poller.service" /etc/systemd/system/advantix-deploy-poller.service
install -m 0644 "${SCRIPT_DIR}/advantix-deploy-poller.timer" /etc/systemd/system/advantix-deploy-poller.timer

systemctl daemon-reload

echo "[install] enabling + starting timer"
systemctl enable --now advantix-deploy-poller.timer

echo
echo "[install] done. Status:"
systemctl status --no-pager advantix-deploy-poller.timer || true

echo
echo "Tail the deploy log with:"
echo "  tail -f /var/log/advantix-deploy.log"
echo "Force an immediate cycle with:"
echo "  systemctl start advantix-deploy-poller.service"
