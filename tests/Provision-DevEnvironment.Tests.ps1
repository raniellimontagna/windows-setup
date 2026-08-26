Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Parent $PSScriptRoot
$scriptUnderTest = Join-Path $repoRoot 'lib\Provision-DevEnvironment.ps1'
if (-not (Test-Path $scriptUnderTest)) {
  throw "Script de provisionamento ausente: $scriptUnderTest"
}
. $scriptUnderTest

function Assert-True {
  param([bool]$Condition, [string]$Message)
  if (-not $Condition) { throw "ASSERT: $Message" }
}

function Assert-Contains {
  param([string[]]$Values, [string]$Expected)
  Assert-True ($Expected -in $Values) "esperava chamada '$Expected'; recebeu: $($Values -join ' | ')"
}

$script:Calls = [System.Collections.Generic.List[string]]::new()
$script:FailCommand = ''

function global:fnm {
  $joined = $args -join ' '
  $script:Calls.Add("fnm $joined")
  $global:LASTEXITCODE = if ("fnm $joined" -eq $script:FailCommand) { 1 } else { 0 }
  if ($args[0] -eq 'list') { return @('v20.18.0', '* v24.19.0 default, lts-latest') }
  if ($args[0] -eq 'env') { return '$env:FNM_DIR = "C:\fake-fnm"' }
}
function global:corepack { $joined=$args -join ' '; $script:Calls.Add("corepack $joined"); $global:LASTEXITCODE=if("corepack $joined" -eq $script:FailCommand){1}else{0} }
function global:npm { $joined=$args -join ' '; $script:Calls.Add("npm $joined"); $global:LASTEXITCODE=if("npm $joined" -eq $script:FailCommand){1}else{0} }
function global:uv { $joined=$args -join ' '; $script:Calls.Add("uv $joined"); $global:LASTEXITCODE=if("uv $joined" -eq $script:FailCommand){1}else{0} }
function global:fzf { $global:LASTEXITCODE = 0 }
function global:Get-Module {
  param([switch]$ListAvailable, [string]$Name, [Parameter(ValueFromRemainingArguments)]$Rest)
  if ($Name -eq 'PSFzf') { return $null }
  Microsoft.PowerShell.Core\Get-Module @PSBoundParameters
}
function global:Install-Module {
  param([string]$Name, [string]$Scope, [switch]$Force, [switch]$AllowClobber)
  $script:Calls.Add("Install-Module $Name Scope=$Scope Force=$($Force.IsPresent) AllowClobber=$($AllowClobber.IsPresent)")
}

$tempRoot = $null
try {
  Install-DevEnvironment

  Assert-Contains $script:Calls 'fnm install --lts'
  Assert-Contains $script:Calls 'fnm default v24.19.0'
  Assert-Contains $script:Calls 'fnm use v24.19.0'
  Assert-Contains $script:Calls 'corepack enable'
  Assert-Contains $script:Calls 'corepack prepare pnpm@latest --activate'
  Assert-Contains $script:Calls 'npm install -g --allow-scripts=@anthropic-ai/claude-code @anthropic-ai/claude-code @openai/codex'
  Assert-True (-not ($script:Calls | Where-Object { $_ -like 'npm config set allow-scripts*' })) 'allow-scripts não deve persistir no .npmrc do usuário'
  Assert-Contains $script:Calls 'uv python install --default 3.13'
  Assert-Contains $script:Calls 'uv python pin --global 3.13'
  Assert-Contains $script:Calls 'uv python update-shell'
  Assert-True ([bool]($script:Calls | Where-Object { $_ -like 'Install-Module PSFzf*' })) 'PSFzf deve ser instalado quando ausente'

  $tempRoot = Join-Path ([IO.Path]::GetTempPath()) ("windows-setup-test-" + [guid]::NewGuid())
  New-Item -ItemType Directory -Path $tempRoot | Out-Null
  $source = Join-Path $tempRoot 'source.json'
  $destination = Join-Path $tempRoot 'settings.json'
  Set-Content $source '{"new":true}' -Encoding utf8NoBOM
  Set-Content $destination '{"old":true}' -Encoding utf8NoBOM

  Sync-WindowsTerminalConfig -Source $source -Destination $destination
  Assert-True ((Get-Content $destination -Raw).Trim() -eq '{"new":true}') 'config nova deve chegar ao Terminal'
  Assert-True ((Get-Content "$destination.bak" -Raw).Trim() -eq '{"old":true}') 'config anterior deve ficar no backup'

  # O Windows Terminal normaliza o JSON e acrescenta defaults enquanto está aberto.
  # A configuração desejada continua aplicada, embora o hash deixe de ser idêntico.
  Set-Content $destination '{"new":true,"terminalAdded":"default"}' -Encoding utf8NoBOM
  $backupTime = (Get-Item "$destination.bak").LastWriteTimeUtc
  Sync-WindowsTerminalConfig -Source $source -Destination $destination
  Assert-True ((Get-Item "$destination.bak").LastWriteTimeUtc -eq $backupTime) 'segunda sync idêntica não deve reescrever backup'
  Assert-True ((Get-Content $destination -Raw) -match 'terminalAdded') 'sync semântica deve preservar defaults acrescentados pelo Terminal'

  $terminalSource = Join-Path $tempRoot 'terminal-source.json'
  $terminalDestination = Join-Path $tempRoot 'terminal-settings.json'
  Set-Content $terminalSource @'
{"defaultProfile":"ps7","theme":"Theme","profiles":{"defaults":{"font":{"face":"Nerd"}},"list":[{"guid":"ps7","name":"PowerShell 7","commandline":"pwsh.exe"},{"guid":"legacy","name":"Windows PowerShell","commandline":"powershell.exe"}]},"schemes":[{"name":"Theme","background":"#000000"}]}
'@ -Encoding utf8NoBOM
  Set-Content $terminalDestination @'
{"defaultProfile":"ps7","theme":"Theme","profiles":{"defaults":{"font":{"face":"Nerd"}},"list":[{"guid":"ps7","name":"PowerShell 7","commandline":"pwsh.exe"},{"guid":"legacy","name":"Windows PowerShell"},{"guid":"generated","name":"Command Prompt"}]},"schemes":[{"name":"Theme","background":"#000000"}],"actions":[]}
'@ -Encoding utf8NoBOM
  Assert-True (Test-WindowsTerminalConfigApplied -Source $terminalSource -Destination $terminalDestination) 'defaults normalizados de perfis legados não devem invalidar a configuração gerenciada'

  Set-Content $terminalSource '{"defaultProfile":"ps7","copyOnSelect":false,"copyFormatting":"none","profiles":{"defaults":{},"list":[{"guid":"ps7"}]}}' -Encoding utf8NoBOM
  Set-Content $terminalDestination '{"defaultProfile":"ps7","copyOnSelect":true,"copyFormatting":"html","profiles":{"defaults":{},"list":[{"guid":"ps7"}]}}' -Encoding utf8NoBOM
  Assert-True (-not (Test-WindowsTerminalConfigApplied -Source $terminalSource -Destination $terminalDestination)) 'divergência em copyOnSelect/copyFormatting deve exigir sincronização'

  $script:FailCommand = 'npm install -g --allow-scripts=@anthropic-ai/claude-code @anthropic-ai/claude-code @openai/codex'
  $threw = $false
  try { Install-DevEnvironment } catch { $threw = $true }
  Assert-True $threw 'falha de comando nativo deve abortar o provisionamento em vez de imprimir OK'

  Write-Host 'PASS Provision-DevEnvironment.Tests.ps1'
}
finally {
  Remove-Item Function:\global:fnm, Function:\global:corepack, Function:\global:npm,
              Function:\global:uv, Function:\global:fzf, Function:\global:Get-Module,
              Function:\global:Install-Module `
              -Force -ErrorAction SilentlyContinue
  if ($tempRoot -and (Test-Path $tempRoot)) { Remove-Item $tempRoot -Recurse -Force }
}
