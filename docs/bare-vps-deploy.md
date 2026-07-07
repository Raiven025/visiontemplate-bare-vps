# Bare VPS deployment

This setup runs VisionTemplate on an ordinary Ubuntu VPS with Docker, nginx,
Postgres, a signed GitHub webhook, rollback-on-failed-deploy, and daily database
backups. It does not use Heroku, Vercel, or a managed app platform.

## What the VPS runs

- `visiontemplate-db`: Postgres 16 with a persistent Docker volume.
- `visiontemplate-app`: the live app container, bound to `127.0.0.1:3000`.
- `visiontemplate-candidate`: a temporary container used for deploy smoke tests.
- nginx: public reverse proxy for the app and GitHub webhook endpoint.
- `visiontemplate-webhook.service`: verifies GitHub HMAC signatures and starts deploys.
- `visiontemplate-backup.timer`: runs a daily `pg_dump -Fc` backup.

## One-time setup

1. Create a GitHub repo from this code and push it.
2. Point a DNS `A` record at the VPS, for example `vision.yourdomain.com`.
3. SSH into a fresh Ubuntu 22.04 or 24.04 VPS as root.
4. Clone your repo and run the bootstrap script:

```bash
git clone https://github.com/YOUR_GITHUB_USER/visiontemplate.git
cd visiontemplate
APP_HOST=vision.yourdomain.com \
REPO_URL=https://github.com/YOUR_GITHUB_USER/visiontemplate.git \
./ops/deploy/bootstrap-ubuntu.sh
```

The first run creates `/opt/visiontemplate/.env` with random hex secrets and
stops so you can review it. At minimum, verify:

- `REPO_URL`
- `POSTGRES_PASSWORD`
- `DATABASE_URL` with the same Postgres password
- `GITHUB_WEBHOOK_SECRET`

Then rerun bootstrap and start the first deploy:

```bash
./ops/deploy/bootstrap-ubuntu.sh
sudo -u visiondeploy APP_ROOT=/opt/visiontemplate /opt/visiontemplate/bin/deploy.sh
certbot --nginx -d vision.yourdomain.com
```

Keep the generated secrets shell-safe and URL-safe. The bootstrap script uses
hex strings for that reason.

## GitHub webhook

In the GitHub repo, add a webhook:

- Payload URL: `https://vision.yourdomain.com/_deploy/github`
- Content type: `application/json`
- Secret: the value of `GITHUB_WEBHOOK_SECRET`
- Events: push events only

On every push to `main`, the webhook deploys the pushed commit SHA.

## Deploy behavior

`deploy.sh` fetches the target commit, creates a release worktree, starts or
updates Postgres, applies `db/setup.sql`, builds a Docker image tagged with the
commit SHA, and starts a candidate container on `127.0.0.1:3001`.

The candidate must pass:

- `GET /api/ping`
- `GET /api/notes`

Only after those checks pass does the script replace the live container. If the
live container fails its final smoke tests, the script starts the previous image
again and exits non-zero.

Manual rollback:

```bash
sudo -u visiondeploy APP_ROOT=/opt/visiontemplate /opt/visiontemplate/bin/deploy.sh --rollback
```

## Backups

Backups are stored in `/opt/visiontemplate/backups/postgres` and retained for
`BACKUP_RETENTION_DAYS` days.

Run one manually:

```bash
systemctl start visiontemplate-backup.service
ls -lh /opt/visiontemplate/backups/postgres
```

Restore example:

```bash
docker exec -i visiontemplate-db pg_restore \
  --clean --if-exists \
  -U visiontemplate \
  -d vision_template \
  < /opt/visiontemplate/backups/postgres/vision_template_YYYYMMDDTHHMMSSZ.dump
```

## Verification script for the application

Successful push:

```bash
git commit --allow-empty -m "test deploy"
git push origin main
ssh root@YOUR_VPS 'journalctl -u visiontemplate-webhook.service -n 80 --no-pager'
curl -fsS https://vision.yourdomain.com/api/ping
curl -fsS https://vision.yourdomain.com/api/notes
```

Broken push:

```bash
printf '\nthis is not valid ts\n' >> app/routes/home.tsx
git add app/routes/home.tsx
git commit -m "break build on purpose"
git push origin main
ssh root@YOUR_VPS 'tail -n 160 /opt/visiontemplate/logs/deploy.log'
curl -fsS https://vision.yourdomain.com/api/ping
```

The deploy log should show a failed build or smoke test, and the final `curl`
should still hit the previous live build.
