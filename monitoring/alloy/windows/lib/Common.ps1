# Funcoes compartilhadas por alloy.ps1 e uninstall.ps1 (carregar com ". ").
# Constantes, saida, confirmacoes e download via raw.
# Manter os .ps1 em ASCII: o Windows PowerShell 5.1 le arquivos sem BOM como ANSI.

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
$SqlAnywhereFile = Join-Path $ConfigDir 'sqlanywhere.alloy'
# Inventario de VMs do modulo Hyper-V (ver install.ps1).
$LogDir            = Join-Path $Base 'logs'
$InventoryOutput   = Join-Path $Base 'textfile\hypervisor\hypervisor.prom'
$InventoryTaskPath = '\GrafanaLabs\'
$InventoryTaskName = 'Alloy Hypervisor Inventory'
# Coletor do modulo SQL Anywhere (ver install.ps1).
$SqlState          = Join-Path $DataDir 'sqlanywhere'
$SqlOutput         = Join-Path $Base 'textfile\sqlanywhere\sqlanywhere.prom'
$SqlTaskPath       = '\GrafanaLabs\'
$SqlTaskName       = 'Alloy SQL Anywhere'
# Heartbeat opcional (Uptime Kuma + Loki), ver heartbeat-setup.ps1.
$HeartbeatDir      = Join-Path $Base 'heartbeat'
$HeartbeatUrlFile  = Join-Path $HeartbeatDir 'kuma-url'
$HeartbeatScript   = Join-Path $HeartbeatDir 'heartbeat.ps1'
$HeartbeatLast     = Join-Path $HeartbeatDir 'last.json'
$HeartbeatLogDir   = Join-Path $HeartbeatDir 'logs'
$HeartbeatTaskPath = '\GrafanaLabs\'
$HeartbeatTaskName = 'Alloy Heartbeat'
$UninstallKeys = @(
    'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
    'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*'
)
# Links do diagnostico. Datasource por nome ou UID, como cadastrado no Grafana.
$GrafanaUrl        = 'https://mon.assessoriatech.com/grafana'
$GrafanaDsMetrics  = 'Prometheus'
$GrafanaDsLogs     = 'Loki'

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

# Entrada do Alloy em "Programas e Recursos" (versao e desinstalador).
function Get-AlloyUninstallEntry {
    Get-ItemProperty -Path $UninstallKeys -ErrorAction SilentlyContinue |
        Where-Object { $_.DisplayName -like '*Alloy*' -and $_.Publisher -like '*Grafana*' } |
        Select-Object -First 1
}
