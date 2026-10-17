# Service-owned startup callback; HostOps only supplies lifecycle context.
[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)][string]$HostOpsRoot,
    [string]$ConfigPath,
    [Parameter(Mandatory=$true)][string]$ReleaseGitSha,
    [string]$RecoveryBarrierId,
    [switch]$InspectOnly
)
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
Import-Module (Join-Path $HostOpsRoot 'modules\HostOps.Startup.psm1') -Force
$config=Get-HostOpsConfig -Path $ConfigPath
$serviceContract=Get-Content -LiteralPath (Join-Path $PSScriptRoot '..\config\startup-contract.json') -Raw|ConvertFrom-Json
if ($InspectOnly) {
    # Read-only inspection never adopts a pending next-boot release.
} elseif ([string]::IsNullOrWhiteSpace($RecoveryBarrierId)) {
    [void](Assert-HostOpsActivationEligible -Config $config -ExpectedReleaseGitSha $ReleaseGitSha)
} else {
    [void](Assert-HostOpsRecoveryWorkloadContext -Config $config -BarrierId $RecoveryBarrierId -ExpectedReleaseGitSha $ReleaseGitSha)
    [void](Assert-HostOpsSameSessionRecoveryAdoption -Config $config -ExpectedReleaseGitSha $ReleaseGitSha -BarrierId $RecoveryBarrierId)
}
[void](Assert-HostOpsStorageAdmissionLive -Config $config -ExpectedReleaseGitSha $ReleaseGitSha)

function Test-MailcowReady {
    $result = Invoke-HostOpsExternal -FilePath 'docker.exe' -Arguments @('--context',[string]$serviceContract.docker_context,'ps','--filter',('label=com.docker.compose.project=' + [string]$serviceContract.compose_project),'--format','{{.Names}}')
    if ($result.exit_code -ne 0) { return $false }
    $names = @($result.output | ForEach-Object { [string]$_ } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    if ($names.Count -lt [int]$serviceContract.expected_min_running_containers) { return $false }
    $missingCritical = @()
    foreach ($serviceName in @($serviceContract.critical_services | ForEach-Object { [string]$_ })) {
        $found = @($names | Where-Object { $_ -like ('*-' + $serviceName + '-*') })
        if ($found.Count -ne 1) { $missingCritical += $serviceName }
    }
    if ($missingCritical.Count -gt 0) { return $false }
    return [pscustomobject]@{ count=$names.Count; names=$names; critical_services=@($serviceContract.critical_services) }
}

if (-not $InspectOnly -and -not [string]::IsNullOrWhiteSpace($RecoveryBarrierId)) {
    # Restore only exact original identities through the existing recovery owner.
    $restoreScript=Join-Path $HostOpsRoot 'scripts\Invoke-HostOpsRestoreRecordedWorkloads.ps1'
    $output=@(& $restoreScript -Phase Mailcow -BarrierId $RecoveryBarrierId -ReleaseGitSha $ReleaseGitSha -ConfigPath $ConfigPath -Apply)
    if ($output.Count -ne 1 -or [string]($output[0]|ConvertFrom-Json).status -cne 'READY') { throw 'SAME_SESSION_MAILCOW_EXACT_RESTORE_NOT_PROVED' }
}
$mail=Test-MailcowReady
if (-not $mail) {
    if ($InspectOnly) { throw 'Mailcow inspection requires the existing critical containers to be running' }
    $mail=Wait-HostOpsCondition -TimeoutSeconds ([int]$serviceContract.ready_timeout_seconds) -PollMilliseconds 3000 -Description 'Mailcow restart-always workload recovery' -Condition { Test-MailcowReady }
}
if (-not $mail) { throw 'Mailcow critical containers did not become ready' }
[pscustomobject]@{
    workload='mailcow';status='READY'
    running_count=$mail.count;project=[string]$serviceContract.compose_project
    inspected_only=[bool]$InspectOnly
}
