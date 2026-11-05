#Requires -Version 5.1
<#
.SYNOPSIS
Inventario das VMs do hypervisor (Hyper-V) para o textfile collector do Alloy.

.DESCRIPTION
Executado a cada minuto, como SYSTEM, pela tarefa agendada
"\GrafanaLabs\Alloy Hypervisor Inventory", criada pelo install.ps1 junto com o
modulo Hyper-V. Gera textfile\hypervisor.prom com metricas neutras
(hypervisor_*), lidas pelo Alloy no job integrations/hypervisor:

  hypervisor_inventory_*        saude do proprio inventario
  hypervisor_host_*             plataforma, CPUs logicas e memoria do host
  hypervisor_vm_info            identidade da VM e do sistema convidado
  hypervisor_vm_state           estado atual (one-hot: running, off, saved...)
  hypervisor_vm_*               uptime, vCPU, memoria, checkpoints, heartbeat
  hypervisor_vm_disk_*          discos virtuais (liga VHDX -> VM)
  hypervisor_vm_network_info    placas virtuais (liga adaptador -> VM)

O sistema convidado (hostname e SO) vem do KVP do Hyper-V. VM desligada nao
informa KVP; o ultimo valor conhecido fica em data\hypervisor\guests.json.
Logs diarios em logs\, com retencao de -LogRetentionDays dias.
Manter este arquivo em ASCII: o Windows PowerShell 5.1 le arquivos sem BOM como ANSI.
#>
[CmdletBinding()]
param(
    [string]$Root = (Join-Path $env:ProgramData 'GrafanaLabs\Alloy'),
    [ValidateRange(1, 365)]
    [int]$LogRetentionDays = 14
)

$ErrorActionPreference = 'Stop'
$Started = Get-Date
$OutputDir = Join-Path $Root 'textfile'
$StateDir = Join-Path $Root 'data\hypervisor'
$LogDir = Join-Path $Root 'logs'
$OutFile = Join-Path $OutputDir 'hypervisor.prom'
$CacheFile = Join-Path $StateDir 'guests.json'
$Invariant = [Globalization.CultureInfo]::InvariantCulture
$Platform = 'hyperv'
$States = @('running', 'off', 'saved', 'paused', 'starting', 'stopping', 'other')

$script:Metrics = [ordered]@{}
$script:Problems = New-Object System.Collections.Generic.List[string]

# ------------------------------------------------------------------ saida

function Write-InventoryLog([string]$Text) {
    try {
        if (-not (Test-Path -LiteralPath $LogDir -PathType Container)) { return }
        $file = Join-Path $LogDir ('hypervisor-inventory-' + (Get-Date -Format 'yyyyMMdd') + '.log')
        $line = (Get-Date -Format 'yyyy-MM-dd HH:mm:ss') + '  ' + $Text
        [IO.File]::AppendAllText($file, $line + "`r`n", (New-Object System.Text.UTF8Encoding($false)))
    } catch { }
}

# Retencao: remove logs do inventario mais antigos que $LogRetentionDays.
function Remove-OldLogs {
    try {
        $limit = (Get-Date).AddDays(-$LogRetentionDays)
        Get-ChildItem -LiteralPath $LogDir -Filter 'hypervisor-inventory-*.log' -File -ErrorAction Stop |
            Where-Object { $_.LastWriteTime -lt $limit } |
            Remove-Item -Force -ErrorAction SilentlyContinue
    } catch { }
}

function Add-Problem([string]$Text) {
    $script:Problems.Add($Text)
    Write-InventoryLog ('AVISO ' + $Text)
}

function ConvertTo-LabelValue($Value) {
    if ($null -eq $Value) { return '' }
    $text = [string]$Value
    return $text.Replace('\', '\\').Replace('"', '\"').Replace("`r", '').Replace("`n", '\n')
}

function ConvertTo-PromNumber($Value) {
    if ($null -eq $Value) { return 'NaN' }
    if ($Value -is [bool]) { if ($Value) { return '1' } else { return '0' } }
    return ([double]$Value).ToString('R', $Invariant)
}

# Agrupa amostras por metrica: o formato exige HELP/TYPE uma vez por nome.
function Add-Sample([string]$Name, [string]$Help, $Labels, $Value) {
    if (-not $script:Metrics.Contains($Name)) {
        $script:Metrics[$Name] = @{ Help = $Help; Samples = New-Object System.Collections.Generic.List[string] }
    }
    $pairs = @()
    if ($Labels) {
        foreach ($key in @($Labels.Keys)) {
            $pairs += ('{0}="{1}"' -f $key, (ConvertTo-LabelValue $Labels[$key]))
        }
    }
    $labelText = if ($pairs.Count -gt 0) { '{' + ($pairs -join ',') + '}' } else { '' }
    $script:Metrics[$Name].Samples.Add($Name + $labelText + ' ' + (ConvertTo-PromNumber $Value))
}

# Escrita atomica: grava .tmp (ignorado pelo coletor) e substitui o .prom.
# O textfile collector exige LF e uma quebra de linha no final.
# Substitui Target por Source. [NullString]::Value: o PowerShell converteria
# $null em "" e o .NET recusaria o caminho de backup. Nova tentativa caso o
# Alloy esteja lendo o arquivo no instante da troca.
function Move-Replace([string]$Source, [string]$Target) {
    for ($i = 1; $i -le 5; $i++) {
        try {
            if (Test-Path -LiteralPath $Target -PathType Leaf) {
                [IO.File]::Replace($Source, $Target, [NullString]::Value)
            } else {
                [IO.File]::Move($Source, $Target)
            }
            return
        } catch {
            if ($i -eq 5) { throw }
            Start-Sleep -Milliseconds 300
        }
    }
}

function Save-PromFile {
    $builder = New-Object System.Text.StringBuilder
    foreach ($name in $script:Metrics.Keys) {
        $metric = $script:Metrics[$name]
        [void]$builder.Append('# HELP ' + $name + ' ' + $metric.Help + "`n")
        [void]$builder.Append('# TYPE ' + $name + " gauge`n")
        foreach ($sample in $metric.Samples) { [void]$builder.Append($sample + "`n") }
    }
    $tmp = $OutFile + '.tmp'
    [IO.File]::WriteAllText($tmp, $builder.ToString(), (New-Object System.Text.UTF8Encoding($false)))
    Move-Replace $tmp $OutFile
}

# ------------------------------------------------------- sistema convidado

function Read-GuestCache {
    $cache = @{}
    try {
        if (Test-Path -LiteralPath $CacheFile -PathType Leaf) {
            $json = [IO.File]::ReadAllText($CacheFile) | ConvertFrom-Json
            foreach ($prop in $json.PSObject.Properties) { $cache[$prop.Name] = $prop.Value }
        }
    } catch { Add-Problem "cache de convidados ilegivel: $($_.Exception.Message)" }
    return $cache
}

function Save-GuestCache($Cache) {
    try {
        if (-not (Test-Path -LiteralPath $StateDir -PathType Container)) { return }
        $tmp = $CacheFile + '.tmp'
        [IO.File]::WriteAllText($tmp, (ConvertTo-Json -InputObject $Cache -Depth 4), (New-Object System.Text.UTF8Encoding($false)))
        Move-Replace $tmp $CacheFile
    } catch { Add-Problem "falha ao gravar o cache de convidados: $($_.Exception.Message)" }
}

# KVP (Data Exchange): nome e SO informados pelo proprio convidado.
# Indexado pelo GUID da VM (SystemName), em maiusculas.
function Get-GuestKvp {
    $map = @{}
    try {
        $items = @(Get-CimInstance -Namespace 'root\virtualization\v2' -ClassName 'Msvm_KvpExchangeComponent' -ErrorAction Stop)
    } catch {
        Add-Problem "KVP indisponivel: $($_.Exception.Message)"
        return $map
    }
    foreach ($item in $items) {
        $values = @{}
        foreach ($raw in @($item.GuestIntrinsicExchangeItems)) {
            if (-not $raw) { continue }
            try {
                $xml = [xml]$raw
                $key = $xml.SelectSingleNode("/INSTANCE/PROPERTY[@NAME='Name']/VALUE")
                $data = $xml.SelectSingleNode("/INSTANCE/PROPERTY[@NAME='Data']/VALUE")
                if ($key -and $data) { $values[$key.InnerText] = $data.InnerText }
            } catch { }
        }
        if ($values.Count -gt 0) { $map[([string]$item.SystemName).ToUpperInvariant()] = $values }
    }
    return $map
}

function Get-GuestKind([string]$OsName) {
    if (-not $OsName) { return 'unknown' }
    if ($OsName -match 'Windows') { return 'windows' }
    return 'linux'
}

# ------------------------------------------------------------- mapeamentos

function Get-StateName([string]$State) {
    switch -Wildcard ($State) {
        'Running*'  { return 'running' }
        'Off*'      { return 'off' }
        'Saved*'    { return 'saved' }
        'Paused*'   { return 'paused' }
        'Starting*' { return 'starting' }
        'Resuming*' { return 'starting' }
        'Stopping*' { return 'stopping' }
        'Saving*'   { return 'stopping' }
        'Pausing*'  { return 'stopping' }
        default     { return 'other' }
    }
}

# --------------------------------------------- ligacao com os contadores
# Os labels device e adapter do coletor hyperv sao os nomes de instancia dos
# contadores "Hyper-V Virtual Storage Device" e "Hyper-V Virtual Network
# Adapter". O nome e fixado quando a VM liga: disco movido ou VM renomeada com
# ela ligada mantem o nome antigo ate reiniciar. Por isso o inventario le os
# nomes reais e casa cada disco/placa, em vez de so calcular o nome esperado.

# Disco: caminho com "\" trocado por "-" (os .vmgs vem com o prefixo "--?-").
function Get-StorageDeviceName([string]$Path) {
    if (-not $Path) { return '' }
    return $Path.Replace('\', '-')
}

# Placa: <VM>_<Placa>_<VMGUID>--<PlacaGUID>. Os GUIDs nao mudam.
function Get-NetworkAdapterSuffix([string]$Id) {
    return ($Id -replace '^Microsoft:', '').Replace('\', '--')
}

# Nomes de instancia atuais, pelas classes WMI de desempenho (nomes que nao
# mudam com o idioma do Windows). Lista vazia se a classe nao responder.
function Get-CounterInstances([string]$Class) {
    try {
        return @(Get-CimInstance -ClassName $Class -Property Name -ErrorAction Stop |
            ForEach-Object { [string]$_.Name } |
            Where-Object { $_ -and $_ -ne '_Total' })
    } catch {
        Add-Problem "contadores $Class indisponiveis: $($_.Exception.Message)"
        return @()
    }
}

# Casa cada item com uma instancia real, em duas passadas: primeiro o nome
# exato (com ou sem "--?-"); depois, entre as instancias que sobraram, um
# final unico (arquivo do disco ou GUIDs da placa). match: exact, suffix ou
# none (VM desligada nao tem instancia).
function Resolve-CounterNames($Items, $Instances) {
    $claimed = @{}
    foreach ($item in $Items) {
        $item.Instance = $item.Expected
        $item.Match = 'none'
        foreach ($candidate in @($item.Expected, ('--?-' + $item.Expected))) {
            $hit = @($Instances | Where-Object { $_ -eq $candidate -and -not $claimed.ContainsKey($_) }) | Select-Object -First 1
            if ($hit) {
                $item.Instance = $hit
                $item.Match = 'exact'
                $claimed[$hit] = $true
                break
            }
        }
    }
    foreach ($item in @($Items | Where-Object { $_.Match -eq 'none' -and $_.Suffix })) {
        $hits = @($Instances | Where-Object {
            -not $claimed.ContainsKey($_) -and $_.EndsWith($item.Suffix, [StringComparison]::OrdinalIgnoreCase)
        })
        if ($hits.Count -eq 1) {
            $item.Instance = $hits[0]
            $item.Match = 'suffix'
            $claimed[$hits[0]] = $true
        }
    }
}

# -------------------------------------------------------------- inventario

function Invoke-Inventory {
    $vmHost = Get-VMHost -ErrorAction Stop
    $osVersion = ''
    try { $osVersion = [string](Get-CimInstance -ClassName Win32_OperatingSystem -ErrorAction Stop).Version } catch { }
    $hostLabels = [ordered]@{ platform = $Platform; version = $osVersion }
    Add-Sample 'hypervisor_host_info' 'Plataforma do hypervisor (valor sempre 1).' $hostLabels 1
    Add-Sample 'hypervisor_host_cpus' 'Processadores logicos do host.' $null $vmHost.LogicalProcessorCount
    Add-Sample 'hypervisor_host_memory_bytes' 'Memoria fisica do host.' $null $vmHost.MemoryCapacity

    $vms = @(Get-VM -ErrorAction Stop)
    $kvp = Get-GuestKvp
    $cache = Read-GuestCache
    $seen = @{}
    $disks = New-Object System.Collections.Generic.List[object]
    $nics = New-Object System.Collections.Generic.List[object]

    foreach ($vm in $vms) {
        $name = [string]$vm.Name
        $id = ([string]$vm.Id).ToUpperInvariant()
        $seen[$id] = $true
        $state = Get-StateName ([string]$vm.State)
        $vmLabel = [ordered]@{ vm = $name }

        # Convidado: KVP atual -> ultimo conhecido -> nome da VM.
        $guestHost = ''; $guestOs = ''; $source = 'vm_name'
        if ($kvp.ContainsKey($id)) {
            $values = $kvp[$id]
            $fqdn = [string]$values['FullyQualifiedDomainName']
            if ($fqdn) { $guestHost = $fqdn.Split('.')[0].ToLowerInvariant() }
            $guestOs = [string]$values['OSName']
            if ($guestHost -or $guestOs) {
                $source = 'kvp'
                $cache[$id] = [ordered]@{ guest_host = $guestHost; guest_os = $guestOs; seen = (Get-Date).ToString('o') }
            }
        }
        if ($source -ne 'kvp' -and $cache.ContainsKey($id)) {
            $guestHost = [string]$cache[$id].guest_host
            $guestOs = [string]$cache[$id].guest_os
            $source = 'cache'
        }
        if (-not $guestHost) { $guestHost = $name.ToLowerInvariant() }

        $info = [ordered]@{
            vm           = $name
            vm_id        = $id
            platform     = $Platform
            generation   = [string]$vm.Generation
            config       = [string]$vm.Version
            guest_host   = $guestHost
            guest_os     = $guestOs
            guest_kind   = (Get-GuestKind $guestOs)
            guest_source = $source
        }
        Add-Sample 'hypervisor_vm_info' 'Identidade da VM e do sistema convidado (valor sempre 1). guest_source: kvp, cache ou vm_name.' $info 1
        foreach ($s in $States) {
            Add-Sample 'hypervisor_vm_state' 'Estado atual da VM (1 no estado vigente).' ([ordered]@{ vm = $name; state = $s }) ([int]($s -eq $state))
        }
        Add-Sample 'hypervisor_vm_critical' 'VM em estado critico no Hyper-V (1 = sim).' $vmLabel ([int]([string]$vm.State -like '*Critical'))
        if ($source -ne 'vm_name') {
            Add-Sample 'hypervisor_vm_name_matches_guest' 'Nome da VM igual ao hostname do convidado (1 = sim).' $vmLabel ([int]($name.ToLowerInvariant() -eq $guestHost))
        }
        Add-Sample 'hypervisor_vm_uptime_seconds' 'Tempo ligada.' $vmLabel $vm.Uptime.TotalSeconds
        Add-Sample 'hypervisor_vm_cpus' 'vCPUs configuradas.' $vmLabel $vm.ProcessorCount
        Add-Sample 'hypervisor_vm_memory_startup_bytes' 'Memoria inicial configurada.' $vmLabel $vm.MemoryStartup
        Add-Sample 'hypervisor_vm_memory_assigned_bytes' 'Memoria atribuida agora (0 se desligada).' $vmLabel $vm.MemoryAssigned
        Add-Sample 'hypervisor_vm_dynamic_memory' 'Memoria dinamica habilitada (1 = sim).' $vmLabel ([bool]$vm.DynamicMemoryEnabled)
        if ($vm.DynamicMemoryEnabled) {
            Add-Sample 'hypervisor_vm_memory_maximum_bytes' 'Limite da memoria dinamica.' $vmLabel $vm.MemoryMaximum
        }

        try {
            $checkpoints = @(Get-VMSnapshot -VM $vm -ErrorAction Stop).Count
            Add-Sample 'hypervisor_vm_checkpoints' 'Quantidade de checkpoints.' $vmLabel $checkpoints
        } catch { Add-Problem "$name checkpoints: $($_.Exception.Message)" }

        # Heartbeat so faz sentido com a VM ligada e o servico de integracao ativo.
        if ($state -eq 'running' -and $vm.Heartbeat) {
            $hb = [string]$vm.Heartbeat
            if ($hb -ne 'Disabled') {
                Add-Sample 'hypervisor_vm_heartbeat' 'Convidado respondendo ao heartbeat (1 = OK).' $vmLabel ([int]($hb -like 'Ok*'))
            }
        }

        try {
            foreach ($drive in @(Get-VMHardDiskDrive -VM $vm -ErrorAction Stop)) {
                $path = [string]$drive.Path
                if (-not $path) { continue }
                $controller = '{0}{1}:{2}' -f $drive.ControllerType, $drive.ControllerNumber, $drive.ControllerLocation
                $diskLabels = [ordered]@{ vm = $name; path = $path }
                $type = ''
                try {
                    $vhd = Get-VHD -Path $path -ErrorAction Stop
                    $type = ([string]$vhd.VhdType).ToLowerInvariant()
                    Add-Sample 'hypervisor_vm_disk_size_bytes' 'Tamanho maximo do disco virtual.' $diskLabels $vhd.Size
                    Add-Sample 'hypervisor_vm_disk_file_bytes' 'Espaco ocupado pelo arquivo do disco no host.' $diskLabels $vhd.FileSize
                } catch { Add-Problem "$name disco ${path}: $($_.Exception.Message)" }
                $disks.Add(@{
                    Vm = $name; Path = $path; Controller = $controller; Type = $type
                    Expected = (Get-StorageDeviceName $path)
                    Suffix = ('-' + [IO.Path]::GetFileName($path))
                    Instance = ''; Match = ''
                })
            }
        } catch { Add-Problem "$name discos: $($_.Exception.Message)" }

        try {
            foreach ($nic in @(Get-VMNetworkAdapter -VM $vm -ErrorAction Stop)) {
                $ipv4 = @($nic.IPAddresses | Where-Object { $_ -match '^\d+\.\d+\.\d+\.\d+$' }) -join ','
                $suffix = Get-NetworkAdapterSuffix ([string]$nic.Id)
                $nics.Add(@{
                    Vm = $name; Name = [string]$nic.Name; Id = [string]$nic.Id
                    Switch = [string]$nic.SwitchName; Mac = [string]$nic.MacAddress; Ipv4 = $ipv4
                    Expected = ('{0}_{1}_{2}' -f $name, [string]$nic.Name, $suffix)
                    Suffix = ('_' + $suffix)
                    Instance = ''; Match = ''
                })
            }
        } catch { Add-Problem "$name rede: $($_.Exception.Message)" }
    }

    Resolve-CounterNames $disks (Get-CounterInstances 'Win32_PerfRawData_Counters_HyperVVirtualStorageDevice')
    foreach ($d in $disks) {
        $infoDisk = [ordered]@{
            vm = $d.Vm; path = $d.Path; device = $d.Instance; device_match = $d.Match
            controller = $d.Controller; type = $d.Type
        }
        Add-Sample 'hypervisor_vm_disk_info' 'Disco virtual da VM (valor sempre 1). device = nome nos contadores do Hyper-V; device_match: exact, suffix ou none.' $infoDisk 1
    }
    Resolve-CounterNames $nics (Get-CounterInstances 'Win32_PerfRawData_NvspNicStats_HyperVVirtualNetworkAdapter')
    foreach ($n in $nics) {
        $nicLabels = [ordered]@{
            vm = $n.Vm; name = $n.Name; adapter = $n.Instance; adapter_match = $n.Match
            adapter_id = $n.Id; switch = $n.Switch; mac = $n.Mac; ipv4 = $n.Ipv4
        }
        Add-Sample 'hypervisor_vm_network_info' 'Placa de rede virtual da VM (valor sempre 1). adapter = nome nos contadores do Hyper-V; adapter_match: exact, suffix ou none.' $nicLabels 1
    }

    # Cache: descarta VMs que nao existem mais neste host.
    foreach ($key in @($cache.Keys)) { if (-not $seen.ContainsKey($key)) { $cache.Remove($key) } }
    Save-GuestCache $cache
    return $vms.Count
}

# ------------------------------------------------------------------ principal

Remove-OldLogs
$success = 0
$count = 0
try {
    if (-not (Test-Path -LiteralPath $OutputDir -PathType Container)) {
        throw "Diretorio de saida ausente: $OutputDir (reaplique a configuracao do Alloy)."
    }
    $count = Invoke-Inventory
    $success = 1
} catch {
    Add-Problem "inventario falhou: $($_.Exception.Message)"
    # Sem dados de VM parciais: so a saude do inventario, para o dashboard
    # mostrar a falha em vez de valores antigos.
    $script:Metrics = [ordered]@{}
}

$duration = ((Get-Date) - $Started).TotalSeconds
Add-Sample 'hypervisor_inventory_success' 'Ultima execucao do inventario concluida (1 = sim).' $null $success
Add-Sample 'hypervisor_inventory_problems' 'Avisos na ultima execucao (itens que nao puderam ser lidos).' $null $script:Problems.Count
Add-Sample 'hypervisor_inventory_duration_seconds' 'Duracao da ultima execucao.' $null $duration
Add-Sample 'hypervisor_inventory_timestamp_seconds' 'Horario da ultima execucao (Unix).' $null ([DateTimeOffset]::new($Started).ToUnixTimeSeconds())

try {
    if (Test-Path -LiteralPath $OutputDir -PathType Container) { Save-PromFile }
} catch {
    Add-Problem "falha ao gravar ${OutFile}: $($_.Exception.Message)"
    $success = 0
}

Write-InventoryLog ('{0} vms={1} avisos={2} duracao={3}s' -f $(if ($success) { 'OK' } else { 'FALHA' }), $count, $script:Problems.Count, [Math]::Round($duration, 1).ToString($Invariant))
if (-not $success) { exit 1 }
