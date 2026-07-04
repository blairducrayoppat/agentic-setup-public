#Requires -Version 5.1
<#
.SYNOPSIS
    Mirror the WinUI build closure from the global NuGet cache into the BlarAI
    offline feed as a flat folder of .nupkg files.

.DESCRIPTION
    The BlarAI dispatch fleet builds minimal WinUI apps against a deterministic,
    network-independent feed (see ./nuget.config). This script populates that
    feed by COPYING each closure package's .nupkg out of the global cache
    (~/.nuget/packages/<id-lowercased>/<version>/<id>.<version>.nupkg) into
    the flat feed directory that `dotnet restore --source <dir>` consumes.

    It is a MIRROR FROM CACHE — no downloads. The global cache is read only;
    nothing in it is modified or locked (a plain file copy).

    Idempotent: a package already present in the feed (matching length) is
    skipped. Re-running after a cache refresh re-copies only what changed.

    If a closure package's .nupkg is ABSENT from the cache folder, it is NOT
    fatal — the script records it and reports it at the end (exit code becomes
    non-zero so a caller can detect an incomplete mirror), so a follow-up
    `dotnet restore` can repopulate the cache and you can re-run this script.

.PARAMETER CacheRoot
    The global NuGet packages cache. Defaults to $env:NUGET_PACKAGES if set,
    else ~/.nuget/packages.

.PARAMETER FeedDir
    The destination flat feed directory.
    Defaults to C:\Users\mrbla\blarai-build\nuget-feed.

.NOTES
    Closure (18 packages) is from the Phase-1 restore-proof: 14 from the probe's
    project.assets.json "libraries" + 4 RID-specific runtime/targeting packs from
    "downloadDependencies" that a bare `-r win-x64` build also pulls. Keep this
    list in sync with the canonical fact-sheet / closure if versions are bumped.
#>
[CmdletBinding()]
param(
    [string]$CacheRoot = $(if ($env:NUGET_PACKAGES) { $env:NUGET_PACKAGES } else { Join-Path $HOME ".nuget\packages" }),
    [string]$FeedDir   = "C:\Users\mrbla\blarai-build\nuget-feed"
)

$ErrorActionPreference = "Stop"

# --- The closure: id + exact version (do NOT change without re-measuring) ----
$closure = @(
    @{ id = "Microsoft.WindowsAppSDK";                       version = "1.8.260508005"   },
    @{ id = "Microsoft.WindowsAppSDK.Base";                  version = "1.8.251216001"   },
    @{ id = "Microsoft.WindowsAppSDK.Foundation";            version = "1.8.260505001"   },
    @{ id = "Microsoft.WindowsAppSDK.WinUI";                 version = "1.8.260505002"   },
    @{ id = "Microsoft.WindowsAppSDK.Runtime";               version = "1.8.260508005"   },
    @{ id = "Microsoft.WindowsAppSDK.DWrite";                version = "1.8.25122902"    },
    @{ id = "Microsoft.WindowsAppSDK.AI";                    version = "1.8.76"          },
    @{ id = "Microsoft.WindowsAppSDK.ML";                    version = "1.8.2197"        },
    @{ id = "Microsoft.WindowsAppSDK.Widgets";               version = "1.8.251231004"   },
    @{ id = "Microsoft.WindowsAppSDK.InteractiveExperiences"; version = "1.8.260430001"  },
    @{ id = "Microsoft.Windows.SDK.BuildTools";              version = "10.0.26100.8249" },
    @{ id = "Microsoft.Windows.SDK.BuildTools.MSIX";         version = "1.7.20250829.1"  },
    @{ id = "Microsoft.Web.WebView2";                        version = "1.0.3179.45"     },
    @{ id = "System.Numerics.Tensors";                       version = "9.0.0"           },
    @{ id = "Microsoft.Windows.SDK.NET.Ref";                 version = "10.0.19041.56"   },
    @{ id = "Microsoft.NETCore.App.Runtime.win-x64";         version = "8.0.28"          },
    @{ id = "Microsoft.AspNetCore.App.Runtime.win-x64";      version = "8.0.28"          },
    @{ id = "Microsoft.WindowsDesktop.App.Runtime.win-x64";  version = "8.0.28"          }
)

Write-Host "WinUI offline-feed mirror"
Write-Host "  cache : $CacheRoot"
Write-Host "  feed  : $FeedDir"
Write-Host "  packages in closure: $($closure.Count)"
Write-Host ""

if (-not (Test-Path -LiteralPath $CacheRoot)) {
    throw "Global NuGet cache not found at '$CacheRoot'. Set -CacheRoot or `$env:NUGET_PACKAGES."
}

if (-not (Test-Path -LiteralPath $FeedDir)) {
    New-Item -ItemType Directory -Path $FeedDir -Force | Out-Null
    Write-Host "Created feed directory: $FeedDir"
}

$copied  = 0
$skipped = 0
$missing = @()

foreach ($pkg in $closure) {
    $id      = $pkg.id
    $version = $pkg.version
    $idLower = $id.ToLowerInvariant()

    # Cache layout: <cache>/<id-lowercased>/<version>/<id-lowercased>.<version>.nupkg
    $srcDir  = Join-Path $CacheRoot (Join-Path $idLower $version)
    $srcFile = Join-Path $srcDir ("{0}.{1}.nupkg" -f $idLower, $version)

    if (-not (Test-Path -LiteralPath $srcFile)) {
        # Fall back to any .nupkg in the version dir (defensive — casing/layout drift).
        $alt = $null
        if (Test-Path -LiteralPath $srcDir) {
            $alt = Get-ChildItem -LiteralPath $srcDir -Filter "*.nupkg" -File -ErrorAction SilentlyContinue |
                   Select-Object -First 1
        }
        if ($alt) {
            $srcFile = $alt.FullName
        } else {
            Write-Warning ("MISSING in cache: {0} {1}  (looked in {2})" -f $id, $version, $srcDir)
            $missing += ("{0} {1}" -f $id, $version)
            continue
        }
    }

    # Flat feed file name: <id>.<version>.nupkg (preserve original-cased id for clarity).
    $destFile = Join-Path $FeedDir ("{0}.{1}.nupkg" -f $id, $version)

    if (Test-Path -LiteralPath $destFile) {
        $srcLen  = (Get-Item -LiteralPath $srcFile).Length
        $destLen = (Get-Item -LiteralPath $destFile).Length
        if ($srcLen -eq $destLen) {
            Write-Host ("  [skip] {0} {1}" -f $id, $version)
            $skipped++
            continue
        }
    }

    Copy-Item -LiteralPath $srcFile -Destination $destFile -Force
    Write-Host ("  [copy] {0} {1}" -f $id, $version)
    $copied++
}

# Final feed inventory.
$feedNupkgs = @(Get-ChildItem -LiteralPath $FeedDir -Filter "*.nupkg" -File -ErrorAction SilentlyContinue)

Write-Host ""
Write-Host "Mirror complete."
Write-Host ("  copied      : {0}" -f $copied)
Write-Host ("  skipped     : {0}" -f $skipped)
Write-Host ("  missing     : {0}" -f $missing.Count)
Write-Host ("  feed .nupkg : {0}" -f $feedNupkgs.Count)

if ($missing.Count -gt 0) {
    Write-Host ""
    Write-Warning "The following closure packages were NOT found in the cache:"
    $missing | ForEach-Object { Write-Warning ("  - {0}" -f $_) }
    Write-Warning "Run `dotnet restore` for a WinUI project to repopulate the cache, then re-run this script."
    exit 1
}

exit 0
