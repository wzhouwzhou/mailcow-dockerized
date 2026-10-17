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
if (-not $text.Contains('function Invoke-MailcowRecordedRecovery') -or -not $text.Contains('Assert-MailcowRecordedDockerIdentity') -or $text.Contains('Invoke-HostOpsRestoreRecordedWorkloads.ps1')) { throw 'Exact recovery must be service-owned without the old HostOps application controller' }
if ($text -match 'Start-ScheduledTask') { throw 'Cold-boot callback must not install or dispatch Windows tasks' }
$identityFn=$ast.Find({param($a)$a -is [Management.Automation.Language.FunctionDefinitionAst] -and $a.Name -ceq 'Assert-MailcowRecordedDockerIdentity'},$false)
. ([scriptblock]::Create($identityFn.Extent.Text))
$expected=[pscustomobject]@{short_id='012345';image='registry/image:one'}
$actual=[pscustomobject]@{id='012345abcdef';image='registry/image:one'}
Assert-MailcowRecordedDockerIdentity -Expected $expected -Actual $actual -Name mailcow-fixture
$refused=$false
try{Assert-MailcowRecordedDockerIdentity -Expected $expected -Actual ([pscustomobject]@{id='deadbeef';image='registry/image:one'}) -Name mailcow-fixture}catch{$refused=$true}
if(-not $refused){throw 'Changed container identity must be refused'}
$refused=$false
try{Assert-MailcowRecordedDockerIdentity -Expected $expected -Actual ([pscustomobject]@{id='012345abcdef';image='other/image'}) -Name mailcow-fixture}catch{$refused=$true}
if(-not $refused){throw 'Changed container image must be refused'}
'PASS_MAILCOW_OWNER_STARTUP: ready/critical/exact-recovery checks; no live operations'
