// Data-layer unit tests (no server needed). Extend alongside store.js.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { listItems, getItem, createItem, _reset } from '../src/store.js';

test('create, list, and get items', () => {
  _reset();
  assert.deepEqual(listItems(), []);
  const a = createItem({ name: 'alpha' });
  assert.equal(a.id, 1);
  assert.equal(a.name, 'alpha');
  assert.equal(getItem(1).name, 'alpha');
  assert.equal(getItem(9999), null);
  assert.equal(listItems().length, 1);
});

test('createItem rejects a missing/blank name (400)', () => {
  _reset();
  assert.throws(() => createItem({}), /name is required/);
  assert.throws(() => createItem({ name: '   ' }), /name is required/);
});
