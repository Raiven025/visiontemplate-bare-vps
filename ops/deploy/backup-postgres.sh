#!/usr/bin/env bash
set -Eeuo pipefail

APP_ROOT="${APP_ROOT:-/opt/visiontemplate}"
ENV_FILE="${ENV_FILE:-$APP_ROOT/.env}"

if [[ -f "$ENV_FILE" ]]; then
  set -a
  # shellcheck disable=SC1090
  source "$ENV_FILE"
  set +a
fi

APP_NAME="${APP_NAME:-visiontemplate}"
POSTGRES_DB="${POSTGRES_DB:-vision_template}"
POSTGRES_USER="${POSTGRES_USER:-visiontemplate}"
DB_CONTAINER="${DB_CONTAINER:-${APP_NAME}-db}"
BACKUP_DIR="${BACKUP_DIR:-$APP_ROOT/backups/postgres}"
BACKUP_RETENTION_DAYS="${BACKUP_RETENTION_DAYS:-14}"
LOG_DIR="${LOG_DIR:-$APP_ROOT/logs}"

mkdir -p "$BACKUP_DIR" "$LOG_DIR"
exec > >(tee -a "$LOG_DIR/backup.log") 2>&1

timestamp="$(date -u +%Y%m%dT%H%M%SZ)"
tmp_file="$BACKUP_DIR/${POSTGRES_DB}_${timestamp}.dump.tmp"
final_file="$BACKUP_DIR/${POSTGRES_DB}_${timestamp}.dump"

echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] backing up $POSTGRES_DB from $DB_CONTAINER"
docker exec "$DB_CONTAINER" pg_dump -Fc -U "$POSTGRES_USER" -d "$POSTGRES_DB" > "$tmp_file"
mv "$tmp_file" "$final_file"

find "$BACKUP_DIR" -type f -name "${POSTGRES_DB}_*.dump" -mtime "+$BACKUP_RETENTION_DAYS" -delete
echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] wrote $final_file"
