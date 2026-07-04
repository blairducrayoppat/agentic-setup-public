// The app's DATA LAYER. Kept behind a small module boundary so the task can swap the in-memory Map
// for a real database (SQLite/Postgres/etc.) WITHOUT changing the server -- keep these function
// signatures and replace the bodies. Pure + easily unit-tested.
let nextId = 1;
const items = new Map();

export function listItems() {
  return [...items.values()];
}

export function getItem(id) {
  return items.get(Number(id)) ?? null;
}

export function createItem(data) {
  if (!data || typeof data.name !== 'string' || data.name.trim() === '') {
    const err = new Error('name is required');
    err.statusCode = 400; // surfaced as the HTTP status by the server
    throw err;
  }
  const item = { id: nextId++, name: data.name.trim() };
  items.set(item.id, item);
  return item;
}

// Test helper: reset state between tests. Safe to delete in real code.
export function _reset() {
  items.clear();
  nextId = 1;
}
