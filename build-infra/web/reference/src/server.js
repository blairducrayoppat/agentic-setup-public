// Zero-dependency full-stack server: a small REST API (over a swappable data layer) plus static files.
// Node built-ins only, so it runs and tests offline with no `npm install`. Extend the routes + store.
import { createServer } from 'node:http';
import { readFile } from 'node:fs/promises';
import { fileURLToPath } from 'node:url';
import { dirname, join, normalize } from 'node:path';
import { Buffer } from 'node:buffer';
import { listItems, getItem, createItem } from './store.js';

const here = dirname(fileURLToPath(import.meta.url));
const PUBLIC = join(here, '..', 'public');
const PORT = process.env.PORT ?? 3000;
// Static MIME map. Image types are included so a pre-generated raster asset under public/assets/
// (BlarAI UC-010 dispatch assets, #714) is served with the right content-type and renders in <img>.
const TYPES = {
  '.html': 'text/html', '.js': 'text/javascript', '.css': 'text/css',
  '.png': 'image/png', '.jpg': 'image/jpeg', '.jpeg': 'image/jpeg',
  '.webp': 'image/webp', '.gif': 'image/gif', '.svg': 'image/svg+xml',
};

function sendJson(res, status, body) {
  res.writeHead(status, { 'content-type': 'application/json' });
  res.end(JSON.stringify(body));
}

async function readJsonBody(req) {
  const chunks = [];
  for await (const c of req) chunks.push(c);
  if (chunks.length === 0) return {};
  try {
    return JSON.parse(Buffer.concat(chunks).toString('utf8'));
  } catch {
    const err = new Error('invalid JSON body');
    err.statusCode = 400;
    throw err;
  }
}

export const server = createServer(async (req, res) => {
  try {
    const { pathname } = new URL(req.url, `http://${req.headers.host ?? 'localhost'}`);

    if (pathname === '/api/health') return sendJson(res, 200, { ok: true });

    // REST resource: /api/items (extend with PUT/DELETE as the task needs).
    if (pathname === '/api/items' && req.method === 'GET') return sendJson(res, 200, listItems());
    if (pathname === '/api/items' && req.method === 'POST') {
      return sendJson(res, 201, createItem(await readJsonBody(req)));
    }
    const byId = pathname.match(/^\/api\/items\/(\d+)$/);
    if (byId && req.method === 'GET') {
      const item = getItem(byId[1]);
      return item ? sendJson(res, 200, item) : sendJson(res, 404, { error: 'not found' });
    }

    // Static files from public/ (path-traversal-safe: strip leading ../ after normalizing).
    const rel = normalize(pathname === '/' ? '/index.html' : pathname).replace(/^([/\\]|\.\.[/\\])+/, '');
    try {
      const fileBody = await readFile(join(PUBLIC, rel));
      res.writeHead(200, { 'content-type': TYPES[rel.slice(rel.lastIndexOf('.'))] ?? 'application/octet-stream' });
      res.end(fileBody);
    } catch {
      sendJson(res, 404, { error: 'not found' });
    }
  } catch (err) {
    // Any thrown error (e.g. validation, bad JSON) becomes a clean JSON response, never a crash.
    sendJson(res, err.statusCode ?? 500, { error: err.message ?? 'internal error' });
  }
});

// Listen only when run directly (`node src/server.js`), so tests can import without binding a port.
if (process.argv[1] && process.argv[1] === fileURLToPath(import.meta.url)) {
  server.listen(PORT, () => console.log(`app listening on http://localhost:${PORT}`));
}
