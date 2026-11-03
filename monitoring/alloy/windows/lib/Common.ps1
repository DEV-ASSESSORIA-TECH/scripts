# Funcoes compartilhadas por alloy.ps1 e uninstall.ps1 (carregar com ". ").
# Constantes, saida, confirmacoes, download via raw e leitura do estado local.
# Manter este arquivo em ASCII: o Windows PowerShell 5.1 le .ps1 sem BOM como ANSI.

$RepoRaw     = 'https://raw.githubusercontent.com/DEV-ASSESSORIA-TECH/scripts'
$RemoteDir   = 'monitoring/alloy/windows'
$Base        = Join-Path $env:ProgramData 'GrafanaLabs\Alloy'
$Secret      = Join-Path $Base 'oauth-client-secret'
$ConfigDir   = Join-Path $Base 'config'
$DataDir     = Join-Path $Base 'data'
$BackupDir   = Join-Path $Base 'backups'
$InstallDir  = Join-Path $env:ProgramFiles 'GrafanaLabs\Alloy'
$Exe         = Join-Path $InstallDir 'alloy-windows-amd64.exe'
$Registry    = 'HKLM:\SOFTWARE\GrafanaLabs\Alloy'
$ServiceName = 'Alloy'
$ReadyUrl    = 'http://127.0.0.1:12345/-/ready'
$HyperVFile  = Join-Path $ConfigDir 'hyperv.alloy'

function Write-Log([string]$Text) { Write-Host "[Alloy] $Text" }
function Write-Ok([string]$Text) { Write-Host "[Alloy] $Text" -ForegroundColor Green }
function Write-Warn([string]$Text) { Write-Host "[Alloy] AVISO: $Text" -ForegroundColor Yellow }

function Confirm-Choice([string]$Prompt, [bool]$DefaultYes = $true) {
    $hint = if ($DefaultYes) { '[S/n]' } else { '[s/N]' }
    $answer = (Read-Host "$Prompt $hint").Trim()
    if (-not $answer) { return $DefaultYes }
    return $answer -match '^(s|sim|y|yes)$'
}

function Get-AlloyRef {
    $ref = if ($env:ALLOY_REF) { $env:ALLOY_REF } else { 'main' }
    if ($ref -notmatch '^[A-Za-z0-9][A-Za-z0-9._/-]*$' -or $ref.Contains('..')) {
        throw "Referencia invalida: $ref"
    }
    return $ref
}

# Cliente HTTP unico: as requisicoes reutilizam a mesma conexao TLS.
function Get-HttpClient {
    if (-not $script:HttpClient) {
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        Add-Type -AssemblyName System.Net.Http
        $script:HttpClient = [System.Net.Http.HttpClient]::new()
        $script:HttpClient.Timeout = [TimeSpan]::FromSeconds(30)
        $script:HttpClient.DefaultRequestHeaders.UserAgent.ParseAdd('AssessoriaTech-Alloy-Installer/1.0')
    }
    return $script:HttpClient
}

# Baixa do raw somente os arquivos ausentes em $Destination.
# Em modo local (clone do repositorio), um arquivo ausente e erro.
function Save-RemoteFiles([string]$Destination, [string[]]$Names) {
    $missing = @($Names | Where-Object {
        -not (Test-Path -LiteralPath (Join-Path $Destination $_) -PathType Leaf)
    })
    if ($missing.Count -eq 0) { return }
    if ($script:LocalMode) { throw "Arquivo ausente no repositorio local: $($missing -join ', ')" }
    $ref = Get-AlloyRef
    $http = Get-HttpClient
    foreach ($name in $missing) {
        $target = Join-Path $Destination ($name -replace '/', '\')
        $parent = Split-Path -Parent $target
        if (-not (Test-Path -LiteralPath $parent)) { New-Item -ItemType Directory -Path $parent -Force | Out-Null }
        $response = $http.GetAsync("$RepoRaw/$ref/$RemoteDir/$name").GetAwaiter().GetResult()
        try {
            if (-not $response.IsSuccessStatusCode) {
                throw "Falha ao baixar $name (HTTP $([int]$response.StatusCode), ref $ref)."
            }
            $bytes = $response.Content.ReadAsByteArrayAsync().GetAwaiter().GetResult()
            if ($bytes.Length -eq 0) { throw "Download vazio: $name" }
            [IO.File]::WriteAllBytes($target, $bytes)
        } finally {
            $response.Dispose()
        }
    }
}

# Nome DNS em minusculas, o mesmo usado pelo config.alloy (constants.hostname).
function Get-AlloyHostName {
    $name = $null
    try { $name = (Get-CimInstance -ClassName Win32_ComputerSystem -ErrorAction Stop).DNSHostName } catch { }
    if ([string]::IsNullOrWhiteSpace($name)) { $name = $env:COMPUTERNAME }
    return $name.Trim().ToLowerInvariant()
}

function Get-AlloyService { Get-Service -Name $ServiceName -ErrorAction SilentlyContinue }
function Test-AlloyInstalled { (Test-Path -LiteralPath $Exe -PathType Leaf) -and ($null -ne (Get-AlloyService)) }
function Test-AlloyRunning { $svc = Get-AlloyService; ($null -ne $svc) -and ($svc.Status -eq 'Running') }
function Test-CredentialPresent {
    if (-not (Test-Path -LiteralPath $Secret -PathType Leaf)) { return $false }
    $item = Get-Item -LiteralPath $Secret -Force
    return ($item.Length -gt 0) -and -not ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)
}
function Test-HyperVModule { Test-Path -LiteralPath $HyperVFile -PathType Leaf }
function Test-FirstRun { -not (Test-CredentialPresent) -and -not (Test-AlloyInstalled) }

function Get-AlloyVersion {
    if (-not (Test-Path -LiteralPath $Exe -PathType Leaf)) { return $null }
    $version = (Get-Item -LiteralPath $Exe).VersionInfo.ProductVersion
    if ($version) { return $version.Trim() }
    return '?'
}

function Test-AlloyReady {
    try {
        $resp = Invoke-WebRequest -Uri $ReadyUrl -UseBasicParsing -TimeoutSec 2
        return $resp.StatusCode -eq 200
    } catch { return $false }
}

function Wait-AlloyReady {
    for ($i = 0; $i -lt 15; $i++) {
        if ((Test-AlloyRunning) -and (Test-AlloyReady)) { return $true }
        Start-Sleep -Seconds 1
    }
    return $false
}

# Conta de servico gravada na credencial. Nunca devolve a senha.
function Get-CredentialUser {
    if (-not (Test-CredentialPresent)) { return $null }
    try {
        $raw = [IO.File]::ReadAllText($Secret, [Text.Encoding]::ASCII).Trim()
        $decoded = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($raw))
        $user = $decoded.Split(':')[0]
        $decoded = $null
        if ($user -cmatch '^alloy-[a-z0-9][a-z0-9-]*$') { return $user }
    } catch { }
    return $null
}

function Show-AlloyHeader {
    $origin = if ($script:LocalMode) { 'arquivos locais' } else { 'ref ' + (Get-AlloyRef) }
    Write-Host ''
    Write-Host " Alloy - $(Get-AlloyHostName)  " -NoNewline
    Write-Host "($origin)" -ForegroundColor DarkGray
    Write-Host ' Servico ..... ' -NoNewline
    if (-not (Test-AlloyInstalled)) {
        Write-Host 'nao instalado' -ForegroundColor DarkGray
    } elseif (Test-AlloyRunning) {
        if (Test-AlloyReady) {
            Write-Host 'ativo, pronto' -ForegroundColor Green -NoNewline
        } else {
            Write-Host 'ativo, nao pronto' -ForegroundColor Yellow -NoNewline
        }
        Write-Host " (v$(Get-AlloyVersion))"
    } else {
        Write-Host 'parado' -ForegroundColor Red -NoNewline
        Write-Host " (v$(Get-AlloyVersion))"
    }
    Write-Host ' Credencial .. ' -NoNewline
    if (Test-CredentialPresent) {
        $user = Get-CredentialUser
        if (-not $user) { $user = 'conta ilegivel' }
        Write-Host 'presente' -ForegroundColor Green -NoNewline
        Write-Host " ($user)"
    } else {
        Write-Host 'ausente' -ForegroundColor Yellow
    }
    $modules = 'Windows'
    if (Test-HyperVModule) { $modules += ' + Hyper-V' }
    Write-Host " Modulos ..... $modules"
    Write-Host ''
}

# Teste de alcance: qualquer resposta HTTP comprova DNS, rota e TLS.
function Test-Endpoint([string]$Url) {
    $http = Get-HttpClient
    $label = $Url.PadRight(36)
    try {
        $request = [System.Net.Http.HttpRequestMessage]::new([System.Net.Http.HttpMethod]::Head, $Url)
        $response = $http.SendAsync($request).GetAwaiter().GetResult()
        Write-Host "   $label " -NoNewline
        Write-Host 'OK' -ForegroundColor Green -NoNewline
        Write-Host " (HTTP $([int]$response.StatusCode))"
        $response.Dispose()
    } catch {
        Write-Host "   $label " -NoNewline
        Write-Host 'SEM RESPOSTA' -ForegroundColor Red -NoNewline
        Write-Host ' (DNS, rota ou TLS)'
    }
}

function Show-AlloyDiagnostics {
    $hostName = Get-AlloyHostName
    Show-AlloyHeader
    $svc = Get-AlloyService
    if ($svc) {
        Write-Host '-- Servico'
        $svc | Format-List Name, Status, StartType | Out-String | Write-Host
        Write-Host '-- Ultimos eventos do Alloy (Application)'
        try {
            Get-WinEvent -FilterHashtable @{ LogName = 'Application'; ProviderName = 'Alloy' } -MaxEvents 20 -ErrorAction Stop |
                Format-Table TimeCreated, LevelDisplayName, Message -AutoSize -Wrap | Out-String -Width 200 | Write-Host
        } catch {
            Write-Host '   Nenhum evento encontrado.'
        }
    }
    Write-Host '-- Conectividade'
    Test-Endpoint 'https://auth.assessoriatech.com/'
    Test-Endpoint 'https://mon.assessoriatech.com/'
    Write-Host ''
    Write-Host '-- Consultas no Grafana (Explore)'
    Write-Host "   Prometheus: up{job=`"integrations/windows`",host=`"$hostName`"}"
    Write-Host "   Loki:       {job=`"windows-eventlog`",host=`"$hostName`"}"
    if (Test-HyperVModule) {
        Write-Host "   Prometheus: up{job=`"integrations/hyperv`",host=`"$hostName`"}"
        Write-Host "   Loki:       {job=`"hyperv-eventlog`",host=`"$hostName`"}"
    }
    Write-Host ''
    Write-Host '   Para validar a credencial de ponta a ponta, use "Testar credencial".'
}
