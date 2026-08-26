Set-StrictMode -Version Latest

function Write-ProvisionInfo([string]$Message) {
  Write-Host "`n==> $Message" -ForegroundColor Cyan
}

function Write-ProvisionOk([string]$Message) {
  Write-Host "OK  $Message" -ForegroundColor Green
}

function Write-ProvisionWarn([string]$Message) {
  Write-Host "AVISO $Message" -ForegroundColor Yellow
}

function Assert-NativeSuccess([string]$Operation) {
  $exitCodeVariable = Get-Variable LASTEXITCODE -ErrorAction SilentlyContinue
  if ($exitCodeVariable -and [int]$exitCodeVariable.Value -ne 0) {
    throw "$Operation falhou com código $($exitCodeVariable.Value)."
  }
}

function Install-DevEnvironment {
  [CmdletBinding()]
  param()

  Write-ProvisionInfo 'Provisionando runtimes e CLIs de desenvolvimento...'

  if (Get-Command fnm -ErrorAction SilentlyContinue) {
    fnm install --lts
    Assert-NativeSuccess 'fnm install --lts'
    $versionLines = @(fnm list)
    Assert-NativeSuccess 'fnm list'
    $versionLine = $versionLines | Select-String -Pattern 'lts-latest' | Select-Object -First 1
    if (-not $versionLine) { throw 'fnm instalou o LTS, mas não informou nenhuma versão em `fnm list`.' }
    $version = [regex]::Match("$versionLine", 'v\d+\.\d+\.\d+').Value
    fnm default $version
    Assert-NativeSuccess "fnm default $version"
    $fnmEnvironment = fnm env --use-on-cd --shell powershell | Out-String
    Assert-NativeSuccess 'fnm env'
    $fnmEnvironment | Invoke-Expression
    fnm use $version
    Assert-NativeSuccess "fnm use $version"
    Write-ProvisionOk "Node $version definido como padrão"

    if (Get-Command corepack -ErrorAction SilentlyContinue) {
      corepack enable
      Assert-NativeSuccess 'corepack enable'
      corepack prepare pnpm@latest --activate
      Assert-NativeSuccess 'corepack prepare pnpm@latest --activate'
      Write-ProvisionOk 'Corepack e pnpm habilitados'
    } else {
      Write-ProvisionWarn 'corepack não apareceu após ativar o Node LTS — pnpm e CLIs de IA foram pulados.'
      return
    }

    if (Get-Command npm -ErrorAction SilentlyContinue) {
      # npm 11 bloqueia lifecycle scripts globais que não estejam explicitamente
      # permitidos. O Claude Code usa install.cjs para finalizar a instalação.
      npm install -g --allow-scripts=@anthropic-ai/claude-code @anthropic-ai/claude-code @openai/codex
      Assert-NativeSuccess 'npm install dos CLIs de IA'
      Write-ProvisionOk 'Claude Code e Codex CLI instalados'
    } else {
      Write-ProvisionWarn 'npm não apareceu após ativar o Node LTS — CLIs de IA foram pulados.'
    }
  } else {
    Write-ProvisionWarn 'fnm não encontrado — Node, pnpm e CLIs de IA foram pulados.'
  }

  if (Get-Command uv -ErrorAction SilentlyContinue) {
    # --default cria python.exe e python3.exe em ~/.local/bin. Sem ele, o alias
    # da Microsoft Store vence e `python` continua dizendo que não está instalado.
    uv python install --default 3.13
    Assert-NativeSuccess 'uv python install --default 3.13'
    uv python pin --global 3.13
    Assert-NativeSuccess 'uv python pin --global 3.13'
    uv python update-shell
    Assert-NativeSuccess 'uv python update-shell'
    Write-ProvisionOk 'Python 3.13 instalado e definido como padrão pelo uv'
  } else {
    Write-ProvisionWarn 'uv não encontrado — Python foi pulado.'
  }

  if (Get-Command fzf -ErrorAction SilentlyContinue) {
    if (-not (Get-Module -ListAvailable -Name PSFzf)) {
      Install-Module -Name PSFzf -Scope CurrentUser -Force -AllowClobber
      Write-ProvisionOk 'PSFzf instalado (Ctrl+R e Ctrl+T)'
    }
  } else {
    Write-ProvisionWarn 'fzf não encontrado — PSFzf e os atalhos Ctrl+R/Ctrl+T foram pulados.'
  }
}

function Test-ConfigSubset {
  param($Expected, $Actual)

  if ($null -eq $Expected) { return $null -eq $Actual }
  if ($null -eq $Actual) { return $false }

  if ($Expected -is [System.Management.Automation.PSCustomObject]) {
    foreach ($property in $Expected.PSObject.Properties) {
      $actualProperty = $Actual.PSObject.Properties[$property.Name]
      if ($null -eq $actualProperty -or
          -not (Test-ConfigSubset -Expected $property.Value -Actual $actualProperty.Value)) {
        return $false
      }
    }
    return $true
  }

  if ($Expected -is [System.Collections.IEnumerable] -and $Expected -isnot [string]) {
    $actualItems = @($Actual)
    foreach ($expectedItem in @($Expected)) {
      $found = $false
      foreach ($actualItem in $actualItems) {
        if (Test-ConfigSubset -Expected $expectedItem -Actual $actualItem) {
          $found = $true
          break
        }
      }
      if (-not $found) { return $false }
    }
    return $true
  }

  return $Expected -eq $Actual
}

function Test-WindowsTerminalConfigApplied {
  param(
    [Parameter(Mandatory)][string]$Source,
    [Parameter(Mandatory)][string]$Destination
  )

  if (-not (Test-Path -LiteralPath $Destination)) { return $false }
  if ((Get-FileHash -LiteralPath $Source).Hash -eq (Get-FileHash -LiteralPath $Destination).Hash) {
    return $true
  }

  try {
    $expected = Get-Content -LiteralPath $Source -Raw | ConvertFrom-Json
    $actual = Get-Content -LiteralPath $Destination -Raw | ConvertFrom-Json

    # O Terminal elimina valores que equivalem aos defaults dos perfis integrados
    # (por exemplo, commandline do Windows PowerShell) e acrescenta perfis gerados.
    # Compare apenas o perfil que este repo gerencia como padrão, mais aparência e
    # dimensões globais. Os demais perfis continuam livres para normalização do app.
    if ($expected.PSObject.Properties['defaultProfile'] -and
        $expected.PSObject.Properties['profiles']) {
      $managedProfile = $expected.profiles.list |
        Where-Object { $_.guid -eq $expected.defaultProfile } |
        Select-Object -First 1
      $contract = [ordered]@{
        defaultProfile = $expected.defaultProfile
        profiles = [ordered]@{
          defaults = $expected.profiles.defaults
          list = @($managedProfile)
        }
      }
      foreach ($name in @('copyOnSelect', 'copyFormatting', 'disabledProfileSources', 'initialCols', 'initialRows', 'theme', 'schemes', 'themes')) {
        if ($expected.PSObject.Properties[$name]) { $contract[$name] = $expected.$name }
      }
      $expected = ($contract | ConvertTo-Json -Depth 100) | ConvertFrom-Json
    }
    return Test-ConfigSubset -Expected $expected -Actual $actual
  }
  catch {
    # Arquivo inválido ou parcialmente escrito: a sincronização abaixo restaura
    # uma cópia válida e guarda o conteúdo problemático no .bak.
    return $false
  }
}

function Sync-WindowsTerminalConfig {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)][string]$Source,
    [Parameter(Mandatory)][string]$Destination
  )

  if (-not (Test-Path -LiteralPath $Source)) {
    Write-ProvisionWarn "config do Windows Terminal não encontrada: $Source"
    return
  }

  $destinationDir = Split-Path -Parent $Destination
  if (-not (Test-Path -LiteralPath $destinationDir)) {
    Write-ProvisionWarn 'o Windows Terminal ainda não criou sua pasta de configuração; abra-o e rode o Stage 2 novamente.'
    return
  }

  if (Test-WindowsTerminalConfigApplied -Source $Source -Destination $Destination) {
    Write-ProvisionOk 'Windows Terminal já está sincronizado'
    return
  }

  if (Test-Path -LiteralPath $Destination) {
    Copy-Item -LiteralPath $Destination -Destination "$Destination.bak" -Force
    Write-ProvisionOk "backup do Windows Terminal em $Destination.bak"
  }
  Copy-Item -LiteralPath $Source -Destination $Destination -Force
  Write-ProvisionOk 'Windows Terminal configurado com PowerShell 7 e Starship'
}

function Get-WindowsTerminalSettingsPath {
  [CmdletBinding()]
  param()

  $candidates = @(
    (Join-Path $env:LOCALAPPDATA 'Packages\Microsoft.WindowsTerminal_8wekyb3d8bbwe\LocalState\settings.json'),
    (Join-Path $env:LOCALAPPDATA 'Packages\Microsoft.WindowsTerminalPreview_8wekyb3d8bbwe\LocalState\settings.json'),
    (Join-Path $env:LOCALAPPDATA 'Microsoft\Windows Terminal\settings.json')
  )
  return $candidates |
    Where-Object { Test-Path -LiteralPath (Split-Path -Parent $_) } |
    Select-Object -First 1
}
