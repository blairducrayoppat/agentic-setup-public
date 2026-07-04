# WinUI build infrastructure (BlarAI dispatch fleet)

Reusable, **offline**, deterministic scaffolding for building minimal WinUI 3 /
Windows App SDK apps on the operator's box. The BlarAI dispatch fleet uses this
to take a freshly-decomposed WinUI target from "empty folder" to a building
`App.exe` without touching the network and without the bare fleet gate
false-failing.

## What's here

| Path | What it is |
|---|---|
| `reference/` | A minimal, **compilable** WinUI 3 app template (`MinimalWinUI.csproj` + `App.xaml`/`.cs` + `MainWindow.xaml`/`.cs`). Trivial single window with one button. Builds to `App.exe`. This is the SHAPE a new WinUI target starts from. |
| `nuget.config` | `<clear/>`s all package sources and adds ONLY the local feed, so restore is reproducible and network-independent. Lives one level above `reference/` so the template inherits it via NuGet's directory walk. |
| `mirror-feed.ps1` | Idempotent script that mirrors the WinUI package **closure** (18 packages) out of the global cache (`~/.nuget/packages`) into the offline feed as a flat folder of `.nupkg` files. No downloads — it's a copy from cache. |
| `README.md` | This file. |

The binary package feed itself lives **outside** this version-controlled dir, at:

    C:\Users\mrbla\blarai-build\nuget-feed\

(18 flat `.nupkg` files after `mirror-feed.ps1` runs.)

## The closure (18 packages)

Two `PackageReference`s in the template — `Microsoft.WindowsAppSDK`
`1.8.260508005` and `Microsoft.Windows.SDK.BuildTools` `10.0.26100.8249` — are
the complete WinUI set a minimal app declares. Their full transitive closure is
**18 packages**: 14 resolved into `project.assets.json`'s `libraries` section
plus **4 RID-specific runtime/targeting packs** that a bare `-r win-x64` build
pulls via `downloadDependencies` (`Microsoft.Windows.SDK.NET.Ref`
`10.0.19041.56` and the `NETCore`/`AspNetCore`/`WindowsDesktop`
`App.Runtime.win-x64` `8.0.28` packs). A mirror that copied only `libraries`
would miss those four and the "offline" restore would silently hit the network —
so `mirror-feed.ps1` carries all 18 explicitly.

> `System.Drawing.Common` is intentionally **excluded** — it is BlarAI-app
> specific (screenshot capture), not a WinUI build requirement. Add it to the
> closure list only if a target app references it.

## The bare-build false-fail (why the template pins singular selectors)

The fleet gate runs a **flagless** `dotnet build` — no `-p:Platform` / `-r` on
the command line. The canonical `BlarAI.Desktop.csproj` sets only the **plural**
`<Platforms>x64;ARM64</Platforms>` + `<RuntimeIdentifiers>win-x64;win-arm64</RuntimeIdentifiers>`,
which do **not** select a single architecture. A flagless build therefore
defaults to `AnyCPU` and the Windows App SDK targets throw:

    WindowsAppSDKSelfContained requires a supported Windows architecture

(Confirmed on this codebase — `BUILD_JOURNAL.md` lines 8327-8330: a platform-flag
issue, not a missing workload; `-p:Platform=x64 -r win-x64` builds clean.)

So `MinimalWinUI.csproj` bakes the **singular** selectors into a `PropertyGroup`
so no command line is needed:

- `<RuntimeIdentifier>win-x64</RuntimeIdentifier>` — SINGULAR. Supplies the
  "supported Windows architecture". **Primary fix.**
- `<Platform>x64</Platform>` — SINGULAR. Pins MSBuild's `$(Platform)` to `x64`
  (default is `AnyCPU`) so RID resolution and the SDK arch-check agree.
- `<WindowsAppSDKSelfContained>true</WindowsAppSDKSelfContained>` (with
  `WindowsPackageType=None`) — fine to keep once the RID is pinned. Do **not**
  set `<SelfContained>` independently.

If a target later needs a multi-arch publish, switch back to the plural
properties and re-supply `-p:Platform=x64 -r win-x64` (as the BlarAI
runbook/journal builds do).

## How the fleet consumes this

1. **Seed the target** from `reference/` — copy the five template files, then
   rename namespace / `AssemblyName` / `RootNamespace` and add the app's own
   XAML + code. Keep the `PropertyGroup` guards (RID + Platform) so the gate's
   flagless build passes.
2. **Point restore at the offline feed.** Either keep the project under (a
   descendant of) this directory so it inherits `nuget.config`, or copy
   `nuget.config` next to the target's solution. Restore then resolves only from
   `C:\Users\mrbla\blarai-build\nuget-feed` — deterministic and offline.
3. **Build.** A bare `dotnet build` produces `App.exe`. The gate needs no flags.

### Build-lock discipline (concurrent dispatch safe)

A dispatch may be running concurrently and using the shared cache. When you
build, **always** point `dotnet` at a FRESH temporary `globalPackagesFolder` so
you never touch or lock the shared `~/.nuget` cache:

```bash
# Build under a SHORT path (see the MAX_PATH note below) with a fresh temp GPF.
BW="/c/bw"; BG="/c/bg"            # C:\bw working dir, C:\bg temp packages folder
rm -rf "$BW" "$BG"; mkdir -p "$BW"
cp C:/Users/mrbla/agentic-setup/build-infra/winui/reference/* "$BW/"
cp C:/Users/mrbla/agentic-setup/build-infra/winui/nuget.config "$BW/"
( cd "$BW" && dotnet build MinimalWinUI.csproj -p:RestorePackagesPath="$BG" )
# -> C:\bw\bin\x64\Debug\net8.0-windows10.0.19041.0\win-x64\App.exe
```

`mirror-feed.ps1` reads the shared cache (a plain file copy) but does not write
to or lock it, so it is safe to run alongside a dispatch. The feed at
`C:\Users\mrbla\blarai-build\nuget-feed` is the only thing it writes.

### MAX_PATH: build under a SHORT path (load-bearing, verified)

The WinUI XAML compiler (`XamlCompiler.exe`) runs as **.NET Framework 4.7.2**,
which is subject to the legacy \~260-char `MAX_PATH` limit. If the build's working
dir or the temp packages folder sits under a deep path (e.g. a per-session temp
tree), the compiler **false-fails** with a misleading

    XamlCompiler error WMC1006: Cannot resolve Assembly or Windows Metadata file '...Microsoft.*.Projection.dll'

for projection DLLs that are **present on disk** — the file resolves fine, the
net472 tool just can't open a path that long (and the error count varies run to
run, another tell). This was observed and then resolved during staging:
the identical template + feed **failed** from a \~230-char scratchpad temp path
and **built clean (0 warn / 0 err -> App.exe)** the moment the working dir and GPF
were moved to `C:\bw` / `C:\bg`. So the fleet MUST build WinUI targets and restore
into **short** paths (a couple of levels off a drive root). This is the single
most likely "it won't build but everything looks right" trap for this template.

## Refreshing the feed

If the pinned versions change (or the cache is repopulated), re-run:

```powershell
C:\Users\mrbla\agentic-setup\build-infra\winui\mirror-feed.ps1
```

It is idempotent — unchanged packages are skipped. If any closure package is
absent from the cache, the script names it and exits non-zero; run a
`dotnet restore` of a WinUI project to repopulate the cache, then re-run.
