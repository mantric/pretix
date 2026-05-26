#!/usr/bin/env python3
"""GitHub-webhook → docker compose pull/up deploy listener for Advantix EC2.

Story 6.5 (RLDEV-251) — the EC2 side of the Resultant pilot auto-deploy
loop. Receives a push-event webhook from GitHub when mantric/pretix
master moves, validates the HMAC signature, then refreshes the running
pretix container from ECR's `latest` tag.

Why not a self-hosted GHA runner? Because runners execute arbitrary
workflow code with the runner's IAM/identity; putting one inside the
prod EC2 widens the blast radius. A scope-bound webhook listener
(this script) can only do the one thing it's coded to do.

Runtime:
- Python 3.11 stdlib only (no Flask). Reduces attack surface and
  install footprint on the EC2.
- Listens on 127.0.0.1:8765. The host nginx layer (see
  router-webhook.conf) terminates HTTPS on /resultant-webhook/ and
  proxies here.
- Validates `X-Hub-Signature-256` against the shared secret loaded
  from /etc/advantix-webhook.env at boot.
- Only acts on `push` events for `refs/heads/master`. Pings get a 200.
  PR events are ignored (image build is enough; deploy waits for the
  merge).
- Synchronously runs `docker compose pull pretix && docker compose
  up -d pretix` in the configured APP_DIR.

Operational expectations:
- Stay tiny. If you're tempted to add features, add them as separate
  endpoints with their own auth, don't grow this one.
- Logs to stdout (systemd captures it). Don't write secrets to logs.
- Exit non-zero on unrecoverable errors so systemd restarts cleanly.
"""

from __future__ import annotations

import hashlib
import hmac
import json
import logging
import os
import subprocess
import sys
from http import HTTPStatus
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from typing import Optional

LOG = logging.getLogger("advantix-webhook")

# Config — read once at startup. Treat as immutable per-process.
LISTEN_HOST = os.environ.get("WEBHOOK_LISTEN_HOST", "127.0.0.1")
LISTEN_PORT = int(os.environ.get("WEBHOOK_LISTEN_PORT", "8765"))
WEBHOOK_SECRET = os.environ.get("GITHUB_WEBHOOK_SECRET", "").encode("utf-8")
APP_DIR = Path(os.environ.get("APP_DIR", "/opt/advantix-pretix-demo"))
TARGET_REF = os.environ.get("WEBHOOK_TARGET_REF", "refs/heads/master")
ECR_REGISTRY = os.environ.get("ECR_REGISTRY", "")  # e.g. <acct>.dkr.ecr.<region>.amazonaws.com
AWS_REGION = os.environ.get("AWS_REGION", "us-east-1")


def _verify_signature(secret: bytes, body: bytes, header_value: Optional[str]) -> bool:
    """Constant-time HMAC-SHA256 verification of the X-Hub-Signature-256 header."""
    if not header_value or not header_value.startswith("sha256="):
        return False
    expected = hmac.new(secret, body, hashlib.sha256).hexdigest()
    provided = header_value[len("sha256=") :]
    return hmac.compare_digest(expected, provided)


def _run(args: list[str], **kwargs) -> subprocess.CompletedProcess:
    """Subprocess wrapper that logs the command + outcome without leaking env."""
    LOG.info("$ %s", " ".join(args))
    result = subprocess.run(
        args,
        capture_output=True,
        text=True,
        check=False,
        **kwargs,
    )
    if result.stdout:
        LOG.info("stdout:\n%s", result.stdout.rstrip())
    if result.stderr:
        LOG.info("stderr:\n%s", result.stderr.rstrip())
    if result.returncode != 0:
        LOG.error("command exited %s", result.returncode)
    return result


def deploy_latest() -> bool:
    """Refresh the running pretix container from ECR's `latest` tag.

    Returns True on success, False on any non-zero step. Caller is
    responsible for surfacing the result to the webhook response.
    """
    if not APP_DIR.exists():
        LOG.error("APP_DIR %s does not exist", APP_DIR)
        return False

    if ECR_REGISTRY:
        login = _run(
            [
                "bash",
                "-lc",
                f"aws ecr get-login-password --region {AWS_REGION} "
                f"| docker login --username AWS --password-stdin {ECR_REGISTRY}",
            ]
        )
        if login.returncode != 0:
            return False

    pull = _run(["docker", "compose", "pull", "pretix"], cwd=str(APP_DIR))
    if pull.returncode != 0:
        return False

    up = _run(["docker", "compose", "up", "-d", "pretix"], cwd=str(APP_DIR))
    if up.returncode != 0:
        return False

    return True


class WebhookHandler(BaseHTTPRequestHandler):
    server_version = "advantix-webhook/1.0"

    def log_message(self, fmt: str, *args) -> None:  # noqa: D401
        LOG.info("%s - %s", self.client_address[0], fmt % args)

    def _reply(self, status: HTTPStatus, body: dict) -> None:
        payload = json.dumps(body).encode("utf-8")
        self.send_response(status.value)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(payload)))
        self.end_headers()
        self.wfile.write(payload)

    def do_POST(self) -> None:  # noqa: N802 (BaseHTTPRequestHandler API)
        if self.path != "/resultant-webhook":
            self._reply(HTTPStatus.NOT_FOUND, {"error": "unknown endpoint"})
            return

        content_length = int(self.headers.get("Content-Length") or 0)
        body = self.rfile.read(content_length) if content_length else b""

        if not _verify_signature(WEBHOOK_SECRET, body, self.headers.get("X-Hub-Signature-256")):
            LOG.warning("signature verification FAILED for delivery %s",
                        self.headers.get("X-GitHub-Delivery"))
            self._reply(HTTPStatus.FORBIDDEN, {"error": "signature invalid"})
            return

        event = self.headers.get("X-GitHub-Event") or ""
        delivery = self.headers.get("X-GitHub-Delivery") or ""

        if event == "ping":
            self._reply(HTTPStatus.OK, {"pong": True, "delivery": delivery})
            return

        if event != "push":
            self._reply(HTTPStatus.OK, {"ignored": True, "event": event})
            return

        try:
            payload = json.loads(body.decode("utf-8")) if body else {}
        except json.JSONDecodeError:
            self._reply(HTTPStatus.BAD_REQUEST, {"error": "invalid JSON"})
            return

        ref = payload.get("ref")
        if ref != TARGET_REF:
            LOG.info("ignoring push for ref %s (target %s)", ref, TARGET_REF)
            self._reply(HTTPStatus.OK, {"ignored": True, "ref": ref})
            return

        head_sha = (payload.get("after") or "")[:12]
        LOG.info("deploying head_sha=%s (delivery=%s)", head_sha, delivery)

        ok = deploy_latest()
        if ok:
            self._reply(HTTPStatus.OK, {"deployed": True, "ref": ref, "head_sha": head_sha})
        else:
            self._reply(
                HTTPStatus.INTERNAL_SERVER_ERROR,
                {"deployed": False, "ref": ref, "head_sha": head_sha,
                 "hint": "see systemd journalctl -u advantix-webhook -f"},
            )

    def do_GET(self) -> None:  # noqa: N802
        # Liveness probe — no auth, no side effects. Useful for nginx
        # upstream health checks and human curl sanity checks.
        if self.path == "/healthz":
            self._reply(HTTPStatus.OK, {"status": "healthy"})
            return
        self._reply(HTTPStatus.NOT_FOUND, {"error": "unknown endpoint"})


def main() -> int:
    logging.basicConfig(
        level=os.environ.get("LOG_LEVEL", "INFO").upper(),
        format="%(asctime)s %(levelname)s %(name)s: %(message)s",
    )

    if not WEBHOOK_SECRET:
        LOG.error("GITHUB_WEBHOOK_SECRET is empty; refusing to start")
        return 1

    LOG.info("listening on %s:%s, target_ref=%s, app_dir=%s",
             LISTEN_HOST, LISTEN_PORT, TARGET_REF, APP_DIR)
    server = ThreadingHTTPServer((LISTEN_HOST, LISTEN_PORT), WebhookHandler)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        LOG.info("shutdown requested")
    finally:
        server.server_close()
    return 0


if __name__ == "__main__":
    sys.exit(main())
