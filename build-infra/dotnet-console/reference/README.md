# .NET console project skeleton (BlarAI dispatch fleet)

A minimal, **dependency-free** C# console app the fleet seeds into a fresh .NET / CLI / back-end target.
Builds offline with `dotnet build` (no NuGet packages → no feed needed). **Extend it** — keep logic in
classes (`Calculator.cs`) so it's testable; the entry point stays thin.

| Path | What it is |
|---|---|
| `app.csproj` | SDK-style console project (`net8.0`, `Exe`), no dependencies → builds offline. |
| `Calculator.cs` | Core logic as a class (unit-testable). Replace the placeholder `Add`. |
| `Program.cs` | Thin entry point (top-level statements) that calls the logic. |

The fleet gate runs `dotnet build` (build-only). To add tests, create an xunit/MSTest test project **only
if** the offline NuGet cache already has the test packages (`Microsoft.NET.Test.Sdk`, `xunit`); otherwise
keep logic in classes so it stays easy to test later.
