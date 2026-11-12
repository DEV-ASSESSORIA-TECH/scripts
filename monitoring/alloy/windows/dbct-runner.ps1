#Requires -Version 5.1
<#
.SYNOPSIS
Mantem a execucao continua do DB Connection Tester (DBCT) para o modulo dbct.

.DESCRIPTION
Executado como SYSTEM pela tarefa agendada "\GrafanaLabs\Alloy DBCT Runner",
iniciada com o Windows e instalada pelo install.ps1 quando o modulo dbct tem um
perfil configurado. Executa

  dbct run --profile <id> --continuous true --data-dir <pasta> --no-progress

e, quando o dbct termina (erro de configuracao, outra execucao gravando no mesmo
banco, falha), espera e executa de novo. A senha, quando o perfil exige, fica em
data\dbct\password.dpapi (DPAPI, escopo da maquina) e vai pela entrada padrao,
nunca pela linha de comando.

Parar a tarefa encerra o dbct: a execucao fica como Running e o proprio DBCT a
marca como Interrupted no proximo inicio. Desligar o Windows encerra o dbct com
a execucao registrada como Stopped.

Estado em data\dbct\runner.json (lido pelo coletor) e logs diarios em logs\.
Manter este arquivo em ASCII: o Windows PowerShell 5.1 le arquivos sem BOM como ANSI.
#>
[CmdletBinding()]
param(
    [string]$Root = (Join-Path $env:ProgramData 'GrafanaLabs\Alloy'),
    [ValidateRange(1, 365)]
    [int]$LogRetentionDays = 14
)

$ErrorActionPreference = 'Stop'
$StateDir = Join-Path $Root 'data\dbct'
$LogDir = Join-Path $Root 'logs'
$ConfigFile = Join-Path $StateDir 'config.json'
$PasswordFile = Join-Path $StateDir 'password.dpapi'
$RunnerFile = Join-Path $StateDir 'runner.json'
$Utf8 = New-Object System.Text.UTF8Encoding($false)
# Mesma entropia do install.ps1 (Save-DbctSettings).
$Entropy = [Text.Encoding]::UTF8.GetBytes('AssessoriaTech-Alloy-DBCT')
# Espera antes de executar de novo. Outra execucao gravando no banco (codigo 4,
# por exemplo pela GUI) e esperada: nova tentativa mais cedo.
$RetrySeconds = 60
$BusyRetrySeconds = 30

function Write-RunnerLog([string]$Text) {
    try {
        if (-not (Test-Path -LiteralPath $LogDir -PathType Container)) { return }
        $file = Join-Path $LogDir ('dbct-runner-' + (Get-Date -Format 'yyyyMMdd') + '.log')
        $line = (Get-Date -Format 'yyyy-MM-dd HH:mm:ss') + '  ' + $Text
        [IO.File]::AppendAllText($file, $line + "`r`n", $Utf8)
        $limit = (Get-Date).AddDays(-$LogRetentionDays)
        Get-ChildItem -LiteralPath $LogDir -Filter 'dbct-runner-*.log' -File -ErrorAction SilentlyContinue |
            Where-Object { $_.LastWriteTime -lt $limit } | Remove-Item -Force -ErrorAction SilentlyContinue
    } catch { }
}

function Save-RunnerState([hashtable]$State) {
    try {
        $tmp = $RunnerFile + '.tmp'
        [IO.File]::WriteAllText($tmp, ($State | ConvertTo-Json -Compress), $Utf8)
        if (Test-Path -LiteralPath $RunnerFile -PathType Leaf) { [IO.File]::Replace($tmp, $RunnerFile, [NullString]::Value) }
        else { [IO.File]::Move($tmp, $RunnerFile) }
    } catch { Write-RunnerLog "AVISO estado nao gravado: $($_.Exception.Message)" }
}

# Mesmas regras de argumentos do dbct-collector.ps1.
function ConvertTo-Argument([string]$Value) {
    if ($Value -and $Value -notmatch '[\s"]') { return $Value }
    $escaped = [regex]::Replace($Value, '(\\*)"', '$1$1\"')
    $escaped = [regex]::Replace($escaped, '(\\+)$', '$1$1')
    return '"' + $escaped + '"'
}

function Read-Settings {
    if (-not (Test-Path -LiteralPath $ConfigFile -PathType Leaf)) { throw "Configuracao ausente: $ConfigFile" }
    $config = [IO.File]::ReadAllText($ConfigFile) | ConvertFrom-Json
    foreach ($field in @('dbct', 'dataDir', 'profileId')) {
        if ([string]::IsNullOrWhiteSpace([string]$config.$field)) { throw "Campo '$field' vazio em $ConfigFile" }
    }
    if (-not (Test-Path -LiteralPath $config.dbct -PathType Leaf)) { throw "dbct.exe nao encontrado: $($config.dbct)" }
    $password = $null
    if (Test-Path -LiteralPath $PasswordFile -PathType Leaf) {
        Add-Type -AssemblyName System.Security
        $bytes = [Security.Cryptography.ProtectedData]::Unprotect([IO.File]::ReadAllBytes($PasswordFile), $Entropy,
            [Security.Cryptography.DataProtectionScope]::LocalMachine)
        $password = [Text.Encoding]::UTF8.GetString($bytes)
    }
    return [pscustomobject]@{ Dbct = [string]$config.dbct; DataDir = [string]$config.dataDir; ProfileId = [string]$config.profileId; Password = $password }
}

# Executa o dbct ate ele terminar. Devolve o codigo de saida e o fim do stderr
# (com --no-progress, so mensagens de erro).
function Invoke-Run($Settings, [hashtable]$State) {
    $arguments = @('run', '--profile', $Settings.ProfileId, '--continuous', 'true', '--data-dir', $Settings.DataDir,
        '--format', 'json', '--no-progress')
    if ($null -ne $Settings.Password) { $arguments += '--password-stdin' }
    $info = New-Object System.Diagnostics.ProcessStartInfo
    $info.FileName = $Settings.Dbct
    $info.Arguments = (@($arguments | ForEach-Object { ConvertTo-Argument $_ }) -join ' ')
    $info.UseShellExecute = $false
    $info.CreateNoWindow = $true
    $info.RedirectStandardInput = $true
    $info.RedirectStandardOutput = $true
    $info.RedirectStandardError = $true
    $info.StandardOutputEncoding = $Utf8
    $info.StandardErrorEncoding = $Utf8
    $process = [Diagnostics.Process]::Start($info)
    try {
        $stdout = $process.StandardOutput.ReadToEndAsync()
        $stderr = $process.StandardError.ReadToEndAsync()
        if ($null -ne $Settings.Password) { $process.StandardInput.WriteLine($Settings.Password) }
        $process.StandardInput.Close()
        $State.pid = $process.Id
        $State.startedAt = (Get-Date).ToString('o')
        Save-RunnerState $State
        Write-RunnerLog "dbct iniciado (pid $($process.Id), perfil $($Settings.ProfileId))."
        $process.WaitForExit()
        [void]$stdout.GetAwaiter().GetResult()
        $errorText = ($stderr.GetAwaiter().GetResult()).Trim()
        return @{ ExitCode = $process.ExitCode; Error = $errorText }
    } finally { $process.Dispose() }
}

$state = @{ pid = $null; startedAt = $null; restarts = 0; lastExitCode = $null; lastExitAt = $null; lastError = $null }
Write-RunnerLog 'tarefa de execucao iniciada.'
while ($true) {
    $wait = $RetrySeconds
    try {
        $settings = Read-Settings
        $result = Invoke-Run $settings $state
        $state.pid = $null
        $state.lastExitCode = $result.ExitCode
        $state.lastExitAt = (Get-Date).ToString('o')
        $state.lastError = if ($result.Error) { $result.Error } else { $null }
        if ($result.ExitCode -eq 4) { $wait = $BusyRetrySeconds }
        $detail = if ($result.Error) { ': ' + $result.Error } else { '' }
        Write-RunnerLog "dbct encerrado com codigo $($result.ExitCode)$detail. Nova tentativa em ${wait}s."
    } catch {
        $state.pid = $null
        $state.lastError = $_.Exception.Message
        Write-RunnerLog "FALHA $($_.Exception.Message). Nova tentativa em ${wait}s."
    }
    $state.restarts++
    Save-RunnerState $state
    Start-Sleep -Seconds $wait
}
