#requires -Version 5.1
# C++ build helper for the fleet verify gate. Configures (Ninja), builds, and tests a CMake project
# in the CURRENT directory inside an MSVC (vcvars) environment, then exits 0 on success / non-zero on
# failure (so the gate's Invoke-GateCheck records pass/fail).
#
# WHY vcvars + Ninja (not bare cmake): cmake's default generator here is "NMake Makefiles" (needs an
# MSVC env it doesn't set up) and its "Visual Studio 17 2022" generator cannot find a *prerelease* VS
# install ("could not find any instance of Visual Studio"). vcvarsall.bat puts cl + ninja on PATH and
# `cmake -G Ninja` then builds cleanly -- verified on this box (prerelease VS BuildTools 17.14, MSVC 14.44).
$ErrorActionPreference = 'Continue'
$vsw = 'C:\Program Files (x86)\Microsoft Visual Studio\Installer\vswhere.exe'
if (-not (Test-Path $vsw)) { Write-Output 'build-cpp: vswhere not found'; exit 9 }
$vs = & $vsw -all -prerelease -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath 2>$null | Select-Object -First 1
if (-not $vs) { Write-Output 'build-cpp: no VS with VC.Tools found'; exit 9 }
$vcvars = Join-Path $vs 'VC\Auxiliary\Build\vcvarsall.bat'
if (-not (Test-Path $vcvars)) { Write-Output "build-cpp: vcvarsall not found at $vcvars"; exit 9 }
# Configure + build + test, all inside the MSVC env. && stops at the first failure; the tail of this
# output is what the gate surfaces on a failure.
cmd /c "call `"$vcvars`" x64 >nul 2>&1 && cmake -G Ninja -S . -B build && cmake --build build && ctest --test-dir build --output-on-failure"
exit $LASTEXITCODE
