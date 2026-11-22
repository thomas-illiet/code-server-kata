[CmdletBinding()]
param(
    [ValidateRange(3, 200)][int]$Iterations = 10,
    [string]$ClusterName,
    [string]$WorkspaceNamespace = 'code-server',
    [string]$BenchmarkNamespace = 'kata-benchmark',
    [string]$OutputDirectory
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'lib\Common.ps1')

$root = Get-LabRepositoryRoot
$versions = Import-LabVersions
if ([string]::IsNullOrWhiteSpace($ClusterName)) { $ClusterName = $versions.ClusterName }
if ([string]::IsNullOrWhiteSpace($OutputDirectory)) { $OutputDirectory = Join-Path $root 'benchmark-results' }
$kubectl = Resolve-LabTool -Name 'kubectl'
if ([string]::IsNullOrWhiteSpace($kubectl)) { throw 'kubectl was not found.' }
Add-LabToolToPath -ToolPath $kubectl

$context = Invoke-LabCommand -FilePath $kubectl -Arguments @('config', 'current-context') -Capture
if ($context.Output.Trim() -ne "kind-$ClusterName") {
    throw "Current context is '$($context.Output.Trim())', expected 'kind-$ClusterName'. Refusing to benchmark the wrong cluster."
}

$namespaceYaml = Invoke-LabCommand -FilePath $kubectl -Arguments @('create', 'namespace', $BenchmarkNamespace, '--dry-run=client', '-o', 'yaml') -Capture
$namespaceYaml.Output | & $kubectl apply -f -
if ($LASTEXITCODE -ne 0) { throw "Failed to create namespace '$BenchmarkNamespace'." }
Invoke-LabCommand -FilePath $kubectl -Arguments @(
    'label', 'namespace', $BenchmarkNamespace, '--overwrite',
    'pod-security.kubernetes.io/enforce=baseline', 'pod-security.kubernetes.io/warn=baseline'
) | Out-Null

$deploymentRuntime = Invoke-LabCommand -FilePath $kubectl -Arguments @(
    'get', 'deployment/code-server-podman', '-n', $WorkspaceNamespace,
    '-o', 'jsonpath={.spec.template.spec.runtimeClassName}'
) -Capture
$kataRuntimeClass = $deploymentRuntime.Output.Trim()
if ([string]::IsNullOrWhiteSpace($kataRuntimeClass)) { throw 'The workspace Deployment has no RuntimeClass.' }

function Measure-LabPodStart {
    param([string]$Profile, [string]$RuntimeClass, [int]$Iteration)
    $name = "startup-$Profile-$([Guid]::NewGuid().ToString('N').Substring(0, 8))"
    $spec = [ordered]@{
        automountServiceAccountToken = $false
        restartPolicy = 'Never'
        terminationGracePeriodSeconds = 0
        containers = @([ordered]@{
            name = 'pause'
            image = $versions.PodStartupImage
            imagePullPolicy = 'IfNotPresent'
            args = @('pause')
            resources = @{ requests = @{ cpu = '10m'; memory = '16Mi' }; limits = @{ cpu = '500m'; memory = '128Mi' } }
            securityContext = @{ runAsNonRoot = $true; runAsUser = 1000; allowPrivilegeEscalation = $false; capabilities = @{ drop = @('ALL') } }
        })
    }
    if (-not [string]::IsNullOrWhiteSpace($RuntimeClass)) { $spec.runtimeClassName = $RuntimeClass }
    $manifest = [ordered]@{
        apiVersion = 'v1'
        kind = 'Pod'
        metadata = @{ name = $name; namespace = $BenchmarkNamespace; labels = @{ 'benchmark.openai.dev/profile' = $Profile } }
        spec = $spec
    }
    $json = $manifest | ConvertTo-Json -Depth 12 -Compress
    $watch = [Diagnostics.Stopwatch]::StartNew()
    $json | & $kubectl create -f - | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "Failed to create benchmark pod '$name'." }
    try {
        Invoke-LabCommand -FilePath $kubectl -Arguments @('wait', '-n', $BenchmarkNamespace, "pod/$name", '--for=condition=Ready', '--timeout=5m') | Out-Null
        $watch.Stop()
        return [pscustomobject]@{
            Profile = $Profile
            Metric = 'pod-ready'
            Iteration = $Iteration
            Milliseconds = [math]::Round($watch.Elapsed.TotalMilliseconds, 2)
            RuntimeClass = $(if ([string]::IsNullOrWhiteSpace($RuntimeClass)) { 'runc' } else { $RuntimeClass })
        }
    }
    finally {
        Invoke-LabCommand -FilePath $kubectl -Arguments @('delete', 'pod', $name, '-n', $BenchmarkNamespace, '--wait=true', '--timeout=2m', '--ignore-not-found') -AllowFailure | Out-Null
    }
}

$results = New-Object System.Collections.Generic.List[object]
Write-Host 'Warming the common benchmark image for both runtimes...'
Measure-LabPodStart -Profile 'runc-warmup' -RuntimeClass '' -Iteration 0 | Out-Null
Measure-LabPodStart -Profile 'kata-warmup' -RuntimeClass $kataRuntimeClass -Iteration 0 | Out-Null

for ($i = 1; $i -le $Iterations; $i++) {
    Write-Host "Pod startup iteration $i/$Iterations"
    $results.Add((Measure-LabPodStart -Profile 'runc' -RuntimeClass '' -Iteration $i))
    $results.Add((Measure-LabPodStart -Profile 'kata' -RuntimeClass $kataRuntimeClass -Iteration $i))
}

$workspacePod = Get-LabPodName -Kubectl $kubectl -Namespace $WorkspaceNamespace
Write-Host 'Pre-pulling the inner Podman benchmark image...'
Invoke-LabCommand -FilePath $kubectl -Arguments @(
    'exec', '-n', $WorkspaceNamespace, $workspacePod, '-c', 'code-server', '--',
    'podman', 'pull', $versions.InnerTestImage
) | Out-Null
Invoke-LabCommand -FilePath $kubectl -Arguments @(
    'exec', '-n', $WorkspaceNamespace, $workspacePod, '-c', 'code-server', '--',
    'podman', 'run', '--rm', '--pull=never', $versions.InnerTestImage, 'true'
) | Out-Null

$guestTimingScript = @"
set -eu
i=1
while [ "`$i" -le $Iterations ]; do
  start_ns=`$(date +%s%N)
  podman run --rm --pull=never $($versions.InnerTestImage) true >/dev/null
  end_ns=`$(date +%s%N)
  printf '%s,%s\n' "`$i" "`$((end_ns - start_ns))"
  i=`$((i + 1))
done
"@
Write-Host "Measuring $Iterations inner Podman starts inside the Kata guest (kubectl transport excluded)..."
$guestTimings = Invoke-LabCommand -FilePath $kubectl -Arguments @(
    'exec', '-n', $WorkspaceNamespace, $workspacePod, '-c', 'code-server', '--',
    'sh', '-lc', $guestTimingScript
) -Capture
foreach ($line in ($guestTimings.Output -split "`r?`n")) {
    if ($line -notmatch '^(\d+),(\d+)$') { continue }
    $results.Add([pscustomobject]@{
        Profile = 'inner-podman'
        Metric = 'container-run-guest-side'
        Iteration = [int]$Matches[1]
        Milliseconds = [math]::Round(([double]$Matches[2] / 1000000.0), 3)
        RuntimeClass = $kataRuntimeClass
    })
}
if (@($results | Where-Object { $_.Metric -eq 'container-run-guest-side' }).Count -ne $Iterations) {
    throw "Expected $Iterations guest-side Podman timing samples, but did not receive all of them.`n$($guestTimings.Output)"
}

function Get-Percentile {
    param([double[]]$Values, [double]$Percentile)
    $sorted = @($Values | Sort-Object)
    $index = [math]::Max(0, [math]::Ceiling($Percentile * $sorted.Count) - 1)
    return [math]::Round([double]$sorted[$index], 2)
}

$summary = foreach ($group in ($results | Group-Object Profile, Metric)) {
    $values = @($group.Group | ForEach-Object { [double]$_.Milliseconds })
    [pscustomobject]@{
        Profile = $group.Group[0].Profile
        Metric = $group.Group[0].Metric
        Samples = $values.Count
        P50Milliseconds = Get-Percentile -Values $values -Percentile 0.50
        P95Milliseconds = Get-Percentile -Values $values -Percentile 0.95
        MeanMilliseconds = [math]::Round(($values | Measure-Object -Average).Average, 2)
    }
}

New-Item -ItemType Directory -Path $OutputDirectory -Force | Out-Null
$timestamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$rawPath = Join-Path $OutputDirectory "$timestamp-raw.csv"
$summaryPath = Join-Path $OutputDirectory "$timestamp-summary.csv"
$results | Export-Csv -LiteralPath $rawPath -NoTypeInformation -Encoding utf8
$summary | Export-Csv -LiteralPath $summaryPath -NoTypeInformation -Encoding utf8
$summary | Format-Table -AutoSize
Write-Host "Raw samples: $rawPath"
Write-Host "Summary:     $summaryPath"
Write-Host 'Use -Iterations 30 for a decision-quality p95 and repeat on native Linux before production sizing.'
