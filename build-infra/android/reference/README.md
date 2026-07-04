# Android app skeleton (BlarAI dispatch fleet)

A minimal, **offline-building** .NET Android app (`net8.0-android`) the fleet seeds into a fresh Android
target. **Extend it** — keep real logic in plain, platform-free classes (`Calculator.cs`) so it stays
unit-testable; the `Activity` only wires UI to that logic.

| Path | What it is |
|---|---|
| `App.csproj` | SDK-style `net8.0-android` app (`Exe`). Builds offline from the local NuGet cache (no feed). |
| `Calculator.cs` | Core logic as a plain class (no Android types → unit-testable). Replace the placeholder `Add`. |
| `MainActivity.cs` | Entry-point `Activity` (MainLauncher). Wires the UI to `Calculator`; extend `OnCreate`. |
| `AndroidManifest.xml` | App manifest (uses the default launcher icon — add a custom `@mipmap/...` icon if you want one). |
| `Resources/layout/activity_main.xml` | The single screen layout. |
| `Resources/values/strings.xml` | String resources (`app_name`, `app_text`). |

The fleet gate runs `dotnet build -f net8.0-android` (**build-only** — it does not launch an emulator), so a
green build means it COMPILED, not that the UI looks/works right. Keep non-UI logic in classes like
`Calculator` so it stays easy to test. Requires the box's Android toolchain (JDK 17 + the Android SDK,
both already installed; `JAVA_HOME`/`ANDROID_HOME` are set machine/user-wide so the fleet inherits them).
