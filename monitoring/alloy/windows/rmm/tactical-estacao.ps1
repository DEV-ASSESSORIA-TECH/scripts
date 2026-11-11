<#
.SYNOPSIS
Instala ou reaplica o Grafana Alloy (perfil estacao) pelo Tactical RMM, sem nenhuma pergunta.

.DESCRIPTION
Cadastrar no Tactical RMM (Settings > Script Manager > New Script):
  Shell:                 PowerShell
  Run As User:           desmarcado (roda como SYSTEM)
  Timeout:               900
  Environment vars:      ALLOY_PASSWORD={{global.ALLOY_ESTACOES_SENHA}}
  Script Arguments:      nenhum

A senha da conta compartilhada alloy-estacoes fica so no Global Key Store
(Settings > Global Settings > Key Store, chave ALLOY_ESTACOES_SENHA). Ela
chega por variavel de ambiente, nunca por argumento: argumentos aparecem na
linha de comando do processo e no historico do Tactical.

Idempotente: na primeira execucao grava a credencial (testada por OAuth2 +
Loki antes de gravar) e instala; nas seguintes so reaplica a configuracao.
Codigo de saida 0 = sucesso, 1 = falha (motivo na saida do script).

Use -Ref para testar uma branch antes de ir para a main.
#>
param(
    [string]$Ref = 'main'
)
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

if ($Ref -notmatch '^[A-Za-z0-9][A-Za-z0-9._/-]*$' -or $Ref.Contains('..')) {
    Write-Output "Ref invalida: $Ref"
    exit 1
}

# PowerShell 32 bits em Windows 64 bits enxerga "Program Files (x86)" e o
# registro redirecionado: reexecuta no PowerShell 64 bits (sysnative).
if ([Environment]::Is64BitOperatingSystem -and -not [Environment]::Is64BitProcess) {
    $ps64 = Join-Path $env:windir 'sysnative\WindowsPowerShell\v1.0\powershell.exe'
    & $ps64 -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $PSCommandPath -Ref $Ref
    exit $LASTEXITCODE
}

$dir = $null
try {
    $credential = Join-Path $env:ProgramData 'GrafanaLabs\Alloy\oauth-client-secret'
    if (-not (Test-Path -LiteralPath $credential) -and -not $env:ALLOY_PASSWORD) {
        throw 'ALLOY_PASSWORD vazia. Configure no script: Environment vars -> ALLOY_PASSWORD={{global.ALLOY_ESTACOES_SENHA}}.'
    }
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
    $dir = Join-Path $env:TEMP ('alloy-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $dir | Out-Null
    $url = "https://raw.githubusercontent.com/DEV-ASSESSORIA-TECH/scripts/$Ref/monitoring/alloy/windows/alloy.ps1"
    Invoke-WebRequest -Uri $url -OutFile (Join-Path $dir 'alloy.ps1') -UseBasicParsing
    # alloy.ps1 instala/atualiza o alloyctl e segue por ele; a credencial so e
    # pedida se ainda nao existir (setup-credentials.ps1 le ALLOY_PASSWORD).
    & (Join-Path $dir 'alloy.ps1') install -Perfil estacao -Ref $Ref
    Write-Output 'Alloy (estacao) instalado e configurado.'
    exit 0
} catch {
    Write-Output "FALHA: $($_.Exception.Message)"
    exit 1
} finally {
    $env:ALLOY_PASSWORD = $null
    if ($dir) { Remove-Item -LiteralPath $dir -Recurse -Force -ErrorAction SilentlyContinue }
}
