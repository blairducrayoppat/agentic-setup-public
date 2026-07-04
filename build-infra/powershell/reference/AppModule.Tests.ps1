# Pester tests for AppModule (Pester v5 style). Extend these alongside your functions.
# The fleet's gate parse-checks every .ps1/.psm1/.psd1 deterministically and runs Pester here
# only if Pester is installed -- so a missing Pester never false-fails the build.
BeforeAll {
    Import-Module (Join-Path $PSScriptRoot 'AppModule.psd1') -Force
}

Describe 'Get-Summary' {
    It 'computes count, total, and mean' {
        $r = Get-Summary -Numbers 2, 4, 6
        $r.Count | Should -Be 3
        $r.Total | Should -Be 12
        $r.Mean  | Should -Be 4
    }

    It 'handles an empty list without throwing' {
        $r = Get-Summary -Numbers @()
        $r.Count | Should -Be 0
        $r.Total | Should -Be 0
        $r.Mean  | Should -Be 0
    }
}
