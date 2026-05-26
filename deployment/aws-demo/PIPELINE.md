# Advantix Pretix Pilot — PR → Deploy Pipeline

This document is the operator runbook for Story 6.5 / Story 6.7 — the
CI build + auto-deploy + rollback chain that makes a merged PR on
`mantric/pretix master` land on `advantix.tech` within ~60-90 seconds.

This is intentionally a **pilot-grade** pipeline. It runs a single
docker container on a single EC2 instance against a single ECR
`latest` tag. It is not a multi-region, multi-replica, blue-green
production pipeline. The trade-offs are explained inline.

---

## End-to-end flow

```
   developer / Resultant
            │
            ▼
   1. PR merges on mantric/pretix master
            │
            ▼
   2. .github/workflows/advantix-image-build.yml
      builds the docker image and pushes to ECR
      under both `<short-sha>` (immutable) and
      `latest` (mutable) tags.
            │
            ▼
   3. EC2 instance (advantix-pretix-demo) runs the
      systemd timer advantix-deploy-poller.timer
      every 60 seconds. The timer fires the
      poller shell script.
            │
            ▼
   4. advantix-deploy-poller.sh:
          aws ecr get-login-password | docker login …
          docker compose pull pretix
          if image digest moved → docker compose up -d pretix
            │
            ▼
   5. Visit https://advantix.tech — change is live.
            │
            ▼
   6. If broken: bash rollback-prod.sh <previous-short-sha>
      re-tags an older image as `latest`. Within 60s
      the poller rolls back.
```

Lower-latency alternative: `deployment/aws-demo/webhook-listener.py`
is a drop-in replacement for the poller that fires within ~1 second of
the master push instead of waiting for the timer. It's a strict
superset; pick one. The cron poller is recommended for the pilot
because it has zero public-facing HTTP surface on the EC2.

---

## One-time setup (do these in order)

### A. ECR repository

```sh
aws ecr describe-repositories --region us-east-1 --repository-names advantix-pretix-demo \
  || aws ecr create-repository --region us-east-1 --repository-name advantix-pretix-demo
```

(`deploy-demo-ec2.sh` already does this on first run, so if the demo
EC2 is already up, you're done.)

### B. GitHub Actions → ECR via OIDC

1. **AWS — create the OIDC identity provider** (once per AWS account):

   ```sh
   aws iam create-open-id-connect-provider \
     --url https://token.actions.githubusercontent.com \
     --client-id-list sts.amazonaws.com \
     --thumbprint-list 6938fd4d98bab03faadb97b34396831e3780aea1
   ```

2. **AWS — create an IAM role with a trust policy scoped to this repo + master + PRs against master**:

   Trust policy (replace `<acct-id>`):

   ```json
   {
     "Version": "2012-10-17",
     "Statement": [{
       "Effect": "Allow",
       "Principal": {
         "Federated": "arn:aws:iam::<acct-id>:oidc-provider/token.actions.githubusercontent.com"
       },
       "Action": "sts:AssumeRoleWithWebIdentity",
       "Condition": {
         "StringEquals": {
           "token.actions.githubusercontent.com:aud": "sts.amazonaws.com"
         },
         "StringLike": {
           "token.actions.githubusercontent.com:sub": [
             "repo:mantric/pretix:ref:refs/heads/master",
             "repo:mantric/pretix:pull_request"
           ]
         }
       }
     }]
   }
   ```

   Inline permissions policy (or a managed policy you attach):

   ```json
   {
     "Version": "2012-10-17",
     "Statement": [
       {
         "Effect": "Allow",
         "Action": [
           "ecr:GetAuthorizationToken"
         ],
         "Resource": "*"
       },
       {
         "Effect": "Allow",
         "Action": [
           "ecr:BatchCheckLayerAvailability",
           "ecr:BatchGetImage",
           "ecr:CompleteLayerUpload",
           "ecr:DescribeImages",
           "ecr:GetDownloadUrlForLayer",
           "ecr:InitiateLayerUpload",
           "ecr:PutImage",
           "ecr:UploadLayerPart"
         ],
         "Resource": "arn:aws:ecr:us-east-1:<acct-id>:repository/advantix-pretix-demo"
       }
     ]
   }
   ```

3. **GitHub — add the role ARN as a repository secret** named `ADVANTIX_ECR_PUSH_ROLE_ARN`.

   ```sh
   gh secret set ADVANTIX_ECR_PUSH_ROLE_ARN --repo mantric/pretix --body "arn:aws:iam::<acct-id>:role/<role-name>"
   ```

### C. EC2 — install the deploy poller

SSM into the running Advantix EC2 instance (or SSH if you prefer):

```sh
aws ssm start-session --target <instance-id>
```

Then on the instance:

```sh
cd /opt/advantix-pretix-demo

# If you haven't already pulled the pretix repo on the instance,
# rsync these files there or download them from the merged commit.
# E.g.:
sudo curl -fsSLo install-deploy-poller.sh \
  https://raw.githubusercontent.com/mantric/pretix/master/deployment/aws-demo/install-deploy-poller.sh
sudo curl -fsSLo advantix-deploy-poller.sh \
  https://raw.githubusercontent.com/mantric/pretix/master/deployment/aws-demo/advantix-deploy-poller.sh
sudo curl -fsSLo advantix-deploy-poller.service \
  https://raw.githubusercontent.com/mantric/pretix/master/deployment/aws-demo/advantix-deploy-poller.service
sudo curl -fsSLo advantix-deploy-poller.timer \
  https://raw.githubusercontent.com/mantric/pretix/master/deployment/aws-demo/advantix-deploy-poller.timer

sudo bash install-deploy-poller.sh
```

That writes `/etc/advantix-deploy.env`, copies the poller script to
`/opt/advantix-pretix-demo/`, installs the systemd unit + timer at
`/etc/systemd/system/`, and enables + starts the timer.

Verify:

```sh
sudo systemctl status advantix-deploy-poller.timer
sudo journalctl -u advantix-deploy-poller.service --since "5 minutes ago"
tail -f /var/log/advantix-deploy.log
```

### D. EC2 IAM permissions

The EC2 instance profile (`advantix-pretix-demo-ec2-role` per
`deploy-demo-ec2.sh`) already has `AmazonEC2ContainerRegistryReadOnly`
attached, so the poller can `aws ecr get-login-password` without
extra setup. No change needed.

---

## Operating the pipeline

### Watch a deploy in flight

```sh
# From your laptop:
gh run watch --repo mantric/pretix         # observe the GH Actions build
# Then on the EC2 (via SSM):
tail -f /var/log/advantix-deploy.log       # observe the pull/up
```

### Force an immediate deploy (skip waiting for the timer)

```sh
# On the EC2 (via SSM):
sudo systemctl start advantix-deploy-poller.service
```

### Roll back to a previous image

From your laptop (or anywhere with AWS credentials and docker):

```sh
bash deployment/aws-demo/rollback-prod.sh --list
# pick a short-sha you trust, then:
bash deployment/aws-demo/rollback-prod.sh <short-sha>

# Or just "go back one":
bash deployment/aws-demo/rollback-prod.sh
```

The script re-tags an older ECR image as `latest`. The poller picks
it up within 60s and rolls the container. No EC2-side action needed.

### Deploy a specific tag (not master HEAD)

```sh
bash deployment/aws-demo/rollback-prod.sh <short-sha>
```

— it's the same script. "Rollback" is just "deploy any tag I
choose"; the asymmetric naming is intentional so the operator
muscle memory matches the moment of urgency.

---

## Trade-offs and known sharp edges

- **`latest` is mutable.** Two simultaneous master merges can race;
  the second one wins. Acceptable for pilot (sequential review
  cadence), unacceptable for a multi-team prod. Fix: switch to
  digest-pinned task definitions (the appgraph ECS pattern).

- **Poller logs every cycle to the systemd journal.** That's a lot of
  noise. The shell script is quiet when there's no change (only logs
  when the digest moves), but `systemctl status` will show every
  invocation. Set `LogLevelMax=warning` in the unit if it's bothering
  you.

- **No automated rollback on bad health.** If a deploy breaks
  `/health`, the poller still deploys it. The pilot relies on
  reviewer attention + manual `rollback-prod.sh`. Add a health gate
  in the poller if you need automatic protection.

- **Webhook listener is unused by default.** It's checked in as an
  alternative for when sub-second latency matters. If you switch to
  it, the poller and the listener should NOT both be enabled — they
  would compete for `docker compose up -d`.

---

## Verifying the chain end-to-end

The canonical "did the pipeline work" smoke test:

1. From your laptop, open a tiny visible-change PR. Example: bump
   a copy string in `src/pretix/plugins/advantixtheme/`.
2. Watch the build:
   ```sh
   gh run watch --repo mantric/pretix
   ```
3. Merge the PR.
4. The merge triggers a `push` event on `master`. The image-build
   workflow re-runs and now pushes BOTH `<sha>` and `latest`.
5. Within 60s, the EC2 poller pulls `latest`. Tail
   `/var/log/advantix-deploy.log` for the `deployed digest …` line.
6. Refresh `https://advantix.tech/advantix/` — your change is live.

If step 6 fails, `bash rollback-prod.sh` returns to the previous SHA
in under a minute.
