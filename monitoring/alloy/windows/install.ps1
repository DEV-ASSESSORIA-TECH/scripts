#Requires -RunAsAdministrator
#Requires -Version 5.1
# Instala ou reaplica o Alloy com validacao e rollback.
# -Modules: conjunto completo dos modulos opcionais.
#   auto (padrao)          mantem os ativos e oferece os detectados
#   hyperv, sqlanywhere    ativa exatamente os listados (os demais saem)
#   none                   desativa todos
# -ReconfigureSqlAnywhere: pede de novo servidor, banco e usuario do SQL Anywhere.
[CmdletBinding()]
param(
    [switch]$Upgrade,
    [ValidateSet('auto','hyperv','sqlanywhere','none')]
    [string[]]$Modules = @('auto'),
    [switch]$ReconfigureSqlAnywhere
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
$InstallerUrl = 'https://github.com/grafana/alloy/releases/latest/download/alloy-installer-windows-amd64.exe.zip'
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
function Ready {
    for ($i = 0; $i -lt 15; $i++) {
        $svc = Get-Service -Name $Service -ErrorAction SilentlyContinue
        if ($svc -and $svc.Status -eq 'Running') {
            try {
                $resp = Invoke-WebRequest -Uri 'http://127.0.0.1:12345/-/ready' -UseBasicParsing -TimeoutSec 2
                if ($resp.StatusCode -eq 200) { return $true }
            } catch { }
        }
        Start-Sleep -Seconds 1
    }
    return $false
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

# Sincroniza as tarefas dos modulos. Uma falha nao impede o outro modulo;
# as mensagens sao reunidas ao final.
function Sync-ModuleTasks {
    $failures = @()
    try { Sync-HypervisorInventory $hypervEnabled $stageInventory } catch { $failures += $_.Exception.Message }
    try { Sync-SqlAnywhereCollector $sqlEnabled $stageSqlCollector } catch { $failures += $_.Exception.Message }
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
$Modules = @($Modules | Select-Object -Unique)
if ($Modules.Count -gt 1 -and (($Modules -contains 'auto') -or ($Modules -contains 'none'))) {
    throw '-Modules: auto e none nao podem ser combinados com outros valores.'
}
$autoModules = $Modules -contains 'auto'

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

$Source = Join-Path $PSScriptRoot 'config.alloy'
if (-not (Test-Path -LiteralPath $Secret -PathType Leaf) -or (Get-Item -LiteralPath $Secret).Length -eq 0) {
    throw 'Credencial ausente. Execute alloy.ps1 (ou setup-credentials.ps1) primeiro.'
}
if (-not (Test-Path -LiteralPath $Source -PathType Leaf)) {
    throw 'config.alloy nao encontrado ao lado de install.ps1.'
}
$stage = Join-Path $env:TEMP ('alloy-stage-' + [guid]::NewGuid().ToString('N'))
Ensure-Directory $stage
$applied = $false
$backup = $null
$priorArgsExist = $false
$priorArgs = @()
$priorRunning = $false
$priorAuto = $false
$target = Join-Path $ConfigDir 'config.alloy'
try {
    Copy-Item -LiteralPath $Source -Destination (Join-Path $stage 'config.alloy')
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
    if (Test-Path -LiteralPath $ConfigDir -PathType Container) {
        Get-ChildItem -LiteralPath $ConfigDir -Filter '*.alloy' -File | ForEach-Object {
            if ($_.Name -notin @('config.alloy', 'hyperv.alloy', 'sqlanywhere.alloy')) {
                Copy-Item -LiteralPath $_.FullName -Destination (Join-Path $stage $_.Name)
            }
        }
    }

    $existing = (Test-Path -LiteralPath $Exe -PathType Leaf) -and ($null -ne (Get-Service -Name $Service -ErrorAction SilentlyContinue))
    if (-not $existing -or $Upgrade) {
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        Log 'Baixando instalador oficial do Grafana Alloy...'
        $zip = Join-Path $stage 'installer.zip'
        Invoke-WebRequest -Uri $InstallerUrl -OutFile $zip -UseBasicParsing
        $unpack = Join-Path $stage 'package'
        Ensure-Directory $unpack
        Expand-Archive -LiteralPath $zip -DestinationPath $unpack -Force
        $installer = Join-Path $unpack 'alloy-installer-windows-amd64.exe'
        if (-not (Test-Path -LiteralPath $installer)) { throw 'Executavel de instalacao nao encontrado.' }
        $p = Start-Process -FilePath $installer -ArgumentList @('/S', '/DISABLEREPORTING=yes') -Wait -PassThru
        if ($p.ExitCode -ne 0) { throw "Instalador retornou codigo $($p.ExitCode)." }
        if (-not (Test-Path -LiteralPath $Exe) -or -not (Get-Service -Name $Service -ErrorAction SilentlyContinue)) {
            throw 'Alloy nao foi instalado corretamente.'
        }
    } else {
        Log 'Alloy instalado: download e upgrade ignorados.'
    }

    Log 'Validando a configuracao completa antes de alterar o servico...'
    & $Exe validate $stage
    if ($LASTEXITCODE -ne 0) {
        $hint = if ($hypervEnabled -or $sqlEnabled) { ' Os modulos Hyper-V e SQL Anywhere requerem Alloy v1.11+ (use Atualizar Alloy).' } else { '' }
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
    if ($hypervEnabled -or $sqlEnabled) {
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
    $configChanged = -not (Same-File $Source $target)
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
    $argsChanged = ($priorArgs -join [char]10) -cne ($argsNew -join [char]10)
    $mustApply = $configChanged -or $moduleChanged -or $sqlChanged -or $argsChanged -or $Upgrade -or -not $priorRunning -or -not $priorAuto
    if (-not $mustApply) {
        Log 'Nenhuma alteracao na configuracao; servico mantido em execucao.'
        Sync-ModuleTasks
        return
    }

    $backup = Join-Path $BackupDir ('apply-' + (Get-Date -Format 'yyyyMMdd-HHmmss') + '-' + [guid]::NewGuid().ToString('N'))
    Ensure-Directory $backup
    if (Test-Path -LiteralPath $target) { Copy-Item -LiteralPath $target -Destination (Join-Path $backup 'config.alloy') }
    if (Test-Path -LiteralPath $HyperVModule) { Copy-Item -LiteralPath $HyperVModule -Destination (Join-Path $backup 'hyperv.alloy') }
    if (Test-Path -LiteralPath $SqlAnywhereModule) { Copy-Item -LiteralPath $SqlAnywhereModule -Destination (Join-Path $backup 'sqlanywhere.alloy') }
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
    if ($configChanged) { Copy-Item -LiteralPath $Source -Destination $target -Force }
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
    New-ItemProperty -LiteralPath $Registry -Name 'Arguments' -PropertyType MultiString -Value ([string[]]$argsNew) -Force | Out-Null
    Set-Service -Name $Service -StartupType Automatic
    Start-Service -Name $Service -ErrorAction Stop
    if (-not (Ready)) { throw 'Alloy nao ficou pronto (127.0.0.1:12345).'}
    $active = @('Windows')
    if ($hypervEnabled) { $active += 'Hyper-V' }
    if ($sqlEnabled) { $active += 'SQL Anywhere' }
    Log "Alloy ativo e pronto. Modulos: $($active -join ' + ')."
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
            $saved = Join-Path $backup 'config.alloy'
            if (Test-Path -LiteralPath $saved) {
                Copy-Item -LiteralPath $saved -Destination $target -Force
            } else {
                Remove-Item -LiteralPath $target -Force -ErrorAction SilentlyContinue
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
            if ($priorArgsExist) {
                New-ItemProperty -LiteralPath $Registry -Name 'Arguments' -PropertyType MultiString -Value ([string[]]$priorArgs) -Force | Out-Null
            } else {
                Remove-ItemProperty -LiteralPath $Registry -Name 'Arguments' -ErrorAction SilentlyContinue
            }
            if ($priorAuto) { Set-Service -Name $Service -StartupType Automatic }
            else { Set-Service -Name $Service -StartupType Manual }
            if ($priorRunning) {
                Start-Service -Name $Service
                if (-not (Ready)) { Write-Warning 'Alloy anterior nao ficou pronto apos rollback.' }
            }
        } catch { Write-Warning "Rollback incompleto. Verifique $backup." }
    }
    throw $original
} finally {
    Remove-Item -LiteralPath $stage -Recurse -Force -ErrorAction SilentlyContinue
}
