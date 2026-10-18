# Mailcow owner stop hook. Idempotent: unreachable engine or no running
# containers exits 0.
[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)][string]$HostOpsRoot,
    [string]$ConfigPath,
    [Parameter(Mandatory=$true)][string]$ReleaseGitSha,
    [string]$RecoveryBarrierId,
    [switch]$InspectOnly
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $HostOpsRoot 'modules\HostOps.Startup.psm1') -Force
$serviceContract = Get-Content -LiteralPath (Join-Path $PSScriptRoot '..\config\startup-contract.json') -Raw | ConvertFrom-Json
$context = [string]$serviceContract.docker_context
$project = [string]$serviceContract.compose_project
$repoRoot = Split-Path -Parent $PSScriptRoot

function Get-RunningMailcow {
    $r = Invoke-HostOpsExternal -FilePath 'docker.exe' -Arguments @('--context', $context, 'ps', '--filter', ('label=com.docker.compose.project=' + $project), '--format', '{{.Names}}') -TimeoutSeconds 30
    if ($r.exit_code -ne 0) { return $null }
    return @($r.output | ForEach-Object { ([string]$_).Trim() } | Where-Object { $_.Length -gt 0 })
}

$running = Get-RunningMailcow
if ($null -eq $running) {
    Write-Output 'mailcow: engine unreachable; already stopped'
    exit 0
}
if ($InspectOnly) {
    Write-Output ('mailcow: running containers=' + $running.Count + ' (inspect only)')
    exit 0
}
if ($running.Count -eq 0) {
    Write-Output 'mailcow: no running containers; already stopped'
    exit 0
}
Push-Location -LiteralPath $repoRoot
try {
    $stop = Invoke-HostOpsExternal -FilePath 'docker.exe' -Arguments @('--context', $context, 'compose', '-p', $project, 'stop', '-t', '90') -TimeoutSeconds 300
} finally {
    Pop-Location
}
if ([int]$stop.exit_code -ne 0) {
    Write-Output ('mailcow: compose stop failed rc=' + [int]$stop.exit_code)
    exit 1
}
$after = Get-RunningMailcow
if ($null -eq $after) {
    Write-Output 'mailcow: engine unreachable after stop; cannot verify'
    exit 1
}
if ($after.Count -gt 0) {
    Write-Output ('mailcow: containers still running: ' + ($after -join ','))
    exit 1
}
Write-Output 'mailcow: stopped'
exit 0
