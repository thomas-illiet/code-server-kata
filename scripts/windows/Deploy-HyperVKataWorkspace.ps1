[CmdletBinding()]
param(
    [ValidatePattern('^[a-z0-9][a-z0-9-]{0,62}$')]
    [string]$VMName = 'kata-k8s',
    [string]$Kubeconfig,
    [string]$Namespace = 'code-server',
    [string]$Password,
    [switch]$SkipImageBuild,
    [switch]$SkipInnerContainerRun
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'lib\Common.ps1')

$root = Get-LabRepositoryRoot
$versions = Import-LabVersions
$runtimeClass = 'kata-qemu-runtime-rs'
$imageBuilt = $false
$secretChanged = $false

if ($Namespace -ne 'code-server') {
    throw "The checked-in manifests use the fixed namespace 'code-server'."
}
if ([string]::IsNullOrWhiteSpace($Kubeconfig)) {
    $Kubeconfig = Join-Path $root ".state\hyperv-kata\$VMName.kubeconfig"
}
if (-not (Test-Path -LiteralPath $Kubeconfig -PathType Leaf)) {
    throw "Kubeconfig not found: $Kubeconfig"
}
$Kubeconfig = (Resolve-Path -LiteralPath $Kubeconfig).Path

$kubectl = Resolve-LabTool -Name 'kubectl'
$multipass = Resolve-LabTool -Name 'multipass' -AdditionalCandidates @(
    (Join-Path $env:ProgramFiles 'Multipass\bin\multipass.exe'),
    (Join-Path $env:ProgramFiles 'Canonical\Multipass\bin\multipass.exe')
)
if ([string]::IsNullOrWhiteSpace($kubectl)) { throw 'kubectl was not found.' }
if ([string]::IsNullOrWhiteSpace($multipass)) { throw 'multipass was not found.' }

function Invoke-WorkspaceKubectl {
    param(
        [Parameter(Mandatory = $true)][string[]]$Arguments,
        [switch]$AllowFailure
    )
    return Invoke-LabCommand -FilePath $kubectl -Arguments (@(
        '--kubeconfig', $Kubeconfig
    ) + $Arguments) -Capture -AllowFailure:$AllowFailure
}

function Assert-WorkspaceValue {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][bool]$Condition,
        [Parameter(Mandatory = $true)][string]$Evidence
    )
    if (-not $Condition) { throw "$Name failed: $Evidence" }
    Write-Host "[ok] $Name - $Evidence"
}

Write-Host "Checking Multipass VM '$VMName' and Kata RuntimeClass..."
[void](Invoke-LabCommand -FilePath $multipass -Arguments @(
    'exec', $VMName, '--', 'true'
) -Capture)
[void](Invoke-WorkspaceKubectl -Arguments @(
    'wait', '--for=condition=Ready', 'node', '--all', '--timeout=2m'
))
[void](Invoke-WorkspaceKubectl -Arguments @(
    'get', 'runtimeclass', $runtimeClass, '-o', 'name'
))
$kataContainerdConfig = Invoke-LabCommand -FilePath $multipass -Arguments @(
    'exec', $VMName, '--', 'sudo', 'cat',
    '/var/lib/rancher/k3s/agent/etc/containerd/config-v3.toml.d/kata-deploy.toml'
) -Capture
Assert-WorkspaceValue -Name 'Kata runtime device isolation' `
    -Condition ($kataContainerdConfig.Output -match [regex]::Escape(".runtimes.$runtimeClass]") -and
        $kataContainerdConfig.Output -match '(?m)^privileged_without_host_devices\s*=\s*true\s*$') `
    -Evidence 'privileged_without_host_devices=true'

if (-not $SkipImageBuild) {
    $buildId = [Guid]::NewGuid().ToString('N')
    $remoteBuildRoot = "/home/ubuntu/.cache/code-server-kata-build-$buildId"
    if ($remoteBuildRoot -notmatch '^/home/ubuntu/\.cache/code-server-kata-build-[0-9a-f]{32}$') {
        throw "Unsafe remote build path: $remoteBuildRoot"
    }

    try {
        Write-Host "Transferring the image build context to '$VMName'..."
        [void](Invoke-LabCommand -FilePath $multipass -Arguments @(
            'exec', $VMName, '--', 'mkdir', '-p', $remoteBuildRoot
        ) -Capture)
        [void](Invoke-LabCommand -FilePath $multipass -Arguments @(
            'transfer', '--recursive', (Join-Path $root 'container'),
            "${VMName}:$remoteBuildRoot"
        ) -Capture)
        [void](Invoke-LabCommand -FilePath $multipass -Arguments @(
            'exec', $VMName, '--', 'test', '-f', "$remoteBuildRoot/container/Dockerfile"
        ) -Capture)

        Write-Host "Building $($versions.WorkspaceImage) inside the Linux VM..."
        [void](Invoke-LabCommand -FilePath $multipass -Arguments @(
            'exec', $VMName, '--', 'sudo', 'podman', 'build',
            '--pull=missing', '--tag', $versions.WorkspaceImage,
            '--build-arg', "BASE_IMAGE=$($versions.BaseImage)",
            '--build-arg', "CODE_SERVER_VERSION=$($versions.CodeServerVersion)",
            '--build-arg', "CODE_SERVER_AMD64_SHA256=$($versions.CodeServerAmd64Sha256)",
            '--build-arg', "SHADOW_VERSION=$($versions.ShadowVersion)",
            '--build-arg', "SHADOW_SHA256=$($versions.ShadowSha256)",
            '--file', "$remoteBuildRoot/container/Dockerfile", $remoteBuildRoot
        ))

        $archive = "$remoteBuildRoot/code-server-podman.oci.tar"
        Write-Host 'Importing the image into the K3s containerd image store...'
        [void](Invoke-LabCommand -FilePath $multipass -Arguments @(
            'exec', $VMName, '--', 'sudo', 'podman', 'save',
            '--format', 'oci-archive', '--output', $archive, $versions.WorkspaceImage
        ))
        [void](Invoke-LabCommand -FilePath $multipass -Arguments @(
            'exec', $VMName, '--', 'sudo', 'k3s', 'ctr', 'images', 'import', $archive
        ))
        $imageBuilt = $true
    }
    finally {
        [void](Invoke-LabCommand -FilePath $multipass -Arguments @(
            'exec', $VMName, '--', 'sudo', 'rm', '-rf', '--', $remoteBuildRoot
        ) -Capture -AllowFailure)
    }
}

$images = Invoke-LabCommand -FilePath $multipass -Arguments @(
    'exec', $VMName, '--', 'sudo', 'k3s', 'ctr', 'images', 'list', '-q'
) -Capture
$imagePresent = ($images.Output -split "`r?`n") -contains $versions.WorkspaceImage
Assert-WorkspaceValue -Name 'workspace image imported' -Condition $imagePresent -Evidence $versions.WorkspaceImage

Write-Host 'Creating the namespace and authentication Secret...'
[void](Invoke-WorkspaceKubectl -Arguments @(
    'apply', '-f', (Join-Path $root 'k8s\base\namespace.yaml')
))
$existingSecret = Invoke-WorkspaceKubectl -Arguments @(
    'get', 'secret', 'code-server-auth', '--namespace', $Namespace, '-o', 'name'
) -AllowFailure
if ([string]::IsNullOrWhiteSpace($Password) -and $existingSecret.ExitCode -eq 0) {
    Write-Host 'Reusing the existing code-server authentication Secret.'
}
else {
    if ([string]::IsNullOrWhiteSpace($Password)) { $Password = New-LabPassword }
    $secretYaml = Invoke-WorkspaceKubectl -Arguments @(
        'create', 'secret', 'generic', 'code-server-auth', '--namespace', $Namespace,
        "--from-literal=PASSWORD=$Password", '--dry-run=client', '-o', 'yaml'
    )
    $secretYaml.Output | & $kubectl --kubeconfig $Kubeconfig apply -f -
    if ($LASTEXITCODE -ne 0) { throw 'Failed to apply the code-server authentication Secret.' }
    $secretChanged = $true
}

Write-Host 'Deploying the single-container Kata workspace...'
[void](Invoke-WorkspaceKubectl -Arguments @(
    'apply', '-k', (Join-Path $root 'k8s\overlays\kvm')
))
if ($imageBuilt -or $secretChanged) {
    [void](Invoke-WorkspaceKubectl -Arguments @(
        'rollout', 'restart', 'deployment/code-server-podman', '--namespace', $Namespace
    ))
}
[void](Invoke-WorkspaceKubectl -Arguments @(
    'rollout', 'status', 'deployment/code-server-podman',
    '--namespace', $Namespace, '--timeout=15m'
))

$podName = (Invoke-WorkspaceKubectl -Arguments @(
    'get', 'pods', '--namespace', $Namespace,
    '--selector', 'app.kubernetes.io/name=code-server-podman',
    '-o', 'jsonpath={.items[0].metadata.name}'
)).Output.Trim()
if ([string]::IsNullOrWhiteSpace($podName)) { throw 'No code-server pod was created.' }
$pod = (Invoke-WorkspaceKubectl -Arguments @(
    'get', 'pod', $podName, '--namespace', $Namespace, '-o', 'json'
)).Output | ConvertFrom-Json

Assert-WorkspaceValue -Name 'single container' `
    -Condition (@($pod.spec.containers).Count -eq 1 -and $pod.spec.containers[0].name -eq 'code-server') `
    -Evidence "containers=$(@($pod.spec.containers).Count)"
Assert-WorkspaceValue -Name 'Kata RuntimeClass requested' `
    -Condition ([string]$pod.spec.runtimeClassName -eq $runtimeClass) `
    -Evidence ([string]$pod.spec.runtimeClassName)
$containerSecurity = $pod.spec.containers[0].securityContext
$addedCapabilities = @($containerSecurity.capabilities.add | Sort-Object)
$droppedCapabilities = @($containerSecurity.capabilities.drop | Sort-Object)
Assert-WorkspaceValue -Name 'minimal Podman capability envelope' `
    -Condition ($containerSecurity.privileged -eq $false -and
        $containerSecurity.allowPrivilegeEscalation -eq $true -and
        $containerSecurity.readOnlyRootFilesystem -eq $true -and
        [string]$containerSecurity.seccompProfile.type -eq 'Unconfined' -and
        ($addedCapabilities -join ',') -eq 'SETGID,SETUID' -and
        ($droppedCapabilities -join ',') -eq 'ALL') `
    -Evidence "privileged=false; add=$($addedCapabilities -join ','); drop=$($droppedCapabilities -join ',')"
Assert-WorkspaceValue -Name 'strict supplemental groups' `
    -Condition ([string]$pod.spec.securityContext.supplementalGroupsPolicy -eq 'Strict') `
    -Evidence "supplementalGroupsPolicy=$($pod.spec.securityContext.supplementalGroupsPolicy)"

$nodeKernel = (Invoke-WorkspaceKubectl -Arguments @(
    'get', 'node', ([string]$pod.spec.nodeName), '-o', 'jsonpath={.status.nodeInfo.kernelVersion}'
)).Output.Trim()
$guestKernel = (Invoke-WorkspaceKubectl -Arguments @(
    'exec', '--namespace', $Namespace, $podName, '--', 'uname', '-r'
)).Output.Trim()
Assert-WorkspaceValue -Name 'Kata guest kernel' `
    -Condition ($guestKernel -ne $nodeKernel) `
    -Evidence "node=$nodeKernel guest=$guestKernel"

$uid = (Invoke-WorkspaceKubectl -Arguments @(
    'exec', '--namespace', $Namespace, $podName, '--', 'id', '-u'
)).Output.Trim()
Assert-WorkspaceValue -Name 'code-server UID' -Condition ($uid -eq '1000') -Evidence "uid=$uid"

$capabilityStatus = (Invoke-WorkspaceKubectl -Arguments @(
    'exec', '--namespace', $Namespace, $podName, '--',
    'sh', '-lc', "grep -E '^(CapInh|CapPrm|CapEff|CapBnd|CapAmb|NoNewPrivs|Seccomp):' /proc/1/status"
)).Output
$zeroCapabilityFields = @('CapInh', 'CapPrm', 'CapEff', 'CapAmb')
$zeroCapabilities = @($zeroCapabilityFields | Where-Object {
    $capabilityStatus -notmatch "(?m)^$([regex]::Escape($_)):\s+0000000000000000\s*$"
}).Count -eq 0
$capabilityStateOkay = $zeroCapabilities -and
    $capabilityStatus -match '(?m)^CapBnd:\s+00000000000000c0\s*$' -and
    $capabilityStatus -match '(?m)^NoNewPrivs:\s+0\s*$' -and
    $capabilityStatus -match '(?m)^Seccomp:\s+0\s*$'
Assert-WorkspaceValue -Name 'code-server capability state' `
    -Condition $capabilityStateOkay -Evidence ($capabilityStatus -replace "`r?`n", '; ')

$groups = (Invoke-WorkspaceKubectl -Arguments @(
    'exec', '--namespace', $Namespace, $podName, '--', 'id', '-G'
)).Output.Trim()
Assert-WorkspaceValue -Name 'code-server supplemental groups' `
    -Condition ($groups -eq '1000') -Evidence "groups=$groups"

$setidOutput = (Invoke-WorkspaceKubectl -Arguments @(
    'exec', '--namespace', $Namespace, $podName, '--', 'sh', '-lc',
    "find /usr -xdev -type f -perm /6000 -printf '%p\n' 2>/dev/null | sort"
)).Output
$setidPaths = @($setidOutput -split "`r?`n" | Where-Object { $_ -match '^/' })
$expectedSetidPaths = @('/usr/bin/newgidmap', '/usr/bin/newuidmap')
$unexpectedSetidPaths = @($setidPaths | Where-Object { $expectedSetidPaths -notcontains $_ })
$missingSetidPaths = @($expectedSetidPaths | Where-Object { $setidPaths -notcontains $_ })
Assert-WorkspaceValue -Name 'setid helper allowlist' `
    -Condition ($unexpectedSetidPaths.Count -eq 0 -and $missingSetidPaths.Count -eq 0) `
    -Evidence ($setidPaths -join ',')

$helperModes = (Invoke-WorkspaceKubectl -Arguments @(
    'exec', '--namespace', $Namespace, $podName, '--', 'sh', '-lc',
    "stat -c '%a %u:%g %n' /usr/bin/newgidmap /usr/bin/newuidmap"
)).Output
Assert-WorkspaceValue -Name 'uidmap helper ownership and modes' `
    -Condition ($helperModes -match '(?m)^4755 0:0 /usr/bin/newgidmap\s*$' -and
        $helperModes -match '(?m)^4755 0:0 /usr/bin/newuidmap\s*$') `
    -Evidence ($helperModes -replace "`r?`n", '; ')

$rootless = (Invoke-WorkspaceKubectl -Arguments @(
    'exec', '--namespace', $Namespace, $podName, '--',
    'podman', 'info', '--format', '{{.Host.Security.Rootless}}'
)).Output.Trim()
Assert-WorkspaceValue -Name 'Podman rootless' -Condition ($rootless -eq 'true') -Evidence "rootless=$rootless"

$driver = (Invoke-WorkspaceKubectl -Arguments @(
    'exec', '--namespace', $Namespace, $podName, '--',
    'podman', 'info', '--format', '{{.Store.GraphDriverName}}'
)).Output.Trim()
Assert-WorkspaceValue -Name 'Podman storage' -Condition ($driver -eq 'overlay') -Evidence "driver=$driver"

$storageDetails = (Invoke-WorkspaceKubectl -Arguments @(
    'exec', '--namespace', $Namespace, $podName, '--',
    'podman', 'info', '--format', '{{.Store.GraphRoot}}|{{.Store.RunRoot}}|{{json .Store.GraphOptions}}'
)).Output.Trim()
Assert-WorkspaceValue -Name 'Podman native tmpfs storage paths' `
    -Condition ($storageDetails -match '^/tmp/podman-storage\|/tmp/run-user-1000/containers\|' -and
        $storageDetails -notmatch 'mount_program') `
    -Evidence $storageDetails

$uidMap = (Invoke-WorkspaceKubectl -Arguments @(
    'exec', '--namespace', $Namespace, $podName, '--',
    'podman', 'unshare', 'cat', '/proc/self/uid_map'
)).Output
$gidMap = (Invoke-WorkspaceKubectl -Arguments @(
    'exec', '--namespace', $Namespace, $podName, '--',
    'podman', 'unshare', 'cat', '/proc/self/gid_map'
)).Output
$normalizeMap = {
    param([string]$Value)
    return (@($Value -split "`r?`n" | Where-Object { $_ -match '\S' } | ForEach-Object {
        ($_ -replace '\s+', ' ').Trim()
    }) -join ';')
}
$normalizedUidMap = & $normalizeMap $uidMap
$normalizedGidMap = & $normalizeMap $gidMap
$expectedMap = '0 1000 1;1 100000 65536'
Assert-WorkspaceValue -Name 'rootless subordinate UID/GID maps' `
    -Condition ($normalizedUidMap -eq $expectedMap -and $normalizedGidMap -eq $expectedMap) `
    -Evidence "uid=$normalizedUidMap; gid=$normalizedGidMap"

[void](Invoke-WorkspaceKubectl -Arguments @(
    'exec', '--namespace', $Namespace, $podName, '--',
    'curl', '--fail', '--silent', 'http://127.0.0.1:8080/healthz'
))
Write-Host '[ok] code-server health endpoint'

if (-not $SkipInnerContainerRun) {
    $innerRun = Invoke-WorkspaceKubectl -Arguments @(
        'exec', '--namespace', $Namespace, $podName, '--',
        'podman', 'run', '--rm', '--pull=always',
        $versions.InnerTestImage, 'sh', '-lc', 'id -u; cat /proc/self/uid_map; readlink /proc/self/ns/pid'
    ) -AllowFailure
    $podPidNamespace = (Invoke-WorkspaceKubectl -Arguments @(
        'exec', '--namespace', $Namespace, $podName, '--',
        'readlink', '/proc/1/ns/pid'
    )).Output.Trim()
    $multiUidRun = Invoke-WorkspaceKubectl -Arguments @(
        'exec', '--namespace', $Namespace, $podName, '--',
        'podman', 'run', '--rm', '--pull=never', '--user', '2000:2000',
        $versions.InnerTestImage, 'id', '-u'
    ) -AllowFailure
    $multiUidBuildScript = @"
set -eu
export TMPDIR=/tmp
proof_dir=/tmp/podman-user2000-proof
proof_image=localhost/podman-user2000-proof:latest
cleanup() {
  podman image rm -f "`$proof_image" >/dev/null 2>&1 || true
  rm -rf "`$proof_dir"
}
trap cleanup EXIT
mkdir -p "`$proof_dir"
printf '%s\n' 'FROM $($versions.InnerTestImage)' 'USER 2000:2000' 'RUN id -u | grep -qx 2000' 'CMD ["id", "-u"]' > "`$proof_dir/Containerfile"
podman build --pull=never --no-cache --tag "`$proof_image" "`$proof_dir"
result="`$(podman run --rm --pull=never "`$proof_image")"
test "`$result" = 2000
printf '%s\n' "`$result"
"@
    $multiUidBuild = Invoke-WorkspaceKubectl -Arguments @(
        'exec', '--namespace', $Namespace, $podName, '--',
        'sh', '-lc', $multiUidBuildScript
    ) -AllowFailure
    $innerOkay = $innerRun.ExitCode -eq 0 -and
        $innerRun.Output -match '(?m)^0\s*$' -and
        $innerRun.Output -match '(?m)^\s*0\s+1000\s+1\s*$' -and
        $innerRun.Output -match "(?m)^$([regex]::Escape($podPidNamespace))\s*$" -and
        $multiUidRun.ExitCode -eq 0 -and
        $multiUidRun.Output -match '(?m)^2000\s*$' -and
        $multiUidBuild.ExitCode -eq 0 -and
        $multiUidBuild.Output -match '(?m)^2000\s*$'
    Assert-WorkspaceValue -Name 'nested rootless container run and build' `
        -Condition $innerOkay `
        -Evidence "uid2000=$($multiUidRun.Output.Trim()); build-user2000=$($multiUidBuild.ExitCode -eq 0)"
}

Write-Host ''
Write-Host 'Single-container code-server + rootless Podman is ready.' -ForegroundColor Green
Write-Host "Pod: $Namespace/$podName"
$nodeIP = (Invoke-WorkspaceKubectl -Arguments @(
    'get', 'node', ([string]$pod.spec.nodeName),
    '-o', 'jsonpath={.status.addresses[?(@.type=="InternalIP")].address}'
)).Output.Trim()
Write-Host "URL: http://${nodeIP}:30443"
Write-Host 'The password remains in Secret code-server-auth.'
