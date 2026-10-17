[CmdletBinding()]
param()
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
$path=Join-Path $PSScriptRoot 'Start-HostOpsService.ps1'
$tokens=$null; $errors=$null
$ast=[Management.Automation.Language.Parser]::ParseFile($path,[ref]$tokens,[ref]$errors)
if (@($errors).Count) { throw ($errors|Out-String) }
$serviceContract=Get-Content (Join-Path $PSScriptRoot '..\config\startup-contract.json') -Raw|ConvertFrom-Json

$fn=$ast.Find({param($a)$a -is [Management.Automation.Language.FunctionDefinitionAst] -and $a.Name -ceq 'Test-MailcowReady'},$false)
. ([scriptblock]::Create($fn.Extent.Text))
$script:names=@($serviceContract.critical_services|ForEach-Object {'mailcowdockerized-'+$_+'-1'})+@(1..12|ForEach-Object {'fixture-extra-'+$_})
$script:rc=0
function Invoke-HostOpsExternal { param($FilePath,$Arguments) return [pscustomobject]@{exit_code=$script:rc;output=$script:names} }
$ready=Test-MailcowReady
if (-not $ready -or $ready.count -ne 19) { throw 'Current full critical set must be ready' }
$script:names=@($script:names|Where-Object {$_ -notlike '*-postfix-mailcow-*'})
if (Test-MailcowReady) { throw 'Missing critical service must refuse' }
$script:rc=1
if (Test-MailcowReady) { throw 'Docker inspection failure must refuse' }
$text=[IO.File]::ReadAllText($path)
if (-not $text.Contains('if (-not $InspectOnly -and -not [string]::IsNullOrWhiteSpace($RecoveryBarrierId))')) { throw 'Recovery must never run during InspectOnly' }
if (-not $text.Contains('Invoke-HostOpsRestoreRecordedWorkloads.ps1') -or -not $text.Contains('-Phase Mailcow')) { throw 'Existing exact recovery owner required' }
if ($text -match 'Start-ScheduledTask|docker.exe.+start') { throw 'Cold-boot callback must not create a new start policy' }
'PASS_MAILCOW_OWNER_STARTUP: 6 checks; no live operations'
