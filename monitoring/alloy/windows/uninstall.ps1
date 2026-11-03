#Requires -RunAsAdministrator
#Requires -Version 5.1
# Remove o Grafana Alloy do Windows.
# Padrao: remove programa e servico; mantem credencial, configuracao, dados
# e backups em ProgramData para uma reinstalacao sem novo setup.
# -Purge: remove tudo o que a instalacao criou (inclui a credencial).
# -Yes:   nao pede confirmacao (automacao).
[CmdletBinding()]
param([switch]$Purge, [switch]$Yes)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'lib\Common.ps1')

$UninstallKeys = @(
    'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
    'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*'
)

function Find-AlloyUninstaller {
    $entry = Get-ItemProperty -Path $UninstallKeys -ErrorAction SilentlyContinue |
        Where-Object { $_.DisplayName -like '*Alloy*' -and $_.Publisher -like '*Grafana*' } |
        Select-Object -First 1
    if ($entry -and $entry.UninstallString) {
        $path = $entry.UninstallString.Trim()
        if ($path -match '^"([^"]+)"') { $path = $Matches[1] } else { $path = ($path -split '\s+/')[0] }
        if (Test-Path -LiteralPath $path -PathType Leaf) { return $path }
    }
    $fallback = Join-Path $InstallDir 'uninstall.exe'
    if (Test-Path -LiteralPath $fallback -PathType Leaf) { return $fallback }
    return $null
}

function Remove-IfEmpty([string]$Path) {
    if ((Test-Path -LiteralPath $Path -PathType Container) -and
        -not (Get-ChildItem -LiteralPath $Path -Force | Select-Object -First 1)) {
        Remove-Item -LiteralPath $Path -Force
    }
}

$hostName = Get-AlloyHostName
$account = Get-CredentialUser
$installed = Test-AlloyInstalled
$service = Get-AlloyService
$uninstaller = Find-AlloyUninstaller

if ($Purge) {
    $targets = @()
    if ($installed -or $uninstaller) { $targets += 'programa Grafana Alloy' }
    elseif ($service) { $targets += 'servico Alloy' }
    foreach ($path in @($Base, $InstallDir)) {
        if (Test-Path -LiteralPath $path) { $targets += $path }
    }
    if (Test-Path -LiteralPath $Registry) { $targets += $Registry }
    if ($targets.Count -eq 0) {
        Write-Log 'Nada a remover: o Alloy nao esta instalado e nao ha residuos.'
        return
    }
    Write-Host ''
    Write-Host "Limpeza completa em $hostName. Sera removido:"
    $targets | ForEach-Object { Write-Host "  - $_" }
    Write-Host ''
    if (-not $Yes) {
        $typed = (Read-Host "Digite o hostname ($hostName) para confirmar").Trim().ToLowerInvariant()
        if ($typed -cne $hostName) { throw 'Confirmacao incorreta; nada foi removido.' }
    }
} else {
    if (-not $installed -and -not $uninstaller -and -not $service) {
        Write-Log 'O Alloy nao esta instalado. Para remover residuos, use a limpeza completa (-Purge).'
        return
    }
    if (-not $Yes) {
        if (-not (Confirm-Choice "Desinstalar o Alloy de ${hostName}? Credencial e configuracao serao mantidas." $false)) {
            Write-Log 'Cancelado; nada foi alterado.'
            return
        }
    }
}

if ($service) {
    Write-Log 'Parando o servico...'
    Stop-Service -Name $ServiceName -Force -ErrorAction SilentlyContinue
}

# O desinstalador oficial pode limpar ProgramData\GrafanaLabs\Alloy. Sem
# -Purge, a pasta e movida temporariamente (mesmo volume: ACLs preservadas)
# e restaurada ao final.
$keep = $null
if (-not $Purge -and (Test-Path -LiteralPath $Base)) {
    $keep = Join-Path $env:ProgramData ('.alloy-keep-' + [guid]::NewGuid().ToString('N'))
    Move-Item -LiteralPath $Base -Destination $keep
}
try {
    if ($uninstaller) {
        Write-Log 'Executando o desinstalador oficial...'
        $p = Start-Process -FilePath $uninstaller -ArgumentList '/S' -Wait -PassThru
        if ($p.ExitCode -ne 0) { throw "Desinstalador retornou codigo $($p.ExitCode)." }
        # O desinstalador NSIS se copia para TEMP e retorna antes de terminar.
        for ($i = 0; $i -lt 60 -and ((Get-AlloyService) -or (Test-Path -LiteralPath $Exe)); $i++) {
            Start-Sleep -Seconds 1
        }
        if (Get-AlloyService) { throw 'O servico Alloy continua registrado apos o desinstalador.' }
    } elseif ($service) {
        Write-Warn 'Desinstalador nao encontrado; removendo apenas o servico.'
        & sc.exe delete $ServiceName | Out-Null
        if ($LASTEXITCODE -ne 0) { throw "sc.exe delete retornou $LASTEXITCODE." }
    }
} finally {
    if ($keep) {
        if (Test-Path -LiteralPath $Base) {
            Write-Warn "$Base foi recriada; os arquivos preservados estao em $keep."
        } else {
            $parent = Split-Path -Parent $Base
            if (-not (Test-Path -LiteralPath $parent)) { New-Item -ItemType Directory -Path $parent -Force | Out-Null }
            Move-Item -LiteralPath $keep -Destination $Base
        }
    }
}

if ($Purge) {
    Write-Log 'Removendo credencial, configuracao, dados, backups e registro...'
    foreach ($path in @($Base, $InstallDir)) {
        if (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path -Recurse -Force }
    }
    if (Test-Path -LiteralPath $Registry) { Remove-Item -LiteralPath $Registry -Recurse -Force }
    Remove-IfEmpty (Split-Path -Parent $Base)
    Remove-IfEmpty (Split-Path -Parent $InstallDir)
    Remove-IfEmpty 'HKLM:\SOFTWARE\GrafanaLabs'
    Write-Ok "Limpeza completa concluida em $hostName."
    Write-Host ''
    if (-not $account) { $account = "alloy-$hostName" }
    Write-Warn "A conta $account continua ativa no Authentik."
    Write-Warn 'Desative-a ou remova-a do grupo alloy-agents para revogar o acesso deste servidor.'
} else {
    Write-Ok "Alloy desinstalado de $hostName."
    Write-Log "Mantidos: $Secret, $ConfigDir, $DataDir e $BackupDir."
    Write-Log 'Para reinstalar sem novo setup, execute a instalacao novamente.'
}
