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
REPO_URL="${REPO_URL:?set REPO_URL in $ENV_FILE}"
BRANCH="${BRANCH:-main}"
APP_PORT="${APP_PORT:-3000}"
CANDIDATE_PORT="${CANDIDATE_PORT:-3001}"
CONTAINER_PORT="${CONTAINER_PORT:-3000}"
HEALTH_PATH="${HEALTH_PATH:-/api/ping}"
DB_HEALTH_PATH="${DB_HEALTH_PATH:-/api/notes}"
POSTGRES_DB="${POSTGRES_DB:-vision_template}"
POSTGRES_USER="${POSTGRES_USER:-visiontemplate}"
POSTGRES_PASSWORD="${POSTGRES_PASSWORD:?set POSTGRES_PASSWORD in $ENV_FILE}"
DATABASE_URL="${DATABASE_URL:?set DATABASE_URL in $ENV_FILE}"
NETWORK_NAME="${NETWORK_NAME:-${APP_NAME}-net}"
DB_CONTAINER="${DB_CONTAINER:-${APP_NAME}-db}"
DB_COMPOSE_PROJECT="${DB_COMPOSE_PROJECT:-$APP_NAME}"
RELEASES_DIR="${RELEASES_DIR:-$APP_ROOT/releases}"
REPO_DIR="${REPO_DIR:-$APP_ROOT/repo}"
LOG_DIR="${LOG_DIR:-$APP_ROOT/logs}"
CURRENT_IMAGE_FILE="${CURRENT_IMAGE_FILE:-$APP_ROOT/current-image}"
PREVIOUS_IMAGE_FILE="${PREVIOUS_IMAGE_FILE:-$APP_ROOT/previous-image}"
DEPLOY_LOCK_FILE="${DEPLOY_LOCK_FILE:-$APP_ROOT/deploy.lock}"
LIVE_CONTAINER="${LIVE_CONTAINER:-${APP_NAME}-app}"
CANDIDATE_CONTAINER="${CANDIDATE_CONTAINER:-${APP_NAME}-candidate}"

mkdir -p "$RELEASES_DIR" "$LOG_DIR"
exec > >(tee -a "$LOG_DIR/deploy.log") 2>&1

exec 9>"$DEPLOY_LOCK_FILE"
if ! flock -n 9; then
  echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] deploy already running"
  exit 75
fi

export APP_NAME NETWORK_NAME DB_CONTAINER POSTGRES_DB POSTGRES_USER POSTGRES_PASSWORD

log() {
  echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] $*"
}

container_exists() {
  docker ps -a --format '{{.Names}}' | grep -Fxq "$1"
}

cleanup_candidate() {
  docker rm -f "$CANDIDATE_CONTAINER" >/dev/null 2>&1 || true
}

wait_for_http() {
  local label="$1"
  local url="$2"
  local attempts="${3:-30}"

  for _ in $(seq 1 "$attempts"); do
    if curl -fsS --max-time 3 "$url" >/dev/null; then
      return 0
    fi
    sleep 2
  done

  log "health check failed for $label at $url"
  return 1
}

run_app_container() {
  local container_name="$1"
  local image="$2"
  local host_port="$3"
  local restart_policy="$4"

  docker run -d \
    --name "$container_name" \
    --restart "$restart_policy" \
    --network "$NETWORK_NAME" \
    --env-file "$ENV_FILE" \
    -e NODE_ENV=production \
    -e PORT="$CONTAINER_PORT" \
    -p "127.0.0.1:${host_port}:${CONTAINER_PORT}" \
    --label "app=$APP_NAME" \
    "$image" >/dev/null
}

rollback_to() {
  local image="$1"
  local image_to_store_as_previous="${2:-}"

  if [[ -z "$image" ]]; then
    log "rollback requested, but no previous image is recorded"
    return 1
  fi

  log "rolling back live container to $image"
  docker rm -f "$LIVE_CONTAINER" >/dev/null 2>&1 || true
  run_app_container "$LIVE_CONTAINER" "$image" "$APP_PORT" "unless-stopped"

  if ! wait_for_http "rollback app" "http://127.0.0.1:${APP_PORT}${HEALTH_PATH}"; then
    docker logs "$LIVE_CONTAINER" --tail=120 || true
    return 1
  fi

  printf '%s\n' "$image" > "$CURRENT_IMAGE_FILE"
  if [[ -n "$image_to_store_as_previous" ]]; then
    printf '%s\n' "$image_to_store_as_previous" > "$PREVIOUS_IMAGE_FILE"
  fi
  log "rollback is live"
}

if [[ "${1:-}" == "--rollback" ]]; then
  previous_image="$(cat "$PREVIOUS_IMAGE_FILE" 2>/dev/null || true)"
  current_image="$(cat "$CURRENT_IMAGE_FILE" 2>/dev/null || true)"
  rollback_to "$previous_image" "$current_image"
  exit $?
fi

trap cleanup_candidate EXIT

target_ref="${1:-origin/$BRANCH}"

if [[ ! -d "$REPO_DIR/.git" ]]; then
  log "cloning $REPO_URL into $REPO_DIR"
  git clone "$REPO_URL" "$REPO_DIR"
else
  git -C "$REPO_DIR" remote set-url origin "$REPO_URL"
fi

log "fetching origin/$BRANCH"
git -C "$REPO_DIR" fetch --prune origin "$BRANCH"

if [[ "$target_ref" =~ ^[0-9a-f]{40}$ ]]; then
  target_sha="$(git -C "$REPO_DIR" rev-parse "${target_ref}^{commit}")"
else
  target_sha="$(git -C "$REPO_DIR" rev-parse "$target_ref^{commit}")"
fi

if ! git -C "$REPO_DIR" merge-base --is-ancestor "$target_sha" "origin/$BRANCH"; then
  log "refusing to deploy $target_sha because it is not on origin/$BRANCH"
  exit 1
fi

release_dir="$RELEASES_DIR/$target_sha"
if [[ ! -d "$release_dir/.git" ]]; then
  rm -rf "$release_dir"
  log "creating release worktree $release_dir"
  git -C "$REPO_DIR" worktree prune
  git -C "$REPO_DIR" worktree add --detach "$release_dir" "$target_sha"
fi

compose_file="$release_dir/ops/docker-compose.db.yml"
if [[ ! -f "$compose_file" ]]; then
  log "missing $compose_file; the target commit does not contain the VPS ops files"
  exit 1
fi

log "starting Postgres"
docker compose --env-file "$ENV_FILE" -f "$compose_file" -p "$DB_COMPOSE_PROJECT" up -d db

for _ in $(seq 1 30); do
  if docker exec "$DB_CONTAINER" pg_isready -U "$POSTGRES_USER" -d "$POSTGRES_DB" >/dev/null 2>&1; then
    break
  fi
  sleep 2
done

if ! docker exec "$DB_CONTAINER" pg_isready -U "$POSTGRES_USER" -d "$POSTGRES_DB" >/dev/null 2>&1; then
  log "Postgres did not become ready"
  docker logs "$DB_CONTAINER" --tail=120 || true
  exit 1
fi

log "applying idempotent database setup"
docker exec -i "$DB_CONTAINER" psql -v ON_ERROR_STOP=1 -U "$POSTGRES_USER" -d "$POSTGRES_DB" < "$release_dir/db/setup.sql"

image="${APP_NAME}-app:${target_sha}"
log "building $image"
docker build --pull \
  --label "app=$APP_NAME" \
  --label "org.opencontainers.image.revision=$target_sha" \
  -t "$image" \
  "$release_dir"

cleanup_candidate
log "starting candidate container on 127.0.0.1:$CANDIDATE_PORT"
run_app_container "$CANDIDATE_CONTAINER" "$image" "$CANDIDATE_PORT" "no"

wait_for_http "candidate app" "http://127.0.0.1:${CANDIDATE_PORT}${HEALTH_PATH}"
wait_for_http "candidate database route" "http://127.0.0.1:${CANDIDATE_PORT}${DB_HEALTH_PATH}"

old_image="$(cat "$CURRENT_IMAGE_FILE" 2>/dev/null || true)"

log "candidate passed; switching live container"
docker rm -f "$LIVE_CONTAINER" >/dev/null 2>&1 || true

if ! run_app_container "$LIVE_CONTAINER" "$image" "$APP_PORT" "unless-stopped"; then
  log "failed to start live container"
  rollback_to "$old_image" || true
  exit 1
fi

if ! wait_for_http "live app" "http://127.0.0.1:${APP_PORT}${HEALTH_PATH}" ||
   ! wait_for_http "live database route" "http://127.0.0.1:${APP_PORT}${DB_HEALTH_PATH}"; then
  log "new live container failed smoke tests"
  docker logs "$LIVE_CONTAINER" --tail=120 || true
  rollback_to "$old_image" || true
  exit 1
fi

printf '%s\n' "$image" > "$CURRENT_IMAGE_FILE"
if [[ -n "$old_image" ]]; then
  printf '%s\n' "$old_image" > "$PREVIOUS_IMAGE_FILE"
fi

cleanup_candidate
find "$RELEASES_DIR" -mindepth 1 -maxdepth 1 -type d -printf '%T@ %p\n' |
  sort -nr |
  awk 'NR > 5 {print $2}' |
  xargs -r rm -rf

log "deployed $target_sha successfully"
