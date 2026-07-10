// Tests via Node's built-in runner (`node --test`) — zero dependencies, runs offline.
// Add one test file per helper module you create under src/, matching the logic you add.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { slugify } from '../src/core.mjs';

test('slugify turns a messy phrase into a url-safe name', () => {
  assert.equal(slugify('Hello, World!'), 'hello-world');
  assert.equal(slugify('  Trim  Me  '), 'trim-me');
  assert.equal(slugify(''), '');
});
