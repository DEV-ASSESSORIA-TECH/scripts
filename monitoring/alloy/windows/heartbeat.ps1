#Requires -Version 5.1
<#
.SYNOPSIS
Heartbeat do host: estado local do Alloy para o Loki e batida no Uptime Kuma.

.DESCRIPTION
Executado a cada minuto, como SYSTEM, pela tarefa agendada
"\GrafanaLabs\Alloy Heartbeat", criada pelo heartbeat-setup.ps1 (menu [9]).
Nao depende do processo do Alloy:

  1. Le o estado local: servico, /-/ready, /-/healthy e o /metrics do Alloy
     (atraso do remote_write e contadores do loki.write).
  2. Envia uma linha logfmt ao Loki (job alloy-heartbeat), com a credencial
     OAuth2 do Alloy. Sem credencial, esta etapa e pulada.
  3. Faz o push no Uptime Kuma (sempre status=up), com um resumo curto no msg.

Contrato do stream: grafana-dashboards, contracts/loki/heartbeat.yml.
Resultado da ultima execucao em heartbeat\last.json; uma linha por execucao em
heartbeat\logs\, com retencao de -LogRetentionDays dias. A URL do Kuma nunca
e gravada em log.
Codigo de saida: 0 quando o Kuma confirmou a batida, 1 caso contrario.
Manter este arquivo em ASCII: o Windows PowerShell 5.1 le arquivos sem BOM como ANSI.

.PARAMETER KumaUrl
URL de push a testar no lugar da gravada (configuracao, antes de gravar).

.PARAMETER StateDir
Diretorio de estado (last.json, token e logs). Padrao: heartbeat\ do Alloy.

.PARAMETER Show
Mostra o resultado no console (teste manual).
#>
[CmdletBinding()]
param(
    [string]$Root = (Join-Path $env:ProgramData 'GrafanaLabs\Alloy'),
    [string]$KumaUrl,
    [string]$StateDir,
    [switch]$Show,
    [ValidateRange(1, 365)]
    [int]$LogRetentionDays = 14
)

$ErrorActionPreference = 'Stop'
$HeartbeatDir = Join-Path $Root 'heartbeat'
if (-not $StateDir) { $StateDir = $HeartbeatDir }
$UrlFile     = Join-Path $HeartbeatDir 'kuma-url'
$Secret      = Join-Path $Root 'oauth-client-secret'
$LastFile    = Join-Path $StateDir 'last.json'
$TokenFile   = Join-Path $StateDir 'token.json'
$LogDir      = Join-Path $StateDir 'logs'
$ClientId    = '1T4SNZ8iDuvM18ZIB9fSc109ZZVglsXBtLxeU4ng'
$TokenUrl    = 'https://auth.assessoriatech.com/application/o/token/'
$LokiUrl     = 'https://mon.assessoriatech.com/loki/api/v1/push'
$AlloyHttp   = 'http://127.0.0.1:12345'
$ServiceName = 'Alloy'
$UserAgent   = 'AssessoriaTech-Alloy-Heartbeat/1.0'
# Acima disso (segundos sem amostra enviada), o Alloy e considerado degradado.
$LagLimit    = 300
$Invariant   = [Globalization.CultureInfo]::InvariantCulture
$Utf8        = New-Object System.Text.UTF8Encoding($false)

[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
Add-Type -AssemblyName System.Net.Http

# Local: sem proxy e timeout curto. Remoto: proxy do sistema, se houver.
function New-Client([int]$Seconds, [bool]$UseProxy) {
    $handler = New-Object System.Net.Http.HttpClientHandler
    $handler.AllowAutoRedirect = $false
    $handler.UseProxy = $UseProxy
    $client = New-Object System.Net.Http.HttpClient($handler)
    $client.Timeout = [TimeSpan]::FromSeconds($Seconds)
    $client.DefaultRequestHeaders.UserAgent.ParseAdd($UserAgent)
    return $client
}
$script:Local = New-Client 3 $false
$script:Remote = New-Client 10 $true

# @{ Status = codigo HTTP (0 = sem resposta); Body = texto }
function Invoke-Http([System.Net.Http.HttpClient]$Client, [System.Net.Http.HttpRequestMessage]$Request) {
    try {
        $response = $Client.SendAsync($Request).GetAwaiter().GetResult()
        try {
            $body = $response.Content.ReadAsStringAsync().GetAwaiter().GetResult()
            return @{ Status = [int]$response.StatusCode; Body = $body }
        } finally { $response.Dispose() }
    } catch {
        return @{ Status = 0; Body = '' }
    } finally { $Request.Dispose() }
}

function Get-Local([string]$Path) {
    Invoke-Http $script:Local ([System.Net.Http.HttpRequestMessage]::new([System.Net.Http.HttpMethod]::Get, $AlloyHttp + $Path))
}

function Write-RunLog([string]$Text) {
    try {
        if (-not (Test-Path -LiteralPath $LogDir -PathType Container)) {
            New-Item -ItemType Directory -Path $LogDir -Force | Out-Null
        }
        $file = Join-Path $LogDir ('heartbeat-' + (Get-Date -Format 'yyyyMMdd') + '.log')
        [IO.File]::AppendAllText($file, (Get-Date -Format 'yyyy-MM-dd HH:mm:ss') + '  ' + $Text + "`r`n", $Utf8)
        $limit = (Get-Date).AddDays(-$LogRetentionDays)
        Get-ChildItem -LiteralPath $LogDir -Filter 'heartbeat-*.log' -File -ErrorAction SilentlyContinue |
            Where-Object { $_.LastWriteTime -lt $limit } |
            Remove-Item -Force -ErrorAction SilentlyContinue
    } catch { }
}

# Escrita atomica de um arquivo pequeno de estado.
function Write-StateFile([string]$Path, [string]$Text) {
    $dir = Split-Path -Parent $Path
    if (-not (Test-Path -LiteralPath $dir -PathType Container)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    $temp = $Path + '.tmp'
    [IO.File]::WriteAllText($temp, $Text, $Utf8)
    if (Test-Path -LiteralPath $Path -PathType Leaf) {
        [IO.File]::Replace($temp, $Path, [NullString]::Value)
    } else {
        [IO.File]::Move($temp, $Path)
    }
}

# ------------------------------------------------------------- estado local

function Format-Number([double]$Value) { ([Math]::Round($Value)).ToString('0', $Invariant) }

# Soma (ou maximo) das amostras de uma metrica no texto do /metrics.
function Get-MetricValue([string[]]$Lines, [string]$Name, [switch]$Max) {
    $found = $false
    $total = 0.0
    $pattern = '^' + [regex]::Escape($Name) + '(\{[^}]*\})?\s+(\S+)'
    foreach ($line in $Lines) {
        if (-not $line.StartsWith($Name)) { continue }
        $m = [regex]::Match($line, $pattern)
        if (-not $m.Success) { continue }
        $value = 0.0
        if (-not [double]::TryParse($m.Groups[2].Value, [Globalization.NumberStyles]::Float, $Invariant, [ref]$value)) { continue }
        if ([double]::IsNaN($value)) { continue }
        if ($Max) {
            if (-not $found -or $value -gt $total) { $total = $value }
        } else {
            $total += $value
        }
        $found = $true
    }
    if ($found) { return $total }
    return $null
}

function Get-AlloyVersion {
    $keys = @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*'
    )
    $entry = Get-ItemProperty -Path $keys -ErrorAction SilentlyContinue |
        Where-Object { $_.DisplayName -like '*Alloy*' -and $_.Publisher -like '*Grafana*' } |
        Select-Object -First 1
    if ($entry -and $entry.DisplayVersion) { return 'v' + (([string]$entry.DisplayVersion).Trim() -replace '^v', '') }
    return $null
}

# Campos em ordem: viram a linha logfmt do Loki.
function Get-AlloyState {
    $state = [ordered]@{ alloy = ''; service = '' }
    $svc = Get-Service -Name $ServiceName -ErrorAction SilentlyContinue
    if (-not $svc) {
        $state.alloy = 'ausente'
        $state.service = 'absent'
        return $state
    }
    $version = Get-AlloyVersion
    if ([string]$svc.Status -ne 'Running') {
        $state.alloy = 'parado'
        $state.service = 'stopped'
        if ($version) { $state.version = $version }
        return $state
    }
    $state.service = 'running'
    $ready = (Get-Local '/-/ready').Status -eq 200
    $state.ready = if ($ready) { '1' } else { '0' }

    $healthy = $null
    $health = Get-Local '/-/healthy'
    if ($health.Status -eq 200) { $healthy = $true; $state.healthy = '1' }
    elseif ($health.Status -eq 500) {
        $healthy = $false
        $state.healthy = '0'
        $list = ($health.Body -replace '(?s)^.*unhealthy components:\s*', '') -replace '[\r\n]+', ' '
        $list = ($list -replace '[^A-Za-z0-9_.,/ -]', '').Trim() -replace '\s*,\s*', ','
        if ($list.Length -gt 200) { $list = $list.Substring(0, 200) }
        if ($list) { $state.unhealthy = $list }
    }

    $lag = $null
    $metrics = Get-Local '/metrics'
    if ($metrics.Status -eq 200) {
        $lines = $metrics.Body -split "`n"
        $sent = Get-MetricValue $lines 'prometheus_remote_storage_queue_highest_sent_timestamp_seconds' -Max
        if ($null -ne $sent -and $sent -gt 0) {
            $lag = [Math]::Max(0, [DateTimeOffset]::UtcNow.ToUnixTimeSeconds() - $sent)
            $state.metrics_lag_s = Format-Number $lag
        }
        foreach ($pair in @(
            @('samples_failed', 'prometheus_remote_storage_samples_failed_total'),
            @('logs_sent', 'loki_write_sent_entries_total'),
            @('logs_dropped', 'loki_write_dropped_entries_total'))) {
            $value = Get-MetricValue $lines $pair[1]
            if ($null -ne $value) { $state[$pair[0]] = Format-Number $value }
        }
    }
    if ($version) { $state.version = $version }

    if (-not $ready) { $state.alloy = 'nao_pronto' }
    elseif ($healthy -eq $false -or ($null -ne $lag -and $lag -gt $LagLimit)) { $state.alloy = 'degradado' }
    else { $state.alloy = 'ok' }
    return $state
}

function ConvertTo-Logfmt($State) {
    $parts = foreach ($key in $State.Keys) {
        $value = [string]$State[$key]
        if ($value -match '^[A-Za-z0-9_.:/-]+$') { "$key=$value" } else { $key + '="' + ($value -replace '["\\]', '') + '"' }
    }
    return ($parts -join ' ')
}

# ------------------------------------------------------------------- Loki

function Get-HostName {
    $name = $null
    try { $name = (Get-CimInstance -ClassName Win32_ComputerSystem -ErrorAction Stop).DNSHostName } catch { }
    if ([string]::IsNullOrWhiteSpace($name)) { $name = $env:COMPUTERNAME }
    return $name.Trim().ToLowerInvariant()
}

# Token OAuth2 reaproveitado ate 60s antes de expirar (token.json, mesma ACL
# da credencial). Devolve @{ Token; Code } com Code = 'ok' ou o motivo.
function Get-AccessToken([switch]$Fresh) {
    if (-not $Fresh -and (Test-Path -LiteralPath $TokenFile -PathType Leaf)) {
        try {
            $cached = [IO.File]::ReadAllText($TokenFile, $Utf8) | ConvertFrom-Json
            if ($cached.token -and [long]$cached.expires -gt ([DateTimeOffset]::UtcNow.ToUnixTimeSeconds() + 60)) {
                return @{ Token = [string]$cached.token; Code = 'ok' }
            }
        } catch { }
    }
    $credential = [IO.File]::ReadAllText($Secret, [Text.Encoding]::ASCII).Trim()
    $form = New-Object 'System.Collections.Generic.List[System.Collections.Generic.KeyValuePair[string,string]]'
    $form.Add((New-Object 'System.Collections.Generic.KeyValuePair[string,string]' 'grant_type', 'client_credentials'))
    $form.Add((New-Object 'System.Collections.Generic.KeyValuePair[string,string]' 'client_id', $ClientId))
    $form.Add((New-Object 'System.Collections.Generic.KeyValuePair[string,string]' 'client_secret', $credential))
    $form.Add((New-Object 'System.Collections.Generic.KeyValuePair[string,string]' 'scope', 'profile'))
    $credential = $null
    $request = [System.Net.Http.HttpRequestMessage]::new([System.Net.Http.HttpMethod]::Post, $TokenUrl)
    $request.Content = [System.Net.Http.FormUrlEncodedContent]::new($form)
    $result = Invoke-Http $script:Remote $request
    if ($result.Status -eq 0) { return @{ Token = $null; Code = 'token_sem_resposta' } }
    if ($result.Status -ne 200) { return @{ Token = $null; Code = "token_$($result.Status)" } }
    try { $data = $result.Body | ConvertFrom-Json } catch { return @{ Token = $null; Code = 'token_invalido' } }
    if (-not ($data.access_token -is [string]) -or -not $data.access_token) { return @{ Token = $null; Code = 'token_invalido' } }
    $seconds = 300
    if ($data.expires_in -as [int]) { $seconds = [int]$data.expires_in }
    try {
        $cache = [ordered]@{ token = $data.access_token; expires = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds() + $seconds }
        Write-StateFile $TokenFile (ConvertTo-Json -InputObject $cache -Compress)
    } catch { }
    return @{ Token = [string]$data.access_token; Code = 'ok' }
}

function Send-Loki([string]$HostName, [string]$Line) {
    if (-not (Test-Path -LiteralPath $Secret -PathType Leaf)) { return 'sem_credencial' }
    $ns = ([DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds() * 1000000).ToString($Invariant)
    $payload = @{
        streams = @(@{
            stream = [ordered]@{ job = 'alloy-heartbeat'; host = $HostName; os = 'windows' }
            values = @(, @($ns, $Line))
        })
    } | ConvertTo-Json -Depth 6 -Compress
    foreach ($fresh in @($false, $true)) {
        $token = Get-AccessToken -Fresh:$fresh
        if (-not $token.Token) { return $token.Code }
        $request = [System.Net.Http.HttpRequestMessage]::new([System.Net.Http.HttpMethod]::Post, $LokiUrl)
        $request.Content = [System.Net.Http.StringContent]::new($payload, [Text.Encoding]::UTF8, 'application/json')
        $request.Headers.Authorization = [System.Net.Http.Headers.AuthenticationHeaderValue]::new('Bearer', $token.Token)
        $result = Invoke-Http $script:Remote $request
        # 401 com token do cache: pede um novo e tenta uma vez mais.
        if ($result.Status -eq 401 -and -not $fresh) { continue }
        if ($result.Status -eq 0) { return 'sem_resposta' }
        return [string]$result.Status
    }
}

# ------------------------------------------------------------------- Kuma

function Get-KumaUrl {
    $url = if ($KumaUrl) { $KumaUrl } else { [IO.File]::ReadAllText($UrlFile, $Utf8) }
    $url = ($url.Trim() -split '[?#]')[0]
    if ($url -notmatch '^https://[A-Za-z0-9.-]+(:\d+)?(/[A-Za-z0-9._~-]+)*/api/push/[A-Za-z0-9_-]{8,128}$') {
        throw 'URL de push invalida.'
    }
    return $url
}

# Devolve o codigo HTTP como texto ('200', '404'...), 'sem_resposta' ou
# 'resposta_invalida' (200 sem {"ok":true}, ex. pagina da Cloudflare).
function Send-Kuma([string]$Url, [string]$Message) {
    $full = $Url + '?status=up&msg=' + [Uri]::EscapeDataString($Message) + '&ping='
    $result = Invoke-Http $script:Remote ([System.Net.Http.HttpRequestMessage]::new([System.Net.Http.HttpMethod]::Get, $full))
    if ($result.Status -eq 0) { return 'sem_resposta' }
    if ($result.Status -eq 200 -and $result.Body -notmatch '"ok"\s*:\s*true') { return 'resposta_invalida' }
    return [string]$result.Status
}

# ------------------------------------------------------------------ execucao

$kuma = 'nao_enviado'
$loki = 'nao_enviado'
$line = ''
$state = $null
try {
    $state = Get-AlloyState
    $line = ConvertTo-Logfmt $state
    $loki = Send-Loki (Get-HostName) $line

    $summary = 'alloy=' + $state.alloy
    if ($state.Contains('metrics_lag_s')) { $summary += ' lag=' + $state.metrics_lag_s + 's' }
    if ($state.Contains('unhealthy')) { $summary += ' unhealthy=' + $state.unhealthy }
    $summary += ' loki=' + $loki
    if ($state.Contains('version')) { $summary += ' ' + $state.version }
    $kuma = Send-Kuma (Get-KumaUrl) $summary
} catch {
    $kuma = 'erro: ' + ($_.Exception.Message -replace '[\r\n]+', ' ')
} finally {
    $script:Local.Dispose()
    $script:Remote.Dispose()
}

$alloyText = if ($state) { $state.alloy } else { '?' }
$last = [ordered]@{
    time_utc = [DateTimeOffset]::UtcNow.ToString('o', $Invariant)
    kuma     = $kuma
    loki     = $loki
    alloy    = $alloyText
    line     = $line
}
try { Write-StateFile $LastFile (ConvertTo-Json -InputObject $last -Compress) } catch { }
Write-RunLog "kuma=$kuma loki=$loki  $line"

if ($Show) {
    Write-Host "  Alloy        $line"
    Write-Host "  Loki         $loki"
    Write-Host "  Uptime Kuma  $kuma"
}
if ($kuma -ne '200') { exit 1 }
exit 0
