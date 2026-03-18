#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
DEPLOY_DIR="$ROOT_DIR/deployment/aws-demo"

AWS_REGION="${AWS_REGION:-ap-south-1}"
APP_NAME="${APP_NAME:-advantix-pretix-demo}"
INSTANCE_TYPE="${INSTANCE_TYPE:-t3.small}"
VOLUME_SIZE_GB="${VOLUME_SIZE_GB:-30}"

ROLE_NAME="${APP_NAME}-ec2-role"
PROFILE_NAME="${APP_NAME}-instance-profile"
SG_NAME="${APP_NAME}-sg"
REPO_NAME="${APP_NAME}"
INSTANCE_NAME="${APP_NAME}-instance"

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "Missing required command: $1" >&2
    exit 1
  }
}

require_cmd aws
require_cmd docker
require_cmd jq
require_cmd base64
require_cmd openssl

ACCOUNT_ID="$(aws sts get-caller-identity --query Account --output text)"
REGISTRY="${ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com"
IMAGE_URI="${REGISTRY}/${REPO_NAME}:latest"

ADMIN_EMAIL="${ADMIN_EMAIL:-admin@advantix.demo}"
ADMIN_PASSWORD="${ADMIN_PASSWORD:-$(openssl rand -base64 18 | tr -d '\n' | tr '/+' 'ab')}"
DJANGO_SECRET="$(openssl rand -hex 32)"
DB_PASSWORD="$(openssl rand -base64 24 | tr -d '\n' | tr '/+' 'xy')"

TMP_DIR="$(mktemp -d)"
cleanup() {
  rm -rf "$TMP_DIR"
}
trap cleanup EXIT

ssm_wait_online() {
  local instance_id="$1"
  echo "Waiting for SSM on ${instance_id}..."
  for _ in $(seq 1 90); do
    local status
    status="$(aws ssm describe-instance-information \
      --region "$AWS_REGION" \
      --filters "Key=InstanceIds,Values=${instance_id}" \
      --query 'InstanceInformationList[0].PingStatus' \
      --output text 2>/dev/null || true)"
    if [[ "$status" == "Online" ]]; then
      return 0
    fi
    sleep 10
  done
  echo "SSM did not come online in time" >&2
  exit 1
}

ssm_run() {
  local instance_id="$1"
  shift
  local commands_json
  commands_json="$(printf '%s\n' "$@" | jq -R . | jq -s .)"
  local command_id
  command_id="$(aws ssm send-command \
    --region "$AWS_REGION" \
    --instance-ids "$instance_id" \
    --document-name "AWS-RunShellScript" \
    --comment "${APP_NAME} deployment step" \
    --parameters "{\"commands\":${commands_json}}" \
    --query 'Command.CommandId' \
    --output text)"
  aws ssm wait command-executed --region "$AWS_REGION" --command-id "$command_id" --instance-id "$instance_id"
  aws ssm get-command-invocation \
    --region "$AWS_REGION" \
    --command-id "$command_id" \
    --instance-id "$instance_id" \
    --query '{Status:Status,Stdout:StandardOutputContent,Stderr:StandardErrorContent}' \
    --output json
}

send_file() {
  local instance_id="$1"
  local local_path="$2"
  local remote_path="$3"
  local remote_dir mode b64
  remote_dir="$(dirname "$remote_path")"
  mode="${4:-0644}"
  b64="$(base64 -w0 "$local_path")"
  ssm_run "$instance_id" \
    "sudo mkdir -p '$remote_dir'" \
    "echo '$b64' | base64 -d | sudo tee '$remote_path' >/dev/null" \
    "sudo chmod $mode '$remote_path'" >/dev/null
}

echo "Ensuring ECR repository..."
aws ecr describe-repositories --region "$AWS_REGION" --repository-names "$REPO_NAME" >/dev/null 2>&1 || \
  aws ecr create-repository --region "$AWS_REGION" --repository-name "$REPO_NAME" >/dev/null

echo "Building and pushing image to ${IMAGE_URI}..."
aws ecr get-login-password --region "$AWS_REGION" | docker login --username AWS --password-stdin "$REGISTRY" >/dev/null
docker build -t "${IMAGE_URI}" "$ROOT_DIR"
docker push "${IMAGE_URI}"

echo "Ensuring IAM role and instance profile..."
if ! aws iam get-role --role-name "$ROLE_NAME" >/dev/null 2>&1; then
  cat >"$TMP_DIR/trust-policy.json" <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": { "Service": "ec2.amazonaws.com" },
      "Action": "sts:AssumeRole"
    }
  ]
}
EOF
  aws iam create-role --role-name "$ROLE_NAME" --assume-role-policy-document "file://$TMP_DIR/trust-policy.json" >/dev/null
fi

for policy in \
  arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore \
  arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly
do
  aws iam attach-role-policy --role-name "$ROLE_NAME" --policy-arn "$policy" >/dev/null
done

if ! aws iam get-instance-profile --instance-profile-name "$PROFILE_NAME" >/dev/null 2>&1; then
  aws iam create-instance-profile --instance-profile-name "$PROFILE_NAME" >/dev/null
  sleep 5
fi

if ! aws iam get-instance-profile --instance-profile-name "$PROFILE_NAME" \
    --query "InstanceProfile.Roles[?RoleName=='${ROLE_NAME}'] | length(@)" --output text | grep -q '^1$'; then
  aws iam add-role-to-instance-profile --instance-profile-name "$PROFILE_NAME" --role-name "$ROLE_NAME" >/dev/null || true
fi

VPC_ID="$(aws ec2 describe-vpcs --region "$AWS_REGION" --filters Name=is-default,Values=true --query 'Vpcs[0].VpcId' --output text)"
SUBNET_ID="$(aws ec2 describe-subnets --region "$AWS_REGION" --filters Name=default-for-az,Values=true --query 'Subnets[0].SubnetId' --output text)"
AMI_ID="$(aws ssm get-parameter --region "$AWS_REGION" --name /aws/service/ami-amazon-linux-latest/al2023-ami-kernel-6.1-x86_64 --query 'Parameter.Value' --output text)"

echo "Ensuring security group..."
SG_ID="$(aws ec2 describe-security-groups --region "$AWS_REGION" --filters "Name=group-name,Values=${SG_NAME}" "Name=vpc-id,Values=${VPC_ID}" --query 'SecurityGroups[0].GroupId' --output text)"
if [[ "$SG_ID" == "None" || -z "$SG_ID" ]]; then
  SG_ID="$(aws ec2 create-security-group --region "$AWS_REGION" --group-name "$SG_NAME" --description "Security group for ${APP_NAME}" --vpc-id "$VPC_ID" --query 'GroupId' --output text)"
fi
aws ec2 authorize-security-group-ingress --region "$AWS_REGION" --group-id "$SG_ID" --ip-permissions '[
  {"IpProtocol":"tcp","FromPort":80,"ToPort":80,"IpRanges":[{"CidrIp":"0.0.0.0/0","Description":"HTTP"}]},
  {"IpProtocol":"tcp","FromPort":443,"ToPort":443,"IpRanges":[{"CidrIp":"0.0.0.0/0","Description":"HTTPS future use"}]}
]' >/dev/null 2>&1 || true

INSTANCE_ID="$(aws ec2 describe-instances --region "$AWS_REGION" \
  --filters "Name=tag:Name,Values=${INSTANCE_NAME}" "Name=instance-state-name,Values=pending,running,stopping,stopped" \
  --query 'Reservations[0].Instances[0].InstanceId' --output text)"

if [[ "$INSTANCE_ID" == "None" || -z "$INSTANCE_ID" ]]; then
  cat >"$TMP_DIR/user-data.sh" <<EOF
#!/bin/bash
set -euxo pipefail
dnf update -y
dnf install -y docker cronie jq awscli
systemctl enable --now docker
mkdir -p /usr/local/lib/docker/cli-plugins /usr/local/bin
curl -SL https://github.com/docker/compose/releases/download/v2.36.2/docker-compose-linux-x86_64 \
  -o /usr/local/lib/docker/cli-plugins/docker-compose
chmod +x /usr/local/lib/docker/cli-plugins/docker-compose
ln -sf /usr/local/lib/docker/cli-plugins/docker-compose /usr/local/bin/docker-compose
systemctl enable --now crond
mkdir -p /opt/${APP_NAME}/data
chown -R ec2-user:ec2-user /opt/${APP_NAME}
EOF
  INSTANCE_ID="$(aws ec2 run-instances \
    --region "$AWS_REGION" \
    --image-id "$AMI_ID" \
    --instance-type "$INSTANCE_TYPE" \
    --iam-instance-profile Name="$PROFILE_NAME" \
    --security-group-ids "$SG_ID" \
    --subnet-id "$SUBNET_ID" \
    --associate-public-ip-address \
    --block-device-mappings "[{\"DeviceName\":\"/dev/xvda\",\"Ebs\":{\"VolumeSize\":${VOLUME_SIZE_GB},\"VolumeType\":\"gp3\",\"DeleteOnTermination\":true}}]" \
    --tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=${INSTANCE_NAME}},{Key=Project,Value=${APP_NAME}},{Key=Environment,Value=demo}]" \
    --user-data "file://${TMP_DIR}/user-data.sh" \
    --query 'Instances[0].InstanceId' \
    --output text)"
fi

aws ec2 wait instance-running --region "$AWS_REGION" --instance-ids "$INSTANCE_ID"

ALLOC_ID="$(aws ec2 describe-addresses --region "$AWS_REGION" --filters "Name=tag:Project,Values=${APP_NAME}" --query 'Addresses[0].AllocationId' --output text)"
if [[ "$ALLOC_ID" == "None" || -z "$ALLOC_ID" ]]; then
  ALLOC_ID="$(aws ec2 allocate-address --region "$AWS_REGION" --domain vpc --tag-specifications "ResourceType=elastic-ip,Tags=[{Key=Project,Value=${APP_NAME}},{Key=Name,Value=${APP_NAME}-eip}]" --query 'AllocationId' --output text)"
fi
aws ec2 associate-address --region "$AWS_REGION" --instance-id "$INSTANCE_ID" --allocation-id "$ALLOC_ID" --allow-reassociation >/dev/null
PUBLIC_IP="$(aws ec2 describe-addresses --region "$AWS_REGION" --allocation-ids "$ALLOC_ID" --query 'Addresses[0].PublicIp' --output text)"

ssm_wait_online "$INSTANCE_ID"

SITE_HOST="$PUBLIC_IP"
APP_DIR="/opt/${APP_NAME}"

sed \
  -e "s|__SITE_HOST__|${SITE_HOST}|g" \
  -e "s|__DB_PASSWORD__|${DB_PASSWORD}|g" \
  -e "s|__DJANGO_SECRET__|${DJANGO_SECRET}|g" \
  "$DEPLOY_DIR/pretix.cfg.template" > "$TMP_DIR/pretix.cfg"

cat >"$TMP_DIR/.env" <<EOF
PRETIX_IMAGE=${IMAGE_URI}
POSTGRES_PASSWORD=${DB_PASSWORD}
EOF

send_file "$INSTANCE_ID" "$DEPLOY_DIR/docker-compose.yml" "${APP_DIR}/docker-compose.yml"
send_file "$INSTANCE_ID" "$DEPLOY_DIR/nginx.conf" "${APP_DIR}/nginx.conf"
send_file "$INSTANCE_ID" "$TMP_DIR/pretix.cfg" "${APP_DIR}/pretix.cfg"
send_file "$INSTANCE_ID" "$TMP_DIR/.env" "${APP_DIR}/.env" 0600

cat >"$TMP_DIR/cronfile" <<EOF
SHELL=/bin/bash
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
*/5 * * * * root cd ${APP_DIR} && /usr/bin/docker compose run --rm pretix cron >> /var/log/${APP_NAME}-cron.log 2>&1
EOF
send_file "$INSTANCE_ID" "$TMP_DIR/cronfile" "/etc/cron.d/${APP_NAME}"

echo "Starting containers on instance..."
ssm_run "$INSTANCE_ID" \
  "set -euo pipefail" \
  "cd '${APP_DIR}'" \
  "aws ecr get-login-password --region '${AWS_REGION}' | docker login --username AWS --password-stdin '${REGISTRY}'" \
  "docker compose pull || true" \
  "mkdir -p data" \
  "PRETIX_UID=\$(docker run --rm --entrypoint sh '${IMAGE_URI}' -lc 'id -u pretixuser')" \
  "PRETIX_GID=\$(docker run --rm --entrypoint sh '${IMAGE_URI}' -lc 'id -g pretixuser')" \
  "chown -R \${PRETIX_UID}:\${PRETIX_GID} data" \
  "docker compose up -d db redis pretix" \
  "sudo systemctl restart crond" >/dev/null

echo "Waiting for pretix container..."
ssm_run "$INSTANCE_ID" \
  "set -euo pipefail" \
  "cd '${APP_DIR}'" \
  "for i in \$(seq 1 60); do docker compose ps --services --filter status=running | grep -q '^pretix$' && exit 0; sleep 5; done; exit 1" >/dev/null

cat >"$TMP_DIR/seed.py" <<EOF
from datetime import timedelta
from decimal import Decimal

from django.contrib.auth import get_user_model
from django.utils.timezone import now
from django_scopes import scope

from pretix.base.models import Event, Item, Organizer, Quota
from pretix.base.payment import ManualPayment

User = get_user_model()
user, created = User.objects.get_or_create(email="${ADMIN_EMAIL}", defaults={"is_staff": True, "is_superuser": True, "is_active": True})
if created:
    user.set_password("${ADMIN_PASSWORD}")
    user.fullname = "Advantix Admin"
    user.save()

orga, _ = Organizer.objects.get_or_create(name="Advantix", slug="advantix")
orga.settings.primary_color = "#e36414"
orga.settings.theme_color_success = "#2a9d8f"
orga.settings.theme_color_danger = "#c1121f"
orga.settings.theme_color_background = "#fff7ed"
orga.settings.organizer_homepage_text = "Advantix is a demo storefront for movie and entertainment ticket sales in India."
orga.settings.contact_mail = "demo@advantix.local"
orga.save()

events = [
    {
        "slug": "mumbai-movie-night",
        "name": "Mumbai Movie Night",
        "location": "PVR Juhu, Mumbai",
        "days": 10,
        "items": [
            ("Silver Seat", Decimal("299.00"), 250),
            ("Premium Seat", Decimal("599.00"), 100),
        ],
    },
    {
        "slug": "bangalore-live-comedy",
        "name": "Bangalore Live Comedy",
        "location": "Koramangala Indoor Arena, Bengaluru",
        "days": 18,
        "items": [
            ("General Admission", Decimal("499.00"), 300),
            ("Front Row", Decimal("999.00"), 60),
        ],
    },
]

with scope(organizer=orga):
    for spec in events:
        event, created = Event.objects.get_or_create(
            organizer=orga,
            slug=spec["slug"],
            defaults={
                "name": spec["name"],
                "currency": "INR",
                "date_from": now() + timedelta(days=spec["days"]),
                "date_to": now() + timedelta(days=spec["days"], hours=3),
                "presale_start": now() - timedelta(days=1),
                "presale_end": now() + timedelta(days=spec["days"], hours=1),
                "location": spec["location"],
                "live": True,
                "is_public": True,
                "plugins": "pretix.plugins.sendmail,pretix.plugins.statistics,pretix.plugins.checkinlists,pretix.plugins.manualpayment",
            },
        )
        if created:
            event.set_defaults()
        event.live = True
        event.is_public = True
        event.plugins = "pretix.plugins.sendmail,pretix.plugins.statistics,pretix.plugins.checkinlists,pretix.plugins.manualpayment"
        event.settings.timezone = "Asia/Kolkata"
        event.settings.primary_color = "#e36414"
        event.settings.theme_color_success = "#2a9d8f"
        event.settings.theme_color_danger = "#c1121f"
        event.settings.theme_color_background = "#fff7ed"
        event.settings.contact_mail = "demo@advantix.local"
        event.settings.banner_text = "Demo checkout only. No real tickets or payments are being processed."
        event.save()

        manual = ManualPayment(event)
        manual.settings.set("_enabled", True)
        manual.settings.set("public_name", "Reserve now, pay later")
        manual.settings.set("checkout_description", "This is a demo payment method. No real money is collected.")
        manual.settings.set("pending_description", "Your demo order was created. No payment is required.")

        quota = event.quotas.filter(name="Main quota").first()
        if quota is None:
            quota = Quota.objects.create(event=event, name="Main quota", size=None)

        event_items = []
        for pos, (name, price, max_per_order) in enumerate(spec["items"], start=1):
            item, _ = Item.objects.get_or_create(
                event=event,
                name=name,
                defaults={
                    "default_price": price,
                    "admission": True,
                    "active": True,
                    "description": f"{name} for {spec['name']}",
                    "position": pos,
                    "max_per_order": max_per_order,
                },
            )
            item.default_price = price
            item.active = True
            item.admission = True
            item.save()
            event_items.append(item)

        quota.items.set(event_items)

print("seed-complete")
EOF
send_file "$INSTANCE_ID" "$TMP_DIR/seed.py" "${APP_DIR}/seed.py"

echo "Seeding admin user and demo data..."
ssm_run "$INSTANCE_ID" \
  "set -euo pipefail" \
  "cd '${APP_DIR}'" \
  "docker compose exec -T pretix python3 -m pretix shell < '${APP_DIR}/seed.py'" >/dev/null

echo
echo "Deployment complete"
echo "Region:          ${AWS_REGION}"
echo "Instance ID:     ${INSTANCE_ID}"
echo "Public IP:       ${PUBLIC_IP}"
echo "Organizer URL:   http://${PUBLIC_IP}/advantix/"
echo "Event URL:       http://${PUBLIC_IP}/advantix/mumbai-movie-night/"
echo "Backend URL:     http://${PUBLIC_IP}/control/"
echo "Admin email:     ${ADMIN_EMAIL}"
echo "Admin password:  ${ADMIN_PASSWORD}"
