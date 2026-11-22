[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'lib\Common.ps1')

$winget = Resolve-LabTool -Name 'winget'
if ([string]::IsNullOrWhiteSpace($winget)) {
    throw 'winget was not found. Install or update App Installer from Microsoft before continuing.'
}

$packages = @(
    @{ Id = 'RedHat.Podman'; Tool = 'podman' },
    @{ Id = 'Kubernetes.kubectl'; Tool = 'kubectl' },
    @{ Id = 'Kubernetes.kind'; Tool = 'kind' },
    @{ Id = 'Helm.Helm'; Tool = 'helm' }
)

foreach ($package in $packages) {
    Write-Host ("Installing or confirming {0}..." -f $package.Id)
    Invoke-LabCommand -FilePath $winget -Arguments @(
        'install', '--exact', '--id', $package.Id, '--scope', 'user', '--silent',
        '--accept-package-agreements', '--accept-source-agreements', '--disable-interactivity'
    ) | Out-Null
}

$resolved = foreach ($package in $packages) {
    $path = Resolve-LabTool -Name $package.Tool
    if ([string]::IsNullOrWhiteSpace($path)) {
        throw "The $($package.Tool) package was installed but its executable could not be resolved. Open a new PowerShell window and retry."
    }
    Add-LabToolToPath -ToolPath $path
    [pscustomobject]@{ Tool = $package.Tool; Path = $path }
}
$resolved | Format-Table -AutoSize
