<#
.SYNOPSIS
  Starter PowerShell module for the BlarAI dispatch fleet. EXTEND this -- add your functions
  here (one concern each, comment-based help on each) and a matching Pester test in
  AppModule.Tests.ps1. Keep Export-ModuleMember in sync with the functions you add.
#>
Set-StrictMode -Version Latest

function Get-Summary {
    <#
    .SYNOPSIS
      Return count, total, and mean for a list of numbers.
    .DESCRIPTION
      A PLACEHOLDER so the module imports and its tests pass out of the box. Replace or extend
      it with the task's real functions. It models the quality bar: comment-based help, a typed
      parameter, and an edge case (empty input) handled without throwing.
    .EXAMPLE
      Get-Summary -Numbers 2, 4, 6     # Count 3, Total 12, Mean 4
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [double[]]$Numbers
    )
    if (-not $Numbers -or $Numbers.Count -eq 0) {
        return [pscustomobject]@{ Count = 0; Total = 0.0; Mean = 0.0 }
    }
    $total = ($Numbers | Measure-Object -Sum).Sum
    [pscustomobject]@{
        Count = $Numbers.Count
        Total = [double]$total
        Mean  = [double]($total / $Numbers.Count)
    }
}

Export-ModuleMember -Function Get-Summary
