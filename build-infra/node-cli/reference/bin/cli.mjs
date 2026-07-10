#!/usr/bin/env node
// Thin command-line entry: parse argv, call a pure helper from src/, print the result. Keep
// this layer SMALL — all real logic lives in src/ modules so it stays unit-testable without
// spawning a process. Extend the dispatch below as you add helpers under src/.
import { slugify } from '../src/core.mjs';

function main(argv) {
  const [cmd, ...rest] = argv;
  switch (cmd) {
    case 'slugify':
      process.stdout.write(slugify(rest.join(' ')) + '\n');
      return 0;
    default:
      process.stderr.write('usage: app <command> [args...]\n  commands: slugify\n');
      return cmd ? 1 : 0;
  }
}

process.exit(main(process.argv.slice(2)));
