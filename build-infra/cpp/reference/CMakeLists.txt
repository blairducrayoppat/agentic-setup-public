# Minimal, dependency-free C++ project for the BlarAI dispatch fleet.
# The SHAPE a fresh C++ target starts from: the app's logic lives in a small library
# (app_core) so BOTH the executable and the tests link it -- the coder EXTENDS core.*,
# keeps the exe thin, and adds tests. Builds with any cmake-supported compiler
# (MSVC / clang / gcc); no third-party packages, so it configures + builds offline.
cmake_minimum_required(VERSION 3.20)
project(app CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

# App logic as a library so the executable and the tests share it.
add_library(app_core src/core.cpp)
target_include_directories(app_core PUBLIC src)

add_executable(app src/main.cpp)
target_link_libraries(app PRIVATE app_core)

enable_testing()
add_executable(core_tests tests/test_core.cpp)
target_link_libraries(core_tests PRIVATE app_core)
add_test(NAME core_tests COMMAND core_tests)
