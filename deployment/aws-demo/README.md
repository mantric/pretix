# AWS Demo / Dev Staging

This deployment package supports the maintained low-budget shape for
the Advantix demo:

- 1 EC2 instance running Docker Compose
- 1 Caddy container terminating TLS on host ports 80 + 443 (Let's
  Encrypt via ACME http-01, automatic)
- 1 pretix container reverse-proxied from Caddy on the docker network
- 1 local PostgreSQL container
- 1 local Redis container
- 1 Elastic IP for stable inbound access
- External DNS hosted at Spaceship (apex + www A records → EIP)

This is intentionally a demo / dev staging target, not a production
HA stack.

> **Note.** Earlier revisions of this README described a CloudFront +
> ACM front-end. That layer was removed for the Advantix pilot
> because the demo doesn't benefit from edge caching or DDoS
> shielding and the CF→origin path added operational surface that
> wasn't pulling its weight. See "Cutover from CloudFront" below
> for the migration runbook (kept as historical context). The
> dormant CF artifacts — viewer-request function source, workflow
> invalidation step, repo variable — were removed in a cleanup PR
> once the Caddy stack soaked.

## Final Architecture

- Viewer traffic: `advantix.tech` and `www.advantix.tech`
- DNS host: Spaceship (apex A and www A both point to the EC2 EIP)
- TLS termination: Caddy on the EC2 (Let's Encrypt, automatic
  renewal)
- Reverse proxy: Caddy → `pretix:80` over the docker compose
  network
- App data: local Docker volumes and `/opt/advantix-pretix-demo/data`
- Cert state: `caddy-data` named volume (durable — see Caddyfile
  notes)
- Jobs: host cron runs `pretix cron` every 5 minutes
- Admin/backend: `/control/`
- Organizer storefront: `/advantix/`

Cost avoidance: ALB, ECS, RDS, ElastiCache, EFS, CloudFront.

Tradeoff: single-instance. If the EC2 fails the site is down until
it's restored or replaced.

## Record Live Inventory

After you deploy, record these values in your operator notes:

- AWS account ID
- EC2 region
- EC2 instance ID
- EC2 public IP (the Elastic IP)
- EC2 public DNS

## What You Get

- Public HTTPS demo site on `https://advantix.tech`
- `www` redirected to apex (Caddyfile rule)
- root `/` redirected to `/advantix/` (Caddyfile rule)
- seeded polished Advantix storefront with branding, hero copy, and
  demo events
- pretix backend at `/control/`
- image-based redeploys via the master-push deploy pipeline (see
  `PIPELINE.md`)

## Files

- `docker-compose.yml`: on-instance service definition (Caddy + db
  + redis + pretix)
- `Caddyfile`: Caddy reverse-proxy + TLS config (apex + www, ACME)
- `nginx.conf`: in-pretix-container nginx config (serves the
  django unix socket; reached by Caddy on `pretix:80`)
- `pretix.cfg.template`: rendered instance config
- `deploy-demo-ec2.sh`: one-shot EC2 bootstrap (legacy CF
  provisioning blocks inside it are no longer the deploy target;
  removing them is queued as a separate follow-up since they don't
  hurt anyone in the current pipeline)
- `advantix-deploy-poller.{sh,service,timer}`: master-push deploy
  poller (see `PIPELINE.md`)
- `rollback-prod.sh`: re-tag an older ECR image as `latest`

## Phase 1: Base EC2 Deploy

From the repo root:

```bash
chmod +x deployment/aws-demo/deploy-demo-ec2.sh
deployment/aws-demo/deploy-demo-ec2.sh
```

The deploy script provisions the EC2, security group, EIP, and
initial container set. **The script still contains CloudFront
provisioning blocks** (legacy) — for a fresh Caddy-only stack, skip
those blocks or comment them out before running. The Advantix demo
EC2 already exists, so this script is no longer run for the
pilot's day-to-day deploys.

First boot runs the full pretix migration set, so the site can
return 502 briefly before becoming healthy.

## Phase 2: DNS at Spaceship

Keep Spaceship nameservers in place. Do not move DNS to Route 53
if you want to preserve Spaceship email forwarding.

### Website DNS records

Point apex and www directly at the EC2 EIP:

```dns
@    A      <ec2-eip>
www  A      <ec2-eip>
```

Both records have a low TTL during cutover (e.g. 60 seconds)
so propagation is fast. Once the cutover is verified, raise to
~3600s.

Do not remove your existing MX, SPF, DKIM, or email-forwarding
records.

### TLS / ACME

Caddy obtains and renews the certificate automatically via the
http-01 challenge as long as:

- port 80 is open from the public internet to the EC2 EIP
  (security group allows `0.0.0.0/0` on tcp/80)
- the apex and www A records resolve to the EC2 EIP

The first issuance happens within ~30 seconds of Caddy starting
once DNS is correct. Watch `docker compose logs -f caddy` for
"certificate obtained successfully" lines.

The issued cert + ACME state lives in the `caddy-data` named
volume. Treat that volume as durable; deleting it triggers
re-issuance and can hit Let's Encrypt's rate limit of 5 certs
per exact-domain-set per week.

## Runtime Configuration

For the Caddy-fronted domain, the live pretix origin config should
be:

```ini
[pretix]
url=https://advantix.tech
trust_x_forwarded_proto=true
```

Caddy sends `X-Forwarded-Proto: https` to the pretix container,
which the Django app uses to emit `https://` URLs in redirects and
absolute links.

## Cutover from CloudFront

The Advantix pilot ran briefly on CloudFront → EC2 before being
simplified to direct DNS → Caddy → pretix. If you're doing the
cutover now, the sequence is:

1. **Lower DNS TTL ahead of time.** A few hours before cutover, set
   the apex + www records' TTL at Spaceship to 60 seconds. This
   shortens the propagation window during the actual switch.

2. **Pull the new compose files onto the EC2.** SSM into the
   instance with the admin profile (devbox's `staging-ops` lacks
   `ssm:StartSession` on this instance):

   ```bash
   aws --profile principledevolution-ai ssm start-session \
     --target i-0e527b07a48513bb7

   cd /opt/advantix-pretix-demo
   for f in docker-compose.yml Caddyfile nginx.conf; do
     sudo curl -fsSL \
       "https://raw.githubusercontent.com/mantric/pretix/master/deployment/aws-demo/${f}" \
       -o "${f}"
   done
   ```

3. **Verify the security group allows tcp/80 + tcp/443 from
   `0.0.0.0/0`.** Required for Caddy's ACME http-01 challenge and
   for the public site itself.

4. **Switch DNS at Spaceship.** Update both records:

   ```dns
   @    A      <ec2-eip>
   www  A      <ec2-eip>
   ```

   (Both replace the prior CloudFront CNAMEs.) Verify propagation
   from multiple resolvers:

   ```bash
   dig +short advantix.tech @1.1.1.1
   dig +short advantix.tech @8.8.8.8
   dig +short advantix.tech @9.9.9.9
   ```

5. **Roll the compose stack on the EC2.** Once DNS shows the EIP
   from a public resolver:

   ```bash
   cd /opt/advantix-pretix-demo
   docker compose pull caddy
   docker compose up -d --remove-orphans
   docker compose logs -f caddy
   ```

   Look for `certificate obtained successfully` for both
   `advantix.tech` and `www.advantix.tech`. This typically lands
   inside the first 30-60 seconds.

6. **Smoke-test from a local terminal:**

   ```bash
   curl -sI https://advantix.tech/                 # expect 302 -> /advantix/
   curl -sI https://advantix.tech/advantix/        # expect 200
   curl -sI https://www.advantix.tech/             # expect 301 -> https://advantix.tech/
   curl -sI https://advantix.tech/static/pretixplugins/advantixtheme/advantix.css
   ```

7. **Disable CloudFront.** Once the Caddy stack is verified, set
   the CloudFront distribution `Enabled=false` (admin profile).
   Leave it disabled for a day or two as a fast rollback before
   deleting.

**Cutover downtime:** ~5-15 minutes total, dominated by DNS
propagation + first ACME issuance.

**Rollback:** if any step above fails badly, revert DNS to the
CloudFront CNAMEs (still recorded in Spaceship change history)
and re-enable the CF distribution. Pretix itself is unchanged,
so reverting fronting reverts the user-facing site to the prior
behavior.

## App Update Workflow

The day-to-day deploy is automated by the master-push pipeline:

1. A PR merges to `mantric/pretix` master.
2. GitHub Actions builds + pushes the image to ECR.
3. The EC2's `advantix-deploy-poller.timer` (every 60s) detects the
   new `latest` digest and runs `docker compose up -d pretix`.
4. Caddy keeps running; only pretix is rolled.

See `PIPELINE.md` for the full operator runbook.

Manual `pretix` restart on the EC2:

```bash
cd /opt/advantix-pretix-demo
docker compose restart pretix
docker compose logs --tail=200 pretix
```

Useful debug probes from the EC2 host (bypass Caddy):

```bash
# Reach the pretix container directly via its docker network IP
docker compose exec pretix curl -sI -H "Host: advantix.tech" -H "X-Forwarded-Proto: https" http://127.0.0.1/advantix/

# Probe the origin from outside (bypass Caddy + bypass cert checks)
curl -k -H "Host: advantix.tech" http://<ec2-eip>:80/advantix/   # NOTE: 80 only reaches Caddy; 80 → 443 redirect
```

Caddy redirects all plain HTTP to HTTPS, so the public site has no
HTTP-served pages.

## Legacy CloudFront tooling

The CF stack has been fully retired. What was removed:

- `advantix-root-redirect.js` — the CloudFront viewer-request
  function source. The www→apex and /→/advantix/ redirects now
  live in `Caddyfile`.
- `Invalidate CloudFront cache` step (and the 90s wait that
  preceded it) in `.github/workflows/advantix-image-build.yml`.
  The `ADVANTIX_CF_DISTRIBUTION_ID` repo variable can be deleted
  to silence stragglers: `gh variable delete ADVANTIX_CF_DISTRIBUTION_ID --repo mantric/pretix`.

Still in the repo but not in the current deploy path:

- The CloudFront-provisioning blocks inside `deploy-demo-ec2.sh`.
  They don't run unless the script is invoked, which it isn't on
  steady-state deploys. Removing them is queued as a separate
  follow-up.

## Operational Notes

- TLS renewal is automatic via Caddy's ACME loop. Watch
  `docker compose logs caddy` periodically.
- The public EC2 IP is the website endpoint now. Hide it via a
  WAF or a fronted CDN if needed; we don't for the pilot.
- This stack is fine for demos, testing, investor/customer
  previews, and internal staging. It is not a production
  multi-tenant ticketing platform.

## Troubleshooting

- `advantix.tech` does not resolve:
  Spaceship apex/www records aren't pointing at the EC2 EIP.

- `advantix.tech` resolves but HTTPS hangs / fails:
  Caddy isn't running, or port 443 isn't open in the security
  group, or first ACME issuance hasn't completed.
  `docker compose logs caddy` is the first stop.

- Caddy log shows `acme: invalid response` or `unauthorized`:
  Port 80 isn't reachable from the public internet (Let's Encrypt
  needs http-01 access). Check the security group.

- HTTPS works but pretix emits `http://` redirects:
  Check `pretix.cfg` for `url=https://advantix.tech` and
  `trust_x_forwarded_proto=true`, then verify Caddy is sending
  `X-Forwarded-Proto: https` upstream (it does by default per
  the Caddyfile).

- Root shows pretix's default install page:
  `/ → /advantix/` redirect in `Caddyfile` isn't matching. Inspect
  the Caddyfile and reload via `docker compose restart caddy`.

- `www` does not redirect cleanly:
  Check the `www.advantix.tech` site block in `Caddyfile`.

## Later Upgrades

- harden direct origin access with a WAF (CloudFront, ALB+WAF, or
  Cloudflare in front)
- move Postgres to RDS
- move Redis to ElastiCache
- split web and worker into ECS
- move media to S3 or EFS
