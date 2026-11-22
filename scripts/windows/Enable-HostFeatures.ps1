[CmdletBinding()]
param(
    [switch]$Restart
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'lib\Common.ps1')

if (-not (Test-LabAdministrator)) {
    throw 'Run this script from an elevated PowerShell window. Enabling Windows virtualization features requires administrator rights.'
}

Write-Host 'Enabling the Windows features required by the WSL Podman provider...'
foreach ($feature in @('Microsoft-Windows-Subsystem-Linux', 'VirtualMachinePlatform')) {
    $result = Enable-WindowsOptionalFeature -Online -FeatureName $feature -All -NoRestart
    Write-Host ("{0}: {1}" -f $feature, $result.State)
}

$bcdedit = Join-Path $env:SystemRoot 'System32\bcdedit.exe'
Invoke-LabCommand -FilePath $bcdedit -Arguments @('/set', 'hypervisorlaunchtype', 'auto') | Out-Null

$wslConfig = Join-Path $env:USERPROFILE '.wslconfig'
if (Test-Path -LiteralPath $wslConfig) {
    $content = Get-Content -LiteralPath $wslConfig -Raw
    if ($content -match '(?im)^\s*nestedVirtualization\s*=') {
        $content = [regex]::Replace($content, '(?im)^\s*nestedVirtualization\s*=.*$', 'nestedVirtualization=true')
    }
    elseif ($content -match '(?im)^\s*\[wsl2\]\s*$') {
        $content = [regex]::Replace($content, '(?im)^(\s*\[wsl2\]\s*)$', "`$1`r`nnestedVirtualization=true", 1)
    }
    else {
        $content = $content.TrimEnd() + "`r`n`r`n[wsl2]`r`nnestedVirtualization=true`r`n"
    }
    Set-Content -LiteralPath $wslConfig -Value $content -Encoding utf8
}
else {
    Set-Content -LiteralPath $wslConfig -Value "[wsl2]`r`nnestedVirtualization=true`r`n" -Encoding utf8
}

$wsl = Join-Path $env:SystemRoot 'System32\wsl.exe'
Invoke-LabCommand -FilePath $wsl -Arguments @('--update') -AllowFailure | Out-Null

Write-Host ''
Write-Host 'Host features are configured. A Windows restart is required before Podman Machine can start.'
if ($Restart) {
    Restart-Computer -Force
}
else {
    Write-Host 'Restart Windows, then run .\scripts\windows\Install-Cluster.ps1 from a normal PowerShell window.'
}
