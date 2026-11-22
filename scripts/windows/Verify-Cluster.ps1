[CmdletBinding()]
param(
    [string]$ClusterName,
    [string]$Namespace = 'code-server',
    [string]$ExpectedRuntimeClass,
    [switch]$SkipInnerContainerRun
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'lib\Common.ps1')

$versions = Import-LabVersions
if ([string]::IsNullOrWhiteSpace($ClusterName)) { $ClusterName = $versions.ClusterName }
$podman = Resolve-LabTool -Name 'podman'
$kubectl = Resolve-LabTool -Name 'kubectl'
foreach ($path in @($podman, $kubectl)) {
    if ([string]::IsNullOrWhiteSpace($path)) { throw 'podman and kubectl are required for verification.' }
    Add-LabToolToPath -ToolPath $path
}
$env:KIND_EXPERIMENTAL_PROVIDER = 'podman'

$checks = New-Object System.Collections.Generic.List[object]
$failures = New-Object System.Collections.Generic.List[string]
function Add-EvidenceCheck {
    param([string]$Name, [bool]$Passed, [string]$Evidence)
    $script:checks.Add([pscustomobject]@{ Check = $Name; Passed = $Passed; Evidence = $Evidence })
    if (-not $Passed) { $script:failures.Add("$Name`: $Evidence") }
}

$context = Invoke-LabCommand -FilePath $kubectl -Arguments @('config', 'current-context') -Capture
Add-EvidenceCheck 'kind context' ($context.Output.Trim() -eq "kind-$ClusterName") $context.Output.Trim()

$outerRootless = Invoke-LabCommand -FilePath $podman -Arguments @('info', '--format', '{{.Host.Security.Rootless}}') -Capture
Add-EvidenceCheck 'outer engine is rootful infrastructure' ($outerRootless.Output.Trim() -eq 'false') "rootless=$($outerRootless.Output.Trim())"

$podName = Get-LabPodName -Kubectl $kubectl -Namespace $Namespace
$podResult = Invoke-LabCommand -FilePath $kubectl -Arguments @('get', 'pod', $podName, '-n', $Namespace, '-o', 'json') -Capture
$pod = $podResult.Output | ConvertFrom-Json
if ([string]::IsNullOrWhiteSpace($ExpectedRuntimeClass)) { $ExpectedRuntimeClass = [string]$pod.spec.runtimeClassName }

$runtimeClassResult = Invoke-LabCommand -FilePath $kubectl -Arguments @('get', 'runtimeclass', $ExpectedRuntimeClass, '-o', 'name') -Capture -AllowFailure
Add-EvidenceCheck 'RuntimeClass exists' ($runtimeClassResult.ExitCode -eq 0) $ExpectedRuntimeClass
Add-EvidenceCheck 'pod requests Kata' ([string]$pod.spec.runtimeClassName -eq $ExpectedRuntimeClass) "runtimeClassName=$($pod.spec.runtimeClassName)"

$phase = [string]$pod.status.phase
$ready = @($pod.status.conditions | Where-Object { $_.type -eq 'Ready' -and $_.status -eq 'True' }).Count -gt 0
Add-EvidenceCheck 'pod is Ready' ($phase -eq 'Running' -and $ready) "phase=$phase ready=$ready"

$nodeName = "$ClusterName-control-plane"
$nodeKernel = Invoke-LabCommand -FilePath $podman -Arguments @('exec', $nodeName, 'uname', '-r') -Capture
$guestKernel = Invoke-LabCommand -FilePath $kubectl -Arguments @('exec', '-n', $Namespace, $podName, '-c', 'code-server', '--', 'uname', '-r') -Capture
Add-EvidenceCheck 'Kata guest kernel differs from node' ($guestKernel.Output.Trim() -ne $nodeKernel.Output.Trim()) "node=$($nodeKernel.Output.Trim()); guest=$($guestKernel.Output.Trim())"

$uid = Invoke-LabCommand -FilePath $kubectl -Arguments @('exec', '-n', $Namespace, $podName, '-c', 'code-server', '--', 'id', '-u') -Capture
Add-EvidenceCheck 'code-server is non-root' ($uid.Output.Trim() -eq '1000') "uid=$($uid.Output.Trim())"

$capStatus = Invoke-LabCommand -FilePath $kubectl -Arguments @('exec', '-n', $Namespace, $podName, '-c', 'code-server', '--', 'sh', '-lc', "grep -E '^(CapInh|CapPrm|CapEff|CapBnd|CapAmb|NoNewPrivs|Seccomp):' /proc/1/status") -Capture
$capsOkay = @('CapInh', 'CapPrm', 'CapEff', 'CapAmb').Where({
    $capStatus.Output -notmatch "(?m)^$([regex]::Escape($_)):\s+0000000000000000\s*$"
}).Count -eq 0 -and
    $capStatus.Output -match '(?m)^CapBnd:\s+00000000000000c0\s*$' -and
    $capStatus.Output -match '(?m)^NoNewPrivs:\s+0\s*$'
Add-EvidenceCheck 'code-server capability state' $capsOkay ($capStatus.Output -replace "`r?`n", '; ')

$sudo = Invoke-LabCommand -FilePath $kubectl -Arguments @('exec', '-n', $Namespace, $podName, '-c', 'code-server', '--', 'sh', '-lc', 'command -v sudo') -Capture -AllowFailure
Add-EvidenceCheck 'sudo is absent' ($sudo.ExitCode -ne 0) $(if ($sudo.ExitCode -ne 0) { 'not installed' } else { $sudo.Output.Trim() })

$automountSet = $pod.spec.PSObject.Properties.Name -contains 'automountServiceAccountToken'
$automountDisabled = $automountSet -and $pod.spec.automountServiceAccountToken -eq $false
Add-EvidenceCheck 'service-account token disabled' $automountDisabled "automountServiceAccountToken=$($pod.spec.automountServiceAccountToken)"

$hostFlags = @()
foreach ($field in @('hostNetwork', 'hostPID', 'hostIPC')) {
    $value = $false
    if ($pod.spec.PSObject.Properties.Name -contains $field) { $value = [bool]$pod.spec.$field }
    if ($value) { $hostFlags += $field }
}
Add-EvidenceCheck 'no host namespaces' ($hostFlags.Count -eq 0) $(if ($hostFlags.Count -eq 0) { 'none' } else { $hostFlags -join ',' })

$hostPaths = @()
foreach ($volume in @($pod.spec.volumes)) {
    if ($volume.PSObject.Properties.Name -contains 'hostPath') { $hostPaths += $volume.name }
}
Add-EvidenceCheck 'no hostPath volumes' ($hostPaths.Count -eq 0) $(if ($hostPaths.Count -eq 0) { 'none' } else { $hostPaths -join ',' })

$codeContainer = @($pod.spec.containers | Where-Object { $_.name -eq 'code-server' })[0]
$singleContainer = @($pod.spec.containers).Count -eq 1 -and $null -ne $codeContainer
Add-EvidenceCheck 'single code-server container' $singleContainer "containers=$(@($pod.spec.containers).Count)"
$codeStrict = $codeContainer.securityContext.runAsNonRoot -eq $true -and
    [int]$codeContainer.securityContext.runAsUser -eq 1000 -and
    $codeContainer.securityContext.privileged -eq $false -and
    $codeContainer.securityContext.allowPrivilegeEscalation -eq $true -and
    (@($codeContainer.securityContext.capabilities.drop) -join ',') -eq 'ALL' -and
    (@($codeContainer.securityContext.capabilities.add | Sort-Object) -join ',') -eq 'SETGID,SETUID' -and
    [string]$codeContainer.securityContext.seccompProfile.type -eq 'Unconfined'
Add-EvidenceCheck 'nested Podman security context' $codeStrict 'UID 1000; non-privileged; CapBnd SETGID|SETUID; seccomp Unconfined'
Add-EvidenceCheck 'strict supplemental groups' ([string]$pod.spec.securityContext.supplementalGroupsPolicy -eq 'Strict') "supplementalGroupsPolicy=$($pod.spec.securityContext.supplementalGroupsPolicy)"

$groups = Invoke-LabCommand -FilePath $kubectl -Arguments @('exec', '-n', $Namespace, $podName, '-c', 'code-server', '--', 'id', '-G') -Capture
Add-EvidenceCheck 'no image supplemental groups' ($groups.Output.Trim() -eq '1000') "groups=$($groups.Output.Trim())"

$setid = Invoke-LabCommand -FilePath $kubectl -Arguments @('exec', '-n', $Namespace, $podName, '-c', 'code-server', '--', 'sh', '-lc', "find /usr -xdev -type f -perm /6000 -printf '%p\n' | sort") -Capture
$expectedSetid = "/usr/bin/newgidmap`n/usr/bin/newuidmap"
Add-EvidenceCheck 'setid helper allowlist' (($setid.Output.Trim() -replace "`r", '') -eq $expectedSetid) ($setid.Output -replace "`r?`n", '; ')

$innerRootless = Invoke-LabCommand -FilePath $kubectl -Arguments @('exec', '-n', $Namespace, $podName, '-c', 'code-server', '--', 'podman', 'info', '--format', '{{.Host.Security.Rootless}}') -Capture
Add-EvidenceCheck 'inner Podman is rootless' ($innerRootless.Output.Trim() -eq 'true') "rootless=$($innerRootless.Output.Trim())"

$graphDriver = Invoke-LabCommand -FilePath $kubectl -Arguments @('exec', '-n', $Namespace, $podName, '-c', 'code-server', '--', 'podman', 'info', '--format', '{{.Store.GraphDriverName}}') -Capture
Add-EvidenceCheck 'inner storage is native overlay' ($graphDriver.Output.Trim() -eq 'overlay') "driver=$($graphDriver.Output.Trim())"

$uidMap = Invoke-LabCommand -FilePath $kubectl -Arguments @('exec', '-n', $Namespace, $podName, '-c', 'code-server', '--', 'podman', 'unshare', 'cat', '/proc/self/uid_map') -Capture
$hasNonIdentityMap = $uidMap.Output -match '(?m)^\s*0\s+(?!0\s)\d+\s+'
Add-EvidenceCheck 'rootless UID mapping is non-identity' $hasNonIdentityMap ($uidMap.Output -replace "`r?`n", '; ')

$criPodId = Invoke-LabCommand -FilePath $podman -Arguments @('exec', $nodeName, 'crictl', 'pods', '--name', $podName, '-q') -Capture -AllowFailure
if ($criPodId.ExitCode -eq 0 -and -not [string]::IsNullOrWhiteSpace($criPodId.Output)) {
    $inspect = Invoke-LabCommand -FilePath $podman -Arguments @('exec', $nodeName, 'crictl', 'inspectp', $criPodId.Output.Trim()) -Capture
    $handlerMatch = [regex]::Match($inspect.Output, '"runtimeHandler"\s*:\s*"([^"]+)"')
    $handler = if ($handlerMatch.Success) { $handlerMatch.Groups[1].Value } else { '' }
    Add-EvidenceCheck 'CRI selected the Kata handler' ($handler -eq $ExpectedRuntimeClass) "runtimeHandler=$handler"
}
else {
    Add-EvidenceCheck 'CRI selected the Kata handler' $false 'could not locate the pod sandbox with crictl'
}

$hypervisor = Invoke-LabCommand -FilePath $podman -Arguments @('exec', $nodeName, 'sh', '-lc', "pgrep -af 'qemu-system|cloud-hypervisor' | head -1") -Capture -AllowFailure
Add-EvidenceCheck 'Kata hypervisor process exists' ($hypervisor.ExitCode -eq 0 -and -not [string]::IsNullOrWhiteSpace($hypervisor.Output)) $hypervisor.Output.Trim()

if (-not $SkipInnerContainerRun) {
    $innerRun = Invoke-LabCommand -FilePath $kubectl -Arguments @(
        'exec', '-n', $Namespace, $podName, '-c', 'code-server', '--',
        'podman', 'run', '--rm', '--pull=always',
        $versions.InnerTestImage, 'sh', '-lc', 'id -u; cat /proc/self/uid_map'
    ) -Capture -AllowFailure
    $innerOkay = $innerRun.ExitCode -eq 0 -and
        $innerRun.Output -match '(?m)^0\s*$' -and
        $innerRun.Output -match '(?m)^\s*0\s+1000\s+1\s*$'
    Add-EvidenceCheck 'inner rootless container executes' $innerOkay ($innerRun.Output -replace "`r?`n", '; ')

    $multiUidRun = Invoke-LabCommand -FilePath $kubectl -Arguments @(
        'exec', '-n', $Namespace, $podName, '-c', 'code-server', '--',
        'podman', 'run', '--rm', '--pull=never', '--user', '2000:2000',
        $versions.InnerTestImage, 'id', '-u'
    ) -Capture -AllowFailure
    Add-EvidenceCheck 'inner subordinate UID executes' `
        ($multiUidRun.ExitCode -eq 0 -and $multiUidRun.Output.Trim() -eq '2000') `
        $multiUidRun.Output.Trim()
}

$checks | Format-Table -AutoSize -Wrap
if ($failures.Count -gt 0) {
    throw "Verification failed:`n - $($failures -join "`n - ")"
}
Write-Host 'All Kata and rootless Podman proof gates passed.' -ForegroundColor Green
