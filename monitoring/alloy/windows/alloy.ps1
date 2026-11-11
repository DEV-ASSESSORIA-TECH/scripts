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
               [-Modules auto|none|hyperv,sqlanywhere] [-Upgrade]
  credentials  apenas o setup da credencial
  check        testa a credencial gravada (OAuth2 + Loki), sem alterar nada
  rotate       substitui a credencial e reinicia o Alloy
  modules      hyperv|sqlanywhere|none: conjunto completo dos modulos
               opcionais (separados por virgula; os nao listados saem)
  upgrade      atualiza o Alloy
  status       diagnostico (servico, eventos, conectividade, consultas)
  uninstall    remove o Alloy, mantendo credencial e configuracao [-Yes]
  purge        limpeza completa, inclui a credencial [-Yes]
  heartbeat    configura o heartbeat (Uptime Kuma Push + Loki) [-Url <url>]
  heartbeat-test    executa o heartbeat agora e mostra o resultado
  heartbeat-remove  remove o heartbeat [-Yes]
  menu         abre o menu mesmo na primeira execucao
  help         esta ajuda

.PARAMETER Ref
Branch, tag ou commit do repositorio usado nos downloads (padrao: main).

.PARAMETER Url
URL de push do Uptime Kuma (comando heartbeat, sem terminal interativo).

.EXAMPLE
.\alloy.ps1

.EXAMPLE
.\alloy.ps1 modules hyperv

.EXAMPLE
.\alloy.ps1 modules hyperv,sqlanywhere
#>
[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [ValidateSet('menu', 'install', 'credentials', 'check', 'rotate', 'modules', 'upgrade', 'status', 'uninstall', 'purge',
                 'heartbeat', 'heartbeat-test', 'heartbeat-remove', 'help')]
    [string]$Command = '',
    [Parameter(Position = 1)]
    [ValidateSet('auto', 'hyperv', 'sqlanywhere', 'none')]
    [string[]]$Modules = @('auto'),
    [switch]$Upgrade,
    [switch]$Yes,
    [string]$Ref,
    [string]$Url
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
    Save-RemoteFiles $src @('lib/State.ps1', 'lib/Ui.ps1')
    . (Join-Path $src 'lib\Ui.ps1')
    . (Join-Path $src 'lib\State.ps1')

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
            Write-UiSection 'ETAPA 1/2 - CREDENCIAL'
            Invoke-Credentials
            Write-UiSection 'ETAPA 2/2 - INSTALACAO'
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

    # Selection e o conjunto completo dos modulos opcionais desejados.
    function Invoke-Modules([string[]]$Selection) {
        if (-not $Selection -or $Selection -contains 'auto') {
            throw 'Use: modules hyperv|sqlanywhere|none (varios separados por virgula).'
        }
        if (-not (Test-CredentialPresent)) { throw 'Credencial ausente; execute a instalacao primeiro.' }
        Invoke-Installer @{ Modules = $Selection }
    }

    # Liga ou desliga um modulo preservando os demais.
    function Invoke-ToggleModule([string]$Name) {
        $set = @()
        if (Test-HyperVModule) { $set += 'hyperv' }
        if (Test-SqlAnywhereModule) { $set += 'sqlanywhere' }
        if ($set -contains $Name) { $set = @($set | Where-Object { $_ -ne $Name }) } else { $set += $Name }
        if ($set.Count -eq 0) { $set = @('none') }
        Invoke-Modules $set
    }

    function Invoke-ReconfigureSqlAnywhere {
        if (-not (Test-CredentialPresent)) { throw 'Credencial ausente; execute a instalacao primeiro.' }
        Invoke-Installer @{ ReconfigureSqlAnywhere = $true }
    }

    function Invoke-Upgrade {
        if (-not (Test-CredentialPresent)) { throw 'Credencial ausente; execute a instalacao primeiro.' }
        Invoke-Installer @{ Upgrade = $true }
    }

    function Invoke-Uninstall([hashtable]$Arguments = @{}) {
        Save-RemoteFiles $src @('uninstall.ps1')
        & (Join-Path $src 'uninstall.ps1') @Arguments
    }

    # Heartbeat opcional: nunca sugerido na instalacao, so pelo menu [9] ou comando.
    function Invoke-Heartbeat([hashtable]$Arguments = @{}) {
        Save-RemoteFiles $src @('heartbeat-setup.ps1', 'heartbeat.ps1')
        & (Join-Path $src 'heartbeat-setup.ps1') @Arguments
    }

    # ------------------------------------------------------------- interativo
    function Assert-Interactive {
        if ([Console]::IsInputRedirected) { throw 'Sem terminal interativo: informe um comando (Get-Help .\alloy.ps1).' }
    }

    function Invoke-FirstInstall {
        Clear-UiScreen
        Write-UiBanner (Get-AlloyHostName)
        Write-Host '  Primeira instalacao neste servidor.'
        Write-Host ''
        Write-UiText '  [1/2] Credencial' 'White' -NoNewline
        Write-Host '   conta alloy-<hostname> + senha de aplicativo,'
        Write-Host '                     validada (OAuth2 + Loki) antes de gravar'
        Write-UiText '  [2/2] Instalacao' 'White' -NoNewline
        Write-Host '   Alloy + configuracao, com validacao e rollback'
        Write-Host ''
        if (-not (Confirm-Choice '  Continuar?')) { Write-Log 'Cancelado; nada foi alterado.'; return }
        Invoke-Install
        Write-Host ''
        $script:LastStatus = 'ok'
        $script:LastAction = "Primeira instalacao - concluida ($(Get-Date -Format 'HH:mm'))"
        Show-AlloyHeader
        Write-Host '  Para gerenciar este servidor depois, execute o mesmo comando.'
    }

    # Tela propria para a acao, resultado e "ultima acao" no cabecalho.
    function Invoke-Screen([string]$Title, [scriptblock]$Action) {
        Clear-UiScreen
        Write-UiSection $Title.ToUpperInvariant()
        Write-Host ''
        try {
            & $Action
            $script:LastStatus = 'ok'
            $script:LastAction = "$Title - concluido ($(Get-Date -Format 'HH:mm'))"
            Write-Host ''
            Write-Host '  ' -NoNewline; Write-UiBadge 'ok'; Write-Host ' Concluido.'
        } catch {
            $script:LastStatus = 'err'
            $script:LastAction = "$Title - falhou ($(Get-Date -Format 'HH:mm'))"
            Write-Host ''
            Write-Host '  ' -NoNewline; Write-UiBadge 'err'; Write-Host " $($_.Exception.Message)"
        }
        Wait-UiKey
    }

    function Show-HeartbeatMenu {
        while (Test-HeartbeatConfigured) {
            Clear-UiScreen
            Show-AlloyHeader
            Write-UiColumns 'HEARTBEAT' 'White' '' ''
            Write-UiColumns ' [1] Testar agora' '' ' [3] Remover' 'Red'
            Write-UiColumns ' [2] Reconfigurar' '' '' ''
            Write-UiRule '-'
            switch (Read-UiKey 'Tecle a opcao (0 volta)') {
                '1' { Invoke-Screen 'Testar heartbeat' { Invoke-Heartbeat @{ Test = $true } } }
                '2' { Invoke-Screen 'Reconfigurar heartbeat' { Invoke-Heartbeat } }
                '3' { Invoke-Screen 'Remover heartbeat' { Invoke-Heartbeat @{ Remove = $true } } }
                { $_ -in @('0', 'q', 'Q', 'ESC') } { return }
            }
        }
    }

    function Test-SqlAnywherePresent {
        if (@(Get-Process -Name dbsrv17, dbeng17 -ErrorAction SilentlyContinue).Count -gt 0) { return $true }
        return @(Get-CimInstance -ClassName Win32_Service -ErrorAction SilentlyContinue | Where-Object {
            $_.PathName -match '(?i)\bdb(srv|eng)17\.exe\b'
        }).Count -gt 0
    }

    function Show-ModulesMenu {
        $sqlPresent = Test-SqlAnywherePresent
        while ($true) {
            $colorH = ''
            if (Test-HyperVModule) { $labelH = 'Desativar Hyper-V' } else {
                $labelH = 'Ativar Hyper-V'
                if (-not (Get-Service -Name vmms -ErrorAction SilentlyContinue)) { $labelH += ' (ausente)'; $colorH = 'DarkGray' }
            }
            $colorS = ''
            $sqlActive = Test-SqlAnywhereModule
            if ($sqlActive) { $labelS = 'Desativar SQL Anywhere' } else {
                $labelS = 'Ativar SQL Anywhere'
                if (-not $sqlPresent) { $labelS += ' (ausente)'; $colorS = 'DarkGray' }
            }
            $color3 = if ($sqlActive) { '' } else { 'DarkGray' }

            Clear-UiScreen
            Show-AlloyHeader
            Write-UiColumns 'MODULOS OPCIONAIS' 'White' '' ''
            Write-UiColumns " [1] $labelH" $colorH ' [3] Reconfigurar SQL Anywhere' $color3
            Write-UiColumns " [2] $labelS" $colorS '' ''
            Write-UiRule '-'
            switch (Read-UiKey 'Tecle a opcao (0 volta)') {
                '1' { Invoke-Screen $labelH { Invoke-ToggleModule 'hyperv' } }
                '2' { Invoke-Screen $labelS { Invoke-ToggleModule 'sqlanywhere' } }
                '3' { if ($sqlActive) { Invoke-Screen 'Reconfigurar SQL Anywhere' { Invoke-ReconfigureSqlAnywhere } } }
                { $_ -in @('0', 'q', 'Q', 'ESC') } { return }
            }
        }
    }

    function Show-Menu {
        while ($true) {
            $installed = Test-AlloyInstalled
            $default = ''
            if (-not $installed -or -not (Test-AlloyRunning)) { $default = '1' }
            $label1 = if ($installed) { 'Reaplicar configuracao' } else { 'Instalar Alloy' }
            $label5 = if (Test-CredentialPresent) { 'Rotacionar' } else { 'Configurar' }
            $color1 = if ($default) { 'Green' } else { '' }

            Clear-UiScreen
            Show-AlloyHeader
            Write-UiColumns 'INSTALACAO' 'White' 'CREDENCIAL' 'White'
            Write-UiColumns " [1] $label1" $color1 ' [4] Testar' ''
            Write-UiColumns ' [2] Modulos opcionais' '' " [5] $label5" ''
            Write-UiColumns ' [3] Atualizar Alloy' '' '' ''
            Write-Host ''
            Write-UiColumns 'DIAGNOSTICO' 'White' 'REMOCAO' 'White'
            $label9 = if (Test-HeartbeatConfigured) { 'Heartbeat' } else { 'Configurar heartbeat' }
            Write-UiColumns ' [6] Ver diagnostico' '' ' [7] Desinstalar' 'Red'
            Write-UiColumns " [9] $label9" '' ' [8] Limpeza completa' 'Red'
            Write-UiRule '-'
            $prompt = if ($default) { "Tecle a opcao (Enter = $default, 0 sai)" } else { 'Tecle a opcao (0 sai)' }
            $choice = Read-UiKey $prompt
            if ($choice -eq '') { $choice = $default }
            switch ($choice) {
                '1' { Invoke-Screen $label1 { Invoke-Install } }
                '2' { Show-ModulesMenu }
                '3' { Invoke-Screen 'Atualizar Alloy' { Invoke-Upgrade } }
                '4' { Invoke-Screen 'Testar credencial' { Invoke-Check } }
                '5' {
                    if (Test-CredentialPresent) { Invoke-Screen 'Rotacionar credencial' { Invoke-Rotate } }
                    else { Invoke-Screen 'Configurar credencial' { Invoke-SetupCredentials } }
                }
                '6' {
                    Clear-UiScreen
                    Write-UiBanner (Get-AlloyHostName)
                    Show-AlloyDiagnostics
                    Wait-UiKey
                }
                '7' { Invoke-Screen 'Desinstalar' { Invoke-Uninstall } }
                '8' { Invoke-Screen 'Limpeza completa' { Invoke-Uninstall @{ Purge = $true } } }
                '9' {
                    if (Test-HeartbeatConfigured) { Show-HeartbeatMenu }
                    else { Invoke-Screen 'Configurar heartbeat' { Invoke-Heartbeat } }
                }
                { $_ -in @('0', 'q', 'Q') } {
                    Clear-UiScreen
                    Show-AlloySummary
                    Write-Host '  Para abrir o menu de novo, execute o mesmo comando.'
                    return
                }
            }
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
        'status' { Write-UiBanner (Get-AlloyHostName); Show-AlloySummary; Show-AlloyDiagnostics }
        'uninstall' { Invoke-Uninstall @{ Yes = [bool]$Yes } }
        'purge' { Invoke-Uninstall @{ Purge = $true; Yes = [bool]$Yes } }
        'heartbeat' {
            $heartbeatArgs = @{}
            if ($Url) { $heartbeatArgs.Url = $Url }
            Invoke-Heartbeat $heartbeatArgs
        }
        'heartbeat-test' { Invoke-Heartbeat @{ Test = $true } }
        'heartbeat-remove' { Invoke-Heartbeat @{ Remove = $true; Yes = [bool]$Yes } }
    }
} finally {
    if ($script:HttpClient) { $script:HttpClient.Dispose() }
    if ($workDir) { Remove-Item -LiteralPath $workDir -Recurse -Force -ErrorAction SilentlyContinue }
}
