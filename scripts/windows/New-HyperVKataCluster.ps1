[CmdletBinding()]
param(
    [ValidatePattern('^[a-z0-9][a-z0-9-]{0,62}$')]
    [string]$VMName = 'kata-k8s',
    [ValidateRange(4, 32)]
    [int]$ProcessorCount = 8,
    [ValidateRange(8, 128)]
    [int]$MemoryGiB = 16,
    [ValidateRange(60, 2048)]
    [int]$DiskGiB = 100,
    [string]$UbuntuImage,
    [string]$MultipassVersion,
    [string]$K3sVersion,
    [string]$KataVersion,
    [string]$HelmVersion
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'lib\Common.ps1')

$pinnedVersions = Import-LabVersions
if ([string]::IsNullOrWhiteSpace($UbuntuImage)) { $UbuntuImage = [string]$pinnedVersions.UbuntuImage }
if ([string]::IsNullOrWhiteSpace($MultipassVersion)) { $MultipassVersion = [string]$pinnedVersions.MultipassVersion }
if ([string]::IsNullOrWhiteSpace($K3sVersion)) { $K3sVersion = [string]$pinnedVersions.K3sVersion }
if ([string]::IsNullOrWhiteSpace($KataVersion)) { $KataVersion = [string]$pinnedVersions.KataVersion }
if ([string]::IsNullOrWhiteSpace($HelmVersion)) { $HelmVersion = [string]$pinnedVersions.HelmVersion }

function Invoke-CheckedCommand {
    param(
        [Parameter(Mandatory = $true)][string]$FilePath,
        [string[]]$Arguments = @(),
        [switch]$Capture,
        [switch]$AllowFailure
    )

    $previousErrorActionPreference = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    if ($Capture) {
        try {
            $output = @(& $FilePath @Arguments 2>&1)
            $exitCode = $LASTEXITCODE
        }
        finally {
            $ErrorActionPreference = $previousErrorActionPreference
        }
        $text = ($output | ForEach-Object { [string]$_ }) -join "`n"
        if ($exitCode -ne 0 -and -not $AllowFailure) {
            throw "Command failed ($exitCode): $FilePath $($Arguments -join ' ')`n$text"
        }
        return [pscustomobject]@{ ExitCode = $exitCode; Output = $text }
    }

    try {
        & $FilePath @Arguments
        $exitCode = $LASTEXITCODE
    }
    finally {
        $ErrorActionPreference = $previousErrorActionPreference
    }
    if ($exitCode -ne 0 -and -not $AllowFailure) {
        throw "Command failed ($exitCode): $FilePath $($Arguments -join ' ')"
    }
    return $exitCode
}

function Resolve-Multipass {
    $command = Get-Command multipass -ErrorAction SilentlyContinue
    if ($null -ne $command) { return $command.Source }

    foreach ($candidate in @(
        (Join-Path $env:ProgramFiles 'Multipass\bin\multipass.exe'),
        (Join-Path $env:ProgramFiles 'Canonical\Multipass\bin\multipass.exe')
    )) {
        if (Test-Path -LiteralPath $candidate -PathType Leaf) {
            return (Resolve-Path -LiteralPath $candidate).Path
        }
    }
    return $null
}

function Get-MultipassInstance {
    param(
        [Parameter(Mandatory = $true)][string]$Multipass,
        [Parameter(Mandatory = $true)][string]$Name
    )

    $result = Invoke-CheckedCommand -FilePath $Multipass -Arguments @(
        'info', $Name, '--format', 'json'
    ) -Capture -AllowFailure
    if ($result.ExitCode -ne 0) { return $null }

    $json = $result.Output | ConvertFrom-Json
    $property = $json.info.PSObject.Properties[$Name]
    if ($null -eq $property) { return $null }
    return $property.Value
}

function Wait-MultipassReady {
    param(
        [Parameter(Mandatory = $true)][string]$Multipass,
        [Parameter(Mandatory = $true)][string]$Name,
        [int]$TimeoutSeconds = 900
    )

    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    do {
        $probe = Invoke-CheckedCommand -FilePath $Multipass -Arguments @(
            'exec', $Name, '--', 'true'
        ) -Capture -AllowFailure
        if ($probe.ExitCode -eq 0) { return }
        Start-Sleep -Seconds 5
    } while ((Get-Date) -lt $deadline)
    throw "Multipass instance '$Name' did not become ready within $TimeoutSeconds seconds."
}

if (-not (Test-LabAdministrator)) {
    throw 'Run this script from an elevated PowerShell window.'
}

$root = Get-LabRepositoryRoot
$stateDirectory = Join-Path $root '.state\hyperv-kata'
New-Item -ItemType Directory -Path $stateDirectory -Force | Out-Null
$statusPath = Join-Path $stateDirectory 'status.txt'
$logPath = Join-Path $stateDirectory 'provision.log'

try {
    Start-Transcript -LiteralPath $logPath -Append | Out-Null
}
catch {
    Write-Warning "Could not start transcript: $($_.Exception.Message)"
}

try {
    Write-Host "Preparing Hyper-V VM '$VMName'..."

    $feature = Get-WindowsOptionalFeature -Online -FeatureName Microsoft-Hyper-V-All
    $restartRequired = $false
    if ($feature.State -ne 'Enabled') {
        Write-Host 'Enabling the Hyper-V platform...'
        $featureResult = Enable-WindowsOptionalFeature -Online -FeatureName Microsoft-Hyper-V-All -All -NoRestart
        if ($featureResult.RestartNeeded) { $restartRequired = $true }
    }

    $bcdedit = Join-Path $env:SystemRoot 'System32\bcdedit.exe'
    Invoke-CheckedCommand -FilePath $bcdedit -Arguments @(
        '/set', 'hypervisorlaunchtype', 'auto'
    ) | Out-Null

    $computerSystem = Get-CimInstance Win32_ComputerSystem
    if (-not [bool]$computerSystem.HypervisorPresent) {
        $restartRequired = $true
    }

    $cpu = Get-CimInstance Win32_Processor | Select-Object -First 1
    if (-not [bool]$cpu.VirtualizationFirmwareEnabled) {
        throw 'CPU virtualization is disabled in UEFI/firmware.'
    }
    $build = [int](Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion').CurrentBuild
    if ($cpu.Manufacturer -eq 'AuthenticAMD' -and $build -lt 22000) {
        throw 'AMD nested virtualization requires Windows 11 or Windows Server 2022 or later.'
    }

    if ($restartRequired) {
        Set-Content -LiteralPath $statusPath -Value 'RESTART_REQUIRED' -Encoding ascii
        Write-Warning 'Hyper-V is configured, but Windows must be restarted before the VM can be created.'
        Write-Host "After the restart, run this same script again: $PSCommandPath"
        exit 3010
    }

    Import-Module Hyper-V -ErrorAction Stop
    $switch = Get-VMSwitch -Name 'Default Switch' -ErrorAction SilentlyContinue
    if ($null -eq $switch) {
        $switch = Get-VMSwitch | Where-Object SwitchType -eq 'External' | Select-Object -First 1
    }
    if ($null -eq $switch) {
        throw 'No Hyper-V Default Switch or external switch is available.'
    }

    $multipass = Resolve-Multipass
    if ([string]::IsNullOrWhiteSpace($multipass)) {
        $winget = Resolve-LabTool -Name 'winget'
        if ([string]::IsNullOrWhiteSpace($winget)) {
            throw 'winget was not found; Multipass cannot be installed automatically.'
        }
        Write-Host "Installing Canonical Multipass $MultipassVersion..."
        Invoke-CheckedCommand -FilePath $winget -Arguments @(
            'install', '--exact', '--id', 'Canonical.Multipass',
            '--version', $MultipassVersion, '--silent', '--disable-interactivity',
            '--accept-package-agreements', '--accept-source-agreements'
        ) | Out-Null

        for ($attempt = 0; $attempt -lt 60; $attempt++) {
            $multipass = Resolve-Multipass
            if (-not [string]::IsNullOrWhiteSpace($multipass)) { break }
            Start-Sleep -Seconds 2
        }
        if ([string]::IsNullOrWhiteSpace($multipass)) {
            throw 'Multipass was installed but multipass.exe could not be resolved.'
        }
    }

    $multipassReady = $false
    for ($attempt = 0; $attempt -lt 60; $attempt++) {
        $versionProbe = Invoke-CheckedCommand -FilePath $multipass -Arguments @('version') -Capture -AllowFailure
        if ($versionProbe.ExitCode -eq 0) {
            $multipassReady = $true
            break
        }
        Start-Sleep -Seconds 2
    }
    if (-not $multipassReady) {
        throw 'The Multipass service did not finish its certificate initialization.'
    }

    $driver = Invoke-CheckedCommand -FilePath $multipass -Arguments @(
        'get', 'local.driver'
    ) -Capture -AllowFailure
    if ($driver.ExitCode -eq 0 -and $driver.Output.Trim() -ne 'hyperv') {
        $instances = Invoke-CheckedCommand -FilePath $multipass -Arguments @(
            'list', '--format', 'json'
        ) -Capture -AllowFailure
        if ($instances.ExitCode -eq 0 -and $instances.Output -match '"name"\s*:') {
            throw "Multipass already has instances on driver '$($driver.Output.Trim())'. Refusing to hide them by switching drivers."
        }
    }
    Invoke-CheckedCommand -FilePath $multipass -Arguments @(
        'set', 'local.driver=hyperv'
    ) | Out-Null

    $instance = Get-MultipassInstance -Multipass $multipass -Name $VMName
    $hyperVVM = Get-VM -Name $VMName -ErrorAction SilentlyContinue
    if ($null -eq $instance -and $null -ne $hyperVVM) {
        throw "A Hyper-V VM named '$VMName' exists but is not managed by Multipass. Refusing to overwrite it."
    }

    if ($null -eq $instance) {
        Write-Host "Creating Ubuntu $UbuntuImage VM '$VMName' on switch '$($switch.Name)'..."
        Invoke-CheckedCommand -FilePath $multipass -Arguments @(
            'launch', $UbuntuImage,
            '--name', $VMName,
            '--cpus', [string]$ProcessorCount,
            '--memory', "${MemoryGiB}G",
            '--disk', "${DiskGiB}G",
            '--timeout', '1800'
        ) | Out-Null
    }
    else {
        Write-Host "Reusing Multipass instance '$VMName'."
    }

    Invoke-CheckedCommand -FilePath $multipass -Arguments @('stop', $VMName) | Out-Null
    $hyperVVM = Get-VM -Name $VMName -ErrorAction Stop
    if ($hyperVVM.Generation -ne 2) {
        throw "VM '$VMName' is Generation $($hyperVVM.Generation); Generation 2 is required."
    }
    if ([version]$hyperVVM.Version -lt [version]'9.3') {
        throw "VM configuration version $($hyperVVM.Version) is too old for AMD nested virtualization."
    }

    Set-VMProcessor -VMName $VMName -Count $ProcessorCount -ExposeVirtualizationExtensions $true
    Set-VMMemory -VMName $VMName -DynamicMemoryEnabled $false -StartupBytes ([int64]$MemoryGiB * 1GB)
    Set-VMFirmware -VMName $VMName -EnableSecureBoot On -SecureBootTemplate 'MicrosoftUEFICertificateAuthority'
    Set-VM -VMName $VMName -AutomaticCheckpointsEnabled $false -AutomaticStartAction StartIfRunning -AutomaticStopAction ShutDown

    Invoke-CheckedCommand -FilePath $multipass -Arguments @('start', $VMName) | Out-Null
    Wait-MultipassReady -Multipass $multipass -Name $VMName -TimeoutSeconds 900

    $instance = Get-MultipassInstance -Multipass $multipass -Name $VMName
    $ip = @($instance.ipv4 | Where-Object { $_ -match '^\d{1,3}(\.\d{1,3}){3}$' } | Select-Object -First 1)
    if ($ip.Count -ne 1) {
        throw "Could not determine the IPv4 address for '$VMName'."
    }
    $nodeIP = [string]$ip[0]

    $guestInstaller = Join-Path $root 'scripts\linux\Install-K3sKata.sh'
    $kataValues = Join-Path $root 'hyperv\kata-values.yaml'
    foreach ($file in @($guestInstaller, $kataValues)) {
        if (-not (Test-Path -LiteralPath $file -PathType Leaf)) {
            throw "Missing provisioning file: $file"
        }
    }

    Invoke-CheckedCommand -FilePath $multipass -Arguments @(
        'transfer', $guestInstaller, "${VMName}:/home/ubuntu/install-k3s-kata.sh"
    ) | Out-Null
    Invoke-CheckedCommand -FilePath $multipass -Arguments @(
        'transfer', $kataValues, "${VMName}:/home/ubuntu/kata-values.yaml"
    ) | Out-Null

    Write-Host "Installing K3s $K3sVersion and Kata Containers $KataVersion..."
    Invoke-CheckedCommand -FilePath $multipass -Arguments @(
        'exec', $VMName, '--', 'sudo', 'env',
        "K3S_VERSION=$K3sVersion",
        "KATA_VERSION=$KataVersion",
        "HELM_VERSION=$HelmVersion",
        "KATA_SMOKE_IMAGE=$($pinnedVersions.KataSmokeImage)",
        "K3S_NODE_IP=$nodeIP",
        'KATA_VALUES_FILE=/home/ubuntu/kata-values.yaml',
        'bash', '/home/ubuntu/install-k3s-kata.sh'
    ) | Out-Null

    $kubeconfig = Join-Path $stateDirectory "$VMName.kubeconfig"
    if (Test-Path -LiteralPath $kubeconfig) {
        Remove-Item -LiteralPath $kubeconfig -Force
    }
    Invoke-CheckedCommand -FilePath $multipass -Arguments @(
        'transfer', "${VMName}:/home/ubuntu/k3s-host.yaml", $kubeconfig
    ) | Out-Null

    $kubectl = Resolve-LabTool -Name 'kubectl'
    if (-not [string]::IsNullOrWhiteSpace($kubectl)) {
        Invoke-CheckedCommand -FilePath $kubectl -Arguments @(
            'get', 'nodes', '-o', 'wide', '--kubeconfig', $kubeconfig
        ) | Out-Null
        Invoke-CheckedCommand -FilePath $kubectl -Arguments @(
            'get', 'runtimeclass', 'kata-qemu-runtime-rs',
            '--kubeconfig', $kubeconfig
        ) | Out-Null
    }

    [pscustomobject]@{
        VMName = $VMName
        IPAddress = $nodeIP
        Kubeconfig = $kubeconfig
        K3sVersion = $K3sVersion
        KataVersion = $KataVersion
        RuntimeClass = 'kata-qemu-runtime-rs'
        CompletedAt = (Get-Date).ToString('o')
    } | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $stateDirectory 'cluster.json') -Encoding utf8
    Set-Content -LiteralPath $statusPath -Value 'COMPLETE' -Encoding ascii

    Write-Host ''
    Write-Host 'Hyper-V Kata cluster is ready.' -ForegroundColor Green
    Write-Host "VM: $VMName ($nodeIP)"
    Write-Host 'RuntimeClass: kata-qemu-runtime-rs'
    Write-Host "Kubeconfig: $kubeconfig"
    Write-Host "Shell: `"$multipass`" shell $VMName"
}
catch {
    Set-Content -LiteralPath $statusPath -Value 'FAILED' -Encoding ascii
    throw
}
finally {
    try { Stop-Transcript | Out-Null } catch { }
}
