# VisionTemplate

A clean, ready-to-demo full-stack starting point built with **React Router 8**
(SSR), **Tailwind v4**, a local **Postgres** backend, and the "Signal" design
system — cool indigo brand, Geist type, dark mode by default.

Use it as a **GitHub template**: create a new repo from it for each demo, rename in
`app/config.ts`, and start building.

## Quick start

Requires Node 20+ and a local Postgres install (e.g. `brew install postgresql@14`).

```bash
npm install
cp .env.example .env
createdb vision_template      # requires local Postgres running
psql -d vision_template -f db/setup.sql
npm run dev
```

The app runs at `http://localhost:5173`.

## Backend

The app has a real server-side backend via React Router loaders/actions:

- **Postgres** — connection pool in `app/lib/db.server.ts` (set `DATABASE_URL` in `.env`).
- **API endpoints** — resource routes under `app/routes/api.*.ts`, no keys required.

| Endpoint / page | What it does |
| --- | --- |
| `/db-demo` | Sample page: list/add/delete notes stored in Postgres. |
| `/api-demo` | Sample page: ping the server and fetch data from an external API. |
| `GET /api/notes` | JSON list of notes. |
| `POST /api/notes` | Create a note: `{ "title": "...", "content": "..." }`. |
| `GET /api/ping` | Health check: `{ "pong": true, "serverTime": ..., "uptimeSeconds": ... }`. |
| `POST /api/ping` | Echo: `{ "message": "..." }` → `{ "pong": true, "echo": "..." }`. |
| `GET /api/advice` | Server-side fetch to the free adviceslip.com API. |

## Make it yours

- **Name & description** — edit `SITE` in `app/config.ts` (drives the navbar, footer, and `<title>`).
- **Nav links** — add routes in `app/routes.ts`, then list them in `NAV_LINKS` in `app/config.ts`.
- **Brand mark** — swap the SVG in `app/components/Logo.tsx`.
- **Theme** — all colors live as semantic tokens in `app/app.css` (`:root` for light, `.dark` for dark).

## What's included

| Path | What it is |
| --- | --- |
| `app/app.css` | Design system: theme tokens, fonts, and utilities (`aurora`, `grain`, `gradient-text-brand`, `card-lift`, `text-display`). |
| `app/config.ts` | Site name, description, and nav links. |
| `app/root.tsx` | Document shell, dark-by-default boot script, app frame (Navbar + Footer). |
| `app/components/` | `Button` / `LinkButton`, `Navbar`, `Footer`, `Logo`, `ThemeToggle`. |
| `app/routes/home.tsx` | Example landing page showing the style in use. |
| `app/routes/db-demo.tsx` | Sample page backed by Postgres (loader + action). |
| `app/routes/api-demo.tsx` | Sample page exercising the JSON API endpoints. |
| `app/routes/api.*.ts` | Resource routes: `/api/notes`, `/api/ping`, `/api/advice`. |
| `app/lib/db.server.ts` | Postgres connection pool and query helpers. |
| `db/setup.sql` | Creates and seeds the `notes` table. |

Style with the **semantic tokens** (`bg-background`, `text-muted-foreground`,
`border-border`, `bg-primary`, …) rather than raw Tailwind colors so light/dark
stay consistent.

## Build & deploy

```bash
npm run build   # output in build/
npm run start   # serve the production build
```

A `Dockerfile` is included for container deploys (Railway, Fly.io, Cloud Run, etc.).

For a bare VPS deployment with Postgres, GitHub push deploys, rollback, nginx,
and daily backups, see [`docs/bare-vps-deploy.md`](docs/bare-vps-deploy.md).
