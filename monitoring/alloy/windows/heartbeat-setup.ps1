#Requires -RunAsAdministrator
#Requires -Version 5.1
<#
.SYNOPSIS
Configura, testa ou remove o heartbeat do host (Uptime Kuma Push + Loki).

.DESCRIPTION
Opcional e independente da instalacao do Alloy (menu [9] do alloy.ps1).
Sem parametros: configura. Pede a URL de push copiada do Uptime Kuma, faz uma
batida de teste e so entao grava a URL (ACL so SYSTEM e Administradores),
instala heartbeat.ps1 e registra a tarefa agendada, conferindo a primeira
execucao. A URL completa e informada na configuracao: o endereco do Kuma nao
fica no repositorio.

-Url   URL de push (automacao); sem ela, a URL e pedida no terminal.
-Test  executa a tarefa agora e mostra o resultado.
-Remove remove tarefa, URL, script, estado e logs do heartbeat. -Yes nao pede confirmacao.
#>
[CmdletBinding()]
param([string]$Url, [switch]$Test, [switch]$Remove, [switch]$Yes)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'lib\Common.ps1')
. (Join-Path $PSScriptRoot 'lib\Ui.ps1')
. (Join-Path $PSScriptRoot 'lib\State.ps1')

function Ensure-Directory([string]$Path) {
    if (Test-Path -LiteralPath $Path) {
        $item = Get-Item -LiteralPath $Path -Force
        if (-not $item.PSIsContainer -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
            throw "Diretorio invalido: $Path"
        }
    } else {
        New-Item -ItemType Directory -Path $Path -Force | Out-Null
    }
}

# Somente SYSTEM e Administradores (a pasta guarda a URL e codigo executado como SYSTEM).
function Set-PrivateDirectoryAcl([string]$Path) {
    $acl = [System.Security.AccessControl.DirectorySecurity]::new()
    $acl.SetAccessRuleProtection($true, $false)
    $acl.SetOwner([System.Security.Principal.SecurityIdentifier]::new('S-1-5-32-544'))
    $inherit = [System.Security.AccessControl.InheritanceFlags]::ContainerInherit -bor [System.Security.AccessControl.InheritanceFlags]::ObjectInherit
    foreach ($sid in @('S-1-5-18', 'S-1-5-32-544')) {
        $id = [System.Security.Principal.SecurityIdentifier]::new($sid)
        $rule = [System.Security.AccessControl.FileSystemAccessRule]::new($id, [System.Security.AccessControl.FileSystemRights]::FullControl, $inherit, [System.Security.AccessControl.PropagationFlags]::None, [System.Security.AccessControl.AccessControlType]::Allow)
        $acl.AddAccessRule($rule)
    }
    Set-Acl -LiteralPath $Path -AclObject $acl
}

function Assert-ScriptSyntax([string]$Path) {
    $tokens = $null
    $errors = $null
    [void][System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$tokens, [ref]$errors)
    if ($errors -and $errors.Count -gt 0) {
        throw "$(Split-Path -Leaf $Path) com erro de sintaxe (linha $($errors[0].Extent.StartLineNumber)): $($errors[0].Message)"
    }
}

# URL colada do Kuma (com ou sem ?status=up&msg=OK&ping=) -> URL base de push.
function ConvertTo-PushUrl([string]$Text) {
    $value = ([string]$Text).Trim().Trim('"', "'")
    $value = ($value -split '[?#]')[0]
    if ($value -notmatch '^https://[A-Za-z0-9.-]+(:\d+)?(/[A-Za-z0-9._~-]+)*/api/push/[A-Za-z0-9_-]{8,128}$') {
        throw 'URL invalida. Formato esperado: https://<servidor>/api/push/<token> (copie do monitor Push do Uptime Kuma).'
    }
    return $value
}

# Explica o resultado do Kuma gravado em last.json.
function Get-KumaHint([string]$Code) {
    switch -Regex ($Code) {
        '^200$' { return 'batida confirmada' }
        '^404$' { return 'token desconhecido ou monitor pausado/inexistente no Kuma' }
        '^(401|403|resposta_invalida)$' { return 'resposta bloqueada no caminho (Cloudflare ou Nginx); verifique as regras para /api/push' }
        '^sem_resposta$' { return 'sem resposta do Kuma (DNS, rota, TLS ou firewall)' }
        '^erro' { return $Code }
        default { return "HTTP $Code" }
    }
}

function Read-LastRun([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $null }
    try { return [IO.File]::ReadAllText($Path) | ConvertFrom-Json } catch { return $null }
}

function Write-RunResult($Last) {
    Write-UiRow 'Alloy' 'none' $Last.line
    $lokiKind = if ($Last.loki -eq '204') { 'ok' } elseif ($Last.loki -eq 'sem_credencial') { 'warn' } else { 'err' }
    $lokiText = switch ($Last.loki) {
        '204' { 'linha gravada (job alloy-heartbeat)' }
        'sem_credencial' { 'sem credencial do Alloy: so o Kuma recebe a batida' }
        default { "falhou: $($Last.loki)" }
    }
    Write-UiRow 'Loki' $lokiKind $lokiText
    $kumaKind = if ($Last.kuma -eq '200') { 'ok' } else { 'err' }
    Write-UiRow 'Uptime Kuma' $kumaKind (Get-KumaHint $Last.kuma)
}

# Executa a tarefa agora e espera o last.json novo (ate 60s).
function Invoke-HeartbeatTask {
    $before = [DateTime]::MinValue
    if (Test-Path -LiteralPath $HeartbeatLast) { $before = (Get-Item -LiteralPath $HeartbeatLast).LastWriteTimeUtc }
    Start-ScheduledTask -TaskPath $HeartbeatTaskPath -TaskName $HeartbeatTaskName
    for ($i = 0; $i -lt 30; $i++) {
        Start-Sleep -Seconds 2
        $task = Get-ScheduledTask -TaskPath $HeartbeatTaskPath -TaskName $HeartbeatTaskName
        if ((Test-Path -LiteralPath $HeartbeatLast) -and
            (Get-Item -LiteralPath $HeartbeatLast).LastWriteTimeUtc -gt $before -and
            [string]$task.State -ne 'Running') {
            return Read-LastRun $HeartbeatLast
        }
    }
    throw "A tarefa nao concluiu em 60s. Veja os logs em $HeartbeatLogDir."
}

function Register-HeartbeatTask {
    # Conta SYSTEM pelo SID: o nome muda com o idioma do Windows.
    $system = ([System.Security.Principal.SecurityIdentifier]::new('S-1-5-18')).Translate([System.Security.Principal.NTAccount]).Value
    $powershell = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $action = New-ScheduledTaskAction -Execute $powershell -Argument ('-NoProfile -NonInteractive -ExecutionPolicy Bypass -File "{0}"' -f $HeartbeatScript)
    $everyMinute = New-ScheduledTaskTrigger -Once -At (Get-Date).Date -RepetitionInterval (New-TimeSpan -Minutes 1)
    $atStartup = New-ScheduledTaskTrigger -AtStartup
    $principal = New-ScheduledTaskPrincipal -UserId $system -LogonType ServiceAccount -RunLevel Highest
    $settings = New-ScheduledTaskSettingsSet -MultipleInstances IgnoreNew -ExecutionTimeLimit (New-TimeSpan -Minutes 2) `
        -StartWhenAvailable -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries
    Register-ScheduledTask -TaskPath $HeartbeatTaskPath -TaskName $HeartbeatTaskName -Action $action `
        -Trigger @($everyMinute, $atStartup) -Principal $principal -Settings $settings -Force `
        -Description 'Heartbeat do host: estado do Alloy no Loki e batida no Uptime Kuma. Gerenciado pelo heartbeat-setup.ps1.' | Out-Null
}

# Grava a URL com escrita atomica; a ACL vem da pasta (heranca).
function Save-PushUrl([string]$Value) {
    $temp = Join-Path $HeartbeatDir ('.kuma-url-' + [guid]::NewGuid().ToString('N') + '.tmp')
    try {
        [IO.File]::WriteAllText($temp, $Value, (New-Object System.Text.UTF8Encoding($false)))
        if (Test-Path -LiteralPath $HeartbeatUrlFile -PathType Leaf) {
            [IO.File]::Replace($temp, $HeartbeatUrlFile, [NullString]::Value)
        } else {
            [IO.File]::Move($temp, $HeartbeatUrlFile)
        }
    } finally {
        Remove-Item -LiteralPath $temp -Force -ErrorAction SilentlyContinue
    }
}

$hostName = Get-AlloyHostName
$task = Get-HeartbeatTask

# ------------------------------------------------------------------ remover
if ($Remove) {
    if (-not $task -and -not (Test-Path -LiteralPath $HeartbeatDir)) {
        Write-Log 'Heartbeat nao configurado; nada a remover.'
        return
    }
    if (-not $Yes -and -not (Confirm-Choice "Remover o heartbeat de ${hostName}?" $false)) {
        Write-Log 'Cancelado; nada foi alterado.'
        return
    }
    if ($task) { Unregister-ScheduledTask -TaskPath $HeartbeatTaskPath -TaskName $HeartbeatTaskName -Confirm:$false }
    if (Test-Path -LiteralPath $HeartbeatDir) { Remove-Item -LiteralPath $HeartbeatDir -Recurse -Force }
    Write-Ok 'Heartbeat removido (tarefa, URL, script, estado e logs).'
    Write-Warn "Pause ou exclua o monitor Push deste host no Uptime Kuma: sem batidas, ele vai para DOWN."
    return
}

# -------------------------------------------------------------------- testar
if ($Test) {
    if (-not (Test-HeartbeatConfigured)) { throw 'Heartbeat nao configurado.' }
    if (-not $task) { throw 'Tarefa agendada ausente (Alloy desinstalado?). Reconfigure o heartbeat.' }
    Write-Log 'Executando a tarefa agendada agora (como SYSTEM)...'
    $last = Invoke-HeartbeatTask
    Write-Host ''
    Write-RunResult $last
    if ($last.kuma -ne '200') { throw 'O Uptime Kuma nao confirmou a batida.' }
    return
}

# ---------------------------------------------------------------- configurar
$staged = Join-Path $PSScriptRoot 'heartbeat.ps1'
if (-not (Test-Path -LiteralPath $staged -PathType Leaf)) { throw 'heartbeat.ps1 nao encontrado ao lado de heartbeat-setup.ps1.' }
Assert-ScriptSyntax $staged

$candidate = $null
if ($Url) {
    $candidate = ConvertTo-PushUrl $Url
} else {
    if ([Console]::IsInputRedirected) { throw 'Sem terminal interativo: informe -Url.' }
    if ((Test-HeartbeatConfigured) -and (Confirm-Choice '  Usar a URL de push ja gravada?')) {
        $candidate = ConvertTo-PushUrl ([IO.File]::ReadAllText($HeartbeatUrlFile))
    } else {
        Write-Host '  No Uptime Kuma, crie um monitor do tipo Push para este host:'
        Write-Host ''
        Write-UiRow 'Nome' 'none' "heartbeat-$hostName"
        Write-UiRow 'Intervalo' 'none' '120 s (Heartbeat Interval)'
        Write-UiRow 'Tentativas' 'none' '1, com intervalo de 60 s (DOWN em ~3 min)'
        Write-Host ''
        Write-Host '  Copie a URL de push mostrada no monitor e cole abaixo.'
        Write-Host ''
        $candidate = ConvertTo-PushUrl (Read-Host '  URL de push')
    }
}
if (-not (Test-CredentialPresent)) {
    Write-Warn 'Sem credencial do Alloy: o estado nao vai para o Loki, so a batida no Kuma.'
}

# Batida de teste antes de gravar qualquer coisa (estado em pasta temporaria).
Write-Host ''
Write-Log 'Teste: estado local, Loki e batida no Uptime Kuma...'
$probeDir = Join-Path $env:TEMP ('alloy-heartbeat-' + [guid]::NewGuid().ToString('N'))
try {
    & $staged -Root $Base -KumaUrl $candidate -StateDir $probeDir | Out-Null
    $probe = Read-LastRun (Join-Path $probeDir 'last.json')
} finally {
    Remove-Item -LiteralPath $probeDir -Recurse -Force -ErrorAction SilentlyContinue
}
if (-not $probe) { throw 'O teste nao produziu resultado. Nada foi gravado.' }
Write-RunResult $probe
if ($probe.kuma -ne '200') { throw "Teste reprovado: $(Get-KumaHint $probe.kuma). Nada foi gravado." }

Ensure-Directory $Base
Ensure-Directory $HeartbeatDir
Set-PrivateDirectoryAcl $HeartbeatDir
Save-PushUrl $candidate
Copy-Item -LiteralPath $staged -Destination $HeartbeatScript -Force
Register-HeartbeatTask
Write-Host ''
Write-Log 'URL gravada e tarefa registrada. Conferindo a primeira execucao agendada...'
$last = Invoke-HeartbeatTask
if ($last.kuma -ne '200') {
    Write-RunResult $last
    throw "A tarefa executou, mas o Kuma nao confirmou: $(Get-KumaHint $last.kuma)."
}
Write-Ok "Heartbeat ativo: a cada minuto, como SYSTEM ($HeartbeatTaskPath$HeartbeatTaskName)."
