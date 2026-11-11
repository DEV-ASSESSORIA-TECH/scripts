#Requires -Version 5.1
<#
.SYNOPSIS
Ponto de entrada unico do Grafana Alloy no Windows, servidor ou estacao (comando alloyctl).

.DESCRIPTION
Sem comando: primeira instalacao guiada (credencial + instalacao) ou, se o
servidor ja tiver credencial ou Alloy, menu interativo com o estado atual.

Executado a partir do download (comando do README), instala o comando
alloyctl (C:\Program Files\AssessoriaTech\alloyctl, no PATH da maquina) e
segue por ele. O alloyctl se atualiza a cada execucao pela branch
acompanhada e baixa sob demanda, presos ao mesmo commit, apenas os arquivos
de cada operacao. Sem Administrador, pede elevacao (UAC) e abre em nova janela.

Comandos:
  install      credencial (se ausente) + instalacao/reaplicacao
               [-Perfil auto|servidor|estacao] [-Modules auto|none|hyperv,sqlanywhere] [-Upgrade]
  credentials  apenas o setup da credencial
  check        testa a credencial gravada (OAuth2 + Loki), sem alterar nada
  rotate       substitui a credencial e reinicia o Alloy
  modules      hyperv|sqlanywhere|none: conjunto completo dos modulos
               opcionais (separados por virgula; os nao listados saem)
  upgrade      atualiza o Alloy
  status       diagnostico (servico, eventos, conectividade, consultas)
  uninstall    remove o Alloy, mantendo credencial, configuracao e o alloyctl [-Yes]
  purge        limpeza completa, inclui a credencial e o alloyctl [-Yes]
  heartbeat    configura o heartbeat (Uptime Kuma Push + Loki) [-Url <url>]
  heartbeat-test    executa o heartbeat agora e mostra o resultado
  heartbeat-remove  remove o heartbeat [-Yes]
  update       atualiza so o alloyctl e mostra a versao
  menu         abre o menu mesmo na primeira execucao
  help         esta ajuda

.PARAMETER Ref
Branch, tag ou commit acompanhado pelo alloyctl (padrao: main). Fica gravado
para as proximas execucoes.

.PARAMETER Perfil
servidor: job integrations/windows, com alertas. estacao: maquina descartavel,
job integrations/windows-desktop, sem alertas, sem modulos opcionais e sem
heartbeat. auto (padrao): mantem o perfil instalado; na primeira instalacao,
estacao em Windows de cliente (10/11) e servidor no Windows Server.

.PARAMETER NoUpdate
Nao atualiza o alloyctl antes de executar.

.PARAMETER Url
URL de push do Uptime Kuma (comando heartbeat, sem terminal interativo).

.EXAMPLE
alloyctl

.EXAMPLE
alloyctl modules hyperv,sqlanywhere

.EXAMPLE
alloyctl install -Perfil estacao
#>
[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [ValidateSet('menu', 'install', 'credentials', 'check', 'rotate', 'modules', 'upgrade', 'status', 'uninstall', 'purge',
                 'heartbeat', 'heartbeat-test', 'heartbeat-remove', 'update', 'help')]
    [string]$Command = '',
    # Validado abaixo: pelo alloyctl.cmd ou na elevacao, "hyperv,sqlanywhere"
    # chega como um unico texto.
    [Parameter(Position = 1)]
    [string[]]$Modules = @('auto'),
    [ValidateSet('auto', 'servidor', 'estacao')]
    [string]$Perfil = 'auto',
    [switch]$Upgrade,
    [switch]$Yes,
    [string]$Ref,
    [string]$Url,
    [switch]$NoUpdate,
    # Reexecucao elevada (nova janela): pausa no final para mostrar o resultado.
    [Parameter(DontShow)]
    [switch]$Elevated
)

$ErrorActionPreference = 'Stop'
if ($Command -eq 'help') { Get-Help $PSCommandPath -Detailed; return }
$Modules = @($Modules | ForEach-Object { $_ -split ',' } | ForEach-Object { $_.Trim() } | Where-Object { $_ })
if ($Modules.Count -eq 0) { $Modules = @('auto') }
foreach ($module in $Modules) {
    if ($module -notin @('auto', 'hyperv', 'sqlanywhere', 'none')) {
        throw "Modulo invalido: $module (use auto, hyperv, sqlanywhere ou none)."
    }
}
if (-not $Ref -and $env:ALLOY_REF) { $Ref = $env:ALLOY_REF }
# Argumentos recebidos, sem Ref/NoUpdate/Elevated (tratados aqui).
$PassArgs = @{}
foreach ($key in $PSBoundParameters.Keys) {
    if ($key -notin @('Ref', 'NoUpdate', 'Elevated')) { $PassArgs[$key] = $PSBoundParameters[$key] }
}
$PassArgs['Modules'] = $Modules

# --------------------------------------------------------------- elevacao
$identity = [Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
if (-not $identity.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    if ([Console]::IsInputRedirected -or -not $PSCommandPath) { throw 'Execute como Administrador.' }
    $quote = { param($Text) '"' + ([string]$Text -replace '"', '\"') + '"' }
    $line = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', (& $quote $PSCommandPath))
    foreach ($key in $PassArgs.Keys) {
        $value = $PassArgs[$key]
        if ($value -is [Management.Automation.SwitchParameter]) {
            if ($value.IsPresent) { $line += "-$key" }
        } else {
            $line += "-$key"
            $line += (& $quote (@($value) -join ','))
        }
    }
    if ($Ref) { $line += '-Ref'; $line += (& $quote $Ref) }
    if ($NoUpdate) { $line += '-NoUpdate' }
    $line += '-Elevated'
    Write-Host '[alloyctl] Sem permissao de Administrador: solicitando elevacao (UAC). Continua em uma nova janela.'
    try {
        $process = Start-Process -FilePath (Join-Path $PSHOME 'powershell.exe') -ArgumentList ($line -join ' ') -Verb RunAs -Wait -PassThru
    } catch {
        throw "Elevacao cancelada ou negada: $($_.Exception.Message)"
    }
    exit $process.ExitCode
}

# --------------------------------------------------------------- alloyctl
$ToolDir = Join-Path $env:ProgramFiles 'AssessoriaTech\alloyctl'
$ToolCmd = Join-Path $ToolDir 'alloyctl.cmd'
$ToolRepo = 'DEV-ASSESSORIA-TECH/scripts'
$ToolRemoteDir = 'monitoring/alloy/windows'
# Nucleo baixado a cada versao; o resto vem sob demanda (Save-RemoteFiles).
$ToolCore = @('alloy.ps1', 'lib/Common.ps1', 'lib/State.ps1', 'lib/Ui.ps1')

function Write-ToolLog([string]$Text) { Write-Host "[alloyctl] $Text" }
function Write-ToolWarn([string]$Text) { Write-Host "[alloyctl] AVISO: $Text" -ForegroundColor Yellow }
function Test-ToolRef([string]$Value) { ($Value -match '^[A-Za-z0-9][A-Za-z0-9._/-]*$') -and -not $Value.Contains('..') }

function Get-ToolHttp {
    if (-not $script:ToolHttp) {
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        Add-Type -AssemblyName System.Net.Http
        $script:ToolHttp = [System.Net.Http.HttpClient]::new()
        $script:ToolHttp.Timeout = [TimeSpan]::FromSeconds(20)
        $script:ToolHttp.DefaultRequestHeaders.UserAgent.ParseAdd('AssessoriaTech-Alloy-Installer/1.0')
    }
    return $script:ToolHttp
}

# Commit atual de uma branch/tag (uma requisicao a API do GitHub); $null se falhar.
function Resolve-ToolSha([string]$Value) {
    try {
        $request = [System.Net.Http.HttpRequestMessage]::new([System.Net.Http.HttpMethod]::Get,
            "https://api.github.com/repos/$ToolRepo/commits/$Value")
        [void]$request.Headers.TryAddWithoutValidation('Accept', 'application/vnd.github.sha')
        $response = (Get-ToolHttp).SendAsync($request).GetAwaiter().GetResult()
        try {
            if (-not $response.IsSuccessStatusCode) { return $null }
            $sha = $response.Content.ReadAsStringAsync().GetAwaiter().GetResult().Trim()
        } finally { $response.Dispose() }
        if ($sha -cmatch '^[0-9a-f]{40}$') { return $sha }
    } catch { }
    return $null
}

# PATH da maquina sem expandir (preserva %SystemRoot% etc.) e aviso aos
# processos abertos (WM_SETTINGCHANGE), como o Painel de Controle faz.
function Add-ToolPath {
    $key = Get-Item -LiteralPath 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Environment'
    $current = [string]$key.GetValue('Path', '', [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
    $entries = @($current -split ';' | Where-Object { $_ })
    if (@($entries | Where-Object { $_.TrimEnd('\') -ieq $ToolDir }).Count -gt 0) { return }
    $value = (@($entries) + $ToolDir) -join ';'
    Set-ItemProperty -LiteralPath $key.PSPath -Name 'Path' -Value $value -Type ExpandString
    try {
        Add-Type -Namespace AlloyCtl -Name Native -MemberDefinition @'
[DllImport("user32.dll", SetLastError = true, CharSet = CharSet.Auto)]
public static extern IntPtr SendMessageTimeout(IntPtr hWnd, uint Msg, UIntPtr wParam, string lParam,
    uint fuFlags, uint uTimeout, out UIntPtr lpdwResult);
'@
        $result = [UIntPtr]::Zero
        [void][AlloyCtl.Native]::SendMessageTimeout([IntPtr]0xffff, 0x1A, [UIntPtr]::Zero, 'Environment', 2, 5000, [ref]$result)
    } catch { }
}

# Baixa o nucleo do commit em um diretorio novo e troca o diretorio inteiro
# (descarta os arquivos sob demanda da versao anterior). O PowerShell ja leu
# o script em execucao: renomear a pasta nao o afeta.
function Install-Tool([string]$TrackedRef, [string]$Sha) {
    $parent = Split-Path -Parent $ToolDir
    if (-not (Test-Path -LiteralPath $parent)) { New-Item -ItemType Directory -Path $parent -Force | Out-Null }
    $stage = $ToolDir + '.new-' + [guid]::NewGuid().ToString('N')
    $old = $null
    try {
        foreach ($name in $ToolCore) {
            $target = Join-Path $stage ($name -replace '/', '\')
            $dir = Split-Path -Parent $target
            if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
            $bytes = (Get-ToolHttp).GetByteArrayAsync("https://raw.githubusercontent.com/$ToolRepo/$Sha/$ToolRemoteDir/$name").GetAwaiter().GetResult()
            if ($bytes.Length -eq 0) { throw "Download vazio: $name" }
            [IO.File]::WriteAllBytes($target, $bytes)
            $tokens = $null
            $errors = $null
            [void][Management.Automation.Language.Parser]::ParseFile($target, [ref]$tokens, [ref]$errors)
            if ($errors -and $errors.Count -gt 0) { throw "$name com erro de sintaxe: $($errors[0].Message)" }
        }
        [IO.File]::WriteAllText((Join-Path $stage 'ref'), $TrackedRef + "`r`n")
        [IO.File]::WriteAllText((Join-Path $stage 'version'), $Sha + "`r`n")
        # "& exit /b" na mesma linha: o cmd nao rele o .cmd depois do PowerShell
        # (o arquivo pode ter sido trocado ou removido nesse meio tempo).
        $shim = "@echo off`r`nrem alloyctl: Grafana Alloy (gerado pelo alloy.ps1; atualizado a cada versao).`r`n" +
            "`"%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe`" -NoProfile -ExecutionPolicy Bypass -File `"%~dp0alloy.ps1`" %* & exit /b`r`n"
        [IO.File]::WriteAllText((Join-Path $stage 'alloyctl.cmd'), $shim, [Text.Encoding]::ASCII)
        if (Test-Path -LiteralPath $ToolDir) {
            $old = $ToolDir + '.old-' + [guid]::NewGuid().ToString('N')
            Rename-Item -LiteralPath $ToolDir -NewName (Split-Path -Leaf $old)
        }
        Rename-Item -LiteralPath $stage -NewName (Split-Path -Leaf $ToolDir)
    } catch {
        Remove-Item -LiteralPath $stage -Recurse -Force -ErrorAction SilentlyContinue
        if ($old -and -not (Test-Path -LiteralPath $ToolDir) -and (Test-Path -LiteralPath $old)) {
            Rename-Item -LiteralPath $old -NewName (Split-Path -Leaf $ToolDir) -ErrorAction SilentlyContinue
        }
        Write-ToolWarn "falha ao instalar o alloyctl: $($_.Exception.Message)"
        return $false
    }
    if ($old) { Remove-Item -LiteralPath $old -Recurse -Force -ErrorAction SilentlyContinue }
    Add-ToolPath
    return $true
}

# Executa a versao instalada no mesmo processo, sem nova verificacao.
function Invoke-Tool {
    $arguments = @{} + $PassArgs
    $arguments['NoUpdate'] = $true
    if ($Elevated) { $arguments['Elevated'] = $true }
    & (Join-Path $ToolDir 'alloy.ps1') @arguments
}

if ($Ref -and -not (Test-ToolRef $Ref)) { throw "Referencia invalida: $Ref" }
$toolMode = 'bootstrap'
if ($PSScriptRoot -and ($PSScriptRoot.TrimEnd('\') -ieq $ToolDir)) {
    $toolMode = 'installed'
} elseif ($PSScriptRoot -and (Test-Path -LiteralPath (Join-Path $PSScriptRoot 'install.ps1')) -and
          (Test-Path -LiteralPath (Join-Path $PSScriptRoot 'lib\Common.ps1'))) {
    $toolMode = 'local'   # clone do repositorio: usa os arquivos locais
}

if ($toolMode -eq 'bootstrap') {
    # Comando do README: instala (ou atualiza) o alloyctl e segue por ele.
    $tracked = if ($Ref) { $Ref } else { 'main' }
    $first = -not (Test-Path -LiteralPath (Join-Path $ToolDir 'alloy.ps1'))
    $sha = Resolve-ToolSha $tracked
    if ($sha -and (Install-Tool $tracked $sha)) {
        if ($first) {
            Write-ToolLog "comando instalado em $ToolDir (acompanha $tracked). Em um novo terminal, use: alloyctl"
        }
        Invoke-Tool
        return
    }
    Write-ToolWarn 'nao foi possivel instalar o alloyctl; seguindo com arquivos temporarios.'
} elseif ($toolMode -eq 'installed') {
    $tracked = 'main'
    try { $tracked = ([IO.File]::ReadAllText((Join-Path $ToolDir 'ref'))).Trim() } catch { }
    if (-not (Test-ToolRef $tracked)) { $tracked = 'main' }
    $version = ''
    try { $version = ([IO.File]::ReadAllText((Join-Path $ToolDir 'version'))).Trim() } catch { }
    # -Ref diferente troca a branch acompanhada; so vale se a atualizacao der certo.
    $short = $version.Substring(0, [Math]::Min(7, $version.Length))
    $wanted = $tracked
    $force = $false
    if ($Ref -and $Ref -ne $tracked) { $wanted = $Ref; $force = $true }
    if (-not $NoUpdate -or $force) {
        $sha = Resolve-ToolSha $wanted
        if (-not $sha) {
            Write-ToolWarn "sem atualizacao (GitHub inacessivel ou ref '$wanted' inexistente); usando $tracked @ $short."
        } elseif ($sha -ne $version -or $force) {
            if (Install-Tool $wanted $sha) {
                Write-ToolLog "atualizado: $short -> $($sha.Substring(0, 7)) ($wanted)"
                Invoke-Tool
                return
            }
            Write-ToolWarn "falha ao atualizar; usando a versao instalada ($tracked @ $short)."
        }
    }
    if ($version -cnotmatch '^[0-9a-f]{40}$') { throw "$ToolDir\version invalido; rode o comando do README." }
}

# ------------------------------------------------------------------ bootstrap
$workDir = $null
switch ($toolMode) {
    'installed' {
        # Tudo o que for baixado daqui em diante vem do mesmo commit.
        $env:ALLOY_REF = $version
        $env:ALLOYCTL_REF = $tracked
        $script:LocalMode = $false
        $src = $ToolDir
    }
    'local' {
        $env:ALLOY_REF = if ($Ref) { $Ref } else { 'main' }
        $script:LocalMode = $true
        $src = $PSScriptRoot
    }
    default {
        $env:ALLOY_REF = if ($Ref) { $Ref } else { 'main' }
        $script:LocalMode = $false
        $workDir = Join-Path $env:TEMP ('alloy-cli-' + [guid]::NewGuid().ToString('N'))
        $src = $workDir
    }
}
$env:ALLOYCTL_MODE = $toolMode

try {
    if ($workDir) {
        New-Item -ItemType Directory -Path (Join-Path $workDir 'lib') -Force | Out-Null
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        try {
            Invoke-WebRequest -UseBasicParsing -OutFile (Join-Path $workDir 'lib\Common.ps1') `
                -Uri "https://raw.githubusercontent.com/$ToolRepo/$($env:ALLOY_REF)/$ToolRemoteDir/lib/Common.ps1"
        } catch {
            throw "Falha ao baixar as bibliotecas (ref $($env:ALLOY_REF)): $($_.Exception.Message)"
        }
    }
    . (Join-Path $src 'lib\Common.ps1')
    Save-RemoteFiles $src @('lib/State.ps1', 'lib/Ui.ps1')
    . (Join-Path $src 'lib\Ui.ps1')
    . (Join-Path $src 'lib\State.ps1')

    # -------------------------------------------------------------- operacoes
    # Os scripts filhos rodam com seus proprios controles de erro e rollback;
    # uma falha lanca excecao, tratada pelo menu ou repassada ao chamador.

    # Perfil efetivo: o pedido, ou o instalado/detectado (lib\State.ps1).
    function Resolve-Perfil([string]$Requested) {
        if ($Requested -and $Requested -ne 'auto') { return $Requested }
        return Get-AlloyPerfil
    }
    function Test-Estacao { (Get-AlloyPerfil) -eq 'estacao' }

    function Invoke-Credentials([hashtable]$Arguments = @{}) {
        Save-RemoteFiles $src @('setup-credentials.ps1')
        & (Join-Path $src 'setup-credentials.ps1') @Arguments
    }

    function Invoke-Installer([hashtable]$Arguments = @{}) {
        Save-RemoteFiles $src @('install.ps1', 'config.alloy', 'desktop.alloy')
        & (Join-Path $src 'install.ps1') @Arguments
    }

    function Invoke-Install([hashtable]$Arguments = @{}) {
        if (-not (Test-CredentialPresent)) {
            # Os tres arquivos com o mesmo cliente HTTP, antes da etapa 1.
            Save-RemoteFiles $src @('setup-credentials.ps1', 'install.ps1', 'config.alloy', 'desktop.alloy')
            Write-UiSection 'ETAPA 1/2 - CREDENCIAL'
            Invoke-Credentials @{ Perfil = (Resolve-Perfil $Arguments.Perfil) }
            Write-UiSection 'ETAPA 2/2 - INSTALACAO'
        }
        Invoke-Installer $Arguments
    }

    function Invoke-SetupCredentials {
        if (Test-CredentialPresent) { throw 'Credencial ja existe. Use "rotate" para substituir.' }
        Invoke-Credentials @{ Perfil = (Resolve-Perfil $Perfil) }
    }

    function Invoke-Check {
        if (-not (Test-CredentialPresent)) { throw 'Nenhuma credencial gravada.' }
        Invoke-Credentials @{ Check = $true }
    }

    function Invoke-Rotate {
        if (-not (Test-CredentialPresent)) { throw 'Nenhuma credencial gravada; use o setup de credencial.' }
        Invoke-Credentials @{ Rotate = $true; Perfil = (Get-AlloyPerfil) }
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
        if ((Test-Estacao) -and @($Selection | Where-Object { $_ -ne 'none' }).Count -gt 0) {
            throw 'Modulos opcionais nao se aplicam ao perfil estacao.'
        }
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

    # A limpeza completa remove tambem o alloyctl: nada mais a executar.
    function Test-ToolRemoved {
        return ($toolMode -eq 'installed') -and -not (Test-Path -LiteralPath (Join-Path $ToolDir 'alloy.ps1'))
    }

    function Invoke-ToolVersion {
        if ($toolMode -ne 'installed') {
            throw 'alloyctl nao instalado; execute o comando do README (sem -NoUpdate) para instalar.'
        }
        Write-Ok "alloyctl $tracked @ $($version.Substring(0, 7)) ($ToolCmd)"
    }

    function Get-ReopenHint {
        if ($toolMode -eq 'installed') { return 'execute: alloyctl' }
        return 'execute o mesmo comando.'
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
        $chosen = Resolve-Perfil $Perfil
        Write-Host '  Primeira instalacao nesta maquina.'
        Write-Host ''
        if ($Perfil -eq 'auto') {
            Write-UiText '  Perfil detectado: ' 'White' -NoNewline
            Write-Host $chosen
            $answer = (Read-Host '  Perfil [S]ervidor ou [E]stacao (Enter mantem o detectado)').Trim()
            if ($answer -match '^(s|servidor)$') { $chosen = 'servidor' }
            elseif ($answer -match '^(e|estacao)$') { $chosen = 'estacao' }
        }
        if ($chosen -eq 'estacao') {
            Write-Host '  Estacao: maquina descartavel, sem alertas, fora dos dashboards de servidores.'
        }
        Write-Host ''
        $account = if ($chosen -eq 'estacao') { 'conta compartilhada alloy-estacoes' } else { 'conta alloy-<hostname>' }
        Write-UiText '  [1/2] Credencial' 'White' -NoNewline
        Write-Host "   $account + senha de aplicativo,"
        Write-Host '                     validada (OAuth2 + Loki) antes de gravar'
        Write-UiText '  [2/2] Instalacao' 'White' -NoNewline
        Write-Host '   Alloy + configuracao, com validacao e rollback'
        Write-Host ''
        if (-not (Confirm-Choice '  Continuar?')) { Write-Log 'Cancelado; nada foi alterado.'; return }
        Invoke-Install @{ Perfil = $chosen }
        Write-Host ''
        $script:LastStatus = 'ok'
        $script:LastAction = "Primeira instalacao - concluida ($(Get-Date -Format 'HH:mm'))"
        Show-AlloyHeader
        Write-Host "  Para gerenciar esta maquina depois, $(Get-ReopenHint)"
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
            # Estacao: modulos opcionais e heartbeat so para remover o que ja existir.
            $estacao = Test-Estacao
            $modulesActive = (Test-HyperVModule) -or (Test-SqlAnywhereModule)
            $label2 = 'Modulos opcionais'; $color2 = ''
            if ($estacao -and -not $modulesActive) { $label2 = 'Modulos (so servidor)'; $color2 = 'DarkGray' }

            Clear-UiScreen
            Show-AlloyHeader
            Write-UiColumns 'INSTALACAO' 'White' 'CREDENCIAL' 'White'
            Write-UiColumns " [1] $label1" $color1 ' [4] Testar' ''
            Write-UiColumns " [2] $label2" $color2 " [5] $label5" ''
            Write-UiColumns ' [3] Atualizar Alloy' '' '' ''
            Write-Host ''
            Write-UiColumns 'DIAGNOSTICO' 'White' 'REMOCAO' 'White'
            $label9 = if (Test-HeartbeatConfigured) { 'Heartbeat' } else { 'Configurar heartbeat' }
            $color9 = ''
            if ($estacao -and -not (Test-HeartbeatConfigured)) { $label9 = 'Heartbeat (so servidor)'; $color9 = 'DarkGray' }
            Write-UiColumns ' [6] Ver diagnostico' '' ' [7] Desinstalar' 'Red'
            Write-UiColumns " [9] $label9" $color9 ' [8] Limpeza completa' 'Red'
            Write-UiRule '-'
            $prompt = if ($default) { "Tecle a opcao (Enter = $default, 0 sai)" } else { 'Tecle a opcao (0 sai)' }
            $choice = Read-UiKey $prompt
            if ($choice -eq '') { $choice = $default }
            switch ($choice) {
                '1' { Invoke-Screen $label1 { Invoke-Install } }
                '2' {
                    if ($estacao -and -not $modulesActive) {
                        Invoke-Screen 'Modulos opcionais' { throw 'Modulos opcionais nao se aplicam ao perfil estacao.' }
                    } else { Show-ModulesMenu }
                }
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
                '8' {
                    Invoke-Screen 'Limpeza completa' { Invoke-Uninstall @{ Purge = $true } }
                    if (Test-ToolRemoved) {
                        Write-Log 'alloyctl removido. Para instalar de novo, use o comando do README.'
                        return
                    }
                }
                '9' {
                    if (Test-HeartbeatConfigured) { Show-HeartbeatMenu }
                    else { Invoke-Screen 'Configurar heartbeat' { Invoke-Heartbeat } }
                }
                { $_ -in @('0', 'q', 'Q') } {
                    Clear-UiScreen
                    Show-AlloySummary
                    Write-Host "  Para abrir o menu de novo, $(Get-ReopenHint)"
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
            $installArgs = @{ Modules = $Modules; Perfil = $Perfil }
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
        'update' { Invoke-ToolVersion }
    }
} finally {
    if ($script:HttpClient) { $script:HttpClient.Dispose() }
    if ($script:ToolHttp) { $script:ToolHttp.Dispose() }
    if ($workDir) { Remove-Item -LiteralPath $workDir -Recurse -Force -ErrorAction SilentlyContinue }
    if ($Elevated -and -not [Console]::IsInputRedirected) {
        Write-Host ''
        [void](Read-Host '  Enter para fechar esta janela')
    }
}
