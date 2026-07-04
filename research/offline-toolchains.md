# offline-toolchains

## FINDINGS
MACHINE STATE (verified locally): Python 3.14.3, uv 0.10.0, Node 24.13.0 (LTS "Krypton"), npm 11.6.2, .NET SDK 8.0.422 ONLY, git 2.54.0.windows.1, cmake 4.2.3. Existing caches: uv cache 19.4 GB (%LOCALAPPDATA%\uv\cache), npm-cache 0.5 GB, NuGet 2.4 GB (\~\.nuget\packages), \~\.android 0.5 GB, NO \~\.gradle, NO pnpm. 230 GB free on C:. Dead Ollama blobs: 16.8 GB reclaimable.

Current versions confirmed June 2026: .NET 10 SDK 10.0.301 (LTS, EOL 2028-11-14); Verdaccio 6.7.2; pnpm 11.5.3; Gitea 1.26.2; Zeal 0.8.1; w64devkit 2.8.0; LLVM/Clang 22.1.7; Flutter stable 3.44.1 (Dart 3.12.1); Android Studio "Quail" 2026.1.1 stable; MSVC Build Tools 14.51 (default in VS 2026 18.6, May 2026).

=== 1. PYTHON ===
uv has a global `--offline` flag and `UV_OFFLINE=1` env var (docs.astral.sh/uv/reference/environment/) that disable ALL network access; uv then serves from its cache. Cache lives at %LOCALAPPDATA%\uv\cache (already 19.4 GB here — everything previously installed already works offline via `uv sync --offline`).
Setup while online:
1. Pre-install interpreters: `uv python install 3.12 3.13 3.14` (stored under %LOCALAPPDATA%\uv\python; needed because uv downloads python-build-standalone on demand). UV_PYTHON_INSTALL_MIRROR can point at a local dir as backup.
2. Build a wheelhouse — uv has NO `uv pip download` equivalent (open issue); use pip: write requirements-all.txt (fastapi, uvicorn[standard], flask, sqlalchemy, alembic, pandas, numpy, scipy, opencv-python, paddleocr, paddlepaddle, openvino, openvino-genai, openvino-tokenizers, pytest, pytest-asyncio, httpx, requests, pydantic, pillow, matplotlib, rich, typer) then run PER PYTHON VERSION: `py -3.14 -m pip download -r requirements-all.txt -d C:\offline\wheelhouse --only-binary=:all:` and again with a 3.12 interpreter (paddlepaddle cp314 Windows wheels are NOT guaranteed — PaddleOCR only added 3.13/3.14 CI in Mar 2026).
3. Per project: `uv export --format requirements-txt --all-groups --no-emit-project -o req.txt` then `pip download -r req.txt -d C:\offline\wheelhouse`. Known bug (uv#15519): `uv sync --frozen --no-index` still resolves dev/group deps — seed ALL groups.
4. Config: pip side — %APPDATA%\pip\pip.ini with `[global]` `no-index = true` + `find-links = C:\offline\wheelhouse`. uv side — set env `UV_OFFLINE=1`, or per-command `uv pip install --offline --no-index --find-links C:\offline\wheelhouse <pkg>`. Optional: uv-pack (github.com/davnn/uv-pack) bundles a locked uv project into a portable offline-installable dir.
Verify offline: airplane mode → `uv venv -p 3.12 t; uv pip install --offline --no-index --find-links C:\offline\wheelhouse paddleocr` and `uv init demo; cd demo; $env:UV_OFFLINE='1'; uv add --no-index --find-links C:\offline\wheelhouse fastapi; uv run python -c "import fastapi"`. NEVER run `uv cache clean/prune` — the 19.4 GB cache IS your offline safety net.

=== 2. NODE/NPM ===
Verdict: YES, Verdaccio is the recommended backbone for a single offline machine; npm's own cache only replays exact previously-installed versions (`npm ci --offline`, `npm install --offline|--prefer-offline`) and breaks on any scaffolder that queries "latest" metadata (npm/cli#6367). Verdaccio caches every tarball AND its metadata document, so `npm create vite@latest` etc. keep working offline.
Setup while online:
1. `npm i -g verdaccio@6.7.2 verdaccio-offline-storage@2.0.0`; run `verdaccio` (http://localhost:4873; config %APPDATA%\verdaccio\config.yaml, storage %APPDATA%\verdaccio\storage). Enable the offline-storage plugin in config.yaml (`store: { offline-storage: {} }`) — it serves only-local versions when uplink is unreachable. Autostart via Task Scheduler logon task (`verdaccio` has no Windows service installer).
2. `npm config set registry http://localhost:4873/` (and `pnpm config set registry` same).
3. Seed by scaffolding each stack ONCE while online through the proxy: `npm create vite@latest seed-react -- --template react-ts`, `npm create vue@latest`, `npx create-next-app@latest`, Express (`npm i express`), Tailwind v4 (`npm i tailwindcss @tailwindcss/vite`), plus typescript/eslint/prettier/vitest/playwright and your ecommerce deps (stripe, prisma, drizzle, zod, react-router, pinia). Then `npm i` inside each so every transitive tarball lands in Verdaccio storage.
4. Also install pnpm 11.5.3 (`npm i -g pnpm` — avoid corepack, it is deprecated/being removed from Node) and run `pnpm install` in the same seed projects: its content-addressable store (%LOCALAPPDATA%\pnpm\store) + `pnpm fetch` (lockfile-driven prefetch) + `pnpm install --offline` is the best per-project offline workflow, layered on the same Verdaccio registry.
Verify offline: airplane mode → `npm config get registry` → localhost:4873; `npm create vite@latest t2 -- --template react` succeeds; `pnpm install --offline` succeeds in a seeded repo; `npm ci --offline` in a project with package-lock.

=== 3. .NET ===
2026 LTS call: .NET 10 (SDK 10.0.301, runtime 10.0.9, supported to 2028-11-14). .NET 8 hits EOL 2026-11-10 (five months away); .NET 9 STS already ended May 2026. Action: download the full offline SDK installer dotnet-sdk-10.0.301-win-x64.exe (self-contained, installs with zero network) and keep 8.0.4xx beside it until migration.
NuGet offline:
1. Never delete \~\.nuget\packages — restore is automatically offline for any cached package version.
2. Build a folder feed by abusing `--packages`: create one kitchen-sink project referencing everything you use (EF Core + Sqlite, Dapper, Serilog, xunit, Moq/NSubstitute, Swashbuckle, Polly, CommunityToolkit, System.CommandLine...) and run `dotnet restore --packages C:\offline\nuget-feed` — that folder uses the hierarchical layout NuGet accepts as a source. Then in %APPDATA%\NuGet\NuGet.Config add `<add key="offline" value="C:\offline\nuget-feed" />`; when fully offline add `<clear />` before it so nuget.org never times out. Known quirks: NuGet/Home#2623 (offline restore from local source) and #14624 (mixing local+remote `-s` flags) — prefer NuGet.Config over `-s`.
3. Lockfiles make offline deterministic: `dotnet restore --use-lock-file` online, `dotnet restore --locked-mode` offline.
4. Workloads (needed for MAUI/Android/wasm-tools): online `dotnet workload install maui-android --download-to-cache C:\offline\workload-cache`; offline `dotnet workload install maui-android --from-cache C:\offline\workload-cache --skip-manifest-update` (learn.microsoft.com dotnet-workload-install).
Verify offline: airplane mode → `dotnet new webapi -o t; dotnet add t package Serilog; dotnet build t` (Serilog version must be in feed/cache); `dotnet workload list`.

=== 4. C++ ON WINDOWS ===
Three options compared:
- VS Build Tools offline layout (VS 2026 BT 18.x / MSVC 14.51, or VS 2022 17.x LTSC): the only toolchain giving the MSVC ABI that Python native builds, node-gyp, Rust-msvc and most vcpkg ports expect. Layout: `vs_BuildTools.exe --layout C:\offline\vslayout --add Microsoft.VisualStudio.Workload.VCTools --includeRecommended --lang en-US` (\~6–12 GB; full VS layout is 45 GB — don't). Offline install: `C:\offline\vslayout\vs_BuildTools.exe --noWeb --add Microsoft.VisualStudio.Workload.VCTools --includeRecommended`; if signature errors, install the certs from the layout's Certificates folder; the layout path is recorded in ProgramData state.json and must not move.
- w64devkit 2.8.0: single \~120 MB self-extracting archive (GCC 15 g++/gdb/make/busybox), zero installer, zero network ever, trivially portable. The gentlest novice experience that can never break offline.
- LLVM/Clang 22.1.7 standalone installer: offline-friendly single exe but NOT self-sufficient — needs MSVC or MinGW headers/libs; treat as an add-on.
vcpkg offline: (a) asset cache: `$env:X_VCPKG_ASSET_SOURCES = "clear;x-azurl,file:///C:/offline/vcpkg-assets,,readwrite"` while online captures every source tarball/tool; add `;x-block-origin` offline to forbid network (learn.microsoft.com/vcpkg/users/assetcaching). (b) binary cache is on by default at %LOCALAPPDATA%\vcpkg\archives — rebuilt ports reinstall offline. (c) `vcpkg export --zip` produces a self-contained dependency SDK. Clone the vcpkg repo + bootstrap while online (bootstrap downloads vcpkg.exe).
Verify offline: airplane mode → open "x64 Native Tools" prompt, `cl /EHsc hello.cpp`; in w64devkit `g++ hello.cpp`; `vcpkg install zlib` with x-block-origin set.

=== 5. ANDROID (Pixel 8 Pro) ===
Pain level: HIGH initially, manageable after 1–2 days of online seeding; the chronic pain for ALL frameworks is adding a NEW dependency while offline (fails; must vendor or reconnect). Google's old downloadable "offline components" zips for Gradle/AGP are dead (last published \~AGP 4.x, 2020) — STALE advice if you see it; 2026 approach is cache-by-building.
Setup while online:
1. Install Android Studio Quail 2026.1.1 (bundles JBR Java 21 — no separate JDK needed for Studio builds) OR commandlinetools-win zip + `sdkmanager --sdk_root=C:\Android\sdk`. For CLI builds also grab Temurin JDK 21 LTS offline .msi.
2. Seed SDK: `sdkmanager "platform-tools" "platforms;android-36" "build-tools;36.0.0" "sources;android-36" "extras;google;usb_driver"` and `sdkmanager --licenses` (accept while online; license files persist). Skip the \~4 GB NDK unless doing C++/JNI. Skip emulator images (\~8 GB each) — you have a real Pixel.
3. Create a real project in Studio, run `gradlew build lint` once: populates %USERPROFILE%\.gradle\wrapper\dists (Gradle 9.x distribution zip — the wrapper otherwise downloads it!) and .gradle\caches\modules-2 (all Maven deps from google()/mavenCentral()). Add a resolveAllDependencies task to force-resolve every configuration (pattern documented in Gradle dependency_caching docs + Medium/Bitrise CI articles). Pin Gradle + AGP versions.
4. Offline builds: `gradlew --offline assembleDebug` or Studio: File > Settings > Build, Execution, Deployment > Gradle > "Offline work".
5. ADB: enable Developer options (tap Build number 7x) + USB debugging on the Pixel; Win11 enumerates modern Pixels without extra drivers (Google USB driver cached as SDK package if needed); `adb devices` → accept RSA prompt. Wireless debugging pairing is LAN-only, fully offline. APK deploys are fully offline.
Framework comparison:
- Native Kotlin: best docs/samples; offline = Gradle caches; recommended for learning.
- Flutter 3.44.1: `flutter precache --android` fetches all engine artifacts; pub cache (%LOCALAPPDATA%\Pub\Cache) + `dart pub get --offline` work well; BUT Android builds still go through Gradle (same seeding) and `flutter upgrade`/`flutter create` from a new SDK needs network — pin the SDK version. Net: decently offline-friendly but you maintain TWO toolchains.
- .NET MAUI: most offline-friendly PIPELINE on paper — no Gradle/Maven at all; everything routes through NuGet + `dotnet workload --download-to-cache/--from-cache`; still needs Android SDK + JDK. Best if the app is C#-centric.
Verify offline: airplane mode → `gradlew --offline assembleDebug` then `adb install -r app\build\outputs\apk\debug\app-debug.apk`.

=== 6. OFFLINE DOCS ===
Two audiences, two answers:
- Human: Zeal 0.8.1 (Windows installer/portable) with Dash-format docsets (Python, JavaScript, TypeScript, React, Vue, Tailwind, C++, Android...). Docsets live at %LOCALAPPDATA%\Zeal\Zeal\docsets as SQLite index + plain HTML — incidentally grep-able by an agent too.
- Local coding agent (BlarAI): plain files beat apps. Build C:\offline\docs from: (1) `git clone --depth 1 https://github.com/mdn/content` (\~0.5 GB of pure Markdown — the entire MDN, ideal for grep/RAG); (2) Python: docs.python.org/3.14/download.html — grab the PLAIN TEXT archive (best for agents) + HTML zip; (3) `git clone --depth 1 https://github.com/dotnet/docs` (Markdown); (4) Node API docs from nodejs.org/dist/v24.13.0/docs/; (5) framework docs repos (react.dev, vuejs/docs, tailwindcss.com are all Markdown on GitHub). (6) Kiwix ZIMs from download.kiwix.org/zim/devdocs/ (per-tech DevDocs ZIMs, e.g. devdocs_en_docker_2025-04.zim) + kiwix-serve (Windows build) for a localhost browsable mirror; github.com/mozanunal/llm-tools-kiwix exposes ZIM full-text search to LLM tooling (ZIMs embed an SQLite FTS index). Full MDN ZIM \~10 GB — the mdn/content git clone is 20x smaller and agent-friendlier. DevDocs self-hosting needs Ruby; the official devdocs.io PWA offline mode is per-browser-cache — fragile; skip both.

=== 7. GIT ===
Git is inherently offline; nothing to do for core workflow. For backup/remote semantics on one machine: `git init --bare C:\offline\gitremotes\<proj>.git` + `git remote add local <path>`; periodic `git bundle create proj.bundle --all` to external storage. Gitea 1.26.2 = single \~100 MB Windows exe + SQLite, runs fine as a service; worth it ONLY for: web UI browsing, issues/PR-style review, Gitea Actions (local CI), or giving a local agent a forge-style REST API to drive. Its built-in package registry HOSTS npm/NuGet/PyPI/Maven packages but does NOT pull-through-cache public registries, so it does not replace Verdaccio or the wheelhouse.

VERIFY-OFFLINE METHOD (all sections): toggle airplane mode for routine checks; for hard guarantees use Windows Firewall outbound-block rules per executable, or a Hyper-V VM on an Internal-only switch (Hyper-V already in use for BlarAI).

## RECOMMENDATION
Do this in one weekend while online, in priority order:
1. Disk first: delete the 16.8 GB \~/.ollama/models (Ollama is gone; your runtime is OpenVINO) — buys headroom for the \~40–60 GB total this plan needs out of your 230 GB.
2. Python (biggest win, you're mostly there): keep the 19.4 GB uv cache forever (never `uv cache clean`); run `uv python install 3.12 3.13 3.14`; build C:\offline\wheelhouse with `pip download --only-binary=:all:` for BOTH cp314 and cp312 (paddlepaddle needs 3.12); set UV_OFFLINE=1 + pip.ini no-index/find-links when offline.
3. Node: install Verdaccio 6.7.2 + verdaccio-offline-storage as a logon task, point npm and pnpm 11.5.3 at http://localhost:4873, then scaffold-and-install Vite/React/Vue/Next/Express/Tailwind seed projects once. This is the single best Node answer for your machine — npm cache alone will strand you.
4. .NET: install the .NET 10.0.301 SDK offline installer NOW (.NET 8 dies 2026-11-10); seed C:\offline\nuget-feed via `dotnet restore --packages` on a kitchen-sink project; use lockfiles + --locked-mode.
5. C++: create a VS Build Tools offline layout (VCTools workload, --includeRecommended, \~10 GB) — you need MSVC anyway as an OpenVINO contributor and for Python/node native builds — AND drop w64devkit 2.8.0 (120 MB zip) on disk as the novice-friendly, can-never-break fallback. Set X_VCPKG_ASSET_SOURCES to a file:/// readwrite cache today.
6. Android: accept it's the highest-maintenance item. Install Android Studio Quail 2026.1.1 + sdkmanager packages (platform-tools, android-36, build-tools 36, usb_driver; skip NDK/emulator), build one Kotlin project to fill \~/.gradle, then live in `gradlew --offline`. Learn on native Kotlin; if you ever build a C#-heavy app, MAUI is actually your most offline-friendly pipeline (pure NuGet + workload cache, no Gradle). USB debugging to the Pixel 8 Pro is fully offline.
7. Docs for BlarAI: make C:\offline\docs from git clones of mdn/content (\~0.5 GB Markdown), dotnet/docs, framework doc repos, plus Python plain-text docs — agents grep Markdown far better than they drive doc apps. Install Zeal 0.8.1 for yourself. Add Kiwix ZIMs only for techs without a Markdown repo.
8. Git: skip Gitea for now — bare repos + `git bundle` cover a single machine. Revisit Gitea 1.26.2 (one exe + SQLite, trivial to add later) only if BlarAI agents would benefit from a local PR/issues/CI API.
Finally, verify everything with airplane mode on: uv add, npm create vite, dotnet build with a new package, cl.exe hello.cpp, gradlew --offline assembleDebug + adb install.

## CAVEATS
1. Python 3.14 wheel gaps: paddlepaddle Windows cp314 wheels are unverified (PaddleOCR only added 3.13/3.14 CI in Mar 2026); possibly other native packages too — that is why the cp312 wheelhouse + uv-managed 3.12 is non-negotiable. Re-download the wheelhouse whenever you bump Python.
2. Anything not seeded is unavailable offline — the chronic failure mode across ALL ecosystems is "add new dependency while offline." Budget periodic online re-seeding sessions; caches/layouts go stale (VS layout should be refreshed with the bootstrapper when online; Gradle/AGP upgrades are online events — pin versions).
3. npm scaffolders (`create-next-app` etc.) query latest metadata; they only work offline through Verdaccio, and only for versions whose tarballs were previously proxied. verdaccio-offline-storage 2.0.0 is a small community plugin — test it against Verdaccio 6.7.2 before relying on it (plugin API mismatches have happened across major versions).
4. uv known bug (#15519): offline `uv sync` can still attempt PyPI for dependency groups missing from the wheelhouse — export with --all-groups when seeding.
5. dotnet workload --from-cache requires --skip-manifest-update and matching SDK feature band; an SDK patch update can invalidate the workload cache. NuGet has open quirks with mixed local/remote sources (NuGet/Home#14624) — configure feeds in NuGet.Config, not -s flags.
6. VS Build Tools layout: must stay at its original path (recorded in state.json); signature/cert errors offline require installing certs from the layout's Certificates folder; C++-only layout \~6–12 GB (not the 45 GB full figure).
7. Android licensing: sdkmanager license acceptance files must exist before going offline; Android Studio itself may nag about updates offline (harmless). Emulator images were deliberately skipped — phone-only testing. Hyper-V coexistence with the (unused) emulator is fine since AEHD/Hyper-V backends now coexist, but untested here.
8. Disk math: VS layout (\~10 GB) + Android SDK/Gradle/Studio (\~15–20 GB) + wheelhouse (\~5–10 GB) + Verdaccio storage (grows) + optional MDN ZIM (10 GB) ≈ 40–60 GB of the 230 GB free; fine today, but Flutter (+\~5 GB) and NDK (+4 GB) only if actually needed.
9. Version drift: all version numbers verified June 2026 (live registry/GitHub/builds.dotnet queries); Android Studio "Quail 2026.1.1" is from a search-result snapshot of developer.android.com and may already have a newer dot release. The Google "offline components" zips you may find in older guides are abandoned (\~2020) — do not follow that advice.
10. Hardware-specific: nothing here touches the Arc 140V/NPU stacks; OpenVINO wheels go in the wheelhouse like any other package, but driver updates (GPU/NPU) are inherently online and outside this plan.

## SOURCES
https://docs.astral.sh/uv/reference/environment/
https://docs.astral.sh/uv/concepts/cache/
https://github.com/astral-sh/uv/issues/15519
https://github.com/astral-sh/uv/issues/9794
https://github.com/davnn/uv-pack
https://github.com/PaddlePaddle/PaddleOCR/blob/main/docs/version3.x/installation.en.md
https://pypi.org/project/paddlepaddle/
https://www.verdaccio.org/
https://github.com/verdaccio/verdaccio
https://www.npmjs.com/package/verdaccio-offline-storage
https://github.com/npm/cli/issues/6367
https://addyosmani.com/blog/using-npm-offline/
https://learn.microsoft.com/en-us/dotnet/core/tools/dotnet-workload-install
https://learn.microsoft.com/en-us/dotnet/core/tools/dotnet-restore
https://learn.microsoft.com/en-us/nuget/consume-packages/package-restore
https://github.com/NuGet/Home/issues/2623
https://github.com/NuGet/Home/issues/14624
https://dotnet.microsoft.com/en-us/platform/support/policy/dotnet-core
https://endoflife.date/dotnet
https://builds.dotnet.microsoft.com/dotnet/release-metadata/10.0/releases.json
https://learn.microsoft.com/en-us/visualstudio/install/create-an-offline-installation-of-visual-studio?view=vs-2022
https://devblogs.microsoft.com/cppblog/msvc-version-1451-available/
https://devblogs.microsoft.com/cppblog/msvc-build-tools-versions-14-30-14-43-now-available-in-visual-studio-2026/
https://learn.microsoft.com/en-us/vcpkg/concepts/offline
https://learn.microsoft.com/en-us/vcpkg/users/assetcaching
https://learn.microsoft.com/en-us/vcpkg/consume/asset-caching
https://github.com/skeeto/w64devkit
https://docs.gradle.org/current/userguide/dependency_caching.html
https://developer.android.com/tools/sdkmanager
https://developer.android.com/studio/releases
https://developer.android.com/tools/releases/cmdline-tools
https://medium.com/@simon.russiazushi/codex-android-development-pre-fetching-gradle-dependencies-for-offline-test-execution-655cfec085c5
https://devcenter.bitrise.io/en/dependencies-and-caching/managing-dependencies-for-android-apps.html
https://dart.dev/tools/pub/cmd/pub-cache
https://storage.googleapis.com/flutter_infra_release/releases/releases_windows.json
https://www.digisoftsolution.com/blog/dotnet-maui-vs-flutter
https://github.com/zealdocs/zeal
https://jiby.tech/post/offline-dev-docs-zeal-dash-docsets/
https://download.kiwix.org/zim/devdocs/
https://github.com/mozanunal/llm-tools-kiwix
https://github.com/mdn/content
https://www.anchorpoint.app/blog/how-to-set-up-a-local-git-server-on-windows-in-10-minutes-using-gitea
https://about.gitea.com/
https://github.com/go-gitea/gitea
