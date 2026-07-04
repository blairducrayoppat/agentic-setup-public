// Tests via Node's built-in runner (`node --test`) -- zero dependencies, runs offline. Extend
// alongside the logic you add in src/.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { add } from '../src/core.js';

test('add sums two numbers', () => {
  assert.equal(add(2, 3), 5);
  assert.equal(add(-1, 1), 0);
  assert.equal(add(0, 0), 0);
});
