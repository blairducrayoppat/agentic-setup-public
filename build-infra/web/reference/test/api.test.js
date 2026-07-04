// Real HTTP integration test: start the server on an ephemeral port and make actual requests.
// (Prefers real execution over mocks; uses the built-in test runner + global fetch -- zero deps.)
import { test, before, after } from 'node:test';
import assert from 'node:assert/strict';
import { server } from '../src/server.js';
import { _reset } from '../src/store.js';

let base;
before(async () => {
  await new Promise((resolve) => server.listen(0, resolve));
  base = `http://localhost:${server.address().port}`;
});
after(() => server.close());

async function api(method, path, body) {
  const res = await fetch(base + path, {
    method,
    headers: body ? { 'content-type': 'application/json' } : undefined,
    body: body ? JSON.stringify(body) : undefined,
  });
  const text = await res.text();
  return { status: res.status, json: text ? JSON.parse(text) : null };
}

test('GET /api/health', async () => {
  const r = await api('GET', '/api/health');
  assert.equal(r.status, 200);
  assert.equal(r.json.ok, true);
});

test('items: list -> create -> get -> 404 -> 400', async () => {
  _reset();
  let r = await api('GET', '/api/items');
  assert.equal(r.status, 200);
  assert.deepEqual(r.json, []);

  r = await api('POST', '/api/items', { name: 'widget' });
  assert.equal(r.status, 201);
  assert.equal(r.json.name, 'widget');
  const id = r.json.id;

  r = await api('GET', `/api/items/${id}`);
  assert.equal(r.status, 200);
  assert.equal(r.json.name, 'widget');

  r = await api('GET', '/api/items/9999');
  assert.equal(r.status, 404);

  r = await api('POST', '/api/items', {}); // missing name
  assert.equal(r.status, 400);
});
