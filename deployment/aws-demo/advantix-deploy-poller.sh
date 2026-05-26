#!/usr/bin/env bash
#
# Pull-based deploy poller for the Advantix EC2 demo.
#
# Story 6.5 (RLDEV-251) — the simpler half of the auto-deploy pair. A
# systemd timer (see advantix-deploy-poller.timer) invokes this script
# every minute. It runs `docker compose pull pretix` against ECR; if
# `latest` has moved, `docker compose up -d pretix` rolls the running
# container to the new image. Idempotent: if `latest` hasn't moved,
# both commands are no-ops.
#
# We prefer this over a GitHub-webhook listener for the pilot because:
#   * no public HTTPS endpoint on the EC2 to manage
#   * no shared secret to rotate
#   * deploy latency is at most one timer interval (~60s), which
#     is well under what reviewers notice
#   * total surface area is one shell script + one systemd timer
#
# If you need sub-second deploys, deployment/aws-demo/webhook-listener.py
# is a drop-in alternative — it's a strict superset of this behavior.

set -euo pipefail

APP_DIR="${APP_DIR:-/opt/advantix-pretix-demo}"
AWS_REGION="${AWS_REGION:-us-east-1}"
ECR_REPOSITORY="${ECR_REPOSITORY:-advantix-pretix-demo}"
LOG_FILE="${LOG_FILE:-/var/log/advantix-deploy.log}"

# State file remembers the last successfully-deployed image digest so
# we can announce "rolled X -> Y" cleanly in logs even though
# `docker compose up -d` is itself idempotent.
STATE_FILE="${STATE_FILE:-/var/lib/advantix-deploy-state}"

log() {
  local ts
  ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  printf '%s %s\n' "$ts" "$*" | tee -a "$LOG_FILE"
}

if [[ ! -d "$APP_DIR" ]]; then
  log "ERROR: APP_DIR ${APP_DIR} missing — has deploy-demo-ec2.sh been run?"
  exit 1
fi

ACCOUNT_ID="$(aws sts get-caller-identity --query Account --output text 2>/dev/null || true)"
if [[ -z "$ACCOUNT_ID" ]]; then
  log "ERROR: aws sts get-caller-identity failed — check the EC2 instance profile"
  exit 1
fi

REGISTRY="${ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com"
IMAGE_REF="${REGISTRY}/${ECR_REPOSITORY}:latest"

PREVIOUS_DIGEST="$(cat "$STATE_FILE" 2>/dev/null || echo "")"

# Authenticate against ECR. Short-lived token, so just re-login every cycle.
aws ecr get-login-password --region "$AWS_REGION" \
  | docker login --username AWS --password-stdin "$REGISTRY" >/dev/null

cd "$APP_DIR"

# `docker compose pull` is the no-op-when-no-change primitive.
docker compose pull pretix >/dev/null

CURRENT_DIGEST="$(docker image inspect "$IMAGE_REF" --format '{{index .RepoDigests 0}}' 2>/dev/null | awk -F'@' '{print $2}')"

if [[ -z "$CURRENT_DIGEST" ]]; then
  log "WARN: could not inspect ${IMAGE_REF} after pull; skipping this cycle"
  exit 0
fi

if [[ "$CURRENT_DIGEST" == "$PREVIOUS_DIGEST" ]]; then
  # No change. Don't even log every cycle — the timer fires every 60s
  # and we don't want to drown the log.
  exit 0
fi

log "image moved: ${PREVIOUS_DIGEST:-<none>} -> ${CURRENT_DIGEST}"
log "running: docker compose up -d pretix"

docker compose up -d pretix >>"$LOG_FILE" 2>&1

# Persist the new digest only after a successful up. If up failed,
# we retry on the next timer fire instead of declaring victory.
mkdir -p "$(dirname "$STATE_FILE")"
echo "$CURRENT_DIGEST" > "$STATE_FILE"
log "deployed digest ${CURRENT_DIGEST}"
