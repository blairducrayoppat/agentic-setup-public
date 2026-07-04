# C++ project skeleton (BlarAI dispatch fleet)

A minimal, **dependency-free**, CMake-based C++ project the fleet seeds into a fresh C++
target. **Extend it** -- put logic in `src/core.*`, keep the executable thin, add tests.

| Path | What it is |
|---|---|
| `CMakeLists.txt` | C++17 project: an `app_core` library, an `app` executable, and a `core_tests` test wired into CTest. |
| `src/core.hpp` / `src/core.cpp` | The app's logic as a library (so the exe and tests share it). Replace the placeholder `add`. |
| `src/main.cpp` | Thin entry point that uses `app_core`. |
| `tests/test_core.cpp` | Zero-dependency tests via `<cassert>` + CTest. |

Builds with any cmake-supported compiler (MSVC / clang / gcc), no third-party packages:

```
cmake -S . -B build
cmake --build build
ctest --test-dir build --output-on-failure
```
