#Requires -Version 5.1
<#
.SYNOPSIS
PONTE TEMPORARIA: o alloyctl mudou para DEV-ASSESSORIA-TECH/alloy.

.DESCRIPTION
Atende quem ainda chega pelo endereco antigo: o comando antigo do README, o
script do Tactical RMM ainda nao recolado e o alloyctl ja instalado, que se
atualiza por este caminho e baixa alloy.ps1 + lib\*.ps1 (os lib\ daqui sao
vazios de proposito). Baixa o ponto de entrada do repositorio novo e o
executa: ele instala o alloyctl da ultima release (canal stable) e segue com o
mesmo comando. -Ref e -NoUpdate sao descartados (as refs deste repositorio nao
existem no novo).

Aceita os mesmos parametros da versao anterior: o alloyctl antigo chama este
arquivo com eles.
#>
[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [string]$Command = '',
    [Parameter(Position = 1)]
    [string[]]$Modules = @('auto'),
    [string]$Perfil = 'auto',
    [switch]$Upgrade,
    [switch]$Yes,
    [string]$Ref,
    [string]$Url,
    [switch]$NoUpdate,
    [Parameter(DontShow)]
    [switch]$Elevated
)

$ErrorActionPreference = 'Stop'
$newEntry = 'https://raw.githubusercontent.com/DEV-ASSESSORIA-TECH/alloy/main/windows/alloy.ps1'

$forward = @{}
foreach ($key in $PSBoundParameters.Keys) {
    if ($key -notin @('Ref', 'NoUpdate')) { $forward[$key] = $PSBoundParameters[$key] }
}
$savedRef = $env:ALLOY_REF
$env:ALLOY_REF = $null

Write-Host '[alloyctl] O alloyctl mudou para github.com/DEV-ASSESSORIA-TECH/alloy; migrando...'
$dir = Join-Path $env:TEMP ('alloy-ponte-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $dir | Out-Null
try {
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
    $entry = Join-Path $dir 'alloy.ps1'
    Invoke-WebRequest -Uri $newEntry -OutFile $entry -UseBasicParsing -Headers @{ 'User-Agent' = 'AssessoriaTech-Alloy-Installer/1.0' }
    & $entry @forward
} finally {
    $env:ALLOY_REF = $savedRef
    Remove-Item -LiteralPath $dir -Recurse -Force -ErrorAction SilentlyContinue
}
