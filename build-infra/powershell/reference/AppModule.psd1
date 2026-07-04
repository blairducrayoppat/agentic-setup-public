@{
    # Module manifest for the starter module. Keep FunctionsToExport in sync as you add functions.
    RootModule        = 'AppModule.psm1'
    ModuleVersion     = '0.1.0'
    GUID              = 'b1a40000-0000-4000-8000-000000000001'
    Author            = 'dispatch'
    Description       = 'Starter PowerShell module (extend this).'
    PowerShellVersion = '5.1'
    FunctionsToExport = @('Get-Summary')
    CmdletsToExport   = @()
    VariablesToExport = @()
    AliasesToExport   = @()
}
