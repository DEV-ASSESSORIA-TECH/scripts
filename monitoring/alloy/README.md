# Grafana Alloy

Instalação e gestão do agente [Grafana Alloy](https://grafana.com/docs/alloy/latest/),
que envia métricas e logs de cada servidor ao monitoramento central.

Um único comando abre a ferramenta. Na primeira execução, ele segue direto o
fluxo de credencial e depois a instalação. Nas seguintes, abre um menu:

```
 ==============================================================
  GRAFANA ALLOY                                        srv-web
 ==============================================================
  Servico      [ OK ]  ativo e pronto         v1.11.2
  Credencial   [ OK ]  alloy-srv-web
  Modulos              Linux
  Ultima acao  [ OK ]  Testar credencial - concluido (10:42)
 --------------------------------------------------------------
  INSTALACAO                    CREDENCIAL
   [1] Reaplicar configuracao    [4] Testar
   [2] Ativar Docker             [5] Rotacionar
   [3] Atualizar Alloy

  DIAGNOSTICO                   REMOCAO
   [6] Ver diagnostico           [7] Desinstalar
                                 [8] Limpeza completa
 --------------------------------------------------------------
  Tecle a opcao (0 sai):
```

As opções são escolhidas com uma tecla, sem Enter. Quando o serviço não
está instalado ou está parado, Enter executa a opção recomendada ([1]). O
diagnóstico mostra avisos e erros das últimas 24h, a conectividade com
`auth` e `mon` e links do Grafana Explore já filtrados pelo host.

## Executar

**Linux (Debian/Ubuntu)**

```bash
(
  set -e
  dir=$(mktemp -d)
  trap 'rm -rf "$dir"' EXIT
  curl -fsSL https://raw.githubusercontent.com/DEV-ASSESSORIA-TECH/scripts/main/monitoring/alloy/linux/alloy.sh -o "$dir/alloy.sh"
  sudo bash "$dir/alloy.sh"
)
```

**Windows Server (PowerShell como Administrador)**

```powershell
$dir = Join-Path $env:TEMP ("alloy-" + [guid]::NewGuid())
New-Item -ItemType Directory -Path $dir | Out-Null
try {
    Invoke-WebRequest "https://raw.githubusercontent.com/DEV-ASSESSORIA-TECH/scripts/main/monitoring/alloy/windows/alloy.ps1" -OutFile "$dir\alloy.ps1" -UseBasicParsing
    & "$dir\alloy.ps1"
} finally {
    Remove-Item $dir -Recurse -Force -ErrorAction SilentlyContinue
}
```

O ponto de entrada baixa, a partir do mesmo ref, só os arquivos de que cada
operação precisa. Executado a partir de um clone, usa os arquivos locais.

## Comandos diretos (automação)

| Linux (`alloy.sh`) | Windows (`alloy.ps1`) | Ação |
|--------------------|-----------------------|------|
| `install [--modules docker\|none] [--upgrade]` | `install [-Modules hyperv\|none] [-Upgrade]` | credencial (se ausente) + instalação |
| `credentials` | `credentials` | só o setup da credencial |
| `check` | `check` | testa a credencial gravada, sem alterar nada |
| `rotate` | `rotate` | troca a credencial e reinicia o Alloy |
| `modules docker\|none` | `modules hyperv\|none` | ativa/desativa o módulo opcional |
| `upgrade` | `upgrade` | atualiza o Alloy |
| `status` | `status` | diagnóstico |
| `uninstall [--yes]` | `uninstall [-Yes]` | remove o Alloy, mantendo credencial e configuração |
| `purge [--yes]` | `purge [-Yes]` | limpeza completa |

`--ref <branch|tag|commit>` (`-Ref` no Windows) fixa a versão do repositório.

## Arquivos

| Arquivo | Função |
|---------|--------|
| `alloy.sh` / `alloy.ps1` | ponto de entrada: menu e comandos |
| `lib/common.*` | constantes, saída e download |
| `lib/state.*` | estado do servidor, cabeçalho e diagnóstico |
| `lib/ui.*` | interface do terminal: telas, marcadores, menu e teclas |
| `setup-credentials.*` | valida a conta de serviço (OAuth2 + Loki) e grava a credencial |
| `install.*` | instala o Alloy e aplica a configuração, com validação e rollback |
| `uninstall.*` | desinstalação e limpeza completa |
| `config.alloy` | configuração base do sistema |
| `docker.alloy` / `hyperv.alloy` | módulos opcionais |
| `hypervisor-inventory.ps1` | inventário de VMs do módulo Hyper-V (tarefa agendada) |

## Módulo Hyper-V

Detectado automaticamente na instalação (serviço `vmms` ativo e `Get-VM`
acessível). Em servidores que já têm o módulo, **[1] Reaplicar configuração**
atualiza tudo, inclusive o inventário de VMs.

| Parte | Onde | O que faz |
|-------|------|-----------|
| Métricas Hyper-V | `config\hyperv.alloy`, job `integrations/hyperv` | contadores do hypervisor: CPU, memória, discos e rede virtuais |
| Inventário de VMs | `scripts\hypervisor-inventory.ps1`, job `integrations/hypervisor` | estado de cada VM (inclusive desligadas), sistema convidado, vCPU, memória, checkpoints, heartbeat, discos e placas de rede |
| Logs | `hyperv.alloy`, job `hyperv-eventlog` | canais VMMS-Admin e Worker-Admin |

O inventário roda a cada minuto, como SYSTEM, pela tarefa agendada
`\GrafanaLabs\Alloy Hypervisor Inventory`, e grava `textfile\hypervisor.prom`,
lido pelo coletor `textfile` do Alloy (requer Alloy v1.11+). As métricas usam
nomes neutros (`hypervisor_*`, com `platform="hyperv"`) para que outras
plataformas possam publicar o mesmo formato.

Diretórios em `C:\ProgramData\GrafanaLabs\Alloy` (acesso só de SYSTEM e
Administradores):

| Diretório | Conteúdo | Retenção |
|-----------|----------|----------|
| `scripts\` | script do inventário | substituído a cada reaplicação |
| `textfile\` | `hypervisor.prom` | sobrescrito a cada execução |
| `data\hypervisor\` | `guests.json`: último hostname/SO conhecido de cada VM (VM desligada não informa) | VMs removidas saem na execução seguinte |
| `logs\` | `hypervisor-inventory-AAAAMMDD.log`, uma linha por execução | 14 dias |

Desativar o módulo remove a tarefa, o script, a saída, o cache e os logs do
inventário. Desinstalar o Alloy remove a tarefa; a limpeza completa remove
também os arquivos.
