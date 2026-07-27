"""Toolchain smoke tests: prove the package imports and pytest collects and runs.

These seeds are NEUTRAL -- they assert nothing about the product, so they stay true
(and green) for the life of the project. Keep them, and add the task's real tests
beside them.

House rules for the tests you add (README.md has the worked exemplar):
- Interactive entry points take their I/O as a parameter (an answer_fn / input_fn
  argument): the cli passes input, tests pass a stub. Never read a real tty in a test.
- Data files live under pytest's tmp_path fixture, never at the repo root: a test
  leaves the working tree byte-identical after it runs.
"""
import app


def test_package_imports():
    # Resolves from the project root (pyproject's pythonpath = ["."]) -- proves the
    # layout and the pytest config, which is all a seeded test should prove.
    assert app.__version__


def test_tmp_path_isolated_data(tmp_path):
    # The house pattern for file-backed tests: data is created under tmp_path, so
    # nothing ever reads or writes a shared repo-root store.
    sample = tmp_path / "sample.json"
    sample.write_text('{"ok": true}', encoding="utf-8")
    assert sample.read_text(encoding="utf-8") == '{"ok": true}'
