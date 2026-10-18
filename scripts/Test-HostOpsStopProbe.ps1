Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
$tokens=$null;$errors=$null
$ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $PSScriptRoot 'Stop-HostOpsService.ps1'),[ref]$tokens,[ref]$errors)
if($errors.Count){throw 'Owner stop parse failed'}
$function=$ast.Find({param($node)$node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -ceq 'Get-RunningMailcow'},$true)
. ([scriptblock]::Create($function.Extent.Text))
$context='fixture';$project='fixture'
$script:result=[pscustomobject]@{exit_code=0;output=@()}
function Invoke-HostOpsExternal {param($FilePath,$Arguments,$TimeoutSeconds) return $script:result}
$probe=Get-RunningMailcow
if(-not $probe.available -or $probe.names.Count -ne 0){throw 'Empty successful ps is not a stopped engine'}
$script:result=[pscustomobject]@{exit_code=1;output=@('unreachable')}
$probe=Get-RunningMailcow
if($probe.available){throw 'Unavailable engine accepted'}
$script:result=[pscustomobject]@{exit_code=0;output=@('mailcow-postfix','mailcow-dovecot')}
$probe=Get-RunningMailcow
if(-not $probe.available -or $probe.names.Count -ne 2){throw 'Running containers lost'}
[pscustomobject]@{status='PASS_MAILCOW_OWNER_STOP_PROBE';checks=3;production_mutation=$false}|ConvertTo-Json -Compress
