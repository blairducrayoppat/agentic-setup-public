# Web project skeleton (BlarAI dispatch fleet)

A **zero-dependency**, full-stack web project the fleet seeds into a fresh web/JS/REST target. Node
built-ins only, so it runs and tests **offline** with no `npm install`. **Extend it.**

| Path | What it is |
|---|---|
| `package.json` | ESM project; `start` = `node src/server.js`, `test` = `node --test`. No dependencies. |
| `src/server.js` | `node:http` server: REST routes + static files from `public/` (path-traversal-safe), JSON body parsing, status codes, and a top-level error handler. Listens only when run directly, so tests can import it. |
| `src/store.js` | The **data layer** behind a module boundary — swap the in-memory `Map` for a real DB without touching the server. |
| `src/core.js` | A generic pure helper + its test (example). |
| `test/` | `store.test.js` (data layer), `api.test.js` (real HTTP integration test on an ephemeral port), `core.test.js`. |
| `public/` | Front-end (`index.html` + `app.js`) that calls the API. |

## REST API (extend these)

| Method | Route | Does |
|---|---|---|
| GET | `/api/health` | liveness — `{ "ok": true }` |
| GET | `/api/items` | list items |
| POST | `/api/items` | create an item from `{ "name": "..." }` → `201` (or `400` if invalid) |
| GET | `/api/items/:id` | fetch one → `200` or `404` |

Run: `npm start` (http://localhost:3000) · Test: `npm test`. Add dependencies only if the offline npm
cache has them; otherwise stay on Node built-ins.
