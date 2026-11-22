[CmdletBinding()]
param(
    [string]$MachineName,
    [string]$ClusterName,
    [int]$MachineCpus = 16,
    [int]$MachineMemoryMiB = 32768,
    [int]$MachineDiskGiB = 160,
    [int]$MachineSwapMiB = 4096,
    [string]$Namespace = 'code-server',
    [string]$Password,
    [switch]$SkipToolInstall,
    [switch]$SkipImageBuild
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'lib\Common.ps1')

$root = Get-LabRepositoryRoot
$versions = Import-LabVersions
if ([string]::IsNullOrWhiteSpace($MachineName)) { $MachineName = $versions.MachineName }
if ([string]::IsNullOrWhiteSpace($ClusterName)) { $ClusterName = $versions.ClusterName }
if ($Namespace -ne 'code-server') {
    throw "The checked-in manifests use the fixed namespace 'code-server'. Custom namespaces are intentionally rejected to avoid partially rewritten security policy and Secret references."
}

if (-not $SkipToolInstall) {
    & (Join-Path $PSScriptRoot 'Install-Tools.ps1')
}

$podman = Resolve-LabTool -Name 'podman'
$kubectl = Resolve-LabTool -Name 'kubectl'
$kind = Resolve-LabTool -Name 'kind'
$helm = Resolve-LabTool -Name 'helm'
foreach ($tool in @(
    @{ Name = 'podman'; Path = $podman }, @{ Name = 'kubectl'; Path = $kubectl },
    @{ Name = 'kind'; Path = $kind }, @{ Name = 'helm'; Path = $helm }
)) {
    if ([string]::IsNullOrWhiteSpace($tool.Path)) { throw "$($tool.Name) was not found. Run Install-Tools.ps1 first." }
    Add-LabToolToPath -ToolPath $tool.Path
}

$wsl = Join-Path $env:SystemRoot 'System32\wsl.exe'
$wslStatus = Invoke-LabCommand -FilePath $wsl -Arguments @('--status') -Capture -AllowFailure
if ($wslStatus.ExitCode -ne 0) {
    throw "WSL 2 cannot start. Run Enable-HostFeatures.ps1 from an elevated PowerShell, restart Windows, and retry.`n$($wslStatus.Output)"
}

$podmanVersion = Invoke-LabCommand -FilePath $podman -Arguments @('version', '--format', '{{.Client.Version}}') -Capture -AllowFailure
if ($podmanVersion.ExitCode -ne 0) {
    $podmanVersion = Invoke-LabCommand -FilePath $podman -Arguments @('--version') -Capture
}
if ($podmanVersion.Output -match '(\d+\.\d+\.\d+)') {
    if ([version]$Matches[1] -lt [version]$versions.PodmanMinimum) {
        throw "Podman $($Matches[1]) is older than the required minimum $($versions.PodmanMinimum)."
    }
}

$kindVersion = Invoke-LabCommand -FilePath $kind -Arguments @('version') -Capture
if ($kindVersion.Output -notmatch [regex]::Escape("v$($versions.KindVersion)")) {
    Write-Warning "Expected kind v$($versions.KindVersion); found: $($kindVersion.Output). The node image remains digest-pinned."
}

$state = Get-LabMachineState -Podman $podman -MachineName $MachineName
if ($null -eq $state) {
    Write-Host "Creating rootful WSL Podman machine '$MachineName'..."
    Invoke-LabCommand -FilePath $podman -Arguments @(
        'machine', 'init', '--provider', 'wsl', '--cpus', [string]$MachineCpus,
        '--memory', [string]$MachineMemoryMiB, '--disk-size', [string]$MachineDiskGiB,
        '--swap', [string]$MachineSwapMiB, '--rootful', '--update-connection', $MachineName
    ) | Out-Null
    $state = 'stopped'
}

if ($state -notmatch '(?i)running') {
    Invoke-LabCommand -FilePath $podman -Arguments @('machine', 'set', '--rootful', $MachineName) | Out-Null
    Invoke-LabCommand -FilePath $podman -Arguments @('machine', 'start', $MachineName) | Out-Null
}

$machineInspectResult = Invoke-LabCommand -FilePath $podman -Arguments @('machine', 'inspect', $MachineName, '--format', 'json') -Capture
$machineInspect = @($machineInspectResult.Output | ConvertFrom-Json)[0]
$machineIsRootful = $machineInspect.PSObject.Properties.Name -contains 'Rootful' -and [bool]$machineInspect.Rootful
if (-not $machineIsRootful) {
    Write-Host 'Switching the infrastructure engine to rootful mode (the Kata workload remains non-root)...'
    Invoke-LabCommand -FilePath $podman -Arguments @('machine', 'stop', $MachineName) | Out-Null
    Invoke-LabCommand -FilePath $podman -Arguments @('machine', 'set', '--rootful', $MachineName) | Out-Null
    Invoke-LabCommand -FilePath $podman -Arguments @('machine', 'start', $MachineName) | Out-Null
}

# A host may have several Podman machines. Select this machine's root socket
# explicitly so kind, builds, and subsequent exec calls cannot hit another engine.
$connectionsResult = Invoke-LabCommand -FilePath $podman -Arguments @('system', 'connection', 'list', '--format', 'json') -Capture
$connections = @($connectionsResult.Output | ConvertFrom-Json)
$rootConnection = @($connections | Where-Object {
    $_.Name -eq "$MachineName-root" -or
    ($_.Name -like "$MachineName*" -and [string]$_.URI -match '/run/podman/podman\.sock$')
} | Select-Object -First 1)
if ($rootConnection.Count -ne 1) {
    throw "Could not identify the rootful Podman connection for machine '$MachineName'."
}
Invoke-LabCommand -FilePath $podman -Arguments @('system', 'connection', 'default', [string]$rootConnection[0].Name) | Out-Null
$outerRootless = Invoke-LabCommand -FilePath $podman -Arguments @('info', '--format', '{{.Host.Security.Rootless}}') -Capture
if ($outerRootless.Output.Trim() -ne 'false') {
    throw "The selected connection '$($rootConnection[0].Name)' is not rootful."
}

$cgroups = Invoke-LabCommand -FilePath $podman -Arguments @('info', '--format', '{{.Host.CgroupsVersion}}') -Capture
if ($cgroups.Output.Trim() -ne 'v2') {
    throw "The outer Podman engine must use cgroup v2; detected '$($cgroups.Output.Trim())'."
}

$machineProbeScript = @'
set -eu
sudo modprobe kvm_amd 2>/dev/null || sudo modprobe kvm_intel 2>/dev/null || true
sudo modprobe vhost_vsock 2>/dev/null || true
sudo modprobe vhost_net 2>/dev/null || true
if grep -Eq '(vmx|svm)' /proc/cpuinfo && sudo test -c /dev/kvm && sudo test -r /dev/kvm && sudo test -w /dev/kvm; then
  echo KVM
elif sudo test -c /dev/mshv && sudo test -r /dev/mshv && sudo test -w /dev/mshv; then
  echo MSHV
else
  echo 'Neither a usable /dev/kvm nor /dev/mshv is available in Podman Machine.' >&2
  exit 42
fi
'@
$machineProbe = Invoke-LabCommand -FilePath $podman -Arguments @('machine', 'ssh', $MachineName, 'sh', '-lc', $machineProbeScript) -Capture -AllowFailure
if ($machineProbe.ExitCode -ne 0) {
    throw "Kata hardware virtualization preflight failed inside Podman Machine. Software emulation is intentionally rejected because it is slow and not a credible isolation validation.`n$($machineProbe.Output)"
}
$profile = if ($machineProbe.Output -match '(?m)^KVM\s*$') { 'kvm' } elseif ($machineProbe.Output -match '(?m)^MSHV\s*$') { 'mshv' } else { throw "Could not classify the virtualization device.`n$($machineProbe.Output)" }
$runtimeClass = if ($profile -eq 'kvm') { 'kata-qemu-runtime-rs' } else { 'kata-clh-azure-runtime-rs' }
Write-Host "Selected Kata profile: $profile ($runtimeClass)"

$env:KIND_EXPERIMENTAL_PROVIDER = 'podman'
$clusters = Invoke-LabCommand -FilePath $kind -Arguments @('get', 'clusters') -Capture -AllowFailure
$clusterExists = $clusters.ExitCode -eq 0 -and (($clusters.Output -split "`r?`n") -contains $ClusterName)
if (-not $clusterExists) {
    Write-Host "Creating kind cluster '$ClusterName' through rootful Podman..."
    Invoke-LabCommand -FilePath $kind -Arguments @(
        'create', 'cluster', '--name', $ClusterName, '--config', (Join-Path $root 'kind\cluster.yaml'),
        '--image', $versions.KindNodeImage, '--wait', '5m'
    ) | Out-Null
}
else {
    Write-Host "Reusing existing kind cluster '$ClusterName'."
    Invoke-LabCommand -FilePath $kind -Arguments @('export', 'kubeconfig', '--name', $ClusterName) | Out-Null
}

$nodeName = "$ClusterName-control-plane"
$nodeProbeScript = if ($profile -eq 'kvm') {
    'test -c /dev/kvm && test -r /dev/kvm && test -w /dev/kvm && test -c /dev/vhost-vsock && test -c /dev/vhost-net'
}
else {
    'test -c /dev/mshv && test -r /dev/mshv && test -w /dev/mshv'
}
$nodeProbe = Invoke-LabCommand -FilePath $podman -Arguments @('exec', $nodeName, 'sh', '-lc', $nodeProbeScript) -Capture -AllowFailure
if ($nodeProbe.ExitCode -ne 0) {
    throw "The kind node does not inherit the required virtualization/vhost devices. An extra volume mount cannot manufacture hardware access. Node: $nodeName"
}

if (-not $SkipImageBuild) {
    Write-Host "Building $($versions.WorkspaceImage)..."
    Invoke-LabCommand -FilePath $podman -Arguments @(
        'build', '--pull=missing', '--tag', $versions.WorkspaceImage,
        '--build-arg', "CODE_SERVER_VERSION=$($versions.CodeServerVersion)",
        '--file', (Join-Path $root 'container\Dockerfile'), $root
    ) | Out-Null
}

Write-Host 'Loading the workspace image into kind containerd...'
Invoke-LabCommand -FilePath $kind -Arguments @('load', 'docker-image', $versions.WorkspaceImage, '--name', $ClusterName) | Out-Null

$kataValues = Join-Path $root (if ($profile -eq 'kvm') { 'kata\values-kvm.yaml' } else { 'kata\values-mshv.yaml' })
Write-Host "Installing Kata Containers $($versions.KataVersion)..."
Invoke-LabCommand -FilePath $helm -Arguments @(
    'upgrade', '--install', 'kata-deploy', $versions.KataChart,
    '--version', $versions.KataVersion, '--namespace', 'kata-system', '--create-namespace',
    '--values', $kataValues, '--set-string', "job.nodes[0]=$nodeName", '--wait', '--timeout', '15m'
) | Out-Null
Invoke-LabCommand -FilePath $kubectl -Arguments @('wait', '--for=create', "runtimeclass/$runtimeClass", '--timeout=2m') | Out-Null

$namespaceManifest = Join-Path $root 'k8s\base\namespace.yaml'
Invoke-LabCommand -FilePath $kubectl -Arguments @('apply', '-f', $namespaceManifest) | Out-Null
if ([string]::IsNullOrWhiteSpace($Password)) { $Password = New-LabPassword }
$secretYaml = Invoke-LabCommand -FilePath $kubectl -Arguments @(
    'create', 'secret', 'generic', 'code-server-auth', '--namespace', $Namespace,
    "--from-literal=PASSWORD=$Password", '--dry-run=client', '-o', 'yaml'
) -Capture
$secretYaml.Output | & $kubectl apply -f -
if ($LASTEXITCODE -ne 0) { throw 'Failed to apply the code-server authentication Secret.' }

$overlay = Join-Path $root "k8s\overlays\$profile"
Invoke-LabCommand -FilePath $kubectl -Arguments @('apply', '-k', $overlay) | Out-Null
Invoke-LabCommand -FilePath $kubectl -Arguments @(
    'rollout', 'status', 'deployment/code-server-podman', '--namespace', $Namespace, '--timeout=10m'
) | Out-Null

& (Join-Path $PSScriptRoot 'Verify-Cluster.ps1') -ClusterName $ClusterName -Namespace $Namespace -ExpectedRuntimeClass $runtimeClass

Write-Host ''
Write-Host 'Cluster and Kata workspace are ready.' -ForegroundColor Green
Write-Host 'URL:      http://127.0.0.1:8443'
Write-Host "Password: $Password"
Write-Host 'The password is stored only in the Kubernetes Secret. Retrieve it later with:'
Write-Host "  kubectl -n $Namespace get secret code-server-auth -o jsonpath='{.data.PASSWORD}' | ForEach-Object { [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String(`$_)) }"
