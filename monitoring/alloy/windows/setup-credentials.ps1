#Requires -RunAsAdministrator
#Requires -Version 5.1
[CmdletBinding()]
param([switch]$Rotate)
# Valida a conta de servico do Alloy (OAuth2 + ingestao no Loki) e, somente
# se ambos os testes passarem, grava a credencial com ACL restrita.
# Equivalente Windows do linux/setup-credentials.py.

$ErrorActionPreference = 'Stop'

$ClientId = '1T4SNZ8iDuvM18ZIB9fSc109ZZVglsXBtLxeU4ng'
$TokenUrl = 'https://auth.assessoriatech.com/application/o/token/'
$LokiUrl  = 'https://mon.assessoriatech.com/loki/api/v1/push'
$Base     = Join-Path $env:ProgramData 'GrafanaLabs\Alloy'
$Secret   = Join-Path $Base 'oauth-client-secret'
$Backups  = Join-Path $Base 'backups'

[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
Add-Type -AssemblyName System.Net.Http

$handler = New-Object System.Net.Http.HttpClientHandler
$handler.AllowAutoRedirect = $false
$client = New-Object System.Net.Http.HttpClient($handler)
$client.Timeout = [TimeSpan]::FromSeconds(12)
$client.DefaultRequestHeaders.UserAgent.ParseAdd('AssessoriaTech-Alloy-Setup/1.0')
$client.DefaultRequestHeaders.Accept.ParseAdd('application/json')

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
foreach ($pathToCheck in @($Base, $Secret)) {
    if (Test-Path -LiteralPath $pathToCheck) {
        $item = Get-Item -LiteralPath $pathToCheck -Force
        if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw "Caminho redirecionado nao permitido: $pathToCheck"
        }
    }
}
$exists = Test-Path -LiteralPath $Secret
if ($exists -and -not (Test-Path -LiteralPath $Secret -PathType Leaf)) {
    throw 'Caminho da credencial nao e arquivo regular.'
}
if ($exists -and -not $Rotate) { throw 'Credencial ja existe. Use -Rotate para substituir.' }
if (-not $exists -and $Rotate) { throw 'Credencial inexistente. Execute sem -Rotate.' }

$suggested = 'alloy-' + $env:COMPUTERNAME.ToLowerInvariant()
$username = (Read-Host "Conta de servico [$suggested]").Trim().ToLowerInvariant()
if (-not $username) { $username = $suggested }
$securePassword = Read-Host 'Senha do aplicativo' -AsSecureString
$bstr = [IntPtr]::Zero
$password = $null
try {
    $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($securePassword)
    $password = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr)
    if (-not $password) { throw 'Senha vazia; nenhum arquivo alterado.' }
    $credential = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($username + ':' + $password))
} finally {
    if ($bstr -ne [IntPtr]::Zero) {
        [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)
    }
    $password = $null
    $securePassword.Dispose()
}

if ($username -cnotmatch '^alloy-[a-z0-9][a-z0-9-]*$') {
    throw 'Conta invalida. Formato: alloy-<hostname>.'
}

try {
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
} finally {
    $client.Dispose()
    $handler.Dispose()
    $accessToken = $null
}

# Apenas a partir daqui persistimos no disco. Nao exige Alloy instalado.
# Novo diretorio e credencial possuem ACL somente para SYSTEM/Administradores.
function New-RestrictedAcl([switch]$Directory) {
    $acl = if ($Directory) { New-Object System.Security.AccessControl.DirectorySecurity } else {
        New-Object System.Security.AccessControl.FileSecurity
    }
    $acl.SetAccessRuleProtection($true, $false)
    $admins = New-Object System.Security.Principal.SecurityIdentifier('S-1-5-32-544')
    $acl.SetOwner($admins)
    foreach ($sid in @('S-1-5-18', 'S-1-5-32-544')) {
        $identity = New-Object System.Security.Principal.SecurityIdentifier($sid)
        if ($Directory) {
            $flags = [System.Security.AccessControl.InheritanceFlags]::ContainerInherit -bor
                     [System.Security.AccessControl.InheritanceFlags]::ObjectInherit
            $rule = [System.Security.AccessControl.FileSystemAccessRule]::new(
                $identity, [System.Security.AccessControl.FileSystemRights]::FullControl,
                $flags, [System.Security.AccessControl.PropagationFlags]::None,
                [System.Security.AccessControl.AccessControlType]::Allow)
        } else {
            $rule = [System.Security.AccessControl.FileSystemAccessRule]::new(
                $identity, [System.Security.AccessControl.FileSystemRights]::FullControl,
                [System.Security.AccessControl.AccessControlType]::Allow)
        }
        $acl.AddAccessRule($rule)
    }
    return $acl
}

if (-not (Test-Path -LiteralPath $Base)) {
    New-Item -ItemType Directory -Path $Base -Force | Out-Null
    Set-Acl -LiteralPath $Base -AclObject (New-RestrictedAcl -Directory)
}
if ($Rotate) {
    if (Test-Path -LiteralPath $Backups) {
        $folder = Get-Item -LiteralPath $Backups -Force
        if (($folder.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw 'Diretorio de backups redirecionado; operacao cancelada.'
        }
    } else {
        New-Item -ItemType Directory -Path $Backups -Force | Out-Null
    }
    Set-Acl -LiteralPath $Backups -AclObject (New-RestrictedAcl -Directory)
}

$temp = Join-Path $Base ('.oauth-client-secret-' + [Guid]::NewGuid().ToString('N') + '.tmp')
$rollback = $null
$committed = $false
$verified = $false
$restored = $false
try {
    # Arquivo nasce vazio; ACL aplicada ANTES de escrever a credencial.
    $stream = [IO.File]::Open($temp, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
    $stream.Dispose()
    Set-Acl -LiteralPath $temp -AclObject (New-RestrictedAcl)
    $bytes = [Text.Encoding]::ASCII.GetBytes($credential)
    $stream = [IO.File]::Open($temp, [IO.FileMode]::Open, [IO.FileAccess]::Write, [IO.FileShare]::None)
    try {
        $stream.Write($bytes, 0, $bytes.Length)
        $stream.Flush($true)
    } finally {
        $stream.Dispose()
        [Array]::Clear($bytes, 0, $bytes.Length)
    }

    if ($Rotate) {
        $rollback = Join-Path $Backups ('oauth-client-secret.rollback-' + [Guid]::NewGuid().ToString('N'))
        # Substituicao atomica no mesmo volume, com copia da versao anterior.
        [IO.File]::Replace($temp, $Secret, $rollback, $true)
    } else {
        [IO.File]::Move($temp, $Secret)
    }
    $committed = $true
    Set-Acl -LiteralPath $Secret -AclObject (New-RestrictedAcl)
    if ([IO.File]::ReadAllText($Secret, [Text.Encoding]::ASCII) -cne $credential) {
        throw 'Credencial gravada nao corresponde ao valor validado.'
    }
    $verified = $true
    if ($Rotate) {
        Write-Host "Credencial rotacionada: $Secret"
        Write-Host 'Se o Alloy ja estiver instalado, reinicie o servico para carregar a nova credencial.'
    } else {
        Write-Host "Credencial instalada: $Secret"
    }
    Write-Host 'ACL: somente SYSTEM e Administradores.'
} catch {
    if ($committed -and $Rotate -and $rollback -and (Test-Path -LiteralPath $rollback)) {
        try {
            [IO.File]::Replace($rollback, $Secret, $null, $true)
            $restored = $true
            Write-Warning 'Credencial anterior restaurada.'
        } catch {
            Write-Warning "Falha no rollback. Copia anterior preservada em $rollback"
        }
    } elseif ($committed -and -not $Rotate) {
        Remove-Item -LiteralPath $Secret -Force -ErrorAction SilentlyContinue
    }
    throw
} finally {
    if (Test-Path -LiteralPath $temp) {
        Remove-Item -LiteralPath $temp -Force -ErrorAction SilentlyContinue
    }
    if (($verified -or $restored) -and $rollback -and (Test-Path -LiteralPath $rollback)) {
        Remove-Item -LiteralPath $rollback -Force -ErrorAction SilentlyContinue
    }
    $credential = $null
}
Write-Host 'Proxima etapa: instalar e configurar o Alloy (install.ps1).'
