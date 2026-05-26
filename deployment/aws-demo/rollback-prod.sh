#!/usr/bin/env bash
#
# Rollback the Advantix prod container to a previous image revision.
#
# Story 6.7 (RLDEV-253) — the "I just merged something and the demo
# is broken" lever. ECR keeps per-commit tags (`<short-sha>`), so we
# re-tag a known-good SHA back to `latest` and let the existing
# deploy-poller (or webhook) roll the container.
#
# Usage:
#
#   bash rollback-prod.sh                  # roll back to the previous tag
#   bash rollback-prod.sh <short-sha>      # roll back to a specific SHA
#   bash rollback-prod.sh --list           # list recent tags
#
# Requires: aws, jq, docker on the machine running the script.
# Operates against ECR — does not need SSH/SSM into the EC2 itself,
# because once ECR `latest` moves, the EC2's poller deploys it within
# ~60s.

set -euo pipefail

AWS_REGION="${AWS_REGION:-us-east-1}"
ECR_REPOSITORY="${ECR_REPOSITORY:-advantix-pretix-demo}"
LIMIT="${ROLLBACK_LIST_LIMIT:-20}"

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "ERROR: missing required command: $1" >&2
    exit 1
  }
}
require_cmd aws
require_cmd jq

list_recent_tags() {
  aws ecr describe-images --region "$AWS_REGION" \
      --repository-name "$ECR_REPOSITORY" \
      --query 'sort_by(imageDetails, &imagePushedAt)[*].{tags: imageTags, digest: imageDigest, pushed: imagePushedAt}' \
      --output json \
    | jq -r --argjson n "$LIMIT" 'reverse | .[0:$n] | .[] |
        ((.tags // []) | map(select(. != "latest")) | join(",")) +
        "\t" + (.pushed | tostring) +
        "\t" + (.digest | tostring)'
}

if [[ "${1:-}" == "--list" || "${1:-}" == "-l" ]]; then
  echo "Recent ${ECR_REPOSITORY} images (latest first):"
  echo "TAG(S)                       PUSHED                          DIGEST"
  list_recent_tags
  exit 0
fi

# Find current `latest` digest so we know what we're rolling away from.
CURRENT_DIGEST="$(aws ecr describe-images --region "$AWS_REGION" \
  --repository-name "$ECR_REPOSITORY" \
  --image-ids imageTag=latest \
  --query 'imageDetails[0].imageDigest' --output text 2>/dev/null || echo "")"

if [[ -z "$CURRENT_DIGEST" || "$CURRENT_DIGEST" == "None" ]]; then
  echo "ERROR: no current 'latest' tag on ${ECR_REPOSITORY} — nothing to roll back" >&2
  exit 1
fi

TARGET_SHA="${1:-}"

if [[ -z "$TARGET_SHA" ]]; then
  # Pick the most-recent non-latest tag that isn't the current latest digest.
  TARGET_SHA="$(aws ecr describe-images --region "$AWS_REGION" \
      --repository-name "$ECR_REPOSITORY" \
      --query 'sort_by(imageDetails, &imagePushedAt)[*]' \
      --output json \
    | jq -r --arg cur "$CURRENT_DIGEST" 'reverse | .[]
        | select(.imageDigest != $cur)
        | (.imageTags // [])
        | map(select(. != "latest" and (test("^[a-f0-9]{6,}$"))))
        | .[0]' \
    | grep -v '^null$' \
    | head -n 1)"

  if [[ -z "$TARGET_SHA" ]]; then
    echo "ERROR: could not find a recent non-latest SHA tag to roll back to." >&2
    echo "Try: $0 --list, then re-run with an explicit SHA." >&2
    exit 1
  fi
  echo "[rollback] picking previous tag automatically: ${TARGET_SHA}"
fi

# Resolve the target tag to a digest so we can re-tag it.
TARGET_DIGEST="$(aws ecr describe-images --region "$AWS_REGION" \
  --repository-name "$ECR_REPOSITORY" \
  --image-ids imageTag="$TARGET_SHA" \
  --query 'imageDetails[0].imageDigest' --output text 2>/dev/null || echo "")"

if [[ -z "$TARGET_DIGEST" || "$TARGET_DIGEST" == "None" ]]; then
  echo "ERROR: tag '${TARGET_SHA}' not found on ${ECR_REPOSITORY}" >&2
  echo "Try: $0 --list" >&2
  exit 1
fi

if [[ "$TARGET_DIGEST" == "$CURRENT_DIGEST" ]]; then
  echo "[rollback] target ${TARGET_SHA} already IS 'latest' — nothing to do"
  exit 0
fi

echo "[rollback] re-tagging ${TARGET_SHA} (${TARGET_DIGEST}) as 'latest'"
echo "[rollback] previous 'latest' was ${CURRENT_DIGEST}"

# Fetch the manifest by digest, then put it back under the `latest` tag.
MANIFEST="$(aws ecr batch-get-image --region "$AWS_REGION" \
  --repository-name "$ECR_REPOSITORY" \
  --image-ids imageDigest="$TARGET_DIGEST" \
  --query 'images[0].imageManifest' --output text)"

aws ecr put-image --region "$AWS_REGION" \
  --repository-name "$ECR_REPOSITORY" \
  --image-tag latest \
  --image-manifest "$MANIFEST" >/dev/null

echo "[rollback] done. The EC2 deploy poller will roll the container within ~60s."
echo "[rollback] Watch with:  ssm-session -> tail -f /var/log/advantix-deploy.log"
echo "[rollback] Or force immediate: ssm-session -> systemctl start advantix-deploy-poller.service"
