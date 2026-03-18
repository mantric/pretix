# AWS Demo / Dev Staging

This deployment package now supports the maintained low-budget shape for the Advantix demo:

- 1 `EC2` instance running Docker Compose
- 1 pretix container using the repo's built-in `pretix all` entrypoint
- 1 local `PostgreSQL` container
- 1 local `Redis` container
- 1 Elastic IP for stable origin access
- 1 `CloudFront` distribution for public HTTPS
- 1 `ACM` certificate in `us-east-1`
- external DNS hosted at Spaceship, not Route 53

This is intentionally a demo / dev staging target, not a production HA stack.

## Final Architecture

- Viewer traffic: `advantix.tech` and `www.advantix.tech`
- DNS host: Spaceship
- TLS termination: CloudFront with ACM
- Origin: single `EC2` instance over plain HTTP on port `80`
- App data: local Docker volumes and `/opt/advantix-pretix-demo/data`
- Jobs: host cron runs `pretix cron` every 5 minutes
- Admin/backend: `/control/`
- Organizer storefront: `/advantix/`

This keeps cost down by avoiding:

- `ALB`
- `ECS`
- `RDS`
- `ElastiCache`
- `EFS`

Tradeoff: the stack is single-instance. If the EC2 instance fails, the site is down until the instance is restored or replaced.

## Record Live Inventory

After you deploy, record these values in your operator notes:

- AWS account ID
- EC2 region
- EC2 instance ID
- EC2 public IP
- EC2 public DNS
- CloudFront distribution ID
- CloudFront domain
- ACM certificate ARN
- CloudFront function name

## What You Get

- Public HTTPS demo site on `advantix.tech`
- `www` redirected to apex
- root `/` redirected to `/advantix/`
- seeded demo storefront for `Advantix`
- demo event pages under `/advantix/<event-slug>/`
- pretix backend at `/control/`
- image-based redeploys by rerunning the EC2 deploy script and restarting the instance services

## Files

- `docker-compose.yml`: on-instance service definition
- `nginx.conf`: origin proxy config used by the demo stack
- `pretix.cfg.template`: rendered instance config
- `deploy-demo-ec2.sh`: one-shot EC2 bootstrap and app deploy
- `advantix-root-redirect.js`: CloudFront viewer-request function source

## Phase 1: Base EC2 Deploy

From the repo root:

```bash
chmod +x deployment/aws-demo/deploy-demo-ec2.sh
deployment/aws-demo/deploy-demo-ec2.sh
```

Optional overrides:

```bash
AWS_REGION=ap-south-1 \
APP_NAME=advantix-pretix-demo \
INSTANCE_TYPE=t3.small \
deployment/aws-demo/deploy-demo-ec2.sh
```

The deploy script:

- builds and pushes the image to ECR
- creates or reuses the IAM role, profile, security group, EC2 instance, and EIP
- uploads `docker-compose.yml`, `nginx.conf`, `.env`, and `pretix.cfg`
- starts `db`, `redis`, and `pretix`
- seeds the Advantix organizer, demo events, and admin user

First boot runs the full pretix migration set, so the site can return `502` briefly before becoming healthy.

## Phase 2: CloudFront + ACM + Spaceship DNS

Keep Spaceship nameservers in place. Do not move DNS to Route 53 if you want to preserve Spaceship email forwarding.

### ACM validation records

Leave the ACM validation `CNAME` records in Spaceship so ACM can renew the certificate.
Pull them from ACM after the certificate request is created:

```bash
aws acm describe-certificate \
  --region us-east-1 \
  --certificate-arn <acm-certificate-arn>
```

### Website DNS records

Spaceship flattens a root-level `CNAME`, so use `CNAME` for both records:

```dns
@    CNAME  <cloudfront-domain>
www  CNAME  <cloudfront-domain>
```

Do not remove your existing MX, SPF, DKIM, or email-forwarding records.

## Runtime Configuration

For the CloudFront-fronted domain, the live pretix origin config should be:

```ini
[pretix]
url=https://advantix.tech
trust_x_forwarded_proto=true
```

CloudFront should:

- use aliases `advantix.tech` and `www.advantix.tech`
- use your ACM certificate in `us-east-1`
- redirect viewers from HTTP to HTTPS
- send `X-Forwarded-Proto: https` to the origin
- point to your EC2 public DNS name on HTTP port `80`

## CloudFront Function Behavior

The active viewer-request function source is stored in:

- `deployment/aws-demo/advantix-root-redirect.js`

Its behavior is:

- `www.advantix.tech/*` -> `https://advantix.tech/*`
- `https://advantix.tech/` -> `/advantix/`
- all other requests pass through unchanged

### Update the function

```bash
aws cloudfront describe-function \
  --name advantix-root-redirect \
  --stage DEVELOPMENT

aws cloudfront update-function \
  --name advantix-root-redirect \
  --if-match <etag-from-describe-function> \
  --function-code fileb://deployment/aws-demo/advantix-root-redirect.js \
  --function-config Comment="Redirect root and www for Advantix",Runtime=cloudfront-js-2.0

aws cloudfront publish-function \
  --name advantix-root-redirect \
  --if-match <etag-from-update-function>
```

The distribution already associates this function on `viewer-request`, so publishing a new function version is enough unless you replace the function name.

## App Update Workflow

For app changes:

1. Push a new image with `deployment/aws-demo/deploy-demo-ec2.sh`.
2. Upload any changed `docker-compose.yml`, `nginx.conf`, or `pretix.cfg`.
3. Restart the app container on the instance.
4. Verify the CloudFront path and the direct origin health.

Useful origin-side commands through SSM:

```bash
cd /opt/advantix-pretix-demo
docker compose ps
docker compose logs --tail=200 pretix
docker compose restart pretix
curl -I -H "Host: advantix.tech" -H "X-Forwarded-Proto: https" http://127.0.0.1/advantix/
curl -I -H "Host: advantix.tech" -H "X-Forwarded-Proto: https" http://127.0.0.1/advantix/mumbai-movie-night/
```

Useful CloudFront verification from a local terminal before DNS cutover:

```bash
curl -I --connect-to advantix.tech:443:<cloudfront-domain>:443 https://advantix.tech/
curl -I --connect-to advantix.tech:443:<cloudfront-domain>:443 https://advantix.tech/advantix/
curl -I --connect-to advantix.tech:443:<cloudfront-domain>:443 https://advantix.tech/advantix/mumbai-movie-night/
curl -I --connect-to www.advantix.tech:443:<cloudfront-domain>:443 "https://www.advantix.tech/advantix/?x=1"
```

Expected results:

- root returns `302` to `/advantix/`
- organizer page returns `200`
- event page returns `200`
- `www` returns `301` to apex and preserves path/query

## Operational Notes

- ACM renewal is automatic as long as the validation CNAMEs remain in Spaceship DNS.
- The public EC2 IP is an origin detail. Users should access the site through CloudFront, not directly.
- `KnownDomain` entries are not used for `advantix.tech` in this setup. The apex host is treated as the system domain and CloudFront handles the root redirect.
- This stack is fine for demos, testing, investor/customer previews, and internal staging. It is not a production multi-tenant ticketing platform.

## Troubleshooting

- `advantix.tech` does not resolve:
  The Spaceship apex and `www` records are not pointed at CloudFront yet.
- HTTPS works on CloudFront but pretix emits `http://` redirects:
  Check `pretix.cfg` for `url=https://advantix.tech` and `trust_x_forwarded_proto=true`, then verify the origin sees `X-Forwarded-Proto: https`.
- ACM shows pending validation:
  The validation CNAMEs are missing or incorrect in Spaceship.
- Root shows pretix's default install page:
  CloudFront is bypassed or the root redirect function is not active.
- `www` does not redirect cleanly:
  Re-publish `deployment/aws-demo/advantix-root-redirect.js`.

## Later Upgrades

- restrict direct origin access with CloudFront-only origin hardening
- move Postgres to `RDS`
- move Redis to `ElastiCache`
- split web and worker into `ECS`
- move media to `S3` or `EFS`
