// Pure, testable helper logic — kept free of I/O so the CLI entry (bin/cli.mjs) and the
// tests both import it. This `slugify` is a PLACEHOLDER modelling the quality bar (a clear
// export, an edge case handled, a matching test). Replace or extend it with the task's real
// helpers: add one focused module per helper under src/ (e.g. src/units.mjs, src/password.mjs)
// and a matching test under test/, rather than piling everything into one file.
export function slugify(text) {
  return String(text ?? '')
    .toLowerCase()
    .trim()
    .replace(/[^a-z0-9]+/g, '-')
    .replace(/^-+|-+$/g, '');
}
