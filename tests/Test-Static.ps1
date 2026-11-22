[CmdletBinding()]
param(
    [switch]$RenderHelmChart
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$root = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
. (Join-Path $root 'scripts\windows\lib\Common.ps1')
$versions = Import-LabVersions

function Assert-True {
    param(
        [Parameter(Mandatory = $true)][bool]$Condition,
        [string]$Message = 'assertion returned false'
    )
    if (-not $Condition) { throw "Static validation failed: $Message" }
}

function Assert-Match {
    param(
        [Parameter(Mandatory = $true)][string]$Text,
        [Parameter(Mandatory = $true)][string]$Pattern,
        [Parameter(Mandatory = $true)][string]$Message
    )
    Assert-True -Condition ([regex]::IsMatch($Text, $Pattern, [Text.RegularExpressions.RegexOptions]::Multiline)) -Message $Message
}

$requiredFiles = @(
    '.github\workflows\validate.yml',
    '.github\workflows\release-image.yml',
    '.github\dependabot.yml',
    'CHANGELOG.md',
    'CONTRIBUTING.md',
    'SECURITY.md',
    'container\Dockerfile',
    'container\start-code-server.sh',
    'container\storage-overlay.conf',
    'Makefile',
    'kind\cluster.yaml',
    'kata\values-kvm.yaml',
    'kata\values-mshv.yaml',
    'k8s\base\deployment.yaml',
    'k8s\base\persistence.yaml',
    'k8s\base\admission-policy.yaml',
    'k8s\overlays\kvm\kustomization.yaml',
    'k8s\overlays\mshv\kustomization.yaml',
    'scripts\windows\Install-Cluster.ps1',
    'scripts\windows\Verify-Cluster.ps1',
    'scripts\windows\Benchmark.ps1',
    'scripts\wsl\lib\common.sh',
    'scripts\wsl\check-version-pins.sh',
    'scripts\wsl\doctor.sh',
    'scripts\wsl\check-repository.sh',
    'scripts\wsl\install-tools.sh',
    'scripts\wsl\provision-cluster.sh',
    'scripts\wsl\deploy-workspace.sh',
    'scripts\wsl\verify-workspace.sh',
    'scripts\wsl\benchmark-podman.sh',
    'scripts\wsl\status.sh',
    'scripts\wsl\shell.sh',
    'tests\test-static.sh',
    'docs\wsl.md',
    'docs\shadow-uidmap.md',
    'docs\benchmark-podman-20261121.md',
    'docs\storage-performance.md',
    'docs\production.md',
    'docs\upgrading.md',
    'k8s\overlays\production\kustomization.yaml',
    'k8s\overlays\production\ingress.yaml',
    'k8s\overlays\production\network-policy.yaml',
    'k8s\overlays\production\README.md'
)
foreach ($relativePath in $requiredFiles) {
    Assert-True -Condition (Test-Path -LiteralPath (Join-Path $root $relativePath) -PathType Leaf) -Message "missing $relativePath"
}

$parseFailures = New-Object System.Collections.Generic.List[string]
Get-ChildItem -LiteralPath (Join-Path $root 'scripts') -Filter '*.ps1' -File -Recurse | ForEach-Object {
    $tokens = $null
    $errors = $null
    [void][Management.Automation.Language.Parser]::ParseFile($_.FullName, [ref]$tokens, [ref]$errors)
    foreach ($parseError in $errors) {
        $parseFailures.Add("$($_.FullName):$($parseError.Extent.StartLineNumber): $($parseError.Message)")
    }
}
Assert-True -Condition ($parseFailures.Count -eq 0) -Message ("PowerShell parse errors: " + ($parseFailures -join "`n"))

$dockerfile = Get-Content -LiteralPath (Join-Path $root 'container\Dockerfile') -Raw
Assert-Match -Text ([string]$versions.KataSmokeImage) -Pattern '^docker\.io/library/busybox:[^@]+@sha256:[0-9a-f]{64}$' -Message 'Kata smoke image is not digest-pinned'
Assert-Match -Text ([string]$versions.PodStartupImage) -Pattern '^registry\.k8s\.io/e2e-test-images/agnhost:[^@]+@sha256:[0-9a-f]{64}$' -Message 'Pod startup image is not digest-pinned'
$makefile = Get-Content -LiteralPath (Join-Path $root 'Makefile') -Raw
Assert-Match -Text $makefile -Pattern '(?m)^versions-check:\s*$' -Message 'Makefile does not expose versions-check'
Assert-Match -Text $makefile -Pattern '(?m)^check:\s+versions-check\s*$' -Message 'make check does not enforce version pin validation'
$guestInstaller = Get-Content -LiteralPath (Join-Path $root 'scripts\linux\Install-K3sKata.sh') -Raw
Assert-Match -Text $guestInstaller -Pattern '\$\{KATA_SMOKE_IMAGE\}' -Message 'Kata smoke test does not use the centralized image'
Assert-Match -Text $guestInstaller -Pattern 'KATA_SMOKE_IMAGE must be pinned by a sha256 digest\.' -Message 'Kata installer does not reject an unpinned smoke image'
$wslProvisioner = Get-Content -LiteralPath (Join-Path $root 'scripts\wsl\provision-cluster.sh') -Raw
Assert-Match -Text $wslProvisioner -Pattern 'version_value\s+KataSmokeImage' -Message 'WSL provisioner does not load KataSmokeImage'
$windowsProvisioner = Get-Content -LiteralPath (Join-Path $root 'scripts\windows\New-HyperVKataCluster.ps1') -Raw
Assert-Match -Text $windowsProvisioner -Pattern '\$pinnedVersions\.KataSmokeImage' -Message 'Windows provisioner does not load KataSmokeImage'
$windowsBenchmark = Get-Content -LiteralPath (Join-Path $root 'scripts\windows\Benchmark.ps1') -Raw
Assert-Match -Text $windowsBenchmark -Pattern '\$versions\.InnerTestImage' -Message 'PowerShell benchmark does not use InnerTestImage'
Assert-Match -Text $windowsBenchmark -Pattern '\$versions\.PodStartupImage' -Message 'PowerShell benchmark does not use PodStartupImage'
Assert-True -Condition ($windowsBenchmark -notmatch 'docker\.io/library/alpine:3\.23(?!@sha256:)') -Message 'PowerShell benchmark contains an unpinned Alpine image'
Assert-True -Condition ($windowsBenchmark -notmatch "registry\.k8s\.io/e2e-test-images/agnhost:2\.57'") -Message 'PowerShell benchmark contains an unpinned agnhost image'
Assert-Match -Text $dockerfile -Pattern ([regex]::Escape($versions.BaseImage)) -Message 'Ubuntu base image is not digest-pinned to versions.psd1'
Assert-Match -Text $dockerfile -Pattern ([regex]::Escape($versions.CodeServerVersion)) -Message 'code-server version is not pinned'
Assert-Match -Text $dockerfile -Pattern ([regex]::Escape($versions.CodeServerAmd64Sha256)) -Message 'code-server amd64 checksum is not verified'
Assert-Match -Text $dockerfile -Pattern ([regex]::Escape($versions.ShadowVersion)) -Message 'shadow uidmap helper source version is not pinned'
Assert-Match -Text $dockerfile -Pattern ([regex]::Escape($versions.ShadowSha256)) -Message 'shadow uidmap helper source checksum is not verified'
Assert-True -Condition ($dockerfile -notmatch '(?i)NOPASSWD') -Message 'the workspace image must not configure passwordless sudo'
Assert-Match -Text $dockerfile -Pattern 'chmod\s+a-s' -Message 'unexpected setuid/setgid binaries are not stripped'
Assert-Match -Text $dockerfile -Pattern 'HAVE_SYS_CAPABILITY_H\s+1' -Message 'custom uidmap helpers are not built with capability support'
Assert-Match -Text $dockerfile -Pattern 'COPY\s+--from=uidmap-builder\s+--chmod=4755\s+/out/newuidmap' -Message 'custom newuidmap helper is not installed setuid'
Assert-Match -Text $dockerfile -Pattern 'COPY\s+--from=uidmap-builder\s+--chmod=4755\s+/out/newgidmap' -Message 'custom newgidmap helper is not installed setuid'
Assert-Match -Text $dockerfile -Pattern 'test\s+"\$\(find /usr -xdev -type f -perm /6000 \| wc -l\)"\s+-eq\s+2' -Message 'the image does not assert the exact setid helper count'

$containersConfig = Get-Content -LiteralPath (Join-Path $root 'container\containers.conf') -Raw
Assert-Match -Text $containersConfig -Pattern '(?m)^cgroups\s*=\s*"enabled"\s*$' -Message 'inner Podman cgroups must be enabled'
Assert-Match -Text $containersConfig -Pattern '(?m)^netns\s*=\s*"host"\s*$' -Message 'inner Podman must use the Kata pod network namespace'
Assert-Match -Text $containersConfig -Pattern '(?m)^pidns\s*=\s*"host"\s*$' -Message 'inner Podman must use the Kata pod PID namespace'
Assert-True -Condition ($containersConfig -notmatch '(?m)^cgroups\s*=\s*"disabled"\s*$') -Message 'inner Podman may not disable cgroups with pidns=host'

$kindConfig = Get-Content -LiteralPath (Join-Path $root 'kind\cluster.yaml') -Raw
Assert-Match -Text $kindConfig -Pattern ([regex]::Escape($versions.KindNodeImage)) -Message 'kind node image is not pinned by digest'
Assert-True -Condition ($kindConfig -notmatch '(?m)^\s*hostPath\s*:') -Message 'kind config must not pretend a /dev/kvm volume is sufficient proof'

$kubectl = Resolve-LabTool -Name 'kubectl'
Assert-True -Condition (-not [string]::IsNullOrWhiteSpace($kubectl)) -Message 'kubectl is required to render kustomize overlays'

$expectedRuntimeClasses = @{
    kvm = 'kata-qemu-runtime-rs'
    mshv = 'kata-clh-azure-runtime-rs'
}
foreach ($profile in $expectedRuntimeClasses.Keys) {
    $overlay = Join-Path $root "k8s\overlays\$profile"
    $rendered = Invoke-LabCommand -FilePath $kubectl -Arguments @('kustomize', $overlay) -Capture
    $yaml = $rendered.Output
    Assert-Match -Text $yaml -Pattern "runtimeClassName:\s*$([regex]::Escape($expectedRuntimeClasses[$profile]))" -Message "$profile overlay does not select its expected Kata RuntimeClass"
    Assert-Match -Text $yaml -Pattern ([regex]::Escape($versions.WorkspaceImage)) -Message "$profile overlay does not use the pinned workspace image"
    Assert-True -Condition ($yaml -notmatch '(?m)^\s*hostPath\s*:') -Message "$profile overlay contains a hostPath"
    Assert-True -Condition ($yaml -notmatch '(?m)^\s*(hostPID|hostIPC|hostNetwork)\s*:\s*true\s*$') -Message "$profile overlay shares a host namespace"
    Assert-Match -Text $yaml -Pattern '(?m)^\s*automountServiceAccountToken:\s*false\s*$' -Message "$profile overlay mounts a service-account token"
    Assert-Match -Text $yaml -Pattern '(?m)^\s*runAsUser:\s*1000\s*$' -Message "$profile overlay does not explicitly use UID 1000"
    $containerCount = ([regex]::Matches($yaml, '(?m)^\s{8}name:\s*code-server\s*$')).Count
    Assert-True -Condition ($containerCount -eq 1) -Message "$profile overlay must contain exactly one code-server container"
    Assert-True -Condition ($yaml -notmatch '(?m)^\s*privileged:\s*true\s*$') -Message "$profile overlay must not contain a privileged container"
    Assert-Match -Text $yaml -Pattern '(?m)^\s*privileged:\s*false\s*$' -Message "$profile overlay must explicitly disable privileged mode"
    Assert-Match -Text $yaml -Pattern '(?m)^\s*supplementalGroupsPolicy:\s*Strict\s*$' -Message "$profile overlay must reject image-defined supplemental groups"
    Assert-Match -Text $yaml -Pattern '(?ms)^\s*capabilities:\s*\n\s*add:\s*\n\s*- SETGID\s*\n\s*- SETUID\s*\n\s*drop:\s*\n\s*- ALL\s*$' -Message "$profile overlay must use only SETGID and SETUID"
    Assert-Match -Text $yaml -Pattern '(?m)^\s*allowPrivilegeEscalation:\s*true\s*$' -Message "$profile overlay must allow the capability-aware setuid uidmap helpers"
    Assert-Match -Text $yaml -Pattern '(?m)^\s*type:\s*Unconfined\s*$' -Message "$profile overlay must permit nested rootless user namespaces"
    Assert-Match -Text $yaml -Pattern '(?m)^\s*claimName:\s*code-server-home\s*$' -Message "$profile overlay does not mount the persistent home PVC"
    foreach ($cachePath in @('/tmp/cache', '/tmp/cache/npm', '/tmp/cache/pip', '/tmp/cache/go-build')) {
        Assert-Match -Text $yaml -Pattern ("(?m)^\s*value:\s*" + [regex]::Escape($cachePath) + '\s*$') -Message "$profile overlay does not route cache to $cachePath"
    }
    Assert-Match -Text $yaml -Pattern '(?m)^\s*-\s+name:\s*TMPDIR\s*\r?\n\s*value:\s*/tmp\s*$' -Message "$profile overlay does not set TMPDIR=/tmp"
    Assert-Match -Text $yaml -Pattern '(?m)^\s*nodePort:\s*30443\s*$' -Message "$profile overlay does not expose the expected local NodePort"
}

$productionOverlay = Join-Path $root 'k8s\overlays\production'
$productionYaml = (Invoke-LabCommand -FilePath $kubectl -Arguments @('kustomize', $productionOverlay) -Capture).Output
Assert-Match -Text $productionYaml -Pattern '(?m)^\s*type:\s*ClusterIP\s*$' -Message 'production Service is not internal'
Assert-True -Condition ($productionYaml -notmatch '(?m)^\s*nodePort:') -Message 'production overlay exposes a NodePort'
Assert-Match -Text $productionYaml -Pattern 'registry\.example\.invalid/code-server-podman@sha256:0{64}' -Message 'production overlay does not fail closed with its reserved image placeholder'
Assert-Match -Text $productionYaml -Pattern '(?m)^kind:\s*Ingress\s*$' -Message 'production overlay has no TLS ingress'
Assert-Match -Text $productionYaml -Pattern '(?m)^kind:\s*NetworkPolicy\s*$' -Message 'production overlay has no ingress policy'

$policy = Get-Content -LiteralPath (Join-Path $root 'k8s\base\admission-policy.yaml') -Raw
foreach ($requiredTerm in @('runtimeClassName', 'hostPath', 'hostPID', 'hostIPC', 'hostNetwork', 'exactly one code-server container', 'privileged', 'capabilities', 'supplementalGroupsPolicy', 'SETGID', 'SETUID')) {
    Assert-Match -Text $policy -Pattern ([regex]::Escape($requiredTerm)) -Message "admission policy does not constrain $requiredTerm"
}

foreach ($pair in @(
    @{ File = 'kata\values-kvm.yaml'; Shim = 'qemu-runtime-rs' },
    @{ File = 'kata\values-mshv.yaml'; Shim = 'clh-azure-runtime-rs' }
)) {
    $values = Get-Content -LiteralPath (Join-Path $root $pair.File) -Raw
    Assert-Match -Text $values -Pattern '(?m)^\s*disableAll:\s*true\s*$' -Message "$($pair.File) does not disable unused Kata shims"
    Assert-Match -Text $values -Pattern ("(?m)^\s*" + [regex]::Escape($pair.Shim) + ':\s*$') -Message "$($pair.File) does not enable $($pair.Shim)"
}

if ($RenderHelmChart) {
    $helm = Resolve-LabTool -Name 'helm'
    Assert-True -Condition (-not [string]::IsNullOrWhiteSpace($helm)) -Message 'Helm is required for -RenderHelmChart'
    foreach ($profile in $expectedRuntimeClasses.Keys) {
        $valuesPath = Join-Path $root "kata\values-$profile.yaml"
        [void](Invoke-LabCommand -FilePath $helm -Arguments @(
            'template', 'kata-deploy', $versions.KataChart, '--version', $versions.KataVersion,
            '--namespace', 'kata-system', '--values', $valuesPath
        ) -Capture)
    }
}

Write-Host 'Static validation passed.' -ForegroundColor Green
