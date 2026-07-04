# Fleet builder brief — Android target (RESOLVED 2026-06-24)

**Status: RESOLVED 2026-06-24** (operator-approved the toolchain install). Android is now a gate-proven
scaffold (library entry #7), alongside winui, dotnet-console, python, web, powershell, cpp. What was done:

- **Microsoft OpenJDK 17.0.19 LTS** installed via winget; `JAVA_HOME` set machine-wide by the MSI (fixes
  the `XA0034` missing-JDK cause).
- **Android SDK** installed via `dotnet build -t:InstallAndroidDependencies -p:AcceptAndroidSDKLicenses=true`
  into `%LOCALAPPDATA%\Android\Sdk` — platforms android-34/36, build-tools 34.0.0/36.1.0, platform-tools,
  licenses accepted (fixes the `MSB4044`/`XA5300` no-SDK cause). `ANDROID_HOME` + `ANDROID_SDK_ROOT` set
  user-wide. Both env vars persist so fleet runs inherit them.
- **Offline verified** (the air-gap mirror): a `net8.0-android` app builds ONLINE 0/0 and OFFLINE 0/0 with
  NuGet pointed at an empty feed (restored purely from the local cache).
- **Scaffold** `build-infra/android/reference/` (App.csproj + MainActivity.cs + Calculator.cs + manifest +
  Resources) — the seeded scaffold builds offline 0/0.
- **No gate change** was needed: a single-TFM `net8.0-android` csproj builds under the existing
  `dotnet:build` gate (confirmed by running the exact gate command on the seed with only inherited env).
- **Detection** added to `Resolve-TaskScaffold` (build-signal-only; ordered before winui). verify-scaffold
  +9 tests; full gate 282/0. Commit `200e8de`.

The rest of this file is the original deferral diagnosis, kept as a record of the root cause and the path.

---

## Original deferral diagnosis (historical)

Android was the one queued scaffold target that was **not** a quick win: it needed a multi-component
toolchain that was entirely absent on the box, and the .NET tooling could not bootstrap it headless.

## Why it was deferred (two clean failures, same root cause)

Two probe builds of a fresh `dotnet new maui` app targeting `net8.0-android` both failed fast:

1. **Plain build** (`dotnet build -f net8.0-android`):
   `error XA5300: The Android SDK directory could not be found.`
2. **The official installer target** (`dotnet build -t:InstallAndroidDependencies -f net8.0-android`):
   `error MSB4044: The "InstallAndroidDependencies" task was not given a value for the required
   parameter "AndroidSdkPath"` — i.e. the installer has **no SDK location to install into**, and it
   also emits `warning XA0034: Failed to get the Java SDK version. Please ensure you have Java 11.0 or
   above installed.`

Root cause: the `InstallAndroidDependencies` target is **not** a from-zero bootstrapper. It provisions
*into* an existing Android SDK and validates a JDK; with neither present it cannot run. Confirmed on-box:

- `java` is **not on PATH**; `JAVA_HOME` is **empty** → no JDK.
- `ANDROID_HOME` / `ANDROID_SDK_ROOT` are **empty** → no Android SDK.

## What IS already in place (do not redo)

- **.NET MAUI workload** installed (`dotnet workload install maui`, 8.0.100). `dotnet workload list`
  shows `maui` / `android` workloads present.
- The Android **SDK pack** `Microsoft.Android.Sdk.Windows 34.0.154` is present under
  `C:\Program Files\dotnet\packs\` (it ships with the workload) — but that is the *build targets*, not
  the SDK *platform/tools* the build actually needs.

## Remaining prerequisite chain (in order)

This box is **offline-first / air-gap-aligned**, so each step must end with a *cached/mirrored* artifact,
not a live download at dispatch time.

1. **Install a JDK 11+** (Microsoft OpenJDK 17 is the MAUI-recommended choice) and set `JAVA_HOME`
   + add its `bin` to PATH. Verify: `java -version` → 17.x.
2. **Install the Android SDK** command-line tools + accept licenses, and set `ANDROID_HOME`
   (= `ANDROID_SDK_ROOT`). The supported headless path is the .NET target ONCE a JDK exists and an SDK
   path is provided:
   `dotnet build -t:InstallAndroidDependencies -f net8.0-android -p:AndroidSdkDirectory=<path> -p:AcceptAndroidSDKLicenses=true`
   (or `sdkmanager "platform-tools" "platforms;android-34" "build-tools;34.0.0"` + `sdkmanager --licenses`).
3. **Verify a clean offline build**: `dotnet build -f net8.0-android` → 0 errors, from cache only
   (no network). This is the gate the fleet will run.
4. **Mirror** the resolved SDK packages/NuGet so step 3 reproduces with the network off (consistent with
   the WinUI offline feed at `C:\Users\mrbla\blarai-build\nuget-feed`).
5. **Scaffold + gate** (the actual fleet work, small once 1–4 are done):
   - `build-infra/android/reference/` — a known-good, COMPILING MAUI (or `net8.0-android`) skeleton with
     logic in a testable class (mirror the dotnet-console/winui pattern).
   - `Resolve-TaskScaffold` — add an `android` detect rule (signals: `android`, `.apk`, `maui ... android`,
     `xamarin`). Order it so a desktop/.NET goal is unaffected.
   - `verify-project.ps1` — an `android:build` gate check (`dotnet build -f net8.0-android`, build-only,
     like the other gates).
   - `verify-scaffold.ps1` — detection + copy tests (incl. a precedence [kill] vs winui/dotnet-console).

## Recommendation

Steps 1–2 install a JDK and (with licenses) the Android SDK. Installing an Android SDK + accepting its
licenses is heavier than a NuGet restore and is **operator-review-required** (it writes a new toolchain
to the box and accepts third-party licenses) — write the install script clearly flagged, have the operator
run it, then steps 3–5 are routine fleet work that follows the existing scaffold/gate pattern exactly.

Until then the fleet simply never seeds `android` (the detector returns none → the coder hand-authors and
error-feedback backstops, same as any unsupported target). No code references a missing Android scaffold,
so nothing is broken by the deferral.
