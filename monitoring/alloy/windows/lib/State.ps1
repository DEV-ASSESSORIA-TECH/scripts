# Leitura do estado local do Alloy (sem alterar nada), cabecalho e diagnostico.
# Requer lib\Common.ps1 e lib\Ui.ps1.

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

# O executavel do Alloy nao traz versao nos metadados. Ordem: registro de
# desinstalacao, depois "alloy --version". Cache ate o executavel mudar.
function Get-AlloyVersion {
    if (-not (Test-Path -LiteralPath $Exe -PathType Leaf)) { return $null }
    $stamp = (Get-Item -LiteralPath $Exe).LastWriteTimeUtc.Ticks
    if ($script:AlloyVersionStamp -eq $stamp) { return $script:AlloyVersion }
    $version = $null
    $entry = Get-AlloyUninstallEntry
    if ($entry -and $entry.DisplayVersion) { $version = [string]$entry.DisplayVersion }
    if (-not $version) {
        try {
            $line = & $Exe --version 2>$null | Select-Object -First 1
            if ($line -match 'v?(\d+\.\d+\.\d+[0-9A-Za-z.+-]*)') { $version = $Matches[1] }
        } catch { }
    }
    if (-not $version) { $version = '?' }
    $script:AlloyVersion = 'v' + ($version.Trim() -replace '^v', '')
    $script:AlloyVersionStamp = $stamp
    return $script:AlloyVersion
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

# Estado do servico: @{ Kind = ok|warn|err|off; Text = ... }
function Get-ServiceStatus {
    if (-not (Test-AlloyInstalled)) { return @{ Kind = 'off'; Text = 'nao instalado' } }
    if (Test-AlloyRunning) {
        if (Test-AlloyReady) { return @{ Kind = 'ok'; Text = 'ativo e pronto' } }
        return @{ Kind = 'warn'; Text = 'ativo, nao pronto' }
    }
    return @{ Kind = 'err'; Text = 'parado' }
}

# $script:LastStatus/$script:LastAction sao definidos pelo menu do alloy.ps1.
function Show-AlloyHeader {
    $status = Get-ServiceStatus
    $text = $status.Text
    if (Test-AlloyInstalled) { $text = $text.PadRight(22) + ' ' + (Get-AlloyVersion) }
    Write-UiBanner (Get-AlloyHostName)
    Write-UiRow 'Servico' $status.Kind $text
    if (Test-CredentialPresent) {
        $user = Get-CredentialUser
        if (-not $user) { $user = 'presente (conta ilegivel)' }
        Write-UiRow 'Credencial' 'ok' $user
    } else {
        Write-UiRow 'Credencial' 'warn' 'ausente'
    }
    $modules = 'Windows'
    if (Test-HyperVModule) { $modules += ' + Hyper-V' }
    Write-UiRow 'Modulos' 'none' $modules
    if ($script:LocalMode) {
        Write-UiRow 'Origem' 'none' 'arquivos locais'
    } elseif ((Get-AlloyRef) -ne 'main') {
        Write-UiRow 'Origem' 'none' ('ref ' + (Get-AlloyRef))
    }
    if ($script:LastAction) {
        $kind = if ($script:LastStatus) { $script:LastStatus } else { 'none' }
        Write-UiRow 'Ultima acao' $kind $script:LastAction
    }
    Write-UiRule '-'
}

# Resumo de uma linha (saida do menu e comandos diretos).
function Show-AlloySummary {
    $status = Get-ServiceStatus
    Write-Host '  Alloy ' -NoNewline
    Write-UiBadge $status.Kind
    $line = ' ' + $status.Text
    if (Test-CredentialPresent) {
        $user = Get-CredentialUser
        if (-not $user) { $user = 'presente' }
        $line += "  |  credencial $user"
    }
    Write-Host $line
}

# Teste de alcance: qualquer resposta HTTP comprova DNS, rota e TLS.
function Test-Endpoint([string]$Label, [string]$HostName) {
    $http = Get-HttpClient
    try {
        $request = [System.Net.Http.HttpRequestMessage]::new([System.Net.Http.HttpMethod]::Head, "https://$HostName/")
        $response = $http.SendAsync($request).GetAwaiter().GetResult()
        Write-UiRow $Label 'ok' "$HostName - HTTP $([int]$response.StatusCode)"
        $response.Dispose()
    } catch {
        Write-UiRow $Label 'err' "$HostName - sem resposta (DNS, rota ou TLS)"
    }
}

# Link do Explore ja filtrado (ultima 1h).
function Get-ExploreUrl([string]$Datasource, [string]$Expr) {
    $query = [ordered]@{ refId = 'A'; expr = $Expr }
    $pane = [ordered]@{ datasource = $Datasource; queries = @($query); range = [ordered]@{ from = 'now-1h'; to = 'now' } }
    $json = ConvertTo-Json -InputObject ([ordered]@{ a = $pane }) -Depth 6 -Compress
    return "$GrafanaUrl/explore?schemaVersion=1&orgId=1&panes=" + [Uri]::EscapeDataString($json)
}

function Write-Query([string]$Label, [string]$Datasource, [string]$Expr) {
    Write-UiRow $Label 'none' $Expr
    Write-UiText ((' ' * 23) + (Get-ExploreUrl $Datasource $Expr)) 'DarkGray'
}

# Tarefa agendada e ultimo arquivo gerado pelo inventario de VMs.
function Show-InventoryDiagnostics {
    Write-UiSection 'INVENTARIO DE VMS'
    $task = Get-ScheduledTask -TaskPath $InventoryTaskPath -TaskName $InventoryTaskName -ErrorAction SilentlyContinue
    if (-not $task) {
        Write-UiRow 'Tarefa' 'err' 'ausente: use [1] Reaplicar configuracao'
    } else {
        $info = Get-ScheduledTaskInfo -InputObject $task -ErrorAction SilentlyContinue
        $last = 'nunca executada'
        if ($info -and $info.LastRunTime -and $info.LastRunTime.Year -gt 2000) {
            $last = 'ultima ' + $info.LastRunTime.ToString('dd/MM HH:mm') + ', codigo ' + $info.LastTaskResult
        }
        $kind = 'ok'
        if ([string]$task.State -eq 'Disabled') { $kind = 'err' }
        elseif (-not $info -or $info.LastTaskResult -ne 0) { $kind = 'warn' }
        Write-UiRow 'Tarefa' $kind ("$($task.State) - $last")
    }
    if (Test-Path -LiteralPath $InventoryOutput -PathType Leaf) {
        $item = Get-Item -LiteralPath $InventoryOutput
        $age = [int]((Get-Date) - $item.LastWriteTime).TotalSeconds
        $content = [IO.File]::ReadAllLines($InventoryOutput)
        $ok = @($content | Where-Object { $_ -match '^hypervisor_inventory_success 1$' }).Count -gt 0
        $vms = @($content | Where-Object { $_ -like 'hypervisor_vm_info{*' }).Count
        $kind = if ($ok -and $age -lt 180) { 'ok' } elseif ($ok) { 'warn' } else { 'err' }
        $text = if ($ok) { "$vms VM(s), atualizado ha ${age}s" } else { "ultima execucao falhou (ha ${age}s)" }
        Write-UiRow 'Saida' $kind $text
    } else {
        Write-UiRow 'Saida' 'err' 'hypervisor.prom ausente'
    }
    Write-UiRow 'Logs' 'none' "$LogDir (retencao 14 dias)"
}

function Show-AlloyDiagnostics {
    $hostName = Get-AlloyHostName

    Write-UiSection 'SERVICO'
    $status = Get-ServiceStatus
    $svc = Get-AlloyService
    if (Test-AlloyInstalled) {
        Write-UiRow 'Estado' $status.Kind "$($status.Text) ($($svc.StartType))"
        Write-UiRow 'Versao' 'none' (Get-AlloyVersion)
        if ($status.Kind -ne 'err') {
            try {
                $processId = (Get-CimInstance -ClassName Win32_Service -Filter "Name='$ServiceName'" -ErrorAction Stop).ProcessId
                $started = (Get-Process -Id $processId -ErrorAction Stop).StartTime
                Write-UiRow 'Desde' 'none' $started.ToString('dd/MM/yyyy HH:mm')
            } catch { }
        }
    } else {
        Write-UiRow 'Estado' 'off' 'nao instalado'
    }
    $files = @(Get-ChildItem -LiteralPath $ConfigDir -Filter '*.alloy' -File -ErrorAction SilentlyContinue).Count
    Write-UiRow 'Config' 'none' "$ConfigDir ($files arquivo(s) .alloy)"
    if (Test-CredentialPresent) {
        Write-UiRow 'Credencial' 'ok' $Secret
    } else {
        Write-UiRow 'Credencial' 'warn' 'ausente'
    }

    if (Test-AlloyInstalled) {
        Write-UiSection 'AVISOS E ERROS (24H)'
        $events = @()
        try {
            $events = @(Get-WinEvent -FilterHashtable @{
                LogName = 'Application'; ProviderName = 'Alloy'; Level = 2, 3; StartTime = (Get-Date).AddHours(-24)
            } -MaxEvents 50 -ErrorAction Stop)
        } catch { }
        if ($events.Count -eq 0) {
            Write-UiRow 'Eventos' 'ok' 'nenhum aviso ou erro'
        } else {
            Write-UiRow 'Eventos' 'warn' "$($events.Count) evento(s); os mais recentes:"
            foreach ($evt in ($events | Select-Object -First 6)) {
                $message = (($evt.Message -split "`r?`n")[0]).Trim()
                $line = '    ' + $evt.TimeCreated.ToString('dd/MM HH:mm') + '  ' + $message
                if ($line.Length -gt $UiWidth + 14) { $line = $line.Substring(0, $UiWidth + 11) + '...' }
                Write-Host $line
            }
        }
    }

    if (Test-HyperVModule) { Show-InventoryDiagnostics }

    Write-UiSection 'CONECTIVIDADE'
    Test-Endpoint 'Auth' 'auth.assessoriatech.com'
    Test-Endpoint 'Mon' 'mon.assessoriatech.com'

    Write-UiSection 'GRAFANA - EXPLORE (ULTIMA 1H)'
    Write-Query 'Metricas' $GrafanaDsMetrics "up{job=`"integrations/windows`",host=`"$hostName`"}"
    Write-Query 'Logs' $GrafanaDsLogs "{job=`"windows-eventlog`",host=`"$hostName`"}"
    if (Test-HyperVModule) {
        Write-Query 'Hyper-V' $GrafanaDsMetrics "up{job=`"integrations/hyperv`",host=`"$hostName`"}"
        Write-Query 'Inventario' $GrafanaDsMetrics "hypervisor_inventory_success{job=`"integrations/hypervisor`",host=`"$hostName`"}"
        Write-Query 'Logs Hyper-V' $GrafanaDsLogs "{job=`"hyperv-eventlog`",host=`"$hostName`"}"
    }
    Write-Host ''
    Write-UiText '  Validar a credencial de ponta a ponta: opcao [4].' 'DarkGray'
}
