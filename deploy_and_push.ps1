# =============================================================================
# CLIProxyAPI - Deploy and Push Pipeline (Alias wrapper to build_and_deploy.ps1)
# =============================================================================

param (
    [switch]$SkipPush = $false,
    [switch]$SkipBuild = $false,
    [switch]$AutoDeployProd = $false,
    [switch]$LocalOnly = $false,
    [switch]$NonInteractive = $false
)

$scriptPath = Join-Path $PSScriptRoot "build_and_deploy.ps1"
& $scriptPath @PSBoundParameters
exit $LASTEXITCODE
