Set-StrictMode -Version Latest

function Get-LabRepositoryRoot {
    return (Resolve-Path (Join-Path $PSScriptRoot '..\..\..')).Path
}

function Import-LabVersions {
    $path = Join-Path (Get-LabRepositoryRoot) 'versions.psd1'
    if (-not (Test-Path -LiteralPath $path)) {
        throw "Missing version manifest: $path"
    }

    $versions = Import-PowerShellDataFile -LiteralPath $path
    $required = @(
        'PodmanMinimum', 'BaseImage', 'CodeServerVersion', 'CodeServerAmd64Sha256',
        'ShadowVersion', 'ShadowSha256', 'WorkspaceImage', 'InnerTestImage',
        'KataSmokeImage', 'PodStartupImage',
        'K3sVersion', 'HelmVersion', 'UbuntuImage', 'MultipassVersion',
        'KindVersion', 'KubernetesVersion', 'KindNodeImage', 'KataVersion',
        'KataChart', 'ClusterName', 'MachineName'
    )
    foreach ($key in $required) {
        if (-not $versions.ContainsKey($key) -or [string]::IsNullOrWhiteSpace([string]$versions[$key])) {
            throw "versions.psd1 is missing the required '$key' value."
        }
    }
    return $versions
}

function Test-LabAdministrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Resolve-LabTool {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [string[]]$AdditionalCandidates = @()
    )

    $command = Get-Command $Name -ErrorAction SilentlyContinue
    if ($null -ne $command) {
        return $command.Source
    }

    $candidates = New-Object System.Collections.Generic.List[string]
    foreach ($candidate in $AdditionalCandidates) {
        if (-not [string]::IsNullOrWhiteSpace($candidate)) { $candidates.Add($candidate) }
    }
    if ($Name -eq 'podman') {
        $candidates.Add((Join-Path $env:LOCALAPPDATA 'Programs\Podman\podman.exe'))
        $candidates.Add((Join-Path $env:ProgramFiles 'RedHat\Podman\podman.exe'))
    }
    $windowsApps = Join-Path $env:LOCALAPPDATA "Microsoft\WindowsApps\$Name.exe"
    $candidates.Add($windowsApps)

    foreach ($candidate in $candidates) {
        if (Test-Path -LiteralPath $candidate -PathType Leaf) {
            return (Resolve-Path -LiteralPath $candidate).Path
        }
    }

    $wingetRoot = Join-Path $env:LOCALAPPDATA 'Microsoft\WinGet\Packages'
    if (Test-Path -LiteralPath $wingetRoot) {
        $match = Get-ChildItem -LiteralPath $wingetRoot -Filter "$Name.exe" -File -Recurse -ErrorAction SilentlyContinue |
            Select-Object -First 1
        if ($null -ne $match) { return $match.FullName }
    }
    return $null
}

function Add-LabToolToPath {
    param([Parameter(Mandatory = $true)][string]$ToolPath)
    $directory = Split-Path -Parent $ToolPath
    $pathEntries = $env:Path -split ';'
    if ($pathEntries -notcontains $directory) {
        $env:Path = "$directory;$env:Path"
    }
}

function Invoke-LabCommand {
    param(
        [Parameter(Mandatory = $true)][string]$FilePath,
        [string[]]$Arguments = @(),
        [switch]$Capture,
        [switch]$AllowFailure
    )

    if ($Capture) {
        $output = @(& $FilePath @Arguments 2>&1)
        $exitCode = $LASTEXITCODE
        $text = ($output | ForEach-Object { [string]$_ }) -join "`n"
        if ($exitCode -ne 0 -and -not $AllowFailure) {
            throw "Command failed ($exitCode): $FilePath $($Arguments -join ' ')`n$text"
        }
        return [pscustomobject]@{ ExitCode = $exitCode; Output = $text }
    }

    & $FilePath @Arguments
    $exitCode = $LASTEXITCODE
    if ($exitCode -ne 0 -and -not $AllowFailure) {
        throw "Command failed ($exitCode): $FilePath $($Arguments -join ' ')"
    }
    return $exitCode
}

function Get-LabMachineState {
    param(
        [Parameter(Mandatory = $true)][string]$Podman,
        [Parameter(Mandatory = $true)][string]$MachineName
    )
    $result = Invoke-LabCommand -FilePath $Podman -Arguments @('machine', 'inspect', $MachineName, '--format', 'json') -Capture -AllowFailure
    if ($result.ExitCode -ne 0) { return $null }
    $machine = @($result.Output | ConvertFrom-Json)[0]
    foreach ($property in @('State', 'state')) {
        if ($machine.PSObject.Properties.Name -contains $property) { return [string]$machine.$property }
    }
    return 'unknown'
}

function New-LabPassword {
    param([int]$ByteCount = 24)
    $bytes = New-Object byte[] $ByteCount
    $rng = [Security.Cryptography.RandomNumberGenerator]::Create()
    try { $rng.GetBytes($bytes) } finally { $rng.Dispose() }
    return ([Convert]::ToBase64String($bytes).TrimEnd('=').Replace('+', '-').Replace('/', '_'))
}

function Get-LabPodName {
    param(
        [Parameter(Mandatory = $true)][string]$Kubectl,
        [string]$Namespace = 'code-server'
    )
    $result = Invoke-LabCommand -FilePath $Kubectl -Arguments @(
        'get', 'pods', '-n', $Namespace, '-l', 'app.kubernetes.io/name=code-server-podman',
        '-o', 'jsonpath={.items[0].metadata.name}'
    ) -Capture
    if ([string]::IsNullOrWhiteSpace($result.Output)) {
        throw "No code-server-podman pod was found in namespace '$Namespace'."
    }
    return $result.Output.Trim()
}
