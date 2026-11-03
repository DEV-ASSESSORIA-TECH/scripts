#Requires -RunAsAdministrator
#Requires -Version 5.1
[CmdletBinding()]
param(
    [switch]$Upgrade,
    [ValidateSet('auto','hyperv','none')]
    [string]$Modules = 'auto'
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
$hypervEnabled = $false
switch ($Modules) {
    'hyperv' {
        if (-not (Test-HyperV)) { throw 'Hyper-V solicitado, mas vmms/Get-VM nao estao disponiveis.' }
        $hypervEnabled = $true
    }
    'none' { Log 'Modulo Hyper-V explicitamente desabilitado.' }
    'auto' {
        if (Test-Path -LiteralPath $HyperVModule -PathType Leaf) {
            if (-not (Test-HyperV)) {
                throw 'Hyper-V estava habilitado mas nao esta disponivel. Utilize -Modules none para desativar.'
            }
            $hypervEnabled = $true
            Log 'Modulo Hyper-V existente: preservando.'
        } elseif (Test-HyperV) {
            if ([Console]::IsInputRedirected) {
                Log 'Hyper-V detectado sem terminal interativo. Use -Modules hyperv para habilitar.'
            } else {
                $answer = Read-Host 'Hyper-V detectado. Habilitar metricas e logs administrativos? [S/n]'
                if ($answer -match '^(|s|sim|y|yes)$') { $hypervEnabled = $true }
            }
        }
    }
}

$Source = Join-Path $PSScriptRoot 'config.alloy'
if (-not (Test-Path -LiteralPath $Secret -PathType Leaf) -or (Get-Item -LiteralPath $Secret).Length -eq 0) {
    throw 'Credencial ausente. Execute setup-credentials.ps1 primeiro.'
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
    if ($hypervEnabled) {
        $localModule = Join-Path $PSScriptRoot 'hyperv.alloy'
        $stageModule = Join-Path $stage 'hyperv.alloy'
        if (Test-Path -LiteralPath $localModule -PathType Leaf) {
            Copy-Item -LiteralPath $localModule -Destination $stageModule
        } else {
            Log 'Baixando hyperv.alloy pela API do GitHub...'
            $api = 'https://api.github.com/repos/DEV-ASSESSORIA-TECH/scripts/contents/monitoring/alloy/windows/hyperv.alloy?ref=main'
            $payload = Invoke-RestMethod -Uri $api -Headers @{ 'User-Agent' = 'AssessoriaTech-Alloy-Installer/1.0' }
            if (-not $payload.content) { throw 'Resposta da API GitHub sem conteudo para hyperv.alloy.' }
            $moduleText = [Text.Encoding]::UTF8.GetString(
                [Convert]::FromBase64String(($payload.content -replace '\s', ''))
            )
            [IO.File]::WriteAllText($stageModule, $moduleText, [Text.UTF8Encoding]::new($false))
        }
    }
    if (Test-Path -LiteralPath $ConfigDir -PathType Container) {
        Get-ChildItem -LiteralPath $ConfigDir -Filter '*.alloy' -File | ForEach-Object {
            if ($_.Name -ne 'config.alloy' -and $_.Name -ne 'hyperv.alloy') {
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
    if ($LASTEXITCODE -ne 0) { throw 'Configuracao invalida. Instalacao ativa preservada.' }

    Ensure-Directory $Base
    Ensure-Directory $ConfigDir
    Ensure-Directory $DataDir
    Ensure-Directory $BookmarkDir
    Ensure-Directory $BackupDir
    Set-PrivateDirectoryAcl $ConfigDir
    Set-PrivateDirectoryAcl $DataDir
    Set-PrivateDirectoryAcl $BackupDir

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
    $argsChanged = ($priorArgs -join [char]10) -cne ($argsNew -join [char]10)
    $mustApply = $configChanged -or $moduleChanged -or $argsChanged -or $Upgrade -or -not $priorRunning -or -not $priorAuto
    if (-not $mustApply) {
        Log 'Nenhuma alteracao encontrada; servico mantido em execucao.'
        return
    }

    $backup = Join-Path $BackupDir ('apply-' + (Get-Date -Format 'yyyyMMdd-HHmmss') + '-' + [guid]::NewGuid().ToString('N'))
    Ensure-Directory $backup
    if (Test-Path -LiteralPath $target) { Copy-Item -LiteralPath $target -Destination (Join-Path $backup 'config.alloy') }
    if (Test-Path -LiteralPath $HyperVModule) { Copy-Item -LiteralPath $HyperVModule -Destination (Join-Path $backup 'hyperv.alloy') }
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
    New-ItemProperty -LiteralPath $Registry -Name 'Arguments' -PropertyType MultiString -Value ([string[]]$argsNew) -Force | Out-Null
    Set-Service -Name $Service -StartupType Automatic
    Start-Service -Name $Service -ErrorAction Stop
    if (-not (Ready)) { throw 'Alloy nao ficou pronto (127.0.0.1:12345).'}
    Log "Alloy ativo e pronto. Modulos: Windows$(if ($hypervEnabled) { ' + Hyper-V' })."
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
