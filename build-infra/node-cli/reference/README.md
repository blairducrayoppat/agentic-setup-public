# app (Node.js command-line skeleton — extend this)

A dependency-free starting point for a Node.js command-line project. It builds and tests
**offline** out of the box (`node --test`, no `npm install` needed).

Layout:
- `src/` — pure, testable helper modules (one focused module per helper). Import them from
  the CLI and the tests. `src/core.mjs` is a placeholder to replace/extend.
- `bin/cli.mjs` — the thin argv entry point; keep logic OUT of here, in `src/`.
- `test/` — `node:test` tests, one file per `src/` module.

Extend it: add helper modules under `src/` and matching tests under `test/`; wire each into
`bin/cli.mjs`. Do not author loose top-level scripts.
