# PowerShell module skeleton (BlarAI dispatch fleet)

A clean, minimal PowerShell **module** the fleet seeds into a fresh PowerShell target.
**Extend it** -- add functions to `AppModule.psm1` (with comment-based help), keep
`Export-ModuleMember` and the manifest's `FunctionsToExport` in sync, and add matching tests.

| Path | What it is |
|---|---|
| `AppModule.psm1` | The module. One placeholder function (`Get-Summary`) with comment-based help, `[CmdletBinding()]`, typed params, `Set-StrictMode`. Replace/extend it. |
| `AppModule.psd1` | Module manifest (version, exported functions). |
| `AppModule.Tests.ps1` | Pester v5 tests. |
| `README.md` | This file. |

The fleet's verify gate **parse-checks** every `.ps1`/`.psm1`/`.psd1` (deterministic, no tools
needed) and runs **Pester** only if it's installed. Import locally with
`Import-Module ./AppModule.psd1 -Force`.
