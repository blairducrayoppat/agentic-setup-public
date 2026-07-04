// Core logic, kept pure so the server and the tests both use it. Replace/extend `add` with the
// task's real functionality and keep a matching test in test/.
export function add(a, b) {
  return a + b;
}
