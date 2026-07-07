#!/usr/bin/env bash
set -Eeuo pipefail

if [[ "$(id -u)" -ne 0 ]]; then
  echo "Run this as root on the VPS."
  exit 1
fi

APP_ROOT="${APP_ROOT:-/opt/visiontemplate}"

if [[ -f "$APP_ROOT/.env" ]]; then
  set -a
  # shellcheck disable=SC1090
  source "$APP_ROOT/.env"
  set +a
fi

APP_NAME="${APP_NAME:-visiontemplate}"
APP_HOST="${APP_HOST:?set APP_HOST to the subdomain you pointed at this VPS}"
SYSTEM_USER="${SYSTEM_USER:-visiondeploy}"
REPO_URL="${REPO_URL:-https://github.com/YOUR_GITHUB_USER/visiontemplate.git}"
SOURCE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

apt-get update
apt-get install -y ca-certificates curl gnupg git nginx certbot python3-certbot-nginx nodejs openssl

if ! command -v docker >/dev/null 2>&1; then
  install -m 0755 -d /etc/apt/keyrings
  curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
  chmod a+r /etc/apt/keyrings/docker.asc
  . /etc/os-release
  echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu ${VERSION_CODENAME} stable" > /etc/apt/sources.list.d/docker.list
  apt-get update
  apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
fi

if ! id "$SYSTEM_USER" >/dev/null 2>&1; then
  useradd --system --home "$APP_ROOT" --create-home --shell /usr/sbin/nologin "$SYSTEM_USER"
fi
usermod -aG docker "$SYSTEM_USER"

install -d -o "$SYSTEM_USER" -g "$SYSTEM_USER" "$APP_ROOT" "$APP_ROOT/bin" "$APP_ROOT/logs" "$APP_ROOT/releases" "$APP_ROOT/backups/postgres"
install -m 0755 "$SOURCE_DIR/ops/deploy/deploy.sh" "$APP_ROOT/bin/deploy.sh"
install -m 0755 "$SOURCE_DIR/ops/deploy/backup-postgres.sh" "$APP_ROOT/bin/backup-postgres.sh"
install -m 0755 "$SOURCE_DIR/ops/deploy/webhook.js" "$APP_ROOT/bin/webhook.js"
chown -R "$SYSTEM_USER:$SYSTEM_USER" "$APP_ROOT"

if [[ ! -f "$APP_ROOT/.env" ]]; then
  postgres_password="$(openssl rand -hex 24)"
  webhook_secret="$(openssl rand -hex 32)"

  install -m 0600 -o "$SYSTEM_USER" -g "$SYSTEM_USER" "$SOURCE_DIR/.env.example" "$APP_ROOT/.env"
  sed -i "s|^APP_NAME=.*|APP_NAME=$APP_NAME|" "$APP_ROOT/.env"
  sed -i "s|^APP_HOST=.*|APP_HOST=$APP_HOST|" "$APP_ROOT/.env"
  sed -i "s|^REPO_URL=.*|REPO_URL=$REPO_URL|" "$APP_ROOT/.env"
  sed -i "s|^POSTGRES_PASSWORD=.*|POSTGRES_PASSWORD=$postgres_password|" "$APP_ROOT/.env"
  sed -i "s|^DATABASE_URL=.*|DATABASE_URL=postgresql://visiontemplate:$postgres_password@${APP_NAME}-db:5432/vision_template|" "$APP_ROOT/.env"
  sed -i "s|^GITHUB_WEBHOOK_SECRET=.*|GITHUB_WEBHOOK_SECRET=$webhook_secret|" "$APP_ROOT/.env"
  echo "Created $APP_ROOT/.env with generated secrets. Review REPO_URL and DATABASE_URL, then run this script again."
  exit 0
fi

install -m 0644 "$SOURCE_DIR/ops/systemd/visiontemplate-webhook.service" /etc/systemd/system/visiontemplate-webhook.service
install -m 0644 "$SOURCE_DIR/ops/systemd/visiontemplate-backup.service" /etc/systemd/system/visiontemplate-backup.service
install -m 0644 "$SOURCE_DIR/ops/systemd/visiontemplate-backup.timer" /etc/systemd/system/visiontemplate-backup.timer

sed "s|__APP_HOST__|$APP_HOST|g" "$SOURCE_DIR/ops/nginx/visiontemplate.conf" > /etc/nginx/sites-available/visiontemplate.conf
ln -sfn /etc/nginx/sites-available/visiontemplate.conf /etc/nginx/sites-enabled/visiontemplate.conf
rm -f /etc/nginx/sites-enabled/default
nginx -t

systemctl daemon-reload
systemctl enable --now nginx
systemctl enable --now visiontemplate-webhook.service
systemctl enable --now visiontemplate-backup.timer

echo "Bootstrap complete. Run: sudo -u $SYSTEM_USER APP_ROOT=$APP_ROOT $APP_ROOT/bin/deploy.sh"
echo "After the first deploy succeeds, run: certbot --nginx -d $APP_HOST"
