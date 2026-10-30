#Requires -RunAsAdministrator
# Valida a conta de servico do Alloy (OAuth2 + ingestao no Loki) e, somente
# se ambos os testes passarem, grava a credencial com ACL restrita.
# Equivalente Windows do linux/setup-credentials.py.

$ErrorActionPreference = 'Stop'

$ClientId = '1T4SNZ8iDuvM18ZIB9fSc109ZZVglsXBtLxeU4ng'
$TokenUrl = 'https://auth.assessoriatech.com/application/o/token/'
$LokiUrl  = 'https://mon.assessoriatech.com/loki/api/v1/push'
$Base     = Join-Path $env:ProgramData 'GrafanaLabs\Alloy'
$Secret   = Join-Path $Base 'oauth-client-secret'

[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
Add-Type -AssemblyName System.Net.Http

$handler = New-Object System.Net.Http.HttpClientHandler
$handler.AllowAutoRedirect = $false
$client = New-Object System.Net.Http.HttpClient($handler)
$client.Timeout = [TimeSpan]::FromSeconds(12)

function Invoke-Post($Url, $Content, $Label) {
    try {
        $response = $client.PostAsync($Url, $Content).GetAwaiter().GetResult()
        $body = $response.Content.ReadAsStringAsync().GetAwaiter().GetResult()
        return @{ Status = [int]$response.StatusCode; Body = $body }
    } catch {
        Write-Host "${Label}: HTTP sem resposta | ERRO de rede/TLS ($($_.Exception.GetType().Name))"
        throw 'Nenhum arquivo local foi alterado.'
    }
}

if (Test-Path -LiteralPath $Base -PathType Leaf) {
    throw "Diretorio $Base invalido."
}
if (Test-Path -LiteralPath $Secret) {
    throw 'Credencial ja existe; nada foi sobrescrito.'
}

$username = (Read-Host 'Conta de servico (alloy-<hostname>)').Trim()
$securePassword = Read-Host 'Senha do aplicativo' -AsSecureString
$password = [Runtime.InteropServices.Marshal]::PtrToStringAuto(
    [Runtime.InteropServices.Marshal]::SecureStringToBSTR($securePassword))

if ($username -cnotmatch '^alloy-[a-z0-9][a-z0-9-]*$' -or [string]::IsNullOrEmpty($password)) {
    throw 'Usuario ou senha invalidos; nenhum arquivo alterado.'
}
$credential = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes("${username}:${password}"))
$password = $null

# Teste 1 - OAuth2
$form = New-Object 'System.Collections.Generic.List[System.Collections.Generic.KeyValuePair[string,string]]'
$form.Add((New-Object 'System.Collections.Generic.KeyValuePair[string,string]' 'grant_type', 'client_credentials'))
$form.Add((New-Object 'System.Collections.Generic.KeyValuePair[string,string]' 'client_id', $ClientId))
$form.Add((New-Object 'System.Collections.Generic.KeyValuePair[string,string]' 'client_secret', $credential))
$form.Add((New-Object 'System.Collections.Generic.KeyValuePair[string,string]' 'scope', 'profile'))
$result = Invoke-Post $TokenUrl (New-Object System.Net.Http.FormUrlEncodedContent($form)) 'Teste 1 - OAuth2'
if ($result.Status -ne 200) {
    Write-Host "Teste 1 - OAuth2: HTTP $($result.Status) | REPROVADO - autenticacao negada"
    throw 'Nenhum arquivo local foi alterado.'
}
try {
    $accessToken = ($result.Body | ConvertFrom-Json).access_token
} catch {
    $accessToken = $null
}
if (-not ($accessToken -is [string]) -or [string]::IsNullOrEmpty($accessToken)) {
    Write-Host 'Teste 1 - OAuth2: HTTP 200 | REPROVADO - token ausente'
    throw 'Nenhum arquivo local foi alterado.'
}
Write-Host 'Teste 1 - OAuth2: HTTP 200 | APROVADO - token emitido'

# Teste 2 - Loki
$nowNs = ([DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds() * 1000000).ToString()
$probe = @{
    streams = @(@{
        stream = @{ job = 'alloy-auth-probe'; host = $username.Substring(6) }
        values = @(, @($nowNs, 'Teste de autorizacao Alloy'))
    })
} | ConvertTo-Json -Depth 6 -Compress
$content = New-Object System.Net.Http.StringContent($probe, [Text.Encoding]::UTF8, 'application/json')
$client.DefaultRequestHeaders.Authorization =
    New-Object System.Net.Http.Headers.AuthenticationHeaderValue('Bearer', $accessToken)
$result = Invoke-Post $LokiUrl $content 'Teste 2 - Loki'
if ($result.Status -ne 204) {
    Write-Host "Teste 2 - Loki: HTTP $($result.Status) | REPROVADO - ingestao nao confirmada"
    throw 'Nenhum arquivo local foi alterado.'
}
Write-Host 'Teste 2 - Loki: HTTP 204 | APROVADO - ingestao autorizada'

# Apenas a partir daqui persistimos no disco. Nao exige Alloy instalado.
New-Item -ItemType Directory -Path $Base -Force | Out-Null

$stream = [IO.File]::Open($Secret, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
try {
    $bytes = [Text.Encoding]::ASCII.GetBytes($credential)
    $stream.Write($bytes, 0, $bytes.Length)
    $stream.Flush($true)
} catch {
    $stream.Dispose()
    Remove-Item -LiteralPath $Secret -Force -ErrorAction SilentlyContinue
    throw
}
$stream.Dispose()

# ACL: somente SYSTEM (servico do Alloy) e Administradores, sem heranca.
$acl = New-Object System.Security.AccessControl.FileSecurity
$acl.SetAccessRuleProtection($true, $false)
foreach ($sid in 'S-1-5-18', 'S-1-5-32-544') {
    $identity = New-Object System.Security.Principal.SecurityIdentifier($sid)
    $rule = New-Object System.Security.AccessControl.FileSystemAccessRule($identity, 'FullControl', 'Allow')
    $acl.AddAccessRule($rule)
}
$acl.SetOwner((New-Object System.Security.Principal.SecurityIdentifier('S-1-5-32-544')))
Set-Acl -LiteralPath $Secret -AclObject $acl

Write-Host "Credencial instalada: $Secret (SYSTEM + Administradores)."
Write-Host 'Proxima etapa: instalar e configurar o Alloy (install.ps1).'
