# Grafana Alloy

Instalação e gestão do agente [Grafana Alloy](https://grafana.com/docs/alloy/latest/),
que envia métricas e logs de cada servidor ao monitoramento central.

Um único comando abre a ferramenta: **`alloyctl`**, instalado no servidor na
primeira execução do comando abaixo. Na primeira vez, ele segue direto o fluxo
de credencial e depois a instalação. Nas seguintes, abre um menu:

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
   [9] Configurar heartbeat      [8] Limpeza completa
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

**Windows Server ou estação (PowerShell como Administrador)**

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

Depois da primeira execução, basta `alloyctl` (ou `alloyctl <comando>`). O
comando acima continua valendo: com o `alloyctl` instalado, ele o atualiza e
abre o menu.

## alloyctl

| | Linux | Windows |
|-|-------|---------|
| Ferramenta | `/opt/alloyctl/` | `C:\Program Files\AssessoriaTech\alloyctl\` |
| Comando | `/usr/local/bin/alloyctl` (link) | `alloyctl.cmd`, pasta no PATH da máquina (vale em terminais novos) |
| Sem administrador | pede `sudo` | pede elevação (UAC) e continua em uma nova janela |

- **Atualização a cada execução**: uma consulta à API do GitHub descobre o
  commit atual da branch acompanhada (padrão `main`). Se mudou, baixa o núcleo
  (ponto de entrada + `lib/`) daquele commit, troca a pasta inteira e reinicia
  com a versão nova. Sem acesso ao GitHub, avisa e segue com a versão
  instalada. `--no-update` (`-NoUpdate`) pula a verificação; `alloyctl update`
  só atualiza e mostra a versão.
- **Arquivos sob demanda**: instalação, credencial, módulos e heartbeat são
  baixados na primeira vez que a operação precisa deles, **do mesmo commit** do
  núcleo, e ficam na pasta até a próxima versão.
- **Branch acompanhada**: `--ref <branch|tag|commit>` (`-Ref` no Windows) troca
  e fica gravada (arquivo `ref` na pasta). O comando do README volta para
  `main`, salvo com `--ref`.
- **Configuração do Alloy não muda sozinha**: a atualização mexe só no
  `alloyctl`. Aplicar uma configuração nova continua sendo **[1] Reaplicar
  configuração**.
- **Remoção**: a desinstalação mantém o `alloyctl`; a limpeza completa remove
  a pasta, o comando e (Windows) a entrada do PATH.

Executado a partir de um clone do repositório, o ponto de entrada usa os
arquivos locais e não instala nem atualiza o `alloyctl`.

## Comandos diretos (automação)

Os mesmos comandos valem para `alloyctl` e para o ponto de entrada baixado
(`alloy.sh` / `alloy.ps1`).

| Linux | Windows | Ação |
|-------|---------|------|
| `install [--modules docker\|none] [--upgrade]` | `install [-Perfil servidor\|estacao] [-Modules hyperv,sqlanywhere\|none] [-Upgrade]` | credencial (se ausente) + instalação |
| `credentials` | `credentials` | só o setup da credencial |
| `check` | `check` | testa a credencial gravada, sem alterar nada |
| `rotate` | `rotate` | troca a credencial e reinicia o Alloy |
| `modules docker\|none` | `modules hyperv,sqlanywhere\|none` | define os módulos opcionais (os não listados são desativados) |
| `upgrade` | `upgrade` | atualiza o Alloy |
| `status` | `status` | diagnóstico |
| `uninstall [--yes]` | `uninstall [-Yes]` | remove o Alloy, mantendo credencial, configuração e o `alloyctl` |
| `purge [--yes]` | `purge [-Yes]` | limpeza completa (inclui o `alloyctl`) |
| `heartbeat [--url URL]` | `heartbeat [-Url URL]` | configura o heartbeat (Uptime Kuma + Loki) |
| `heartbeat-test` | `heartbeat-test` | executa o heartbeat agora e mostra o resultado |
| `heartbeat-remove [--yes]` | `heartbeat-remove [-Yes]` | remove o heartbeat |
| `update` | `update` | atualiza só o `alloyctl` e mostra a versão |

`--ref <branch|tag|commit>` (`-Ref`) troca a branch acompanhada;
`--no-update` (`-NoUpdate`) não atualiza antes de executar.

## Arquivos

| Arquivo | Função |
|---------|--------|
| `alloy.sh` / `alloy.ps1` | ponto de entrada: instala/atualiza o `alloyctl`, menu e comandos |
| `lib/common.*` | constantes, saída e download |
| `lib/state.*` | estado do servidor, cabeçalho e diagnóstico |
| `lib/ui.*` | interface do terminal: telas, marcadores, menu e teclas |
| `setup-credentials.*` | valida a conta de serviço (OAuth2 + Loki) e grava a credencial |
| `install.*` | instala o Alloy e aplica a configuração, com validação e rollback |
| `uninstall.*` | desinstalação e limpeza completa |
| `config.alloy` | configuração base do sistema |
| `desktop.alloy` | configuração base do perfil estação (Windows), no lugar do `config.alloy` |
| `docker.alloy` / `hyperv.alloy` / `sqlanywhere.alloy` | módulos opcionais |
| `hypervisor-inventory.ps1` | inventário de VMs do módulo Hyper-V (tarefa agendada) |
| `sqlanywhere-collector.ps1` | coletor do módulo SQL Anywhere (tarefa agendada) |
| `heartbeat-setup.*` | configura, testa e remove o heartbeat |
| `heartbeat.*` | heartbeat executado a cada minuto (tarefa agendada / timer systemd) |

## Perfil estação (Windows)

Para máquinas Windows de uso pessoal, descartáveis, que podem sumir a qualquer
momento. Elas publicam em jobs próprios e por isso ficam fora dos alertas e dos
dashboards de servidores, que sempre fixam o job:

| | Servidor | Estação |
|---|---|---|
| Configuração | `config\config.alloy` | `config\desktop.alloy` |
| Métricas | `integrations/windows` | `integrations/windows-desktop` |
| Logs | `windows-eventlog` | `windows-desktop-eventlog` (só crítico, erro e aviso) |
| Coletores | inclui `service` | sem `service`; scrape de 60 s |
| Credencial | `alloy-<hostname>` | compartilhada: `alloy-estacoes` |
| Módulos opcionais e heartbeat | disponíveis | não se aplicam |
| Alertas | sim | nenhum |

Na primeira instalação o perfil é detectado: estação no Windows de cliente
(10/11), servidor no Windows Server. No modo interativo dá para trocar antes de
continuar; na automação, use `alloyctl install -Perfil estacao`. Depois,
reaplicar e atualizar mantêm o perfil instalado. Trocar de perfil é
`alloyctl install -Perfil <outro>`: o arquivo base do outro perfil é removido
(com o mesmo rollback) e, ao virar estação, os módulos opcionais ativos são
desativados. No menu, **[2] Módulos** e **[9] Heartbeat** aparecem como
"(so servidor)" e só servem para remover o que já existia.

A conta `alloy-estacoes` é uma só para todas as estações: uma máquina que some
não deixa credencial órfã, e revogar a conta corta todas de uma vez.

Ao converter para estação uma máquina que já mandava métricas como servidor, a
série antiga some e o alerta de servidor sem métricas (WIN-102) dispara por até
7 dias. Marque o host como `ignorar` em `servidores:` no `catalogo.yml` do
`grafana-dashboards` durante a transição.

## Módulos opcionais (Windows)

Na instalação (`-Modules auto`, padrão), os módulos já ativos são mantidos e os
detectados são oferecidos (só em terminal interativo). `-Modules` com uma lista
(`hyperv`, `sqlanywhere` ou `hyperv,sqlanywhere`) define o conjunto completo:
os não listados são desativados; `none` desativa todos. No menu, **[2] Módulos
opcionais** liga e desliga cada um sem afetar o outro.

Cada módulo com coletor próprio grava em um subdiretório de `textfile\` e o
Alloy lê só esse subdiretório, em job próprio.

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
`\GrafanaLabs\Alloy Hypervisor Inventory`, e grava `textfile\hypervisor\hypervisor.prom`,
lido pelo coletor `textfile` do Alloy (requer Alloy v1.11+). As métricas usam
nomes neutros (`hypervisor_*`, com `platform="hyperv"`) para que outras
plataformas possam publicar o mesmo formato.

Diretórios em `C:\ProgramData\GrafanaLabs\Alloy` (acesso só de SYSTEM e
Administradores):

| Diretório | Conteúdo | Retenção |
|-----------|----------|----------|
| `scripts\` | script do inventário | substituído a cada reaplicação |
| `textfile\hypervisor\` | `hypervisor.prom` | sobrescrito a cada execução |
| `data\hypervisor\` | `guests.json`: último hostname/SO conhecido de cada VM (VM desligada não informa) | VMs removidas saem na execução seguinte |
| `logs\` | `hypervisor-inventory-AAAAMMDD.log`, uma linha por execução | 14 dias |

Desativar o módulo remove a tarefa, o script, a saída, o cache e os logs do
inventário. Desinstalar o Alloy remove a tarefa; a limpeza completa remove
também os arquivos. A reaplicação apaga o `textfile\hypervisor.prom` das
versões anteriores, gravado na raiz do `textfile\`.

## Módulo SQL Anywhere

Para servidores com SAP SQL Anywhere 17. Detectado na instalação por serviço
ou processo `dbsrv17.exe`/`dbeng17.exe`. Requer o driver ODBC
`SQL Anywhere 17` de **64 bits** e um usuário SQL somente leitura: o coletor só
executa `PROPERTY()` e `DB_PROPERTY()`. Na ativação, o instalador pede
servidor (ENG), banco (DBN), usuário e senha, e **testa a conexão antes de
gravar**. Para trocar esses dados: **[2] Módulos opcionais → [3] Reconfigurar
SQL Anywhere** (ou `install.ps1 -ReconfigureSqlAnywhere`).

| Parte | Onde | O que faz |
|-------|------|-----------|
| Coletor | `scripts\sqlanywhere-collector.ps1`, job `integrations/sqlanywhere` | conexões, requisições e cache do servidor; leituras, gravações, commits, rollbacks e checkpoints do banco |

O coletor roda a cada 30 s, como SYSTEM, pela tarefa agendada
`\GrafanaLabs\Alloy SQL Anywhere` (dois gatilhos de 1 min defasados em 30 s:
o Agendador não repete em menos de 1 min), sem execuções simultâneas e com
limite de 25 s. Conecta via ODBC local (`LINKS=SharedMemory,TCPIP(HOST=127.0.0.1)`)
e grava `textfile\sqlanywhere\sqlanywhere.prom`. Suporta um par ENG/DBN por
servidor.

Métricas: `sqlanywhere_server_*` (`PROPERTY`) e `sqlanywhere_database_*`
(`DB_PROPERTY`), com labels `server` e `database`; `sqlanywhere_info` traz a
versão. Tamanhos de cache são convertidos de KB para bytes. A saúde da coleta
fica em `sqlanywhere_up`, `sqlanywhere_collection_success`,
`sqlanywhere_collection_missing_properties`, `_duration_seconds` e
`_timestamp_seconds`. Propriedade sem valor numérico não gera série (nunca
vira zero) e a lista vai para o log quando muda. Em falha, só as métricas de
saúde são publicadas.

| Diretório | Conteúdo | Retenção |
|-----------|----------|----------|
| `scripts\` | `sqlanywhere-collector.ps1` | substituído a cada reaplicação |
| `textfile\sqlanywhere\` | `sqlanywhere.prom` | sobrescrito a cada execução |
| `data\sqlanywhere\` | `config.json` (servidor, banco, usuário e `links`) e `password.dpapi` (senha cifrada com DPAPI da máquina) | mantidos ao desativar o módulo ou desinstalar; removidos na limpeza completa |
| `logs\` | `sqlanywhere-collector-AAAAMMDD.log`: falhas e mudanças nas propriedades ausentes | 14 dias |

Para usar outro protocolo ou porta, edite `links` no `config.json` (sintaxe do
parâmetro `LINKS` do SQL Anywhere); o coletor relê o arquivo a cada execução. Desativar o módulo remove a
tarefa, o script, a saída e os logs; a configuração fica para reativar sem
digitar de novo.

## Heartbeat (Uptime Kuma + Loki)

Opcional, para os hosts: confirma de fora que o servidor está vivo e informa o
estado local do Alloy mesmo quando a telemetria dele para de chegar. Não é
oferecido na instalação; fica em **[9] Configurar heartbeat** (ou no comando
`heartbeat`). A cada minuto, sem depender do processo do Alloy:

1. lê o estado local: serviço, `/-/ready`, `/-/healthy` e o `/metrics` do
   Alloy (atraso do envio de métricas e contadores do envio de logs);
2. envia uma linha logfmt ao **Loki** (job `alloy-heartbeat`), com a
   credencial do Alloy. Sem credencial, só o Kuma recebe a batida;
3. faz o push no **Uptime Kuma** (sempre `status=up`) com um resumo curto no
   `msg`, só para quem olha a tela: o Kuma não exporta o `msg` para o
   Prometheus.

| Telemetria do Alloy | Heartbeat no Loki | Kuma | Leitura |
|---|---|---|---|
| ok | `alloy=ok` | UP | tudo certo |
| sem dados | `alloy=parado`, `degradado`... | UP | problema no Alloy; o motivo está no Loki |
| sem dados | sem dados | UP (`msg` com `loki=401`...) | credencial ou caminho até o `mon` |
| sem dados | sem dados | DOWN | host fora ou sem rede |

**Configurar.** No Uptime Kuma, crie um monitor **Push** chamado
`heartbeat-<host>`, com intervalo de 120 s, 1 tentativa e intervalo de nova
tentativa de 60 s (DOWN em ~3 min). Em [9], cole a URL de push completa, como
o Kuma mostra (`https://.../api/push/<token>?status=up&msg=OK&ping=`). O
endereço não fica no repositório. A configuração faz uma batida de teste e só
grava se o Kuma confirmar (404 = token errado ou monitor pausado). Depois
registra o agendamento e confere a primeira execução. Com o heartbeat
configurado, [9] abre **Testar agora**, **Reconfigurar** e **Remover**.

**Consultar no Grafana** (contrato `contracts/loki/heartbeat.yml` no
repositório `grafana-dashboards`):

```logql
{job="alloy-heartbeat", host="srv-hv01"} | logfmt
{job="alloy-heartbeat"} | logfmt | alloy != "ok"
max by (host) (max_over_time({job="alloy-heartbeat"} | logfmt | unwrap metrics_lag_s [5m]))
```

Campos: `alloy` (`ok`, `degradado`, `nao_pronto`, `parado`, `ausente`),
`service`, `ready`, `healthy`, `unhealthy`, `metrics_lag_s`, `samples_failed`,
`logs_sent`, `logs_dropped` e `version`. `degradado` = componente com problema
ou mais de 300 s sem enviar métricas.

| | Windows | Linux |
|---|---|---|
| Agendamento | tarefa `\GrafanaLabs\Alloy Heartbeat`, como SYSTEM, a cada minuto e no boot | `alloy-heartbeat.timer` → `alloy-heartbeat.service`, usuário dinâmico (sem root) no grupo `alloy`, systemd 247+ |
| Credencial do Alloy | lida direto (SYSTEM) | lida direto pelo grupo `alloy` (`root:alloy 0640`); no Linux, o heartbeat exige o Alloy instalado |
| URL de push | `heartbeat\kuma-url` (só SYSTEM e Administradores) | `/etc/alloy/heartbeat/kuma-url` (root, 0600), entregue por `LoadCredential=` |
| Script | `heartbeat\heartbeat.ps1` | `/usr/local/libexec/alloy-heartbeat/heartbeat.py` |
| Última execução | `heartbeat\last.json` | `/var/lib/alloy-heartbeat/last` |
| Logs | `heartbeat\logs\`, 14 dias | `journalctl -u alloy-heartbeat` |

A URL e o token OAuth2 nunca vão para log nem para a linha de comando. O
token fica em cache (mesma proteção da credencial) até perto de expirar.
**Desinstalar** para o agendamento e mantém a URL, para reativar em [9] sem
colar de novo; **Limpeza completa** remove tudo. Nos dois casos, pause ou
exclua o monitor no Kuma. Rotacionar a credencial não exige mexer no
heartbeat: ele lê o arquivo a cada execução.

Todas as chamadas a `auth` e `mon` (atrás da Cloudflare) usam User-Agent
próprio (`AssessoriaTech-Alloy-*`), não o padrão do PowerShell, Python ou curl.
Se a Cloudflare ainda desafiar clientes que não são navegador, crie uma regra
de *skip* no WAF para `/api/push/*` e `/loki/api/v1/push`.
