#Requires -RunAsAdministrator
#Requires -Version 5.1
<#
.SYNOPSIS
Ponto de entrada unico do Grafana Alloy no Windows Server.

.DESCRIPTION
Sem comando: primeira instalacao guiada (credencial + instalacao) ou, se o
servidor ja tiver credencial ou Alloy, menu interativo com o estado atual.
Baixa sob demanda, do mesmo ref, apenas os arquivos de cada operacao.

Comandos:
  install      credencial (se ausente) + instalacao/reaplicacao
               [-Modules auto|hyperv|none] [-Upgrade]
  credentials  apenas o setup da credencial
  check        testa a credencial gravada (OAuth2 + Loki), sem alterar nada
  rotate       substitui a credencial e reinicia o Alloy
  modules      hyperv|none: ativa ou desativa o modulo Hyper-V
  upgrade      atualiza o Alloy
  status       diagnostico (servico, eventos, conectividade, consultas)
  uninstall    remove o Alloy, mantendo credencial e configuracao [-Yes]
  purge        limpeza completa, inclui a credencial [-Yes]
  menu         abre o menu mesmo na primeira execucao
  help         esta ajuda

.PARAMETER Ref
Branch, tag ou commit do repositorio usado nos downloads (padrao: main).

.EXAMPLE
.\alloy.ps1

.EXAMPLE
.\alloy.ps1 modules hyperv
#>
[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [ValidateSet('menu', 'install', 'credentials', 'check', 'rotate', 'modules', 'upgrade', 'status', 'uninstall', 'purge', 'help')]
    [string]$Command = '',
    [Parameter(Position = 1)]
    [ValidateSet('auto', 'hyperv', 'none')]
    [string]$Modules = 'auto',
    [switch]$Upgrade,
    [switch]$Yes,
    [string]$Ref
)

$ErrorActionPreference = 'Stop'
if ($Command -eq 'help') { Get-Help $PSCommandPath -Detailed; return }
if ($Ref) { $env:ALLOY_REF = $Ref }
if (-not $env:ALLOY_REF) { $env:ALLOY_REF = 'main' }

# ------------------------------------------------------------------ bootstrap
# Clone do repositorio: usa os arquivos locais. Caso contrario (arquivo
# baixado sozinho), trabalha numa pasta temporaria propria.
$script:LocalMode = (Test-Path -LiteralPath (Join-Path $PSScriptRoot 'install.ps1')) -and
                    (Test-Path -LiteralPath (Join-Path $PSScriptRoot 'lib\Common.ps1'))
$workDir = $null
$src = $PSScriptRoot
if (-not $script:LocalMode) {
    $workDir = Join-Path $env:TEMP ('alloy-cli-' + [guid]::NewGuid().ToString('N'))
    $src = $workDir
}

try {
    if ($workDir) {
        New-Item -ItemType Directory -Path (Join-Path $workDir 'lib') -Force | Out-Null
        $ref = $env:ALLOY_REF
        if ($ref -notmatch '^[A-Za-z0-9][A-Za-z0-9._/-]*$' -or $ref.Contains('..')) { throw "Referencia invalida: $ref" }
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        try {
            Invoke-WebRequest -UseBasicParsing -OutFile (Join-Path $workDir 'lib\Common.ps1') `
                -Uri "https://raw.githubusercontent.com/DEV-ASSESSORIA-TECH/scripts/$ref/monitoring/alloy/windows/lib/Common.ps1"
        } catch {
            throw "Falha ao baixar as bibliotecas (ref $ref): $($_.Exception.Message)"
        }
    }
    . (Join-Path $src 'lib\Common.ps1')

    # -------------------------------------------------------------- operacoes
    # Os scripts filhos rodam com seus proprios controles de erro e rollback;
    # uma falha lanca excecao, tratada pelo menu ou repassada ao chamador.

    function Invoke-Credentials([hashtable]$Arguments = @{}) {
        Save-RemoteFiles $src @('setup-credentials.ps1')
        & (Join-Path $src 'setup-credentials.ps1') @Arguments
    }

    function Invoke-Installer([hashtable]$Arguments = @{}) {
        Save-RemoteFiles $src @('install.ps1', 'config.alloy')
        & (Join-Path $src 'install.ps1') @Arguments
    }

    function Invoke-Install([hashtable]$Arguments = @{}) {
        if (-not (Test-CredentialPresent)) {
            # Os tres arquivos com o mesmo cliente HTTP, antes da etapa 1.
            Save-RemoteFiles $src @('setup-credentials.ps1', 'install.ps1', 'config.alloy')
            Write-Log 'Etapa 1/2 - Credencial'
            Invoke-Credentials
            Write-Log 'Etapa 2/2 - Instalacao'
        }
        Invoke-Installer $Arguments
    }

    function Invoke-SetupCredentials {
        if (Test-CredentialPresent) { throw 'Credencial ja existe. Use "rotate" para substituir.' }
        Invoke-Credentials
    }

    function Invoke-Check {
        if (-not (Test-CredentialPresent)) { throw 'Nenhuma credencial gravada.' }
        Invoke-Credentials @{ Check = $true }
    }

    function Invoke-Rotate {
        if (-not (Test-CredentialPresent)) { throw 'Nenhuma credencial gravada; use o setup de credencial.' }
        Invoke-Credentials @{ Rotate = $true }
        if (Test-AlloyRunning) {
            Write-Log 'Reiniciando o Alloy para carregar a nova credencial...'
            Restart-Service -Name $ServiceName
            if (-not (Wait-AlloyReady)) { throw 'Alloy nao ficou pronto apos a rotacao. Consulte o diagnostico.' }
            Write-Ok 'Alloy pronto com a nova credencial.'
        }
    }

    function Invoke-Modules([string]$Selection) {
        if ($Selection -notin @('hyperv', 'none')) { throw 'Use: modules hyperv|none' }
        if (-not (Test-CredentialPresent)) { throw 'Credencial ausente; execute a instalacao primeiro.' }
        Invoke-Installer @{ Modules = $Selection }
    }

    function Invoke-Upgrade {
        if (-not (Test-CredentialPresent)) { throw 'Credencial ausente; execute a instalacao primeiro.' }
        Invoke-Installer @{ Upgrade = $true }
    }

    function Invoke-Uninstall([hashtable]$Arguments = @{}) {
        Save-RemoteFiles $src @('uninstall.ps1')
        & (Join-Path $src 'uninstall.ps1') @Arguments
    }

    # ------------------------------------------------------------- interativo
    function Assert-Interactive {
        if ([Console]::IsInputRedirected) { throw 'Sem terminal interativo: informe um comando (Get-Help .\alloy.ps1).' }
    }

    function Invoke-FirstInstall {
        Write-Host ''
        Write-Host " Alloy - primeira instalacao em $(Get-AlloyHostName)"
        Write-Host ' 1) Setup da credencial: conta alloy-<hostname> + senha de aplicativo,'
        Write-Host '    validadas com OAuth2 e Loki antes de gravar.'
        Write-Host ' 2) Instalacao do Alloy e aplicacao da configuracao.'
        Write-Host ''
        if (-not (Confirm-Choice 'Continuar?')) { Write-Log 'Cancelado; nada foi alterado.'; return }
        Invoke-Install
        Write-Log 'Para gerenciar este servidor depois, execute o mesmo comando: o menu sera exibido.'
    }

    function Invoke-MenuAction([scriptblock]$Action) {
        Write-Host ''
        try {
            & $Action
            Write-Ok 'Concluido.'
        } catch {
            Write-Warn "A operacao nao foi concluida: $($_.Exception.Message)"
        }
    }

    function Show-Menu {
        while ($true) {
            Show-AlloyHeader
            $default = ''
            if (-not (Test-AlloyInstalled) -or -not (Test-AlloyRunning)) { $default = '1' }
            if (Test-HyperVModule) {
                $hypervLabel = 'Desativar modulo Hyper-V'; $hypervTarget = 'none'
            } else {
                $hypervLabel = 'Ativar modulo Hyper-V'; $hypervTarget = 'hyperv'
                if (-not (Get-Service -Name vmms -ErrorAction SilentlyContinue)) { $hypervLabel += ' (Hyper-V nao detectado)' }
            }
            $credLabel = if (Test-CredentialPresent) { 'Rotacionar credencial' } else { 'Configurar credencial' }

            Write-Host ' 1) Instalar / reaplicar configuracao' -NoNewline
            if ($default) { Write-Host ' (recomendado)' -ForegroundColor Green } else { Write-Host '' }
            Write-Host " 2) $hypervLabel"
            Write-Host ' 3) Atualizar o Alloy'
            Write-Host ' 4) Testar credencial (sem gravar)'
            Write-Host " 5) $credLabel"
            Write-Host ' 6) Diagnostico'
            Write-Host ' 7) Desinstalar (mantem credencial e configuracao)'
            Write-Host ' 8) Limpeza completa'
            Write-Host ' 0) Sair'
            Write-Host ''
            $prompt = if ($default) { "Opcao [$default]" } else { 'Opcao' }
            $choice = (Read-Host $prompt).Trim()
            if (-not $choice) { $choice = $default }
            # "continue" dentro de switch nao volta ao while: usar $pause.
            $pause = $true
            switch ($choice) {
                '1' { Invoke-MenuAction { Invoke-Install } }
                '2' { Invoke-MenuAction { Invoke-Modules $hypervTarget } }
                '3' { Invoke-MenuAction { Invoke-Upgrade } }
                '4' { Invoke-MenuAction { Invoke-Check } }
                '5' {
                    if (Test-CredentialPresent) { Invoke-MenuAction { Invoke-Rotate } }
                    else { Invoke-MenuAction { Invoke-SetupCredentials } }
                }
                '6' { Write-Host ''; Show-AlloyDiagnostics }
                '7' { Invoke-MenuAction { Invoke-Uninstall } }
                '8' { Invoke-MenuAction { Invoke-Uninstall @{ Purge = $true } } }
                { $_ -in @('0', 'q', 'sair') } { return }
                '' { $pause = $false }
                default { Write-Warn "Opcao invalida: $choice"; $pause = $false }
            }
            if ($pause) { $null = Read-Host "`nEnter para voltar ao menu" }
        }
    }

    # --------------------------------------------------------------- despacho
    switch ($Command) {
        '' {
            Assert-Interactive
            if (Test-FirstRun) { Invoke-FirstInstall } else { Show-Menu }
        }
        'menu' { Assert-Interactive; Show-Menu }
        'install' {
            $installArgs = @{ Modules = $Modules }
            if ($Upgrade) { $installArgs.Upgrade = $true }
            Invoke-Install $installArgs
        }
        'credentials' { Invoke-SetupCredentials }
        'check' { Invoke-Check }
        'rotate' { Invoke-Rotate }
        'modules' { Invoke-Modules $Modules }
        'upgrade' { Invoke-Upgrade }
        'status' { Show-AlloyDiagnostics }
        'uninstall' { Invoke-Uninstall @{ Yes = [bool]$Yes } }
        'purge' { Invoke-Uninstall @{ Purge = $true; Yes = [bool]$Yes } }
    }
} finally {
    if ($script:HttpClient) { $script:HttpClient.Dispose() }
    if ($workDir) { Remove-Item -LiteralPath $workDir -Recurse -Force -ErrorAction SilentlyContinue }
}
