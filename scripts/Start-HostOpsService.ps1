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
    # Ordinary start: HostOps has already admitted current-boot capabilities. The legacy
    # next-boot activation marker is HostOps state, not start authority for this service.
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

# DOWN stops Mailcow with compose stop, and Docker does not restart containers
# stopped on purpose. Start only the existing project containers; never up,
# create, recreate, pull or down. Readiness below decides success, so a failed
# start is warned about here rather than thrown.
function Start-MailcowStoppedProjectContainers {
    $repoRoot = Split-Path -Parent $PSScriptRoot
    Push-Location -LiteralPath $repoRoot
    try {
        $started = Invoke-HostOpsExternal -FilePath 'docker.exe' -Arguments @('--context',[string]$serviceContract.docker_context,'compose','-p',[string]$serviceContract.compose_project,'start') -TimeoutSeconds 120
    } finally {
        Pop-Location
    }
    if ([int]$started.exit_code -ne 0) {
        Write-Warning ('MAILCOW_COMPOSE_START_NOT_CLEAN:rc=' + [int]$started.exit_code + '; readiness check decides')
    }
}

# Mailcow owns its exact same-session container recovery. HostOps supplies only
# the protected barrier/plan and platform admission; no HostOps app controller.
function Get-MailcowRecordedDockerIdentity {
    param([Parameter(Mandatory=$true)][string]$Name)
    $format='{{.Id}}|{{.Config.Image}}|{{.State.Running}}|{{index .Config.Labels "com.docker.compose.project"}}'
    $inspection=Invoke-HostOpsExternal -FilePath 'docker.exe' -Arguments @('--context',[string]$serviceContract.docker_context,'inspect','--format',$format,$Name) -TimeoutSeconds 20
    if ([int]$inspection.exit_code -ne 0) { throw ('MAILCOW_RECOVERY_INSPECT_FAILED:'+ $Name) }
    $fields=([string]$inspection.stdout).Trim() -split '\|',4
    if ($fields.Count -ne 4 -or [string]$fields[3] -cne [string]$serviceContract.compose_project) {
        throw ('MAILCOW_RECOVERY_COMPOSE_IDENTITY_MISMATCH:'+$Name)
    }
    return [pscustomobject]@{id=[string]$fields[0];image=[string]$fields[1];running=([string]$fields[2] -ceq 'true')}
}
function Assert-MailcowRecordedDockerIdentity {
    param($Expected,$Actual,[string]$Name)
    if ($null -eq $Actual -or [string]::IsNullOrWhiteSpace([string]$Expected.short_id) -or
        -not ([string]$Actual.id).StartsWith([string]$Expected.short_id,[StringComparison]::OrdinalIgnoreCase) -or
        [string]$Actual.image -cne [string]$Expected.image) {
        throw ('MAILCOW_RECOVERY_REPLACED_CONTAINER_REFUSED:'+$Name)
    }
}
function Invoke-MailcowRecordedRecovery {
    param([Parameter(Mandatory=$true)][string]$BarrierId)
    $planPath=Get-HostOpsRecoveryArtifactPath -Config $config -Kind 'plan' -BarrierId $BarrierId
    [void](Assert-HostOpsLifecycleFile -Config $config -Path $planPath)
    $plan=Read-HostOpsJson -Path $planPath
    if ($null -eq $plan -or [string]$plan.schema -cne 'entreflux.hostops.shutdown-recovery-plan.v1' -or
        [string]$plan.barrier_id -cne $BarrierId -or [string]$plan.boot_id -cne (Get-HostOpsBootIdentity).boot_id) {
        throw 'MAILCOW_RECOVERY_PROTECTED_PLAN_MISMATCH'
    }
    [void](Assert-HostOpsSameSessionRecoveryAdoption -Config $config -ExpectedReleaseGitSha $ReleaseGitSha -BarrierId $BarrierId)
    [void](Assert-HostOpsRecoveryWorkloadContext -Config $config -BarrierId $BarrierId -ExpectedReleaseGitSha $ReleaseGitSha)
    $owned=@($plan.mailcow_running | Sort-Object -Property @{Expression={
        if ([string]$_.name -match '(mysql|redis)-mailcow'){0}
        elseif ([string]$_.name -match 'watchdog'){100}
        else{50}
    }},@{Expression={$_.name}})
    foreach($item in $owned){
        $name=[string]$item.name
        $before=Get-MailcowRecordedDockerIdentity -Name $name
        Assert-MailcowRecordedDockerIdentity -Expected $item -Actual $before -Name $name
        if(-not [bool]$before.running){
            $started=Invoke-HostOpsExternal -FilePath 'docker.exe' -Arguments @('--context',[string]$serviceContract.docker_context,'start',$name) -TimeoutSeconds 90
            if([int]$started.exit_code -ne 0){throw ('MAILCOW_RECOVERY_START_FAILED:'+$name)}
        }
        $after=Get-MailcowRecordedDockerIdentity -Name $name
        Assert-MailcowRecordedDockerIdentity -Expected $item -Actual $after -Name $name
        if(-not [bool]$after.running){throw ('MAILCOW_RECOVERY_CONTAINER_NOT_RUNNING:'+$name)}
    }
}
if (-not $InspectOnly -and -not [string]::IsNullOrWhiteSpace($RecoveryBarrierId)) {
    Invoke-MailcowRecordedRecovery -BarrierId $RecoveryBarrierId
}
$mail=Test-MailcowReady
if (-not $mail) {
    if ($InspectOnly) { throw 'Mailcow inspection requires the existing critical containers to be running' }
    # Ordinary UP only: the recovery barrier path above already restores its protected plan exactly.
    if ([string]::IsNullOrWhiteSpace($RecoveryBarrierId)) { Start-MailcowStoppedProjectContainers }
    $mail=Wait-HostOpsCondition -TimeoutSeconds ([int]$serviceContract.ready_timeout_seconds) -PollMilliseconds 3000 -Description 'Mailcow restart-always workload recovery' -Condition { Test-MailcowReady }
}
if (-not $mail) { throw 'Mailcow critical containers did not become ready' }
[pscustomobject]@{
    workload='mailcow';status='READY'
    running_count=$mail.count;project=[string]$serviceContract.compose_project
    inspected_only=[bool]$InspectOnly
}
