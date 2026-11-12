#Requires -RunAsAdministrator
#Requires -Version 5.1
# Instala ou reaplica o Alloy com validacao e rollback.
# -Modules: conjunto completo dos modulos opcionais.
#   auto (padrao)               mantem os ativos e oferece os detectados
#   hyperv, sqlanywhere, dbct   ativa exatamente os listados (os demais saem)
#   none                        desativa todos
#   dbct (DB Connection Tester) tambem vale no perfil estacao e nunca e
#   oferecido automaticamente.
# -ReconfigureSqlAnywhere: pede de novo servidor, banco e usuario do SQL Anywhere.
# -ReconfigureDbct: pede de novo o dbct.exe e a pasta do banco do DBCT.
# -Perfil: servidor (config.alloy, job integrations/windows, com alertas) ou
#   estacao (desktop.alloy, job integrations/windows-desktop: maquina
#   descartavel, sem alertas e sem modulos opcionais). auto (padrao) mantem o
#   instalado; na primeira instalacao, estacao se o Windows for de cliente.
[CmdletBinding()]
param(
    [switch]$Upgrade,
    [ValidateSet('auto','hyperv','sqlanywhere','dbct','none')]
    [string[]]$Modules = @('auto'),
    [switch]$ReconfigureSqlAnywhere,
    [switch]$ReconfigureDbct,
    [ValidateSet('auto','servidor','estacao')]
    [string]$Perfil = 'auto'
)

$ErrorActionPreference = 'Stop'
$Base = Join-Path $env:ProgramData 'GrafanaLabs\Alloy'
$Secret = Join-Path $Base 'oauth-client-secret'
$ConfigDir = Join-Path $Base 'config'
$DataDir = Join-Path $Base 'data'
$BookmarkDir = Join-Path $DataDir 'bookmarks'
$BackupDir = Join-Path $Base 'backups'
$Exe = Join-Path $env:ProgramFiles 'GrafanaLabs\Alloy\alloy-windows-amd64.exe'
$Registry = 'HKLM:\SOFTWARE\GrafanaLabs\Alloy'
$Service = 'Alloy'
# Instalador oficial: baixado para uma pasta FIXA (nunca %TEMP%\<aleatorio>, que
# antivirus com analise de comportamento, como o Bitdefender ATC, tratam como
# "script baixou e executou binario desconhecido"), conferido pelo SHA256SUMS
# da release e pela assinatura da Grafana Labs antes de executar. A pasta fixa
# permite exclusao por caminho no antivirus (README, secao Antivirus).
$InstallerDir = Join-Path $env:ProgramData 'AssessoriaTech\alloy-installer'
$InstallerZipName = 'alloy-installer-windows-amd64.exe.zip'
$InstallerExeName = 'alloy-installer-windows-amd64.exe'
$InstallerUrl = "https://github.com/grafana/alloy/releases/latest/download/$InstallerZipName"
# Assinante esperado (Microsoft Trusted Signing: o certificado muda a cada
# poucos dias, entao a conferencia e pelo nome, nunca pela impressao digital).
$InstallerSigner = 'Grafana Labs'
$ReadyTimeoutSeconds = 60
# Modulos com tarefa agendada: scripts\, textfile\<modulo>\ e logs\ sao
# compartilhados; cada modulo le apenas o proprio subdiretorio do textfile.
$ScriptsDir = Join-Path $Base 'scripts'
$TextfileDir = Join-Path $Base 'textfile'
$LogDir = Join-Path $Base 'logs'
# Inventario de VMs (modulo Hyper-V): script, saida do textfile, cache e logs.
$InventoryName = 'hypervisor-inventory.ps1'
$InventoryScript = Join-Path $ScriptsDir $InventoryName
$InventoryState = Join-Path $DataDir 'hypervisor'
$InventoryOutputDir = Join-Path $TextfileDir 'hypervisor'
$InventoryOutput = Join-Path $InventoryOutputDir 'hypervisor.prom'
# Versoes anteriores gravavam na raiz do textfile\.
$LegacyInventoryOutput = Join-Path $TextfileDir 'hypervisor.prom'
$InventoryTaskPath = '\GrafanaLabs\'
$InventoryTaskName = 'Alloy Hypervisor Inventory'
# Coletor SQL Anywhere: script, configuracao (com senha DPAPI), saida e logs.
$SqlCollectorName = 'sqlanywhere-collector.ps1'
$SqlCollectorScript = Join-Path $ScriptsDir $SqlCollectorName
$SqlState = Join-Path $DataDir 'sqlanywhere'
$SqlConfigFile = Join-Path $SqlState 'config.json'
$SqlPasswordFile = Join-Path $SqlState 'password.dpapi'
$SqlOutputDir = Join-Path $TextfileDir 'sqlanywhere'
$SqlOutput = Join-Path $SqlOutputDir 'sqlanywhere.prom'
$SqlTaskPath = '\GrafanaLabs\'
$SqlTaskName = 'Alloy SQL Anywhere'
$SqlDriver = 'SQL Anywhere 17'
$SqlDefaultLinks = 'SharedMemory,TCPIP(HOST=127.0.0.1)'
# Mesma entropia do sqlanywhere-collector.ps1.
$SqlEntropy = [Text.Encoding]::UTF8.GetBytes('AssessoriaTech-Alloy-SQLAnywhere')
# DB Connection Tester: so o coletor (a cada 30 s). A execucao continua e do
# proprio DBCT (dbct run ... --autostart); o modulo apenas le o banco.
$DbctCollectorName = 'dbct-collector.ps1'
$DbctCollectorScript = Join-Path $ScriptsDir $DbctCollectorName
$DbctState = Join-Path $DataDir 'dbct'
$DbctConfigFile = Join-Path $DbctState 'config.json'
$DbctOutputDir = Join-Path $TextfileDir 'dbct'
$DbctOutput = Join-Path $DbctOutputDir 'dbct.prom'
$DbctTaskPath = '\GrafanaLabs\'
$DbctCollectorTask = 'Alloy DBCT Collector'

function Log([string]$Text) { Write-Host "[Alloy] $Text" }
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
function Same-File([string]$A, [string]$B) {
    if (-not (Test-Path -LiteralPath $B -PathType Leaf)) { return $false }
    return (Get-FileHash -LiteralPath $A -Algorithm SHA256).Hash -ceq (Get-FileHash -LiteralPath $B -Algorithm SHA256).Hash
}
# Cliente HTTP sem proxy para 127.0.0.1: o Invoke-WebRequest do 5.1 tenta
# descobrir proxy (WPAD) e pode levar segundos por tentativa.
function Get-LocalHttp {
    if (-not $script:LocalHttp) {
        Add-Type -AssemblyName System.Net.Http
        $handler = [System.Net.Http.HttpClientHandler]::new()
        $handler.UseProxy = $false
        $script:LocalHttp = [System.Net.Http.HttpClient]::new($handler)
        $script:LocalHttp.Timeout = [TimeSpan]::FromSeconds(2)
    }
    return $script:LocalHttp
}

# Ate $ReadyTimeoutSeconds: a primeira inicializacao numa estacao pode demorar
# (o antivirus examina o executavel novo). Volta assim que o Alloy responde.
function Ready {
    $deadline = (Get-Date).AddSeconds($ReadyTimeoutSeconds)
    while ((Get-Date) -lt $deadline) {
        $svc = Get-Service -Name $Service -ErrorAction SilentlyContinue
        if ($svc -and $svc.Status -eq 'Running') {
            try {
                $resp = (Get-LocalHttp).GetAsync('http://127.0.0.1:12345/-/ready').GetAwaiter().GetResult()
                try { if ([int]$resp.StatusCode -eq 200) { return $true } } finally { $resp.Dispose() }
            } catch { }
        }
        Start-Sleep -Seconds 1
    }
    return $false
}

# Ultimas mensagens do Alloy no Event Viewer desde $Since (para o erro).
function Get-AlloyEventSummary([datetime]$Since) {
    try {
        $events = @(Get-WinEvent -FilterHashtable @{ LogName = 'Application'; ProviderName = 'Alloy'; StartTime = $Since } -MaxEvents 40 -ErrorAction Stop)
        $lines = @($events | Where-Object { $_.Message -match 'level=(warn|error)|level=(WARN|ERROR)|failed|error' } |
            Select-Object -First 4 | ForEach-Object { '  ' + (($_.Message -split "`r?`n")[0]).Trim() })
        if ($lines.Count -eq 0) { $lines = @($events | Select-Object -First 2 | ForEach-Object { '  ' + (($_.Message -split "`r?`n")[0]).Trim() }) }
        if ($lines.Count -gt 0) { return "`nUltimos eventos do Alloy (Event Viewer > Aplicativo):`n" + ($lines -join "`n") }
    } catch { }
    return ''
}

# Texto padrao quando o antivirus e o suspeito provavel.
function Get-AntivirusHint {
    return "`nProvavel bloqueio do antivirus (ex.: Bitdefender Advanced Threat Control): verifique a quarentena e as exclusoes " +
        "de $InstallerDir, $(Split-Path -Parent $Exe) e $Base (README, secao Antivirus)."
}

# Baixa o instalador oficial para $InstallerDir e confere SHA256 (SHA256SUMS
# da mesma release) e assinatura (Grafana Labs). Devolve o caminho do .exe.
function Get-VerifiedInstaller {
    # ProgramData permite que qualquer usuario crie pastas: a pasta-mae tambem
    # fica so para SYSTEM e Administradores (dono incluso), para ninguem trocar
    # o instalador entre a conferencia e a execucao.
    $installerParent = Split-Path -Parent $InstallerDir
    Ensure-Directory $installerParent
    Set-PrivateDirectoryAcl $installerParent
    Ensure-Directory $InstallerDir
    Set-PrivateDirectoryAcl $InstallerDir
    Get-ChildItem -LiteralPath $InstallerDir -Force | Remove-Item -Recurse -Force
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    Add-Type -AssemblyName System.Net.Http
    # Versao atual: "latest" redireciona para releases/download/vX.Y.Z/<arquivo>.
    # So o primeiro redirecionamento traz a versao (o seguinte vai para o CDN),
    # entao esta consulta nao segue redirecionamentos.
    $probeHandler = [System.Net.Http.HttpClientHandler]::new()
    $probeHandler.AllowAutoRedirect = $false
    $probe = [System.Net.Http.HttpClient]::new($probeHandler)
    try {
        $probe.Timeout = [TimeSpan]::FromSeconds(30)
        $probe.DefaultRequestHeaders.UserAgent.ParseAdd('AssessoriaTech-Alloy-Installer/1.0')
        $response = $probe.GetAsync($InstallerUrl).GetAwaiter().GetResult()
        try {
            $location = if ($response.Headers.Location) { $response.Headers.Location.ToString() } else { '' }
        } finally { $response.Dispose() }
    } finally { $probe.Dispose() }
    if ($location -notmatch '/releases/download/(v[0-9][A-Za-z0-9.+-]*)/') {
        throw "Nao foi possivel identificar a versao atual do Alloy (redirecionamento: '$location')."
    }
    $release = $Matches[1]
    $releaseBase = "https://github.com/grafana/alloy/releases/download/$release"

    $http = [System.Net.Http.HttpClient]::new()
    try {
        $http.Timeout = [TimeSpan]::FromMinutes(5)
        $http.DefaultRequestHeaders.UserAgent.ParseAdd('AssessoriaTech-Alloy-Installer/1.0')
        Log "Baixando instalador oficial do Grafana Alloy ($release)..."
        $zip = Join-Path $InstallerDir $InstallerZipName
        $response = $http.GetAsync("$releaseBase/$InstallerZipName").GetAwaiter().GetResult()
        try {
            if (-not $response.IsSuccessStatusCode) { throw "Download do instalador falhou (HTTP $([int]$response.StatusCode))." }
            [IO.File]::WriteAllBytes($zip, $response.Content.ReadAsByteArrayAsync().GetAwaiter().GetResult())
        } finally { $response.Dispose() }
        $sums = $http.GetStringAsync("$releaseBase/SHA256SUMS").GetAwaiter().GetResult()
    } finally { $http.Dispose() }

    $expected = @{}
    foreach ($line in ($sums -split "`n")) {
        if ($line.Trim() -match '^([0-9a-fA-F]{64})\s+\*?(\S+)$') { $expected[$Matches[2]] = $Matches[1].ToLowerInvariant() }
    }
    if (-not $expected.ContainsKey($InstallerZipName)) { throw "SHA256SUMS da release $release nao lista $InstallerZipName." }
    $zipHash = (Get-FileHash -LiteralPath $zip -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($zipHash -ne $expected[$InstallerZipName]) { throw "SHA256 do instalador nao confere com a release $release. Download descartado." }

    $unpack = Join-Path $InstallerDir 'package'
    Ensure-Directory $unpack
    Expand-Archive -LiteralPath $zip -DestinationPath $unpack -Force
    $installer = Join-Path $unpack $InstallerExeName
    if (-not (Test-Path -LiteralPath $installer -PathType Leaf)) {
        throw ("Executavel do instalador ausente depois de extrair (removido logo apos a extracao?)." + (Get-AntivirusHint))
    }
    if ($expected.ContainsKey($InstallerExeName) -and
        (Get-FileHash -LiteralPath $installer -Algorithm SHA256).Hash.ToLowerInvariant() -ne $expected[$InstallerExeName]) {
        throw "SHA256 de $InstallerExeName nao confere com a release $release."
    }

    $signature = Get-AuthenticodeSignature -LiteralPath $installer
    $subject = if ($signature.SignerCertificate) { $signature.SignerCertificate.Subject } else { '' }
    if ([string]$signature.Status -in @('NotSigned', 'HashMismatch', 'NotSupportedFileFormat')) {
        throw "Instalador sem assinatura valida ($($signature.Status)). Execucao cancelada."
    }
    if ($subject -notmatch ('(^|,\s*)CN=' + [regex]::Escape($InstallerSigner) + '(,|$)') -or
        $subject -notmatch ('(^|,\s*)O=' + [regex]::Escape($InstallerSigner) + '(,|$)')) {
        throw "Instalador assinado por '$subject', esperado $InstallerSigner. Execucao cancelada."
    }
    if ([string]$signature.Status -ne 'Valid') {
        # Ex.: raiz da Microsoft ausente num Windows sem atualizacoes. O SHA256
        # ja confere com a release; o assinante tambem.
        Write-Warning "Cadeia do certificado nao validada neste Windows ($($signature.Status)); SHA256 e assinante conferem. Atualize os certificados raiz."
    }
    Log "Instalador $release conferido (SHA256 da release e assinatura $InstallerSigner)."
    return $installer
}

# Executa o instalador oficial (silencioso) e confere o resultado.
function Install-AlloyPackage {
    $installer = Get-VerifiedInstaller
    try {
        $p = Start-Process -FilePath $installer -ArgumentList @('/S', '/DISABLEREPORTING=yes') -Wait -PassThru
    } catch {
        throw ("Nao foi possivel executar o instalador: $($_.Exception.Message)" + (Get-AntivirusHint))
    }
    if ($p.ExitCode -ne 0) {
        throw ("Instalador interrompido ou com erro (codigo $($p.ExitCode))." + (Get-AntivirusHint))
    }
    $missing = @()
    if (-not (Test-Path -LiteralPath $Exe -PathType Leaf)) { $missing += 'executavel' }
    if (-not (Get-Service -Name $Service -ErrorAction SilentlyContinue)) { $missing += 'servico' }
    if (-not (Test-Path -LiteralPath $Registry)) { $missing += 'registro' }
    if ($missing.Count -gt 0) {
        throw ("Alloy nao foi instalado corretamente (ausente: $($missing -join ', '))." + (Get-AntivirusHint))
    }
    # A pasta fica (para a exclusao do antivirus); o conteudo sai.
    Get-ChildItem -LiteralPath $InstallerDir -Force -ErrorAction SilentlyContinue | Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
}
function Set-PrivateDirectoryAcl([string]$Path) {
    $acl = [System.Security.AccessControl.DirectorySecurity]::new()
    $acl.SetAccessRuleProtection($true, $false)
    $admin = [System.Security.Principal.SecurityIdentifier]::new('S-1-5-32-544')
    $acl.SetOwner($admin)
    foreach ($sid in @('S-1-5-18', 'S-1-5-32-544')) {
        $id = [System.Security.Principal.SecurityIdentifier]::new($sid)
        $inherit = [System.Security.AccessControl.InheritanceFlags]::ContainerInherit -bor [System.Security.AccessControl.InheritanceFlags]::ObjectInherit
        $rule = [System.Security.AccessControl.FileSystemAccessRule]::new($id, [System.Security.AccessControl.FileSystemRights]::FullControl, $inherit, [System.Security.AccessControl.PropagationFlags]::None, [System.Security.AccessControl.AccessControlType]::Allow)
        $acl.AddAccessRule($rule)
    }
    Set-Acl -LiteralPath $Path -AclObject $acl
}

# Arquivo do modulo: do clone local, ou baixado do mesmo ref do alloy.ps1
# (ALLOY_REF; padrao: main).
function Copy-ModuleFile([string]$Name, [string]$Destination) {
    $local = Join-Path $PSScriptRoot $Name
    if (Test-Path -LiteralPath $local -PathType Leaf) {
        Copy-Item -LiteralPath $local -Destination $Destination
        return
    }
    $ref = if ($env:ALLOY_REF) { $env:ALLOY_REF } else { 'main' }
    if ($ref -notmatch '^[A-Za-z0-9][A-Za-z0-9._/-]*$' -or $ref.Contains('..')) {
        throw "ALLOY_REF invalido: $ref"
    }
    Log "Baixando $Name (ref $ref)..."
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    $raw = "https://raw.githubusercontent.com/DEV-ASSESSORIA-TECH/scripts/$ref/monitoring/alloy/windows/$Name"
    Invoke-WebRequest -Uri $raw -OutFile $Destination -UseBasicParsing -Headers @{ 'User-Agent' = 'AssessoriaTech-Alloy-Installer/1.0' }
    if (-not (Test-Path -LiteralPath $Destination) -or (Get-Item -LiteralPath $Destination).Length -eq 0) {
        throw "Download de $Name vazio."
    }
}

# O script roda como SYSTEM: so e instalado se o parser do PowerShell aceitar.
function Assert-ScriptSyntax([string]$Path) {
    $tokens = $null
    $errors = $null
    [void][System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$tokens, [ref]$errors)
    if ($errors -and $errors.Count -gt 0) {
        $first = $errors[0]
        throw "$(Split-Path -Leaf $Path) com erro de sintaxe (linha $($first.Extent.StartLineNumber)): $($first.Message)"
    }
}

# Inventario de VMs: script em scripts\, tarefa agendada a cada minuto como
# SYSTEM e primeira execucao conferida. Desabilitado: remove tarefa, script,
# saida, cache e logs do inventario.
function Sync-HypervisorInventory([bool]$Enabled, [string]$StagedScript) {
    $task = Get-ScheduledTask -TaskPath $InventoryTaskPath -TaskName $InventoryTaskName -ErrorAction SilentlyContinue
    if (-not $Enabled) {
        $hadFiles = (Test-Path -LiteralPath $InventoryScript) -or (Test-Path -LiteralPath $InventoryOutput)
        if ($task) { Unregister-ScheduledTask -TaskPath $InventoryTaskPath -TaskName $InventoryTaskName -Confirm:$false }
        foreach ($path in @($InventoryScript, $InventoryOutput, ($InventoryOutput + '.tmp'))) {
            Remove-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue
        }
        if (Test-Path -LiteralPath $InventoryState) { Remove-Item -LiteralPath $InventoryState -Recurse -Force -ErrorAction SilentlyContinue }
        if (Test-Path -LiteralPath $LogDir) {
            Get-ChildItem -LiteralPath $LogDir -Filter 'hypervisor-inventory-*.log' -File -ErrorAction SilentlyContinue |
                Remove-Item -Force -ErrorAction SilentlyContinue
        }
        if ($task -or $hadFiles) { Log 'Inventario de VMs removido (tarefa, script, saida e logs).' }
        return
    }

    if (-not (Same-File $StagedScript $InventoryScript)) {
        Copy-Item -LiteralPath $StagedScript -Destination $InventoryScript -Force
        Log "Inventario de VMs: script instalado em $InventoryScript."
    }

    $everyMinute = New-ScheduledTaskTrigger -Once -At (Get-Date).Date -RepetitionInterval (New-TimeSpan -Minutes 1)
    Register-CollectorTask $InventoryTaskPath $InventoryTaskName $InventoryScript @($everyMinute) (New-TimeSpan -Minutes 5) `
        'Inventario de VMs para o Grafana Alloy (textfile\hypervisor\hypervisor.prom). Gerenciado pelo install.ps1.'

    $content = Invoke-FirstRun $InventoryTaskPath $InventoryTaskName $InventoryOutput 90 'Inventario de VMs'
    $ok = @($content | Where-Object { $_ -match '^hypervisor_inventory_success 1$' }).Count -gt 0
    $vmCount = @($content | Where-Object { $_ -like 'hypervisor_vm_info{*' }).Count
    $problems = ($content | Where-Object { $_ -like 'hypervisor_inventory_problems *' } | Select-Object -First 1) -replace '^\S+\s+', ''
    if (-not $ok) { throw "Inventario de VMs falhou na primeira execucao. Veja os logs em $LogDir." }
    $note = if ($problems -and $problems -ne '0') { " ($problems aviso(s); veja $LogDir)" } else { '' }
    Log "Inventario de VMs ativo: $vmCount VM(s), atualizado a cada minuto$note."
}

# Tarefa agendada de coletor textfile: SYSTEM (pelo SID: o nome muda com o
# idioma do Windows), sem execucoes simultaneas, tambem na inicializacao.
function Register-CollectorTask([string]$TaskPath, [string]$TaskName, [string]$Script, [object[]]$Triggers,
                                [TimeSpan]$TimeLimit, [string]$Description) {
    $system = ([System.Security.Principal.SecurityIdentifier]::new('S-1-5-18')).Translate([System.Security.Principal.NTAccount]).Value
    $powershell = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $action = New-ScheduledTaskAction -Execute $powershell -Argument ('-NoProfile -NonInteractive -ExecutionPolicy Bypass -File "{0}"' -f $Script)
    $atStartup = New-ScheduledTaskTrigger -AtStartup
    $principal = New-ScheduledTaskPrincipal -UserId $system -LogonType ServiceAccount -RunLevel Highest
    $settings = New-ScheduledTaskSettingsSet -MultipleInstances IgnoreNew -ExecutionTimeLimit $TimeLimit `
        -StartWhenAvailable -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries
    Register-ScheduledTask -TaskPath $TaskPath -TaskName $TaskName -Action $action `
        -Trigger (@($Triggers) + $atStartup) -Principal $principal -Settings $settings -Force `
        -Description $Description | Out-Null
}

# Primeira execucao agora, para nao esperar o proximo ciclo. Devolve as
# linhas do .prom gerado.
function Invoke-FirstRun([string]$TaskPath, [string]$TaskName, [string]$Output, [int]$TimeoutSeconds, [string]$Label) {
    $before = if (Test-Path -LiteralPath $Output) { (Get-Item -LiteralPath $Output).LastWriteTimeUtc } else { [datetime]::MinValue }
    Start-ScheduledTask -TaskPath $TaskPath -TaskName $TaskName
    for ($i = 0; $i -lt [Math]::Ceiling($TimeoutSeconds / 2); $i++) {
        Start-Sleep -Seconds 2
        $state = (Get-ScheduledTask -TaskPath $TaskPath -TaskName $TaskName).State
        if ((Test-Path -LiteralPath $Output) -and (Get-Item -LiteralPath $Output).LastWriteTimeUtc -gt $before -and $state -ne 'Running') {
            return [IO.File]::ReadAllLines($Output)
        }
    }
    throw "$Label nao gerou $Output em ${TimeoutSeconds}s. Veja os logs em $LogDir."
}

# ------------------------------------------------------------ SQL Anywhere

# Servico ou processo do servidor de rede (dbsrv17) ou pessoal (dbeng17).
function Test-SqlAnywhere {
    $services = @(Get-CimInstance -ClassName Win32_Service -ErrorAction SilentlyContinue | Where-Object {
        $_.PathName -match '(?i)\bdb(srv|eng)17\.exe\b'
    })
    if ($services.Count -gt 0) { return $true }
    return @(Get-Process -Name dbsrv17, dbeng17 -ErrorAction SilentlyContinue).Count -gt 0
}

# O coletor roda no PowerShell de 64 bits: precisa do driver de 64 bits.
function Test-SqlAnywhereDriver {
    if (-not (Get-Command Get-OdbcDriver -ErrorAction SilentlyContinue)) { return $false }
    return @(Get-OdbcDriver -Name $SqlDriver -Platform '64-bit' -ErrorAction SilentlyContinue).Count -gt 0
}

function Test-SqlAnywhereSettings {
    (Test-Path -LiteralPath $SqlConfigFile -PathType Leaf) -and (Test-Path -LiteralPath $SqlPasswordFile -PathType Leaf)
}

# Mesma conexao do coletor; devolve a versao do servidor.
function Test-SqlAnywhereConnection([hashtable]$Settings) {
    $builder = New-Object System.Data.Odbc.OdbcConnectionStringBuilder
    $builder['Driver'] = $SqlDriver
    $builder['ServerName'] = $Settings.server
    $builder['DatabaseName'] = $Settings.database
    $builder['UID'] = $Settings.user
    $builder['PWD'] = $Settings.password
    $builder['LINKS'] = $Settings.links
    $connection = New-Object System.Data.Odbc.OdbcConnection($builder.ConnectionString)
    try {
        $connection.ConnectionTimeout = 5
        $connection.Open()
        $cmd = $connection.CreateCommand()
        $cmd.CommandTimeout = 8
        $cmd.CommandText = "SELECT PROPERTY('ProductVersion')"
        return [string]$cmd.ExecuteScalar()
    } finally {
        $connection.Dispose()
    }
}

function Read-Value([string]$Prompt, [string]$Default) {
    $hint = if ($Default) { " [$Default]" } else { '' }
    $value = (Read-Host "$Prompt$hint").Trim()
    if (-not $value) { $value = $Default }
    if (-not $value) { throw "$Prompt e obrigatorio." }
    return $value
}

# Pede servidor, banco e usuario (padrao: valores gravados) e testa a conexao
# antes de aceitar. Nada e gravado aqui: Save-SqlAnywhereSettings grava
# depois da validacao do Alloy.
function Read-SqlAnywhereSettings {
    $current = $null
    if (Test-Path -LiteralPath $SqlConfigFile -PathType Leaf) {
        try { $current = [IO.File]::ReadAllText($SqlConfigFile) | ConvertFrom-Json } catch { }
    }
    Write-Host ''
    Write-Host '  Monitoramento do SQL Anywhere: informe um usuario SQL somente leitura.'
    Write-Host '  Ele so executa PROPERTY() e DB_PROPERTY(); nao precisa ler tabelas.'
    $settings = @{
        server   = Read-Value 'Nome do servidor SQL Anywhere (ENG)' ([string]$current.server)
        database = Read-Value 'Nome do banco (DBN)' ([string]$current.database)
        user     = Read-Value 'Usuario de monitoramento' ([string]$current.user)
        links    = if ($current -and $current.links) { [string]$current.links } else { $SqlDefaultLinks }
    }
    $secure = Read-Host 'Senha' -AsSecureString
    if ($secure.Length -eq 0) { throw 'Senha e obrigatoria.' }
    $ptr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure)
    try { $settings.password = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($ptr) }
    finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($ptr) }
    Log 'Testando a conexao com o SQL Anywhere...'
    try {
        $version = Test-SqlAnywhereConnection $settings
    } catch {
        throw "Conexao ao SQL Anywhere falhou: $($_.Exception.Message)"
    }
    Log "Conexao OK (SQL Anywhere $version)."
    return $settings
}

# Senha com DPAPI (escopo da maquina) alem da ACL de data\: uma copia do
# arquivo fora deste servidor nao revela a senha.
function Save-SqlAnywhereSettings([hashtable]$Settings) {
    Ensure-Directory $SqlState
    Add-Type -AssemblyName System.Security
    $blob = [Security.Cryptography.ProtectedData]::Protect([Text.Encoding]::UTF8.GetBytes($Settings.password), $SqlEntropy,
        [Security.Cryptography.DataProtectionScope]::LocalMachine)
    [IO.File]::WriteAllBytes($SqlPasswordFile, $blob)
    $json = [ordered]@{ server = $Settings.server; database = $Settings.database; user = $Settings.user; links = $Settings.links } |
        ConvertTo-Json
    [IO.File]::WriteAllText($SqlConfigFile, $json, (New-Object System.Text.UTF8Encoding($false)))
    Log "SQL Anywhere: configuracao gravada em $SqlState."
}

# Coletor: script em scripts\, tarefa a cada 30 s como SYSTEM (duas fases de
# 1 min defasadas em 30 s: o Agendador nao repete em menos de 1 min) e
# primeira execucao conferida. Desabilitado: remove tarefa, script, saida e
# logs; a configuracao fica para reativar (a limpeza completa a remove).
function Sync-SqlAnywhereCollector([bool]$Enabled, [string]$StagedScript) {
    $task = Get-ScheduledTask -TaskPath $SqlTaskPath -TaskName $SqlTaskName -ErrorAction SilentlyContinue
    if (-not $Enabled) {
        $hadFiles = (Test-Path -LiteralPath $SqlCollectorScript) -or (Test-Path -LiteralPath $SqlOutput)
        if ($task) { Unregister-ScheduledTask -TaskPath $SqlTaskPath -TaskName $SqlTaskName -Confirm:$false }
        foreach ($path in @($SqlCollectorScript, $SqlOutput, ($SqlOutput + '.tmp'), (Join-Path $SqlState 'missing-properties.txt'))) {
            Remove-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue
        }
        if (Test-Path -LiteralPath $LogDir) {
            Get-ChildItem -LiteralPath $LogDir -Filter 'sqlanywhere-collector-*.log' -File -ErrorAction SilentlyContinue |
                Remove-Item -Force -ErrorAction SilentlyContinue
        }
        if ($task -or $hadFiles) {
            Log "Coletor SQL Anywhere removido (tarefa, script, saida e logs). Configuracao mantida em $SqlState."
        }
        return
    }

    if (-not (Same-File $StagedScript $SqlCollectorScript)) {
        Copy-Item -LiteralPath $StagedScript -Destination $SqlCollectorScript -Force
        Log "Coletor SQL Anywhere: script instalado em $SqlCollectorScript."
    }

    $start = (Get-Date).Date
    $phaseA = New-ScheduledTaskTrigger -Once -At $start -RepetitionInterval (New-TimeSpan -Minutes 1)
    $phaseB = New-ScheduledTaskTrigger -Once -At $start.AddSeconds(30) -RepetitionInterval (New-TimeSpan -Minutes 1)
    Register-CollectorTask $SqlTaskPath $SqlTaskName $SqlCollectorScript @($phaseA, $phaseB) (New-TimeSpan -Seconds 25) `
        'Metricas do SQL Anywhere para o Grafana Alloy (textfile\sqlanywhere\sqlanywhere.prom). Gerenciado pelo install.ps1.'

    $content = Invoke-FirstRun $SqlTaskPath $SqlTaskName $SqlOutput 40 'Coletor SQL Anywhere'
    $ok = @($content | Where-Object { $_ -match '^sqlanywhere_collection_success 1$' }).Count -gt 0
    if (-not $ok) { throw "Coletor SQL Anywhere falhou na primeira execucao. Veja os logs em $LogDir." }
    $missing = ($content | Where-Object { $_ -like 'sqlanywhere_collection_missing_properties *' } | Select-Object -First 1) -replace '^\S+\s+', ''
    $note = if ($missing -and $missing -ne '0') { " ($missing propriedade(s) sem valor; veja $LogDir)" } else { '' }
    Log "Coletor SQL Anywhere ativo, atualizado a cada 30 s$note."
}

# ------------------------------------------------------- DB Connection Tester

# Regras do Windows para argumentos (mesmas do dbct-collector.ps1).
function ConvertTo-DbctArgument([string]$Value) {
    if ($Value -and $Value -notmatch '[\s"]') { return $Value }
    $escaped = [regex]::Replace($Value, '(\\*)"', '$1$1\"')
    $escaped = [regex]::Replace($escaped, '(\\+)$', '$1$1')
    return '"' + $escaped + '"'
}

# Executa o dbct e devolve codigo, stdout e stderr. StdIn opcional (senha).
function Invoke-DbctCommand([string]$Dbct, [string[]]$Arguments, [string]$StdIn = $null, [int]$TimeoutSeconds = 60) {
    $utf8 = New-Object System.Text.UTF8Encoding($false)
    $info = New-Object System.Diagnostics.ProcessStartInfo
    $info.FileName = $Dbct
    $info.Arguments = (@($Arguments | ForEach-Object { ConvertTo-DbctArgument $_ }) -join ' ')
    $info.UseShellExecute = $false
    $info.CreateNoWindow = $true
    $info.RedirectStandardInput = $true
    $info.RedirectStandardOutput = $true
    $info.RedirectStandardError = $true
    $info.StandardOutputEncoding = $utf8
    $info.StandardErrorEncoding = $utf8
    $process = [Diagnostics.Process]::Start($info)
    try {
        $stdout = $process.StandardOutput.ReadToEndAsync()
        $stderr = $process.StandardError.ReadToEndAsync()
        if ($null -ne $StdIn) { $process.StandardInput.WriteLine($StdIn) }
        $process.StandardInput.Close()
        if (-not $process.WaitForExit($TimeoutSeconds * 1000)) {
            try { $process.Kill() } catch { }
            throw "dbct $($Arguments[0]) excedeu ${TimeoutSeconds}s."
        }
        $process.WaitForExit()
        return @{ ExitCode = $process.ExitCode; Output = $stdout.GetAwaiter().GetResult(); Error = ($stderr.GetAwaiter().GetResult()).Trim() }
    } finally { $process.Dispose() }
}

function Invoke-DbctJson([string]$Dbct, [string[]]$Arguments) {
    $result = Invoke-DbctCommand $Dbct $Arguments
    if ($result.ExitCode -ne 0) { throw "dbct $($Arguments[0]) $($Arguments[1]) retornou $($result.ExitCode): $($result.Error)" }
    return ($result.Output | ConvertFrom-Json).data
}

# dbct.exe instalado (MSI por maquina ou por usuario), no PATH ou portatil.
function Find-DbctExecutables {
    $found = @()
    $command = Get-Command dbct.exe -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($command) { $found += $command.Source }
    $found += Join-Path $env:ProgramFiles 'DBConnectionTester\dbct.exe'
    $users = Join-Path $env:SystemDrive 'Users'
    $found += @(Get-ChildItem -Path (Join-Path $users '*\AppData\Local\Programs\DBConnectionTester\dbct.exe') -File -ErrorAction SilentlyContinue |
        ForEach-Object { $_.FullName })
    return @($found | Where-Object { Test-Path -LiteralPath $_ -PathType Leaf } | Select-Object -Unique)
}

# Pastas com data.db, na ordem em que sao sugeridas: as das execucoes
# automaticas do DBCT (tarefas "\DB Connection Tester\...", o caso tipico de
# monitoramento), as de ProgramData\DBConnectionTester\Monitor\<nome>, a
# compartilhada, as locais de cada usuario e a portatil (Data ao lado do dbct.exe).
function Find-DbctDataDirs([string]$Dbct) {
    $found = @()
    foreach ($task in @(Get-ScheduledTask -TaskPath '\DB Connection Tester\' -ErrorAction SilentlyContinue)) {
        foreach ($action in @($task.Actions)) {
            if ([string]$action.Arguments -match '--data-dir\s+(?:"([^"]+)"|(\S+))') {
                $found += $(if ($Matches[1]) { $Matches[1] } else { $Matches[2] }).TrimEnd('\')
            }
        }
    }
    $monitor = Join-Path $env:ProgramData 'DBConnectionTester\Monitor'
    $found += @(Get-ChildItem -LiteralPath $monitor -Directory -ErrorAction SilentlyContinue | ForEach-Object { $_.FullName })
    $found += Join-Path $env:ProgramData 'DBConnectionTester'
    $users = Join-Path $env:SystemDrive 'Users'
    $found += @(Get-ChildItem -Path (Join-Path $users '*\AppData\Local\DBConnectionTester') -Directory -ErrorAction SilentlyContinue |
        ForEach-Object { $_.FullName })
    if ($Dbct) { $found += Join-Path (Split-Path -Parent $Dbct) 'Data' }
    return @($found | Where-Object { Test-Path -LiteralPath (Join-Path $_ 'data.db') -PathType Leaf } | Select-Object -Unique)
}

function Test-DbctSettings { Test-Path -LiteralPath $DbctConfigFile -PathType Leaf }

function Select-DbctValue([string]$Title, [string[]]$Options, [string]$Current) {
    $default = if ($Current) { $Current } elseif ($Options.Count -gt 0) { $Options[0] } else { '' }
    if ($Options.Count -gt 0) {
        Write-Host "  $Title encontrados:"
        foreach ($option in $Options) { Write-Host "    $option" }
    }
    return (Read-Value $Title $default).Trim().Trim('"').TrimEnd('\')
}

# Pede o dbct.exe e a pasta do banco e valida os dois com a propria CLI. A
# execucao continua nao e configurada aqui: e do DBCT (dbct run ... --autostart).
# Nada e gravado aqui: Save-DbctSettings grava depois da validacao do Alloy.
function Read-DbctSettings {
    $current = $null
    if (Test-Path -LiteralPath $DbctConfigFile -PathType Leaf) {
        try { $current = [IO.File]::ReadAllText($DbctConfigFile) | ConvertFrom-Json } catch { }
    }
    Write-Host ''
    Write-Host '  Monitoramento do DB Connection Tester: o coletor le, a cada 30 s, a execucao'
    Write-Host '  ativa no banco do DBCT (data.db) e publica falhas e lentidoes no Prometheus.'
    $dbct = Select-DbctValue 'dbct.exe' (Find-DbctExecutables) ([string]$current.dbct)
    if (-not (Test-Path -LiteralPath $dbct -PathType Leaf)) { throw "dbct.exe nao encontrado: $dbct" }
    foreach ($required in @(@('history', 'cycles', '--help'), @('run', 'status', '--help'))) {
        if ((Invoke-DbctCommand $dbct $required).ExitCode -ne 0) {
            throw "Este dbct.exe nao oferece ""$($required[0]) $($required[1])"": atualize o DB Connection Tester."
        }
    }
    $dataDir = Select-DbctValue 'Pasta do banco do DBCT (com data.db)' (Find-DbctDataDirs $dbct) ([string]$current.dataDir)
    if (-not (Test-Path -LiteralPath (Join-Path $dataDir 'data.db') -PathType Leaf)) { throw "data.db nao encontrado em $dataDir" }
    $common = @('--data-dir', $dataDir, '--format', 'json')
    $status = Invoke-DbctJson $dbct (@('run', 'status') + $common)
    Log "Banco do DBCT OK: $dataDir"
    $autostart = Invoke-DbctJson $dbct (@('autostart', 'show') + $common)
    if ($autostart.enabled) {
        Log "Execucao automatica do DBCT configurada neste banco ($($autostart.scope))."
    } elseif (-not $status.active) {
        Write-Warning ('Nenhuma execucao ativa e nenhuma execucao automatica neste banco. O coletor so publica enquanto houver ' +
            'execucao. Para manter uma, iniciada com o Windows: dbct run <parametros> --data-dir "' + $dataDir + '" --autostart')
    }
    return @{ dbct = $dbct; dataDir = $dataDir }
}

function Save-DbctSettings([hashtable]$Settings) {
    Ensure-Directory $DbctState
    $json = [ordered]@{ dbct = $Settings.dbct; dataDir = $Settings.dataDir } | ConvertTo-Json
    [IO.File]::WriteAllText($DbctConfigFile, $json, (New-Object System.Text.UTF8Encoding($false)))
    # Posicao da coleta anterior nao vale para outro banco.
    Remove-Item -LiteralPath (Join-Path $DbctState 'state.json') -Force -ErrorAction SilentlyContinue
    Log "DBCT: configuracao gravada em $DbctState."
}

# Coletor a cada 30 s, como o do SQL Anywhere. Desabilitado: remove tarefa,
# script, saida, estado e logs; a configuracao fica para reativar (a limpeza
# completa a remove). Nada no DBCT e alterado.
function Sync-DbctModule([bool]$Enabled, [string]$StagedCollector) {
    $collectorTask = Get-ScheduledTask -TaskPath $DbctTaskPath -TaskName $DbctCollectorTask -ErrorAction SilentlyContinue
    if (-not $Enabled) {
        $hadFiles = (Test-Path -LiteralPath $DbctCollectorScript) -or (Test-Path -LiteralPath $DbctOutput)
        if ($collectorTask) { Unregister-ScheduledTask -TaskPath $DbctTaskPath -TaskName $DbctCollectorTask -Confirm:$false }
        foreach ($path in @($DbctCollectorScript, $DbctOutput, ($DbctOutput + '.tmp'), (Join-Path $DbctState 'state.json'))) {
            Remove-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue
        }
        if (Test-Path -LiteralPath $LogDir) {
            Get-ChildItem -LiteralPath $LogDir -Filter 'dbct-collector-*.log' -File -ErrorAction SilentlyContinue |
                Remove-Item -Force -ErrorAction SilentlyContinue
        }
        if ($collectorTask -or $hadFiles) {
            Log "Coletor DBCT removido (tarefa, script, saida e logs). Configuracao mantida em $DbctState."
        }
        return
    }

    if (-not (Same-File $StagedCollector $DbctCollectorScript)) {
        Copy-Item -LiteralPath $StagedCollector -Destination $DbctCollectorScript -Force
        Log "DBCT: coletor instalado em $DbctCollectorScript."
    }
    $start = (Get-Date).Date
    $phaseA = New-ScheduledTaskTrigger -Once -At $start -RepetitionInterval (New-TimeSpan -Minutes 1)
    $phaseB = New-ScheduledTaskTrigger -Once -At $start.AddSeconds(30) -RepetitionInterval (New-TimeSpan -Minutes 1)
    Register-CollectorTask $DbctTaskPath $DbctCollectorTask $DbctCollectorScript @($phaseA, $phaseB) (New-TimeSpan -Seconds 25) `
        'Metricas do DB Connection Tester para o Grafana Alloy (textfile\dbct\dbct.prom). Gerenciado pelo install.ps1.'
    $content = Invoke-FirstRun $DbctTaskPath $DbctCollectorTask $DbctOutput 40 'Coletor DBCT'
    $ok = @($content | Where-Object { $_ -match '^dbct_collection_success 1$' }).Count -gt 0
    if (-not $ok) { throw "Coletor DBCT falhou na primeira execucao. Veja os logs em $LogDir." }
    $active = @($content | Where-Object { $_ -match '^dbct_run_active 1$' }).Count -gt 0
    $note = if ($active) { 'execucao ativa encontrada' } else { 'nenhuma execucao ativa no momento' }
    Log "Coletor DBCT ativo, atualizado a cada 30 s ($note)."
}

# Sincroniza as tarefas dos modulos. Uma falha nao impede o outro modulo;
# as mensagens sao reunidas ao final.
function Sync-ModuleTasks {
    $failures = @()
    try { Sync-HypervisorInventory $hypervEnabled $stageInventory } catch { $failures += $_.Exception.Message }
    try { Sync-SqlAnywhereCollector $sqlEnabled $stageSqlCollector } catch { $failures += $_.Exception.Message }
    try { Sync-DbctModule $dbctEnabled $stageDbctCollector } catch { $failures += $_.Exception.Message }
    if ($failures.Count -gt 0) { throw ($failures -join ' ') }
}

# A presenca dos cmdlets nao confirma que o Hyper-V local esta ativo.
function Test-HyperV {
    $svc = Get-Service -Name vmms -ErrorAction SilentlyContinue
    if (-not $svc -or $svc.Status -ne 'Running') { return $false }
    if (-not (Get-Command Get-VM -ErrorAction SilentlyContinue)) { return $false }
    try {
        $null = @(Get-VM -ErrorAction Stop)
        return $true
    } catch {
        Log "Hyper-V presente, mas nao acessivel: $($_.Exception.Message)"
        return $false
    }
}

$HyperVModule = Join-Path $ConfigDir 'hyperv.alloy'
$SqlAnywhereModule = Join-Path $ConfigDir 'sqlanywhere.alloy'
$DbctModule = Join-Path $ConfigDir 'dbct.alloy'
$Modules = @($Modules | Select-Object -Unique)
if ($Modules.Count -gt 1 -and (($Modules -contains 'auto') -or ($Modules -contains 'none'))) {
    throw '-Modules: auto e none nao podem ser combinados com outros valores.'
}
$autoModules = $Modules -contains 'auto'

# Perfil: define o arquivo base; o do outro perfil e removido ao aplicar.
$PerfilFiles = @{ servidor = 'config.alloy'; estacao = 'desktop.alloy' }
if ($Perfil -eq 'auto') {
    if (Test-Path -LiteralPath (Join-Path $ConfigDir 'desktop.alloy') -PathType Leaf) { $Perfil = 'estacao' }
    elseif (Test-Path -LiteralPath (Join-Path $ConfigDir 'config.alloy') -PathType Leaf) { $Perfil = 'servidor' }
    else {
        # ProductType 1 = Windows de cliente (10/11); 2 e 3 = Windows Server.
        $Perfil = 'servidor'
        try { if ((Get-CimInstance -ClassName Win32_OperatingSystem -ErrorAction Stop).ProductType -eq 1) { $Perfil = 'estacao' } } catch { }
        Log "Perfil detectado: $Perfil (use -Perfil servidor|estacao para escolher)."
    }
}
$BaseName = $PerfilFiles[$Perfil]
$OtherName = if ($Perfil -eq 'estacao') { $PerfilFiles.servidor } else { $PerfilFiles.estacao }
if ($Perfil -eq 'estacao') {
    $optional = @($Modules | Where-Object { $_ -in @('hyperv', 'sqlanywhere') })
    if ($optional.Count -gt 0) { throw "Modulos opcionais ($($optional -join ', ')) nao se aplicam ao perfil estacao." }
    if (Test-Path -LiteralPath (Join-Path $Base 'heartbeat\kuma-url')) {
        Write-Warning 'Heartbeat configurado: estacoes nao usam heartbeat. Remova com "alloyctl heartbeat-remove" e exclua o monitor no Kuma.'
    }
    # Sem deteccao nem pergunta: Hyper-V e SQL Anywhere ativos sao desativados
    # abaixo. O modulo dbct vale para estacoes e segue -Modules normalmente.
    $autoModules = $false
}

$hypervEnabled = $false
if ($autoModules) {
    if (Test-Path -LiteralPath $HyperVModule -PathType Leaf) {
        if (-not (Test-HyperV)) {
            throw 'Hyper-V estava habilitado mas nao esta disponivel. Para desativar, informe -Modules sem hyperv (ex.: -Modules none).'
        }
        $hypervEnabled = $true
        Log 'Modulo Hyper-V existente: preservando.'
    } elseif (Test-HyperV) {
        if ([Console]::IsInputRedirected) {
            Log 'Hyper-V detectado sem terminal interativo. Use -Modules hyperv para habilitar.'
        } else {
            $answer = Read-Host 'Hyper-V detectado. Habilitar metricas, inventario de VMs e logs administrativos? [S/n]'
            if ($answer -match '^(|s|sim|y|yes)$') { $hypervEnabled = $true }
        }
    }
} elseif ($Modules -contains 'hyperv') {
    if (-not (Test-HyperV)) { throw 'Hyper-V solicitado, mas vmms/Get-VM nao estao disponiveis.' }
    $hypervEnabled = $true
} elseif (Test-Path -LiteralPath $HyperVModule -PathType Leaf) {
    Log 'Modulo Hyper-V sera desativado.'
}

$sqlEnabled = $false
$sqlPending = $null
if ($autoModules) {
    if (Test-Path -LiteralPath $SqlAnywhereModule -PathType Leaf) {
        if (-not (Test-SqlAnywhere)) {
            throw 'SQL Anywhere estava habilitado mas nao foi detectado. Para desativar, informe -Modules sem sqlanywhere (ex.: -Modules none).'
        }
        $sqlEnabled = $true
        Log 'Modulo SQL Anywhere existente: preservando.'
    } elseif (Test-SqlAnywhere) {
        if ([Console]::IsInputRedirected) {
            Log 'SQL Anywhere 17 detectado sem terminal interativo. Use -Modules sqlanywhere para habilitar.'
        } else {
            $answer = Read-Host 'SQL Anywhere 17 detectado. Habilitar metricas do servidor e do banco? [S/n]'
            if ($answer -match '^(|s|sim|y|yes)$') { $sqlEnabled = $true }
        }
    }
} elseif ($Modules -contains 'sqlanywhere') {
    if (-not (Test-SqlAnywhere)) { throw 'SQL Anywhere solicitado, mas dbsrv17/dbeng17 nao foram encontrados.' }
    $sqlEnabled = $true
} elseif (Test-Path -LiteralPath $SqlAnywhereModule -PathType Leaf) {
    Log 'Modulo SQL Anywhere sera desativado.'
}
if ($sqlEnabled) {
    if (-not (Test-SqlAnywhereDriver)) {
        throw "Driver ODBC '$SqlDriver' de 64 bits nao encontrado. Instale o cliente SQL Anywhere 17 (64 bits)."
    }
    if ($ReconfigureSqlAnywhere -or -not (Test-SqlAnywhereSettings)) {
        if ([Console]::IsInputRedirected) {
            throw 'SQL Anywhere sem configuracao: execute a instalacao em um terminal interativo.'
        }
        $sqlPending = Read-SqlAnywhereSettings
    }
} elseif ($ReconfigureSqlAnywhere) {
    throw '-ReconfigureSqlAnywhere requer o modulo SQL Anywhere ativo.'
}

# DBCT: nunca oferecido automaticamente (necessidade pontual); auto mantem o
# modulo ativo, em qualquer perfil.
$dbctEnabled = $false
$dbctPending = $null
if ($Modules -contains 'dbct') {
    $dbctEnabled = $true
} elseif (($Modules -contains 'auto') -and (Test-Path -LiteralPath $DbctModule -PathType Leaf)) {
    $dbctEnabled = $true
    Log 'Modulo DBCT existente: preservando.'
} elseif (Test-Path -LiteralPath $DbctModule -PathType Leaf) {
    Log 'Modulo DBCT sera desativado.'
}
if ($dbctEnabled) {
    if ($ReconfigureDbct -or -not (Test-DbctSettings)) {
        if ([Console]::IsInputRedirected) {
            throw 'DBCT sem configuracao: execute a instalacao em um terminal interativo.'
        }
        $dbctPending = Read-DbctSettings
    }
} elseif ($ReconfigureDbct) {
    throw '-ReconfigureDbct requer o modulo DBCT ativo.'
}

$Source = Join-Path $PSScriptRoot $BaseName
if (-not (Test-Path -LiteralPath $Secret -PathType Leaf) -or (Get-Item -LiteralPath $Secret).Length -eq 0) {
    throw 'Credencial ausente. Execute alloy.ps1 (ou setup-credentials.ps1) primeiro.'
}
if (-not (Test-Path -LiteralPath $Source -PathType Leaf)) {
    throw "$BaseName nao encontrado ao lado de install.ps1."
}
$stage = Join-Path $env:TEMP ('alloy-stage-' + [guid]::NewGuid().ToString('N'))
Ensure-Directory $stage
$applied = $false
$backup = $null
$priorArgsExist = $false
$priorArgs = @()
$priorRunning = $false
# O servico ja usava a nossa configuracao antes desta execucao? Se nao (primeira
# instalacao, ou o Alloy rodando com o exemplo do instalador oficial), uma falha
# deixa o servico parado, em vez de "ativo e pronto" sem coletar nada.
$priorOurs = $false
try { $priorOurs = @([string[]](Get-ItemProperty -LiteralPath $Registry -ErrorAction Stop).Arguments) -contains $ConfigDir } catch { }
$configConfirmed = $false
$startedAt = Get-Date
$priorAuto = $false
$target = Join-Path $ConfigDir $BaseName
# Arquivo base do outro perfil: removido ao aplicar (os dois nao convivem).
$otherTarget = Join-Path $ConfigDir $OtherName
try {
    Copy-Item -LiteralPath $Source -Destination (Join-Path $stage $BaseName)
    $stageInventory = $null
    if ($hypervEnabled) {
        Copy-ModuleFile 'hyperv.alloy' (Join-Path $stage 'hyperv.alloy')
        # O alloy validate do diretorio de stage so le *.alloy.
        $stageInventory = Join-Path $stage $InventoryName
        Copy-ModuleFile $InventoryName $stageInventory
        Assert-ScriptSyntax $stageInventory
    }
    $stageSqlCollector = $null
    if ($sqlEnabled) {
        Copy-ModuleFile 'sqlanywhere.alloy' (Join-Path $stage 'sqlanywhere.alloy')
        $stageSqlCollector = Join-Path $stage $SqlCollectorName
        Copy-ModuleFile $SqlCollectorName $stageSqlCollector
        Assert-ScriptSyntax $stageSqlCollector
    }
    $stageDbctCollector = $null
    if ($dbctEnabled) {
        Copy-ModuleFile 'dbct.alloy' (Join-Path $stage 'dbct.alloy')
        $stageDbctCollector = Join-Path $stage $DbctCollectorName
        Copy-ModuleFile $DbctCollectorName $stageDbctCollector
        Assert-ScriptSyntax $stageDbctCollector
    }
    if (Test-Path -LiteralPath $ConfigDir -PathType Container) {
        Get-ChildItem -LiteralPath $ConfigDir -Filter '*.alloy' -File | ForEach-Object {
            if ($_.Name -notin @('config.alloy', 'desktop.alloy', 'hyperv.alloy', 'sqlanywhere.alloy', 'dbct.alloy')) {
                Copy-Item -LiteralPath $_.FullName -Destination (Join-Path $stage $_.Name)
            }
        }
    }

    # Instalacao completa = executavel + servico + chave do registro (onde o
    # servico le os argumentos). Uma parte faltando (antivirus que removeu o
    # executavel ou desfez o registro, desinstalacao interrompida) e reinstalada.
    $hasExe = Test-Path -LiteralPath $Exe -PathType Leaf
    $hasService = $null -ne (Get-Service -Name $Service -ErrorAction SilentlyContinue)
    $hasRegistry = Test-Path -LiteralPath $Registry
    $existing = $hasExe -and $hasService -and $hasRegistry
    if (-not $existing -and ($hasExe -or $hasService -or $hasRegistry)) {
        $absent = @()
        if (-not $hasExe) { $absent += "executavel ($Exe)" }
        if (-not $hasService) { $absent += 'servico' }
        if (-not $hasRegistry) { $absent += "registro ($Registry)" }
        Write-Warning ("Instalacao do Alloy incompleta (ausente: $($absent -join ', ')); reinstalando com o instalador oficial." +
            $(if (-not $hasExe -or -not $hasRegistry) { Get-AntivirusHint } else { '' }))
    }
    if (-not $existing -or $Upgrade) {
        Install-AlloyPackage
    } else {
        Log 'Alloy instalado: download e upgrade ignorados.'
    }

    Log 'Validando a configuracao completa antes de alterar o servico...'
    & $Exe validate $stage
    if ($LASTEXITCODE -ne 0) {
        $hint = if ($hypervEnabled -or $sqlEnabled -or $dbctEnabled) { ' Os modulos Hyper-V, SQL Anywhere e DBCT requerem Alloy v1.11+ (use Atualizar Alloy).' } else { '' }
        throw "Configuracao invalida. Instalacao ativa preservada.$hint"
    }

    Ensure-Directory $Base
    Ensure-Directory $ConfigDir
    Ensure-Directory $DataDir
    Ensure-Directory $BookmarkDir
    Ensure-Directory $BackupDir
    Set-PrivateDirectoryAcl $ConfigDir
    Set-PrivateDirectoryAcl $DataDir
    Set-PrivateDirectoryAcl $BackupDir
    if ($hypervEnabled -or $sqlEnabled -or $dbctEnabled) {
        # scripts\ guarda codigo executado como SYSTEM: so SYSTEM e Administradores.
        # Os subdiretorios de textfile\ herdam a ACL.
        foreach ($dir in @($ScriptsDir, $TextfileDir, $LogDir)) {
            Ensure-Directory $dir
            Set-PrivateDirectoryAcl $dir
        }
    }
    if ($hypervEnabled) {
        Ensure-Directory $InventoryOutputDir
        Ensure-Directory $InventoryState
    }
    if ($sqlEnabled) {
        Ensure-Directory $SqlOutputDir
        Ensure-Directory $SqlState
        if ($sqlPending) { Save-SqlAnywhereSettings $sqlPending }
    }
    if ($dbctEnabled) {
        Ensure-Directory $DbctOutputDir
        Ensure-Directory $DbctState
        if ($dbctPending) { Save-DbctSettings $dbctPending }
    }
    # Saida do inventario na raiz do textfile\ (versoes anteriores): nenhum
    # modulo le mais esse caminho.
    foreach ($legacy in @($LegacyInventoryOutput, ($LegacyInventoryOutput + '.tmp'))) {
        Remove-Item -LiteralPath $legacy -Force -ErrorAction SilentlyContinue
    }

    if (-not (Test-Path -LiteralPath $Registry)) { throw 'Registro do servico Alloy ausente.' }
    $reg = Get-ItemProperty -LiteralPath $Registry
    if ($reg.ALLOY_OTEL_MODE -match '^(1|true)$') { throw 'OTel Engine ativo: modo nao suportado por este instalador.' }
    $priorArgsExist = $null -ne $reg.PSObject.Properties['Arguments']
    if ($priorArgsExist) { $priorArgs = [string[]]$reg.Arguments }
    $extras = @()
    foreach ($arg in @($priorArgs)) {
        if (-not $arg -or $arg -eq 'run' -or $arg -like '--storage.path=*' -or
            $arg -like '--server.http.listen-addr=*' -or $arg -like '*.alloy' -or $arg -eq $ConfigDir) {
            continue
        }
        if ($arg.StartsWith('-')) { $extras += $arg }
    }
    $argsNew = @('run', $ConfigDir, ('--storage.path=' + $DataDir), '--server.http.listen-addr=127.0.0.1:12345') + $extras
    $svc = Get-Service -Name $Service
    $priorRunning = $svc.Status -eq 'Running'
    $priorAuto = $svc.StartType -eq 'Automatic'
    $configChanged = (-not (Same-File $Source $target)) -or (Test-Path -LiteralPath $otherTarget)
    $moduleSource = Join-Path $stage 'hyperv.alloy'
    $moduleChanged = if ($hypervEnabled) {
        -not (Same-File $moduleSource $HyperVModule)
    } else {
        Test-Path -LiteralPath $HyperVModule
    }
    $sqlSource = Join-Path $stage 'sqlanywhere.alloy'
    $sqlChanged = if ($sqlEnabled) {
        -not (Same-File $sqlSource $SqlAnywhereModule)
    } else {
        Test-Path -LiteralPath $SqlAnywhereModule
    }
    $dbctSource = Join-Path $stage 'dbct.alloy'
    $dbctChanged = if ($dbctEnabled) {
        -not (Same-File $dbctSource $DbctModule)
    } else {
        Test-Path -LiteralPath $DbctModule
    }
    $argsChanged = ($priorArgs -join [char]10) -cne ($argsNew -join [char]10)
    $mustApply = $configChanged -or $moduleChanged -or $sqlChanged -or $dbctChanged -or $argsChanged -or $Upgrade -or -not $priorRunning -or -not $priorAuto
    if (-not $mustApply) {
        Log 'Nenhuma alteracao na configuracao; servico mantido em execucao.'
        Sync-ModuleTasks
        return
    }

    $backup = Join-Path $BackupDir ('apply-' + (Get-Date -Format 'yyyyMMdd-HHmmss') + '-' + [guid]::NewGuid().ToString('N'))
    Ensure-Directory $backup
    foreach ($path in @($target, $otherTarget)) {
        if (Test-Path -LiteralPath $path) { Copy-Item -LiteralPath $path -Destination (Join-Path $backup (Split-Path -Leaf $path)) }
    }
    if (Test-Path -LiteralPath $HyperVModule) { Copy-Item -LiteralPath $HyperVModule -Destination (Join-Path $backup 'hyperv.alloy') }
    if (Test-Path -LiteralPath $SqlAnywhereModule) { Copy-Item -LiteralPath $SqlAnywhereModule -Destination (Join-Path $backup 'sqlanywhere.alloy') }
    if (Test-Path -LiteralPath $DbctModule) { Copy-Item -LiteralPath $DbctModule -Destination (Join-Path $backup 'dbct.alloy') }
    if ($priorArgsExist) { [IO.File]::WriteAllLines((Join-Path $backup 'Arguments.txt'), $priorArgs) }

    foreach ($name in @('application','system')) {
        $oldBookmark = Join-Path $Base ('bookmark-' + $name + '.xml')
        $newBookmark = Join-Path $BookmarkDir ($name + '.xml')
        if ((Test-Path -LiteralPath $oldBookmark) -and -not (Test-Path -LiteralPath $newBookmark)) {
            Copy-Item -LiteralPath $oldBookmark -Destination $newBookmark
        }
    }

    Log 'Aplicando configuracao em ProgramData e atualizando argumentos do servico...'
    if ($priorRunning) { Stop-Service -Name $Service -ErrorAction Stop }
    $applied = $true
    if ($configChanged) {
        Copy-Item -LiteralPath $Source -Destination $target -Force
        if (Test-Path -LiteralPath $otherTarget) { Remove-Item -LiteralPath $otherTarget -Force -ErrorAction Stop }
    }
    if ($moduleChanged) {
        if ($hypervEnabled) {
            Copy-Item -LiteralPath $moduleSource -Destination $HyperVModule -Force
        } else {
            Remove-Item -LiteralPath $HyperVModule -Force -ErrorAction Stop
        }
    }
    if ($sqlChanged) {
        if ($sqlEnabled) {
            Copy-Item -LiteralPath $sqlSource -Destination $SqlAnywhereModule -Force
        } else {
            Remove-Item -LiteralPath $SqlAnywhereModule -Force -ErrorAction Stop
        }
    }
    if ($dbctChanged) {
        if ($dbctEnabled) {
            Copy-Item -LiteralPath $dbctSource -Destination $DbctModule -Force
        } else {
            Remove-Item -LiteralPath $DbctModule -Force -ErrorAction Stop
        }
    }
    New-ItemProperty -LiteralPath $Registry -Name 'Arguments' -PropertyType MultiString -Value ([string[]]$argsNew) -Force | Out-Null
    Set-Service -Name $Service -StartupType Automatic
    $startedAt = Get-Date
    Start-Service -Name $Service -ErrorAction Stop
    if (-not (Ready)) {
        throw ("Alloy nao ficou pronto em ${ReadyTimeoutSeconds}s (127.0.0.1:12345)." + (Get-AlloyEventSummary $startedAt))
    }
    $active = @('Windows')
    if ($hypervEnabled) { $active += 'Hyper-V' }
    if ($sqlEnabled) { $active += 'SQL Anywhere' }
    if ($dbctEnabled) { $active += 'DBCT' }
    Log "Alloy ativo e pronto. Perfil: $Perfil. Modulos: $($active -join ' + ')."
    $configConfirmed = $true
    # Configuracao confirmada: uma falha das tarefas dos modulos daqui em
    # diante e reportada, mas nao desfaz o Alloy que ja esta funcionando.
    $applied = $false
    Sync-ModuleTasks
} catch {
    $original = $_
    if ($applied -and $backup) {
        Write-Warning 'Falha apos aplicar a configuracao. Iniciando rollback...'
        try {
            Stop-Service -Name $Service -ErrorAction SilentlyContinue
            foreach ($path in @($target, $otherTarget)) {
                $saved = Join-Path $backup (Split-Path -Leaf $path)
                if (Test-Path -LiteralPath $saved) {
                    Copy-Item -LiteralPath $saved -Destination $path -Force
                } else {
                    Remove-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue
                }
            }
            $savedModule = Join-Path $backup 'hyperv.alloy'
            if (Test-Path -LiteralPath $savedModule) {
                Copy-Item -LiteralPath $savedModule -Destination $HyperVModule -Force
            } else {
                Remove-Item -LiteralPath $HyperVModule -Force -ErrorAction SilentlyContinue
            }
            $savedSql = Join-Path $backup 'sqlanywhere.alloy'
            if (Test-Path -LiteralPath $savedSql) {
                Copy-Item -LiteralPath $savedSql -Destination $SqlAnywhereModule -Force
            } else {
                Remove-Item -LiteralPath $SqlAnywhereModule -Force -ErrorAction SilentlyContinue
            }
            $savedDbct = Join-Path $backup 'dbct.alloy'
            if (Test-Path -LiteralPath $savedDbct) {
                Copy-Item -LiteralPath $savedDbct -Destination $DbctModule -Force
            } else {
                Remove-Item -LiteralPath $DbctModule -Force -ErrorAction SilentlyContinue
            }
            if ($priorArgsExist) {
                New-ItemProperty -LiteralPath $Registry -Name 'Arguments' -PropertyType MultiString -Value ([string[]]$priorArgs) -Force | Out-Null
            } else {
                Remove-ItemProperty -LiteralPath $Registry -Name 'Arguments' -ErrorAction SilentlyContinue
            }
            if ($priorOurs) {
                if ($priorAuto) { Set-Service -Name $Service -StartupType Automatic }
                else { Set-Service -Name $Service -StartupType Manual }
                if ($priorRunning) {
                    Start-Service -Name $Service
                    if (-not (Ready)) { Write-Warning 'Alloy anterior nao ficou pronto apos rollback.' }
                }
            }
        } catch { Write-Warning "Rollback incompleto. Verifique $backup." }
    }
    if (-not $priorOurs -and -not $configConfirmed -and (Get-Service -Name $Service -ErrorAction SilentlyContinue)) {
        # Nada nosso a preservar: sem configuracao valida o Alloy so pareceria
        # saudavel. Fica parado ate uma instalacao concluir.
        Stop-Service -Name $Service -ErrorAction SilentlyContinue
        Set-Service -Name $Service -StartupType Manual -ErrorAction SilentlyContinue
        Write-Warning 'Alloy parado (inicio manual): a instalacao nao foi concluida. Corrija o erro abaixo e execute [1] de novo.'
    }
    throw $original
} finally {
    if ($script:LocalHttp) { $script:LocalHttp.Dispose() }
    Remove-Item -LiteralPath $stage -Recurse -Force -ErrorAction SilentlyContinue
}
