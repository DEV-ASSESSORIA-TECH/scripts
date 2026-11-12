#Requires -Version 5.1
<#
.SYNOPSIS
Metricas do DB Connection Tester (DBCT) para o textfile collector do Alloy.

.DESCRIPTION
Executado como SYSTEM pela tarefa agendada "\GrafanaLabs\Alloy DBCT Collector"
(a cada 30 s), instalada pelo install.ps1 quando o modulo dbct esta ativo. Le a
execucao ativa do banco do DBCT pela propria CLI, so com comandos de consulta
(dbct run status e dbct history cycles, --format json, contrato formatVersion
1), processa apenas os ciclos novos desde a coleta anterior e gera
textfile\dbct\dbct.prom, lido pelo Alloy no job integrations/dbconnectiontester.
A execucao em si e do DBCT (por exemplo, dbct run ... --autostart); o modulo
nunca a inicia nem a altera.


  dbct_run_active                      execucao em andamento no banco (1 = sim)
  dbct_run_info                        execucao, perfil, destino e tipo (valor 1)
  dbct_cycles_total                    ciclos processados da execucao atual
  dbct_stage_checks_total              etapas executadas, por stage
  dbct_stage_failures_total            falhas, por stage e codigo de diagnostico
  dbct_stage_duration_seconds          histograma de duracao, por stage
  dbct_stage_duration_max_seconds      pior duracao entre esta coleta e a anterior
  dbct_stage_last_duration_seconds     duracao no ultimo ciclo
  dbct_stage_last_success              resultado do ultimo ciclo (1 = sucesso)
  dbct_last_cycle_timestamp_seconds    inicio do ultimo ciclo (Unix)
  dbct_autostart_*                     execucao automatica do DBCT neste banco
  dbct_collection_*                    saude da propria coleta

Contadores pertencem a execucao atual: numa execucao nova voltam a zero (o
Prometheus trata como reinicio do contador). Ciclos de uma execucao ja em
andamento ha mais de $CatchUpSeconds s quando o coletor a encontra pela primeira
vez nao sao reprocessados, para nao lancar o passado no horario atual.

Configuracao em data\dbct\ (so SYSTEM e Administradores):
  config.json      dbct (caminho do dbct.exe) e dataDir (pasta do data.db)
  state.json       posicao e contadores da coleta (recriado se ausente)

Logs diarios em logs\, com retencao de -LogRetentionDays dias.
Manter este arquivo em ASCII: o Windows PowerShell 5.1 le arquivos sem BOM como ANSI.
#>
[CmdletBinding()]
param(
    [string]$Root = (Join-Path $env:ProgramData 'GrafanaLabs\Alloy'),
    [ValidateRange(1, 365)]
    [int]$LogRetentionDays = 14
)

$ErrorActionPreference = 'Stop'
$Started = Get-Date
$Timer = [Diagnostics.Stopwatch]::StartNew()
$OutputDir = Join-Path $Root 'textfile\dbct'
$StateDir = Join-Path $Root 'data\dbct'
$LogDir = Join-Path $Root 'logs'
$OutFile = Join-Path $OutputDir 'dbct.prom'
$ConfigFile = Join-Path $StateDir 'config.json'
$StateFile = Join-Path $StateDir 'state.json'
$Invariant = [Globalization.CultureInfo]::InvariantCulture
$Utf8 = New-Object System.Text.UTF8Encoding($false)
# Ciclos por chamada e chamadas por coleta: limita o tempo da tarefa (25 s).
$PageSize = 200
$MaxPages = 10
$CatchUpSeconds = 120
# Limites do histograma, em segundos.
$Buckets = [double[]]@(0.005, 0.01, 0.025, 0.05, 0.1, 0.25, 0.5, 1, 2.5, 5, 10, 30)
$StageNames = @{
    Dns = 'dns'; Ping = 'ping'; Tcp = 'tcp'
    DatabaseConnect = 'database_connect'; DatabaseQuery = 'database_query'
}

$script:Metrics = [ordered]@{}

# ------------------------------------------------------------------ saida

function Write-CollectorLog([string]$Text) {
    try {
        if (-not (Test-Path -LiteralPath $LogDir -PathType Container)) { return }
        $file = Join-Path $LogDir ('dbct-collector-' + (Get-Date -Format 'yyyyMMdd') + '.log')
        $line = (Get-Date -Format 'yyyy-MM-dd HH:mm:ss') + '  ' + $Text
        [IO.File]::AppendAllText($file, $line + "`r`n", $Utf8)
    } catch { }
}

function Remove-OldLogs {
    try {
        $limit = (Get-Date).AddDays(-$LogRetentionDays)
        Get-ChildItem -LiteralPath $LogDir -Filter 'dbct-collector-*.log' -File -ErrorAction Stop |
            Where-Object { $_.LastWriteTime -lt $limit } |
            Remove-Item -Force -ErrorAction SilentlyContinue
    } catch { }
}

function ConvertTo-LabelValue($Value) {
    if ($null -eq $Value) { return '' }
    $text = [string]$Value
    return $text.Replace('\', '\\').Replace('"', '\"').Replace("`r", '').Replace("`n", '\n')
}

# Agrupa amostras por familia: o formato exige HELP/TYPE uma vez por nome.
# Sample permite nomes derivados (histograma: _bucket, _sum, _count).
function Add-Sample([string]$Family, [string]$Type, [string]$Help, $Labels, [double]$Value, [string]$Sample = '') {
    if (-not $script:Metrics.Contains($Family)) {
        $script:Metrics[$Family] = @{ Type = $Type; Help = $Help; Samples = New-Object System.Collections.Generic.List[string] }
    }
    $pairs = @()
    if ($Labels) {
        foreach ($key in @($Labels.Keys)) { $pairs += ('{0}="{1}"' -f $key, (ConvertTo-LabelValue $Labels[$key])) }
    }
    $labelText = if ($pairs.Count -gt 0) { '{' + ($pairs -join ',') + '}' } else { '' }
    $name = if ($Sample) { $Sample } else { $Family }
    $script:Metrics[$Family].Samples.Add($name + $labelText + ' ' + $Value.ToString('R', $Invariant))
}

# Mesma logica do sqlanywhere-collector.ps1: nova tentativa caso o Alloy esteja
# lendo o arquivo no instante da troca.
function Move-Replace([string]$Source, [string]$Target) {
    for ($i = 1; $i -le 5; $i++) {
        try {
            if (Test-Path -LiteralPath $Target -PathType Leaf) {
                [IO.File]::Replace($Source, $Target, [NullString]::Value)
            } else {
                [IO.File]::Move($Source, $Target)
            }
            return
        } catch {
            if ($i -eq 5) { throw }
            Start-Sleep -Milliseconds 300
        }
    }
}

# Escrita atomica (.tmp ignorado pelo coletor), LF e quebra de linha final.
function Save-PromFile {
    $builder = New-Object System.Text.StringBuilder
    foreach ($name in $script:Metrics.Keys) {
        $metric = $script:Metrics[$name]
        [void]$builder.Append('# HELP ' + $name + ' ' + $metric.Help + "`n")
        [void]$builder.Append('# TYPE ' + $name + ' ' + $metric.Type + "`n")
        foreach ($sample in $metric.Samples) { [void]$builder.Append($sample + "`n") }
    }
    $tmp = $OutFile + '.tmp'
    [IO.File]::WriteAllText($tmp, $builder.ToString(), $Utf8)
    Move-Replace $tmp $OutFile
}

# ------------------------------------------------------------------ DBCT

# Regras do Windows para argumentos: aspas quando ha espaco ou aspas, barras
# antes de aspas e no final duplicadas.
function ConvertTo-Argument([string]$Value) {
    if ($Value -and $Value -notmatch '[\s"]') { return $Value }
    $escaped = [regex]::Replace($Value, '(\\*)"', '$1$1\"')
    $escaped = [regex]::Replace($escaped, '(\\+)$', '$1$1')
    return '"' + $escaped + '"'
}

# Executa a CLI e devolve o campo data do envelope JSON. A CLI grava UTF-8
# quando a saida e redirecionada.
function Invoke-Dbct([string]$Exe, [string[]]$Arguments, [int]$TimeoutSeconds = 20) {
    $info = New-Object System.Diagnostics.ProcessStartInfo
    $info.FileName = $Exe
    $info.Arguments = (@($Arguments | ForEach-Object { ConvertTo-Argument $_ }) -join ' ')
    $info.UseShellExecute = $false
    $info.CreateNoWindow = $true
    $info.RedirectStandardOutput = $true
    $info.RedirectStandardError = $true
    $info.StandardOutputEncoding = $Utf8
    $info.StandardErrorEncoding = $Utf8
    $process = [Diagnostics.Process]::Start($info)
    try {
        $stdout = $process.StandardOutput.ReadToEndAsync()
        $stderr = $process.StandardError.ReadToEndAsync()
        if (-not $process.WaitForExit($TimeoutSeconds * 1000)) {
            try { $process.Kill() } catch { }
            throw "dbct $($Arguments[0]) $($Arguments[1]) excedeu ${TimeoutSeconds}s."
        }
        $process.WaitForExit()
        $output = $stdout.GetAwaiter().GetResult()
        $errorText = ($stderr.GetAwaiter().GetResult()).Trim()
        if ($process.ExitCode -ne 0) {
            throw "dbct $($Arguments[0]) $($Arguments[1]) retornou $($process.ExitCode): $errorText"
        }
        return ($output | ConvertFrom-Json).data
    } finally { $process.Dispose() }
}

# ConvertFrom-Json do 5.1 devolve PSCustomObject; o estado e alterado como hashtable.
function ConvertTo-Hashtable($Object) {
    if ($null -eq $Object) { return $null }
    if ($Object -is [Management.Automation.PSCustomObject]) {
        $table = @{}
        foreach ($property in $Object.PSObject.Properties) { $table[$property.Name] = ConvertTo-Hashtable $property.Value }
        return $table
    }
    if ($Object -is [Collections.IEnumerable] -and $Object -isnot [string]) {
        return , @($Object | ForEach-Object { ConvertTo-Hashtable $_ })
    }
    return $Object
}

function ConvertTo-UnixTime([string]$Text) {
    $parsed = [DateTimeOffset]::MinValue
    if (-not [DateTimeOffset]::TryParse($Text, $Invariant, [Globalization.DateTimeStyles]::None, [ref]$parsed)) { return $null }
    return [double]$parsed.ToUnixTimeMilliseconds() / 1000
}

function Read-Settings {
    if (-not (Test-Path -LiteralPath $ConfigFile -PathType Leaf)) { throw "Configuracao ausente: $ConfigFile" }
    $config = [IO.File]::ReadAllText($ConfigFile) | ConvertFrom-Json
    foreach ($field in @('dbct', 'dataDir')) {
        if ([string]::IsNullOrWhiteSpace([string]$config.$field)) { throw "Campo '$field' vazio em $ConfigFile" }
    }
    if (-not (Test-Path -LiteralPath $config.dbct -PathType Leaf)) { throw "dbct.exe nao encontrado: $($config.dbct)" }
    return $config
}

function New-State($Run) {
    $stages = @{}
    foreach ($name in $StageNames.Values) {
        $stages[$name] = @{ checks = 0; count = 0; sum = 0.0; buckets = ([double[]]::new($Buckets.Count + 1)); lastSeconds = $null; lastSuccess = $null }
    }
    return @{
        version = 1; runId = [string]$Run.runId; lastCycle = 0; cycles = 0; lastCycleTime = $null
        target = [string]$Run.target; databaseType = [string]$Run.databaseType; profile = [string]$Run.profileName
        startedAt = [string]$Run.startedAt; stages = $stages; failures = @{}
    }
}

function Read-State {
    if (-not (Test-Path -LiteralPath $StateFile -PathType Leaf)) { return $null }
    try {
        $state = ConvertTo-Hashtable ([IO.File]::ReadAllText($StateFile) | ConvertFrom-Json)
        if ($state.version -ne 1) { return $null }
        foreach ($stage in @($state.stages.Values)) { $stage.buckets = [double[]]@($stage.buckets) }
        return $state
    } catch {
        Write-CollectorLog "AVISO estado ilegivel, recomecando: $($_.Exception.Message)"
        return $null
    }
}

function Save-State($State) {
    $tmp = $StateFile + '.tmp'
    [IO.File]::WriteAllText($tmp, ($State | ConvertTo-Json -Depth 6 -Compress), $Utf8)
    Move-Replace $tmp $StateFile
}

# Soma um ciclo aos contadores. Etapas desabilitadas (Skipped) nao contam.
function Add-Cycle($State, $Cycle, $WindowMax) {
    foreach ($stage in @($Cycle.stages)) {
        if ($stage.status -eq 'Skipped') { continue }
        $name = $StageNames[[string]$stage.stage]
        if (-not $name) { continue }
        $entry = $State.stages[$name]
        $seconds = [double]$stage.elapsedMs / 1000
        $success = $stage.status -eq 'Success'
        $entry.checks++
        $entry.count++
        $entry.sum += $seconds
        $index = 0
        while ($index -lt $Buckets.Count -and $seconds -gt $Buckets[$index]) { $index++ }
        $entry.buckets[$index]++
        $entry.lastSeconds = $seconds
        $entry.lastSuccess = if ($success) { 1 } else { 0 }
        if (-not $success) {
            $code = if ($stage.diagnosticCode) { [string]$stage.diagnosticCode } else { 'sem_codigo' }
            $key = $name + '|' + $code
            if ($State.failures.ContainsKey($key)) { $State.failures[$key]++ } else { $State.failures[$key] = 1 }
        }
        if (-not $WindowMax.ContainsKey($name) -or $seconds -gt $WindowMax[$name]) { $WindowMax[$name] = $seconds }
    }
    $State.cycles++
    $State.lastCycle = [long]$Cycle.number
    $State.lastCycleTime = ConvertTo-UnixTime ([string]$Cycle.startedAt)
}

function Add-StateMetrics($State, [int]$Active, $WindowMax) {
    $info = [ordered]@{ run_id = $State.runId; profile = $State.profile; target = $State.target; database_type = $State.databaseType }
    Add-Sample 'dbct_run_info' 'gauge' 'Execucao monitorada: id, perfil, destino e tipo (valor sempre 1).' $info 1
    $start = ConvertTo-UnixTime $State.startedAt
    if ($null -ne $start) { Add-Sample 'dbct_run_start_timestamp_seconds' 'gauge' 'Inicio da execucao monitorada (Unix).' $null $start }
    Add-Sample 'dbct_cycles_total' 'counter' 'Ciclos processados da execucao monitorada.' $null $State.cycles
    if ($null -ne $State.lastCycleTime) {
        Add-Sample 'dbct_last_cycle_timestamp_seconds' 'gauge' 'Inicio do ultimo ciclo processado (Unix).' $null $State.lastCycleTime
    }
    foreach ($name in @($StageNames.Values | Sort-Object)) {
        $entry = $State.stages[$name]
        if ($entry.checks -eq 0) { continue }
        $labels = [ordered]@{ stage = $name }
        Add-Sample 'dbct_stage_checks_total' 'counter' 'Etapas executadas.' $labels $entry.checks
        $cumulative = 0
        for ($i = 0; $i -lt $Buckets.Count; $i++) {
            $cumulative += $entry.buckets[$i]
            $bucket = [ordered]@{ stage = $name; le = $Buckets[$i].ToString('R', $Invariant) }
            Add-Sample 'dbct_stage_duration_seconds' 'histogram' 'Duracao das etapas.' $bucket $cumulative 'dbct_stage_duration_seconds_bucket'
        }
        Add-Sample 'dbct_stage_duration_seconds' 'histogram' 'Duracao das etapas.' ([ordered]@{ stage = $name; le = '+Inf' }) $entry.count 'dbct_stage_duration_seconds_bucket'
        Add-Sample 'dbct_stage_duration_seconds' 'histogram' 'Duracao das etapas.' $labels $entry.sum 'dbct_stage_duration_seconds_sum'
        Add-Sample 'dbct_stage_duration_seconds' 'histogram' 'Duracao das etapas.' $labels $entry.count 'dbct_stage_duration_seconds_count'
        if ($null -ne $entry.lastSeconds) {
            Add-Sample 'dbct_stage_last_duration_seconds' 'gauge' 'Duracao da etapa no ultimo ciclo.' $labels $entry.lastSeconds
            Add-Sample 'dbct_stage_last_success' 'gauge' 'Resultado da etapa no ultimo ciclo (1 = sucesso).' $labels $entry.lastSuccess
        }
        if ($WindowMax.ContainsKey($name)) {
            Add-Sample 'dbct_stage_duration_max_seconds' 'gauge' 'Pior duracao entre esta coleta e a anterior (ausente sem ciclos novos).' $labels $WindowMax[$name]
        }
    }
    foreach ($key in @($State.failures.Keys | Sort-Object)) {
        $parts = $key.Split('|')
        Add-Sample 'dbct_stage_failures_total' 'counter' 'Falhas por etapa e codigo de diagnostico do DBCT.' ([ordered]@{ stage = $parts[0]; code = $parts[1] }) $State.failures[$key]
    }
}

# Execucao automatica do DBCT (dbct run ... --autostart), pelo dbct run status.
function Add-AutostartMetrics($Status) {
    $configured = if ($Status.autostart) { 1 } else { 0 }
    Add-Sample 'dbct_autostart_configured' 'gauge' 'Execucao automatica do DBCT configurada neste banco (1 = sim).' $null $configured
    if ($configured) {
        $running = if ($Status.autostart.loopRunning) { 1 } else { 0 }
        Add-Sample 'dbct_autostart_running' 'gauge' 'Processo da execucao automatica ativo (1 = sim).' $null $running
    }
}

# ------------------------------------------------------------------ principal

Remove-OldLogs
$success = 0
$active = 0
$failure = $null
try {
    if (-not (Test-Path -LiteralPath $OutputDir -PathType Container)) {
        throw "Diretorio de saida ausente: $OutputDir (reaplique a configuracao do Alloy)."
    }
    $config = Read-Settings
    $common = @('--data-dir', [string]$config.dataDir, '--format', 'json')
    $state = Read-State
    $windowMax = @{}

    # run status: execucao ativa (com processo gravando), sem registros abandonados.
    $status = Invoke-Dbct $config.dbct (@('run', 'status') + $common)
    $run = if ($status.active) { @($status.runs) | Where-Object { -not $_.abandoned } | Select-Object -First 1 } else { $null }
    if ($run) {
        $active = 1
        if (-not $state -or $state.runId -ne [string]$run.runId) {
            $state = New-State $run
            $start = ConvertTo-UnixTime ([string]$run.startedAt)
            $age = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds() - $start
            if ($age -gt $CatchUpSeconds) {
                $state.lastCycle = [long]$run.completedCycles
                Write-CollectorLog "execucao $($run.runId) ja em andamento: acompanhando a partir do ciclo $($state.lastCycle)."
            } else {
                Write-CollectorLog "nova execucao $($run.runId) ($($run.target))."
            }
        }
        for ($page = 0; $page -lt $MaxPages; $page++) {
            $batch = Invoke-Dbct $config.dbct (@('history', 'cycles', [string]$state.runId, '--after', [string]$state.lastCycle,
                '--limit', [string]$PageSize) + $common)
            foreach ($cycle in @($batch.items)) { Add-Cycle $state $cycle $windowMax }
            if (-not $batch.hasMore) { break }
        }
        Save-State $state
    }
    if ($state) { Add-StateMetrics $state $active $windowMax }
    Add-AutostartMetrics $status
    $success = 1
} catch {
    $failure = $_.Exception.Message
    # Sem metricas parciais: so a saude da coleta.
    $script:Metrics = [ordered]@{}
}

$Timer.Stop()
Add-Sample 'dbct_run_active' 'gauge' 'Execucao em andamento no banco do DBCT (1 = sim).' $null $active
Add-Sample 'dbct_collection_success' 'gauge' 'Ultima coleta concluida (1 = sim).' $null $success
Add-Sample 'dbct_collection_duration_seconds' 'gauge' 'Duracao da ultima coleta.' $null $Timer.Elapsed.TotalSeconds
Add-Sample 'dbct_collection_timestamp_seconds' 'gauge' 'Horario da ultima coleta (Unix).' $null ([DateTimeOffset]::new($Started).ToUnixTimeSeconds())

try {
    if (Test-Path -LiteralPath $OutputDir -PathType Container) { Save-PromFile }
} catch {
    if (-not $failure) { $failure = "falha ao gravar ${OutFile}: $($_.Exception.Message)" }
    $success = 0
}

if ($failure) { Write-CollectorLog ('FALHA ' + $failure) }
if (-not $success) { exit 1 }
