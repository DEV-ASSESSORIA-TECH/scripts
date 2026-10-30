#Requires -RunAsAdministrator
# Instala o Grafana Alloy no Windows e aplica o config.alloy desta pasta.
# Equivalente Windows do linux/install.sh. Execute setup-credentials.ps1 antes.

$ErrorActionPreference = 'Stop'

$Secret     = Join-Path $env:ProgramData 'GrafanaLabs\Alloy\oauth-client-secret'
$InstallDir = Join-Path $env:ProgramFiles 'GrafanaLabs\Alloy'
$ConfigPath = Join-Path $InstallDir 'config.alloy'
$AlloyExe   = Join-Path $InstallDir 'alloy-windows-amd64.exe'
$ServiceName = 'Alloy'
$InstallerUrl = 'https://github.com/grafana/alloy/releases/latest/download/alloy-installer-windows-amd64.exe.zip'

if (-not (Test-Path -LiteralPath $Secret) -or (Get-Item -LiteralPath $Secret).Length -eq 0) {
    throw 'Credencial ausente: execute setup-credentials.ps1 antes.'
}

[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$tmp = Join-Path $env:TEMP "alloy-install-$([guid]::NewGuid())"
New-Item -ItemType Directory -Path $tmp | Out-Null
try {
    $zip = Join-Path $tmp 'alloy-installer.zip'
    Invoke-WebRequest -Uri $InstallerUrl -OutFile $zip -UseBasicParsing
    Expand-Archive -LiteralPath $zip -DestinationPath $tmp
    $installer = Join-Path $tmp 'alloy-installer-windows-amd64.exe'

    $proc = Start-Process -FilePath $installer -ArgumentList '/S', '/DISABLEREPORTING=yes' -Wait -PassThru
    if ($proc.ExitCode -ne 0) {
        throw "Instalador do Alloy falhou (codigo $($proc.ExitCode))."
    }
} finally {
    Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
}

Stop-Service -Name $ServiceName -ErrorAction SilentlyContinue

if (Test-Path -LiteralPath $ConfigPath) {
    Copy-Item -LiteralPath $ConfigPath -Destination "$ConfigPath.bak-$(Get-Date -Format 'yyyyMMdd-HHmmss')"
}
Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'config.alloy') -Destination $ConfigPath -Force

& $AlloyExe validate $ConfigPath
if ($LASTEXITCODE -ne 0) {
    throw 'config.alloy invalido; servico nao foi iniciado.'
}

Set-Service -Name $ServiceName -StartupType Automatic
Start-Service -Name $ServiceName
Get-Service -Name $ServiceName | Format-List Name, Status, StartType
