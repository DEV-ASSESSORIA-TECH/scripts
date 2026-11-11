#Requires -Version 5.1
<#
.SYNOPSIS
Metricas do SAP SQL Anywhere 17 para o textfile collector do Alloy.

.DESCRIPTION
Executado como SYSTEM pela tarefa agendada "\GrafanaLabs\Alloy SQL Anywhere"
(a cada 30 s), instalada pelo install.ps1 quando o modulo SQL Anywhere esta
ativo. Conecta via ODBC local (driver "SQL Anywhere 17", 64 bits) com o
usuario de monitoramento e gera textfile\sqlanywhere\sqlanywhere.prom, lido
pelo Alloy no job integrations/sqlanywhere:

  sqlanywhere_collection_*   saude da propria coleta (sem labels)
  sqlanywhere_up             conexao ao banco aberta (1 = sim)
  sqlanywhere_info           servidor, banco e versao (valor sempre 1)
  sqlanywhere_*              propriedades do servidor (PROPERTY) e do banco
                             (DB_PROPERTY), labels server e database

Propriedade que volta NULL ou nao numerica nao gera serie (nunca vira zero);
a lista de ausentes vai para o log quando muda.

Configuracao em data\sqlanywhere\ (so SYSTEM e Administradores):
  config.json      server (ENG), database (DBN), user e links (opcional)
  password.dpapi   senha protegida com DPAPI (escopo da maquina)

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
$OutputDir = Join-Path $Root 'textfile\sqlanywhere'
$StateDir = Join-Path $Root 'data\sqlanywhere'
$LogDir = Join-Path $Root 'logs'
$OutFile = Join-Path $OutputDir 'sqlanywhere.prom'
$ConfigFile = Join-Path $StateDir 'config.json'
$PasswordFile = Join-Path $StateDir 'password.dpapi'
$MissingFile = Join-Path $StateDir 'missing-properties.txt'
$Invariant = [Globalization.CultureInfo]::InvariantCulture
$DefaultLinks = 'SharedMemory,TCPIP(HOST=127.0.0.1)'
# Mesma entropia do install.ps1 (Save-SqlAnywhereSettings).
$Entropy = [Text.Encoding]::UTF8.GetBytes('AssessoriaTech-Alloy-SQLAnywhere')

# Propriedades lidas. Scope: Server = PROPERTY(), Database = DB_PROPERTY() do
# banco conectado. Scale: numero (1024 converte KB em bytes), 'ServerPage' ou
# 'DatabasePage' (multiplica pelo PageSize do escopo) ou 'DateTime' (data do
# servidor convertida em Unix). Nomes e descricoes conforme a documentacao do
# SQL Anywhere 17 ("List of Database Server Properties" e "List of Database
# Properties"). Atencao: Commit de banco conta flushes do cache de disco, nao
# COMMITs; os COMMITs sao a propriedade Commit do servidor.
$Properties = @(
    @{ Scope = 'Server';   Name = 'ConnCount';               Metric = 'sqlanywhere_server_connections';                  Type = 'gauge';   Scale = 1;              Help = 'Conexoes abertas no servidor.' }
    @{ Scope = 'Server';   Name = 'ActiveReq';               Metric = 'sqlanywhere_server_active_requests';              Type = 'gauge';   Scale = 1;              Help = 'Workers atendendo requisicoes agora.' }
    @{ Scope = 'Server';   Name = 'UnschReq';                Metric = 'sqlanywhere_server_waiting_requests';             Type = 'gauge';   Scale = 1;              Help = 'Requisicoes na fila aguardando um worker livre.' }
    @{ Scope = 'Server';   Name = 'MultiProgrammingLevel';   Metric = 'sqlanywhere_server_multiprogramming_level';       Type = 'gauge';   Scale = 1;              Help = 'Maximo atual de tarefas simultaneas (acima disso as requisicoes vao para a fila).' }
    @{ Scope = 'Server';   Name = 'RequestsReceived';        Metric = 'sqlanywhere_server_requests_total';               Type = 'counter'; Scale = 1;              Help = 'Requisicoes cliente/servidor (round trips) desde o inicio.' }
    @{ Scope = 'Server';   Name = 'Commit';                  Metric = 'sqlanywhere_server_commits_total';                Type = 'counter'; Scale = 1;              Help = 'Requisicoes de COMMIT atendidas desde o inicio.' }
    @{ Scope = 'Server';   Name = 'Rlbk';                    Metric = 'sqlanywhere_server_rollbacks_total';              Type = 'counter'; Scale = 1;              Help = 'Requisicoes de ROLLBACK atendidas desde o inicio.' }
    @{ Scope = 'Server';   Name = 'ThreadDeadlocksReported'; Metric = 'sqlanywhere_server_thread_deadlocks_total';       Type = 'counter'; Scale = 1;              Help = 'Erros de thread deadlock devolvidos aos clientes (todos os workers bloqueados).' }
    @{ Scope = 'Server';   Name = 'ProcessCPU';              Metric = 'sqlanywhere_server_cpu_seconds_total';            Type = 'counter'; Scale = 1;              Help = 'CPU acumulada pelo processo do servidor.' }
    @{ Scope = 'Server';   Name = 'StartTime';               Metric = 'sqlanywhere_server_start_time_seconds';           Type = 'gauge';   Scale = 'DateTime';     Help = 'Horario de inicio do servidor (Unix).' }
    @{ Scope = 'Server';   Name = 'PageSize';                Metric = 'sqlanywhere_server_page_size_bytes';              Type = 'gauge';   Scale = 1;              Help = 'Tamanho da pagina do cache do servidor.' }
    @{ Scope = 'Server';   Name = 'CurrentCacheSize';        Metric = 'sqlanywhere_server_cache_size_bytes';             Type = 'gauge';   Scale = 1024;           Help = 'Tamanho atual do cache (alocado).' }
    @{ Scope = 'Server';   Name = 'MinCacheSize';            Metric = 'sqlanywhere_server_cache_min_bytes';              Type = 'gauge';   Scale = 1024;           Help = 'Tamanho minimo permitido do cache.' }
    @{ Scope = 'Server';   Name = 'MaxCacheSize';            Metric = 'sqlanywhere_server_cache_max_bytes';              Type = 'gauge';   Scale = 1024;           Help = 'Tamanho maximo permitido do cache.' }
    @{ Scope = 'Server';   Name = 'PeakCacheSize';           Metric = 'sqlanywhere_server_cache_peak_bytes';             Type = 'gauge';   Scale = 1024;           Help = 'Maior tamanho do cache desde o inicio.' }
    @{ Scope = 'Server';   Name = 'CacheFile';               Metric = 'sqlanywhere_server_cache_file_bytes';             Type = 'gauge';   Scale = 'ServerPage';   Help = 'Cache ocupado com dados dos arquivos do banco.' }
    @{ Scope = 'Server';   Name = 'CacheFree';               Metric = 'sqlanywhere_server_cache_free_bytes';             Type = 'gauge';   Scale = 'ServerPage';   Help = 'Cache livre (paginas sem uso).' }
    @{ Scope = 'Server';   Name = 'CacheAllocated';          Metric = 'sqlanywhere_server_cache_allocated_bytes';        Type = 'gauge';   Scale = 'ServerPage';   Help = 'Cache alocado para outros fins que nao dados dos arquivos (estruturas, consultas).' }
    @{ Scope = 'Server';   Name = 'CacheFileDirty';          Metric = 'sqlanywhere_server_cache_dirty_bytes';            Type = 'gauge';   Scale = 'ServerPage';   Help = 'Cache com paginas alteradas aguardando gravacao.' }
    @{ Scope = 'Server';   Name = 'CachePinned';             Metric = 'sqlanywhere_server_cache_pinned_bytes';           Type = 'gauge';   Scale = 'ServerPage';   Help = 'Cache com paginas fixadas (pinned).' }
    @{ Scope = 'Server';   Name = 'CacheReplacements';       Metric = 'sqlanywhere_server_cache_replacements_total';     Type = 'counter'; Scale = 1;              Help = 'Paginas substituidas no cache desde o inicio.' }
    @{ Scope = 'Server';   Name = 'CacheScavenges';          Metric = 'sqlanywhere_server_cache_scavenges_total';        Type = 'counter'; Scale = 1;              Help = 'Vezes em que o cache precisou procurar pagina para reaproveitar.' }
    @{ Scope = 'Server';   Name = 'CachePanics';             Metric = 'sqlanywhere_server_cache_panics_total';           Type = 'counter'; Scale = 1;              Help = 'Vezes em que o cache nao encontrou pagina para alocar.' }
    @{ Scope = 'Server';   Name = 'QueryMemGrantWaited';     Metric = 'sqlanywhere_server_query_memory_waits_total';     Type = 'counter'; Scale = 1;              Help = 'Vezes em que uma requisicao esperou memoria de consulta.' }
    @{ Scope = 'Server';   Name = 'QueryMemGrantFailed';     Metric = 'sqlanywhere_server_query_memory_failures_total';  Type = 'counter'; Scale = 1;              Help = 'Vezes em que uma requisicao esperou memoria de consulta e nao conseguiu.' }
    @{ Scope = 'Database'; Name = 'ConnCount';               Metric = 'sqlanywhere_database_connections';                Type = 'gauge';   Scale = 1;              Help = 'Conexoes abertas no banco.' }
    @{ Scope = 'Database'; Name = 'PageSize';                Metric = 'sqlanywhere_database_page_size_bytes';            Type = 'gauge';   Scale = 1;              Help = 'Tamanho da pagina do banco.' }
    @{ Scope = 'Database'; Name = 'FileSize';                Metric = 'sqlanywhere_database_file_bytes';                 Type = 'gauge';   Scale = 'DatabasePage'; Help = 'Tamanho do dbspace system.' }
    @{ Scope = 'Database'; Name = 'FreePages';               Metric = 'sqlanywhere_database_free_bytes';                 Type = 'gauge';   Scale = 'DatabasePage'; Help = 'Espaco livre dentro do dbspace system.' }
    @{ Scope = 'Database'; Name = 'CacheRead';               Metric = 'sqlanywhere_database_cache_reads_total';          Type = 'counter'; Scale = 1;              Help = 'Paginas procuradas no cache (inclui os acertos).' }
    @{ Scope = 'Database'; Name = 'CacheHits';               Metric = 'sqlanywhere_database_cache_hits_total';           Type = 'counter'; Scale = 1;              Help = 'Paginas procuradas e encontradas no cache.' }
    @{ Scope = 'Database'; Name = 'DiskRead';                Metric = 'sqlanywhere_database_disk_reads_total';           Type = 'counter'; Scale = 1;              Help = 'Paginas lidas do disco.' }
    @{ Scope = 'Database'; Name = 'DiskWrite';               Metric = 'sqlanywhere_database_disk_writes_total';          Type = 'counter'; Scale = 1;              Help = 'Paginas alteradas gravadas no disco.' }
    @{ Scope = 'Database'; Name = 'Commit';                  Metric = 'sqlanywhere_database_disk_flushes_total';         Type = 'counter'; Scale = 1;              Help = 'Flushes forcados do cache de disco do sistema operacional.' }
    @{ Scope = 'Database'; Name = 'Rlbk';                    Metric = 'sqlanywhere_database_rollbacks_total';            Type = 'counter'; Scale = 1;              Help = 'Requisicoes de ROLLBACK atendidas no banco.' }
    @{ Scope = 'Database'; Name = 'Chkpt';                   Metric = 'sqlanywhere_database_checkpoints_total';          Type = 'counter'; Scale = 1;              Help = 'Checkpoints executados.' }
    @{ Scope = 'Database'; Name = 'LockCount';               Metric = 'sqlanywhere_database_locks';                      Type = 'gauge';   Scale = 1;              Help = 'Locks mantidos no banco agora.' }
    @{ Scope = 'Database'; Name = 'CheckpointUrgency';       Metric = 'sqlanywhere_database_checkpoint_urgency_percent'; Type = 'gauge';   Scale = 1;              Help = 'Tempo desde o ultimo checkpoint, em % do checkpoint_time.' }
    @{ Scope = 'Database'; Name = 'RecoveryUrgency';         Metric = 'sqlanywhere_database_recovery_urgency_percent';   Type = 'gauge';   Scale = 1;              Help = 'Tempo estimado de recuperacao, em % do recovery_time.' }
    @{ Scope = 'Database'; Name = 'QueryLowMemoryStrategy';  Metric = 'sqlanywhere_database_low_memory_strategy_total';  Type = 'counter'; Scale = 1;              Help = 'Planos de execucao alterados por falta de memoria.' }
)

$script:Metrics = [ordered]@{}

# ------------------------------------------------------------------ saida

function Write-CollectorLog([string]$Text) {
    try {
        if (-not (Test-Path -LiteralPath $LogDir -PathType Container)) { return }
        $file = Join-Path $LogDir ('sqlanywhere-collector-' + (Get-Date -Format 'yyyyMMdd') + '.log')
        $line = (Get-Date -Format 'yyyy-MM-dd HH:mm:ss') + '  ' + $Text
        [IO.File]::AppendAllText($file, $line + "`r`n", (New-Object System.Text.UTF8Encoding($false)))
    } catch { }
}

# Retencao: remove logs do coletor mais antigos que $LogRetentionDays.
function Remove-OldLogs {
    try {
        $limit = (Get-Date).AddDays(-$LogRetentionDays)
        Get-ChildItem -LiteralPath $LogDir -Filter 'sqlanywhere-collector-*.log' -File -ErrorAction Stop |
            Where-Object { $_.LastWriteTime -lt $limit } |
            Remove-Item -Force -ErrorAction SilentlyContinue
    } catch { }
}

function ConvertTo-LabelValue($Value) {
    if ($null -eq $Value) { return '' }
    $text = [string]$Value
    return $text.Replace('\', '\\').Replace('"', '\"').Replace("`r", '').Replace("`n", '\n')
}

# Agrupa amostras por metrica: o formato exige HELP/TYPE uma vez por nome.
function Add-Sample([string]$Name, [string]$Type, [string]$Help, $Labels, [double]$Value) {
    if (-not $script:Metrics.Contains($Name)) {
        $script:Metrics[$Name] = @{ Type = $Type; Help = $Help; Samples = New-Object System.Collections.Generic.List[string] }
    }
    $pairs = @()
    if ($Labels) {
        foreach ($key in @($Labels.Keys)) {
            $pairs += ('{0}="{1}"' -f $key, (ConvertTo-LabelValue $Labels[$key]))
        }
    }
    $labelText = if ($pairs.Count -gt 0) { '{' + ($pairs -join ',') + '}' } else { '' }
    $script:Metrics[$Name].Samples.Add($Name + $labelText + ' ' + $Value.ToString('R', $Invariant))
}

# Substitui Target por Source; nova tentativa caso o Alloy esteja lendo o
# arquivo no instante da troca (mesma logica do hypervisor-inventory.ps1).
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

# Escrita atomica: grava .tmp (ignorado pelo coletor) e substitui o .prom.
# O textfile collector exige LF e uma quebra de linha no final.
function Save-PromFile {
    $builder = New-Object System.Text.StringBuilder
    foreach ($name in $script:Metrics.Keys) {
        $metric = $script:Metrics[$name]
        [void]$builder.Append('# HELP ' + $name + ' ' + $metric.Help + "`n")
        [void]$builder.Append('# TYPE ' + $name + ' ' + $metric.Type + "`n")
        foreach ($sample in $metric.Samples) { [void]$builder.Append($sample + "`n") }
    }
    $tmp = $OutFile + '.tmp'
    [IO.File]::WriteAllText($tmp, $builder.ToString(), (New-Object System.Text.UTF8Encoding($false)))
    Move-Replace $tmp $OutFile
}

# Registra no log a lista de propriedades sem valor somente quando ela muda,
# para nao repetir a mesma linha a cada 30 s.
function Update-MissingLog([string[]]$Missing) {
    $current = ($Missing | Sort-Object) -join ','
    $previous = ''
    if (Test-Path -LiteralPath $MissingFile -PathType Leaf) {
        $previous = ([IO.File]::ReadAllText($MissingFile)).Trim()
    }
    if ($current -ceq $previous) { return }
    if ($current) {
        Write-CollectorLog ('AVISO propriedades sem valor numerico (series omitidas): ' + $current)
    } else {
        Write-CollectorLog 'todas as propriedades voltaram a ter valor'
    }
    try { [IO.File]::WriteAllText($MissingFile, $current) } catch { }
}

# ------------------------------------------------------------------ coleta

function Read-Settings {
    if (-not (Test-Path -LiteralPath $ConfigFile -PathType Leaf)) { throw "Configuracao ausente: $ConfigFile" }
    if (-not (Test-Path -LiteralPath $PasswordFile -PathType Leaf)) { throw "Senha ausente: $PasswordFile" }
    $config = [IO.File]::ReadAllText($ConfigFile) | ConvertFrom-Json
    foreach ($field in @('server', 'database', 'user')) {
        if ([string]::IsNullOrWhiteSpace([string]$config.$field)) { throw "Campo '$field' vazio em $ConfigFile" }
    }
    Add-Type -AssemblyName System.Security
    $bytes = [Security.Cryptography.ProtectedData]::Unprotect([IO.File]::ReadAllBytes($PasswordFile), $Entropy,
        [Security.Cryptography.DataProtectionScope]::LocalMachine)
    $links = if ([string]::IsNullOrWhiteSpace([string]$config.links)) { $DefaultLinks } else { [string]$config.links }
    return [pscustomobject]@{
        Server   = [string]$config.server
        Database = [string]$config.database
        User     = [string]$config.user
        Password = [Text.Encoding]::UTF8.GetString($bytes)
        Links    = $links
    }
}

# Uma consulta por escopo: SELECT PROPERTY('A'), PROPERTY('B'), ...
# Os nomes sao constantes deste script, nao entrada externa.
function Read-PropertyRow([System.Data.Odbc.OdbcConnection]$Connection, [string]$Function, [object[]]$Items) {
    $columns = @($Items | ForEach-Object { "$Function('$($_.Name)')" })
    $cmd = $Connection.CreateCommand()
    try {
        $cmd.CommandTimeout = 8
        $cmd.CommandText = 'SELECT ' + ($columns -join ', ')
        $reader = $cmd.ExecuteReader()
        try {
            if (-not $reader.Read()) { throw "$Function sem resultado." }
            $values = @{}
            for ($i = 0; $i -lt $Items.Count; $i++) {
                $values[$Items[$i].Name] = if ($reader.IsDBNull($i)) { $null } else { [string]$reader.GetValue($i) }
            }
            return $values
        } finally { $reader.Dispose() }
    } finally { $cmd.Dispose() }
}

function ConvertTo-Number([string]$Text) {
    if ([string]::IsNullOrWhiteSpace($Text)) { return $null }
    $number = 0.0
    if (-not [double]::TryParse($Text.Trim(), [Globalization.NumberStyles]::Float, $Invariant, [ref]$number)) { return $null }
    if ([double]::IsNaN($number) -or [double]::IsInfinity($number)) { return $null }
    return $number
}

# StartTime vem como texto 'AAAA-MM-DD HH:MM:SS.sss' no horario local do
# servidor (ou do time_zone do banco, se definido). Convertido para Unix.
function ConvertTo-UnixTime([string]$Text) {
    if ([string]::IsNullOrWhiteSpace($Text)) { return $null }
    $formats = [string[]]@('yyyy-MM-dd HH:mm:ss.FFFFFF', 'yyyy-MM-dd HH:mm:ss')
    $parsed = [DateTime]::MinValue
    if (-not [DateTime]::TryParseExact($Text.Trim(), $formats, $Invariant,
            [Globalization.DateTimeStyles]::AssumeLocal, [ref]$parsed)) { return $null }
    return [double]([DateTimeOffset]$parsed).ToUnixTimeSeconds()
}

# Valor final da propriedade, ja na unidade da metrica, ou $null.
function Get-PropertyValue($Item, $Values) {
    $raw = $Values[$Item.Name]
    if ($Item.Scale -is [string] -and $Item.Scale -eq 'DateTime') { return ConvertTo-UnixTime $raw }
    $number = ConvertTo-Number $raw
    if ($null -eq $number) { return $null }
    if ($Item.Scale -is [string]) {
        # ServerPage/DatabasePage: paginas x PageSize do mesmo escopo.
        $pageSize = ConvertTo-Number $Values['PageSize']
        if ($null -eq $pageSize -or $pageSize -le 0) { return $null }
        return $number * $pageSize
    }
    return $number * $Item.Scale
}

# ------------------------------------------------------------------ principal

Remove-OldLogs
$success = 0
$up = 0
$missing = @()
$failure = $null
$connection = $null
try {
    if (-not (Test-Path -LiteralPath $OutputDir -PathType Container)) {
        throw "Diretorio de saida ausente: $OutputDir (reaplique a configuracao do Alloy)."
    }
    $settings = Read-Settings
    $builder = New-Object System.Data.Odbc.OdbcConnectionStringBuilder
    $builder['Driver'] = 'SQL Anywhere 17'
    $builder['ServerName'] = $settings.Server
    $builder['DatabaseName'] = $settings.Database
    $builder['UID'] = $settings.User
    $builder['PWD'] = $settings.Password
    $builder['LINKS'] = $settings.Links
    $connection = New-Object System.Data.Odbc.OdbcConnection($builder.ConnectionString)
    $connection.ConnectionTimeout = 5
    $connection.Open()
    $up = 1

    $labels = [ordered]@{ server = $settings.Server; database = $settings.Database }
    $server = @($Properties | Where-Object { $_.Scope -eq 'Server' })
    $database = @($Properties | Where-Object { $_.Scope -eq 'Database' })
    $serverValues = Read-PropertyRow $connection 'PROPERTY' ($server + @(@{ Name = 'ProductVersion' }))
    $databaseValues = Read-PropertyRow $connection 'DB_PROPERTY' $database

    $info = [ordered]@{ server = $settings.Server; database = $settings.Database; version = [string]$serverValues['ProductVersion'] }
    Add-Sample 'sqlanywhere_info' 'gauge' 'Servidor, banco e versao do SQL Anywhere (valor sempre 1).' $info 1
    foreach ($item in $Properties) {
        $values = if ($item.Scope -eq 'Server') { $serverValues } else { $databaseValues }
        $value = Get-PropertyValue $item $values
        if ($null -eq $value) {
            $missing += ($item.Scope + ':' + $item.Name)
            continue
        }
        Add-Sample $item.Metric $item.Type $item.Help $labels $value
    }
    if ($missing.Count -eq $Properties.Count) { throw 'Nenhuma propriedade retornou valor numerico.' }
    $success = 1
} catch {
    $failure = $_.Exception.Message
    # Sem metricas parciais: so a saude da coleta, para o dashboard mostrar a
    # falha em vez de valores antigos.
    $script:Metrics = [ordered]@{}
} finally {
    if ($null -ne $connection) { $connection.Dispose() }
}

if ($success) { Update-MissingLog $missing }
$Timer.Stop()
Add-Sample 'sqlanywhere_up' 'gauge' 'Conexao ODBC ao banco aberta na ultima coleta (1 = sim).' $null $up
Add-Sample 'sqlanywhere_collection_success' 'gauge' 'Ultima coleta concluida (1 = sim).' $null $success
Add-Sample 'sqlanywhere_collection_missing_properties' 'gauge' 'Propriedades sem valor numerico na ultima coleta (series omitidas).' $null $missing.Count
Add-Sample 'sqlanywhere_collection_duration_seconds' 'gauge' 'Duracao da ultima coleta.' $null $Timer.Elapsed.TotalSeconds
Add-Sample 'sqlanywhere_collection_timestamp_seconds' 'gauge' 'Horario da ultima coleta (Unix).' $null ([DateTimeOffset]::new($Started).ToUnixTimeSeconds())

try {
    if (Test-Path -LiteralPath $OutputDir -PathType Container) { Save-PromFile }
} catch {
    if (-not $failure) { $failure = "falha ao gravar ${OutFile}: $($_.Exception.Message)" }
    $success = 0
}

if ($failure) {
    # A mensagem do driver ODBC nao inclui a senha; a mascara cobre o caso de
    # a string de conexao aparecer no texto.
    Write-CollectorLog ('FALHA ' + ($failure -replace '(?i)(pwd|password)\s*=\s*[^;]*', '$1=***'))
}
if (-not $success) { exit 1 }
