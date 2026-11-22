[CmdletBinding()]
param(
    [string]$ClusterName,
    [string]$MachineName,
    [switch]$RemoveWorkspaceImage,
    [switch]$RemoveMachine,
    [switch]$Force
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'lib\Common.ps1')

if (-not $Force) {
    throw 'Cleanup is destructive. Re-run with -Force after verifying ClusterName and MachineName. Add -RemoveMachine only if the entire Podman VM may be deleted.'
}
$versions = Import-LabVersions
if ([string]::IsNullOrWhiteSpace($ClusterName)) { $ClusterName = $versions.ClusterName }
if ([string]::IsNullOrWhiteSpace($MachineName)) { $MachineName = $versions.MachineName }
$podman = Resolve-LabTool -Name 'podman'
$kind = Resolve-LabTool -Name 'kind'
if ([string]::IsNullOrWhiteSpace($podman) -or [string]::IsNullOrWhiteSpace($kind)) {
    throw 'podman and kind are required for cleanup.'
}
Add-LabToolToPath -ToolPath $podman
Add-LabToolToPath -ToolPath $kind
$env:KIND_EXPERIMENTAL_PROVIDER = 'podman'

Write-Host "Deleting only kind cluster '$ClusterName'..."
Invoke-LabCommand -FilePath $kind -Arguments @('delete', 'cluster', '--name', $ClusterName) -AllowFailure | Out-Null

if ($RemoveWorkspaceImage) {
    Write-Host "Removing workspace image '$($versions.WorkspaceImage)' from Podman..."
    Invoke-LabCommand -FilePath $podman -Arguments @('image', 'rm', '--ignore', $versions.WorkspaceImage) -AllowFailure | Out-Null
}

if ($RemoveMachine) {
    $state = Get-LabMachineState -Podman $podman -MachineName $MachineName
    if ($null -ne $state) {
        if ($state -match '(?i)running') {
            Invoke-LabCommand -FilePath $podman -Arguments @('machine', 'stop', $MachineName) -AllowFailure | Out-Null
        }
        Write-Host "Deleting Podman machine '$MachineName' and all data stored in it..."
        Invoke-LabCommand -FilePath $podman -Arguments @('machine', 'rm', '--force', $MachineName) | Out-Null
    }
}

Write-Host 'Requested cleanup completed.' -ForegroundColor Green
