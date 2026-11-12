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
| Comando | `/usr/local/bin/alloyctl` (link) | `alloyctl.cmd`, pasta no PATH da máquina (vale em terminais novos); se o registro da máquina recusar (política, antivírus), no PATH do usuário; se também recusar, avisa e indica o caminho completo |
| Sem administrador | pede `sudo` | pede elevação (UAC) e continua em uma nova janela |

- **Atualização a cada execução**: uma consulta à API do GitHub descobre o
  commit atual da branch acompanhada (padrão `main`). Se mudou, baixa o núcleo
  (ponto de entrada + `lib/`) daquele commit, troca a pasta inteira e reinicia
  com a versão nova. Sem acesso ao GitHub, avisa e segue com a versão
  instalada. `--no-update` (`-NoUpdate`) pula a verificação; `alloyctl update`
  só atualiza e mostra a versão.
- **Falhas visíveis**: o motivo (ex.: `HTTP 403: limite da API`, nome não
  resolvido, sem permissão na pasta) aparece na tela, na linha `alloyctl` do
  cabeçalho do menu e no log: `/var/log/alloyctl.log` (Linux) ou
  `C:\ProgramData\GrafanaLabs\Alloy\logs\alloyctl-AAAAMMDD.log` (Windows, 14
  dias). Se a instalação pelo comando do README falhar num terminal
  interativo, a ferramenta para e pergunta se deve continuar sem o
  `alloyctl` (arquivos temporários); em automação, segue com aviso. Falha de
  atualização nunca bloqueia: segue com a versão instalada.
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

## Antivírus (Bitdefender GravityZone)

Antivírus com análise de comportamento podem interromper a instalação ou o
agente. Caso real: numa estação Windows, o **Advanced Threat Control** do
Bitdefender encerrou o instalador oficial do Alloy
(`ATC.SuspiciousBehavior`) enquanto ele rodava a partir de uma pasta
aleatória em `%TEMP%`. A desinfecção desfez parte da instalação (a chave do
registro sumiu) e o serviço ficou rodando com a configuração de exemplo do
pacote, sem enviar nada.

### O que o instalador faz para reduzir o risco (Windows)

- Baixa o instalador oficial para uma **pasta fixa**,
  `C:\ProgramData\AssessoriaTech\alloy-installer\`, restrita a SYSTEM e
  Administradores. Não usa mais `%TEMP%\<aleatório>`, que é o padrão "script
  baixou e executou um binário desconhecido" que o ATC vigia. A pasta fixa
  também permite exclusão por caminho. O conteúdo é apagado depois da
  instalação; a pasta fica.
- Antes de executar, confere o **SHA256** contra o `SHA256SUMS` da mesma
  release e a **assinatura Authenticode** (assinante `CN=Grafana Labs,
  O=Grafana Labs`). Se não bater, não executa.
- Se o instalador for encerrado, sumir depois da extração ou deixar a
  instalação incompleta, a mensagem aponta o antivírus, a quarentena e as
  pastas a excluir.
- Instalação incompleta (executável, serviço ou chave do registro faltando)
  é reinstalada pelo **[1] Reaplicar**. O menu mostra
  `[ !! ] sem configuracao (incompleto)` quando o serviço não usa a nossa
  configuração, em vez de "ativo e pronto".
- Na primeira instalação, uma falha deixa o serviço **parado** (início
  manual), em vez de rodando com o exemplo do pacote.

### Exclusões recomendadas

Aplicar na **política do GravityZone** (vale para todas as máquinas da
política), nos módulos Antimalware (no acesso) e Advanced Threat Control.

**Windows (servidores e estações)**

| Tipo | Caminho | Por quê |
|------|---------|---------|
| Pasta | `C:\Program Files\GrafanaLabs\Alloy\` | binário do agente e desinstalador |
| Processo | `C:\Program Files\GrafanaLabs\Alloy\alloy-windows-amd64.exe` | o agente lê eventos e contadores e envia pela rede o tempo todo |
| Pasta | `C:\ProgramData\GrafanaLabs\Alloy\` | configuração, credencial, WAL (`data\`, escrita contínua), bookmarks, scripts dos módulos, textfile, logs e heartbeat |
| Pasta | `C:\ProgramData\AssessoriaTech\alloy-installer\` | instalador oficial durante a instalação ou atualização |
| Processo | `C:\ProgramData\AssessoriaTech\alloy-installer\package\alloy-installer-windows-amd64.exe` | o processo que o ATC encerrou |
| Pasta | `C:\Program Files\AssessoriaTech\alloyctl\` | comando `alloyctl` (`alloyctl.cmd` + scripts PowerShell) |

**Linux (servidores)**

| Tipo | Caminho | Por quê |
|------|---------|---------|
| Processo | `/usr/bin/alloy` | o agente (pacote `alloy` do APT da Grafana) |
| Pasta | `/var/lib/alloy/` | WAL e posições, escrita contínua (desempenho) |
| Pasta | `/etc/alloy/` | configuração, credencial e backups |
| Pasta | `/opt/alloyctl/` | comando `alloyctl` (link em `/usr/local/bin/alloyctl`) |
| Pasta | `/usr/local/libexec/alloy-heartbeat/` | `heartbeat.py`, executado pelo timer `alloy-heartbeat` |
| Pasta | `/var/lib/alloy-heartbeat/` | estado do heartbeat |

**Não excluir** `powershell.exe`, `bash`, `python3` nem pastas temporárias
inteiras: isso abriria uma brecha para qualquer script. As tarefas agendadas
dos módulos (`heartbeat.ps1`, `hypervisor-inventory.ps1`,
`sqlanywhere-collector.ps1`, `dbct-collector.ps1`) rodam com `powershell.exe -File <script>` a
partir das pastas acima. Se o ATC as bloquear, prefira uma exclusão por
**linha de comando** que contenha o caminho do script, se a versão do
GravityZone oferecer.

**Exclusão por certificado**: o instalador e o binário são assinados via
Microsoft Trusted Signing. O certificado da Grafana Labs é trocado a cada
poucos dias, então exclusão pela impressão digital do certificado deixa de
valer logo. Use o nome do assinante, se o console permitir, ou os caminhos
acima.

### Se o antivírus já agiu

1. Restaure da quarentena os arquivos do Alloy e crie as exclusões.
2. Windows: execute `alloyctl upgrade` (ou **[3] Atualizar Alloy**). O
   instalador oficial roda de novo, recria o que faltar e aplica a
   configuração. A credencial é mantida.
3. Confira no diagnóstico (**[6]**): `Config` sem erro e serviço "ativo e
   pronto".

## Comandos diretos (automação)

Os mesmos comandos valem para `alloyctl` e para o ponto de entrada baixado
(`alloy.sh` / `alloy.ps1`).

| Linux | Windows | Ação |
|-------|---------|------|
| `install [--modules docker\|none] [--upgrade]` | `install [-Perfil servidor\|estacao] [-Modules hyperv,sqlanywhere,mysql,dbct\|none] [-Upgrade]` | credencial (se ausente) + instalação |
| `credentials` | `credentials` | só o setup da credencial |
| `check` | `check` | testa a credencial gravada, sem alterar nada |
| `rotate` | `rotate` | troca a credencial e reinicia o Alloy |
| `modules docker\|none` | `modules hyperv,sqlanywhere,mysql,dbct\|none` | define os módulos opcionais (os não listados são desativados) |
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
| `docker.alloy` / `hyperv.alloy` / `sqlanywhere.alloy` / `mysql.alloy` / `dbct.alloy` | módulos opcionais |
| `hypervisor-inventory.ps1` | inventário de VMs do módulo Hyper-V (tarefa agendada) |
| `sqlanywhere-collector.ps1` | coletor do módulo SQL Anywhere (tarefa agendada) |
| `dbct-collector.ps1` | coletor do módulo DB Connection Tester (tarefa agendada) |
| `heartbeat-setup.*` | configura, testa e remove o heartbeat |
| `heartbeat.*` | heartbeat executado a cada minuto (tarefa agendada / timer systemd) |
| `rmm/tactical-estacao.ps1` | instalação de estação pelo Tactical RMM, sem perguntas |

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
| Módulos opcionais e heartbeat | disponíveis | só os módulos MySQL e DBCT |
| Alertas | sim | nenhum |

Na primeira instalação o perfil é detectado: estação no Windows de cliente
(10/11), servidor no Windows Server. No modo interativo dá para trocar antes de
continuar; na automação, use `alloyctl install -Perfil estacao`. Depois,
reaplicar e atualizar mantêm o perfil instalado. Trocar de perfil é
`alloyctl install -Perfil <outro>`: o arquivo base do outro perfil é removido
(com o mesmo rollback) e, ao virar estação, os módulos Hyper-V e SQL Anywhere
ativos são desativados (MySQL e DBCT são mantidos). No menu, Hyper-V, SQL Anywhere e
**[9] Heartbeat** aparecem como "(so servidor)" e só servem para remover o que
já existia.

A conta `alloy-estacoes` é uma só para todas as estações: uma máquina que some
não deixa credencial órfã, e revogar a conta corta todas de uma vez.

Ao converter para estação uma máquina que já mandava métricas como servidor, a
série antiga some e o alerta de servidor sem métricas (WIN-102) dispara por até
7 dias. Marque o host como `ignorar` em `servidores:` no `catalogo.yml` do
`grafana-dashboards` durante a transição.

### Estações pelo Tactical RMM

Para instalar sem terminal interativo (o Tactical roda o script como SYSTEM,
sem área de trabalho), use `windows/rmm/tactical-estacao.ps1`. Ele não faz
nenhuma pergunta: baixa o `alloy.ps1`, instala o `alloyctl` e executa
`install -Perfil estacao`.

1. **Senha no Key Store**: *Settings > Global Settings > Key Store*, chave
   `ALLOY_ESTACOES_SENHA` com a senha de aplicativo da `alloy-estacoes`.
2. **Script**: *Settings > Script Manager > New Script*, com o conteúdo de
   `windows/rmm/tactical-estacao.ps1`, Shell `PowerShell`, timeout `900` e
   *Run As User* desmarcado.
3. **Environment vars** do script:
   `ALLOY_PASSWORD={{global.ALLOY_ESTACOES_SENHA}}`. **Não** passe a senha em
   *Script Arguments*: argumentos ficam na linha de comando do processo e no
   histórico.
4. Execute na estação (ou em lote por *Bulk Script*). Saída `0` = instalado;
   `1` = falha, com o motivo na saída.

O script é idempotente: com a credencial já gravada, só reaplica a
configuração (útil depois de mudar o `desktop.alloy`). A credencial é testada
(OAuth2 + Loki) antes de ser gravada; senha errada não altera nada.

Fora do Tactical vale o mesmo mecanismo: se `ALLOY_PASSWORD` estiver definida,
o `setup-credentials.ps1` usa a conta do perfil e não pergunta nada (a
variável é apagada do processo logo após a leitura). Sem ela e sem terminal
interativo, para na hora com o motivo, em vez de esperar a janela de senha que
ninguém vê.

## Módulos opcionais (Windows)

Na instalação (`-Modules auto`, padrão), os módulos já ativos são mantidos e os
detectados são oferecidos (só em terminal interativo). `-Modules` com uma lista
(`hyperv`, `sqlanywhere`, `mysql`, `dbct` ou combinações, como `hyperv,sqlanywhere`)
define o conjunto completo: os não listados são desativados; `none` desativa
todos. No menu, **[2] Módulos opcionais** liga e desliga cada um sem afetar os
outros. O DBCT nunca é oferecido automaticamente: ative-o pelo menu ou com
`-Modules dbct`.

Cada módulo com coletor próprio grava em um subdiretório de `textfile\` e o
Alloy lê só esse subdiretório, em job próprio. O MySQL não tem coletor: usa o
exportador embutido do Alloy.

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
| Coletor | `scripts\sqlanywhere-collector.ps1`, job `integrations/sqlanywhere` | servidor: conexões, workers e fila, commits e rollbacks, thread deadlocks, CPU, início, cache (alocado, em uso, livre, sujo, panics) e memória de consulta; banco: leituras de cache e disco, gravações, flushes, checkpoints, locks, tamanho do arquivo e urgência de checkpoint/recuperação |

O coletor roda a cada 30 s, como SYSTEM, pela tarefa agendada
`\GrafanaLabs\Alloy SQL Anywhere` (dois gatilhos de 1 min defasados em 30 s:
o Agendador não repete em menos de 1 min), sem execuções simultâneas e com
limite de 25 s. Conecta via ODBC local (`LINKS=SharedMemory,TCPIP(HOST=127.0.0.1)`)
e grava `textfile\sqlanywhere\sqlanywhere.prom`. Suporta um par ENG/DBN por
servidor.

Métricas: `sqlanywhere_server_*` (`PROPERTY`) e `sqlanywhere_database_*`
(`DB_PROPERTY`), com labels `server` e `database`; `sqlanywhere_info` traz a
versão. Tamanhos de cache são convertidos de KB para bytes e contagens de páginas
(cache em uso/livre, arquivo do banco) multiplicadas pelo `PageSize` do escopo.
A propriedade `Commit` do banco conta flushes do cache de disco
(`sqlanywhere_database_disk_flushes_total`); os COMMITs vêm do servidor
(`sqlanywhere_server_commits_total`). `StartTime` vira `_start_time_seconds` (Unix). A saúde da coleta
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

## Módulo MySQL

Para servidores Windows com MySQL (testado com o 5.5) ou MariaDB, uma
instância por máquina. Detectado na instalação por serviço ou processo
`mysqld.exe`/`mariadbd.exe` e oferecido no perfil servidor; no perfil estação
vale também, mas só ativado pelo menu ou com `-Modules mysql`. Para trocar
usuário, senha ou porta, ou reler os caminhos dos logs depois de mudar a
configuração do MySQL: **[2] Módulos opcionais → [7] Reconfigurar MySQL** (ou
`install.ps1 -ReconfigureMysql`).

| Parte | Onde | O que faz |
|-------|------|-----------|
| Métricas | `config\mysql.alloy` (exportador embutido do Alloy), job `integrations/mysql` | `SHOW GLOBAL STATUS`, `SHOW GLOBAL VARIABLES` e threads por estado (`information_schema.PROCESSLIST`), a cada 30 s |
| Logs | `mysql.alloy`, job `mysql` no Loki | error log (`log_type="error"`, com `level` = `error`, `warning` ou `note`) e slow query log (`log_type="slow"`, uma entrada por consulta) |

Sem tarefa agendada nem script: o Alloy conecta direto no MySQL
(`127.0.0.1`, TCP). Só os coletores `global_status`, `global_variables` e
`info_schema.processlist` ficam ativos: o padrão do exportador inclui o
`slave_status`, que usa `SHOW REPLICA STATUS` e falha no 5.5.

### Usuário de monitoramento

Nome padrão **`alloy`**, o mesmo em todos os servidores. Precisa só do
privilégio `PROCESS` (ver as conexões de outros usuários); não lê nenhuma
tabela. Crie com um administrador do MySQL, trocando a senha:

```sql
CREATE USER 'alloy'@'localhost' IDENTIFIED BY 'SENHA';
CREATE USER 'alloy'@'127.0.0.1' IDENTIFIED BY 'SENHA';
GRANT PROCESS ON *.* TO 'alloy'@'localhost' WITH MAX_USER_CONNECTIONS 3;
GRANT PROCESS ON *.* TO 'alloy'@'127.0.0.1' WITH MAX_USER_CONNECTIONS 3;
```

As duas contas cobrem o MySQL com e sem resolução de nomes
(`skip-name-resolve`): a conexão chega como `127.0.0.1` ou como `localhost`.
`MAX_USER_CONNECTIONS 3` impede que o monitoramento ocupe conexões do sistema.
Para conferir: `SHOW GRANTS FOR 'alloy'@'127.0.0.1';`. Para trocar a senha
(depois, **Reconfigurar MySQL**; sintaxe do 5.5 e 5.6, no 5.7+ use
`ALTER USER ... IDENTIFIED BY`):

```sql
SET PASSWORD FOR 'alloy'@'localhost' = PASSWORD('NOVA');
SET PASSWORD FOR 'alloy'@'127.0.0.1' = PASSWORD('NOVA');
```

### Ativação

Na ativação, o instalador pergunta usuário (padrão `alloy`), porta (padrão
3306), o `mysql.exe` (sugere o da pasta `bin` do serviço) e a senha, e **testa
a conexão antes de gravar** com o `mysql.exe`, pela mesma rota do Alloy
(TCP em `127.0.0.1`, sem ler o `my.ini`; senha pelo ambiente, nunca na linha
de comando). Na mesma conexão lê do próprio servidor `@@log_error`,
`@@slow_query_log`, `@@slow_query_log_file` e `@@log_output`: os logs lidos
são os que o MySQL realmente usa. Ao final, confere pelo Alloy que o
exportador conectou (`mysql_up 1`).

### Logs

- **Error log**: lido se o arquivo existir. Linhas sem data (detalhes de
  deadlock, falhas do InnoDB) entram na entrada anterior. `level`: `error`
  (`[ERROR]`, erros e asserções do InnoDB, `got exception`), `warning`
  (`[Warning]`, deadlocks) ou `note` (o resto).
- **Slow query log**: lido só com `slow_query_log=ON` e `log_output` com
  `FILE`. Uma entrada por consulta (de `# User@Host:` até o SQL), com
  `Query_time`, `Lock_time`, `Rows_sent` e `Rows_examined`. As linhas
  `# Time:` e o cabeçalho de cada início do servidor são descartados.
- A primeira leitura começa do fim de cada arquivo (o histórico não é
  reenviado); depois a posição fica em `data\`. O horário das entradas é o da
  leitura (segundos depois da gravação).

O módulo **não altera** a configuração do MySQL. Para ter consultas lentas e
deadlocks no Loki, ligue no `my.ini` (seção `[mysqld]`) e reinicie o serviço
na janela do sistema; ou, sem reiniciar, com `SET GLOBAL` (vale até o próximo
reinício):

```ini
slow_query_log = 1
long_query_time = 2
innodb_print_all_deadlocks = 1
```

```sql
SET GLOBAL slow_query_log = 1;
SET GLOBAL long_query_time = 2;
SET GLOBAL innodb_print_all_deadlocks = 1;
```

O `long_query_time` define o que é "lento"; 2 s é um ponto de partida.
`log_slow_queries` é o nome antigo do `slow_query_log` (5.0/5.1). Depois de
ligar, use **Reconfigurar MySQL** para incluir o arquivo.

### Arquivos

| Diretório | Arquivos | Ciclo de vida |
|---|---|---|
| `config\` | `mysql.alloy` | substituído a cada reaplicação; removido ao desativar |
| `data\mysql\` | `dsn` (`usuario:senha@tcp(host:porta)/`, lido pelo Alloy como segredo) e `config.json` (host, porta, usuário, `mysql.exe` e logs lidos) | mantidos ao desativar o módulo ou desinstalar; removidos na limpeza completa |

A senha não usa DPAPI, como no SQL Anywhere: quem a lê é o próprio Alloy
(`local.file` com `is_secret`), que não decifra DPAPI. O arquivo fica só com
a ACL de `data\` (SYSTEM e Administradores) e não aparece na configuração, na
interface do Alloy nem nos logs. O Alloy relê `dsn` e `config.json` sozinho:
reconfigurar não reinicia o serviço. Para outra porta ou host, prefira
**Reconfigurar MySQL** (testa antes); editar os dois arquivos à mão também
funciona.

No diagnóstico (**[6]**), a seção MYSQL mostra o alvo, se o exportador está
conectado (com a versão), coletores com falha e os logs lidos.

## Módulo DB Connection Tester

Publica no Prometheus as falhas e lentidões de uma execução do
[DB Connection Tester](https://github.com/DEV-ASSESSORIA-TECH/DBConnectionTester)
(DBCT), para consultar pelo horário. Vale para servidores **e estações**.

O módulo **só lê** o banco do DBCT, pela CLI pública (`dbct run status` e
`dbct history cycles`). A execução é do próprio DBCT, que funciona sem o Alloy:
para mantê-la rodando e voltando com o Windows, configure-a no DBCT, por exemplo
em um terminal de administrador:

```powershell
dbct run --type tcp --host srv-db --port 1433 --interval 5 --data-dir "C:\ProgramData\DBConnectionTester" --autostart
```

(`dbct run status`, `dbct run stop`, `dbct autostart show|disable`; veja o guia da
CLI do DBCT.) Requer um DBCT com `run status` e `history cycles`, posterior à 3.0.0.

Ative em **[2] Módulos opcionais > [4] Ativar DBCT** (ou `-Modules dbct`). A
configuração pergunta, sugerindo o que encontrar na máquina, o `dbct.exe` (MSI por
máquina ou por usuário, PATH ou portátil) e a pasta do banco do DBCT, a que contém
o `data.db`. A primeira sugestão é a pasta da execução automática do DBCT (por
exemplo `C:\ProgramData\DBConnectionTester\Monitor\mysql-erp`); depois vêm as
demais pastas de `Monitor`, a compartilhada, as locais e a portátil. Avisa se o banco não tiver execução ativa nem automática.
**[5] Reconfigurar DBCT** (ou `install.ps1 -ReconfigureDbct`) pergunta de novo.

| Parte | Onde | O que faz |
|---|---|---|
| Coletor | tarefa `\GrafanaLabs\Alloy DBCT Collector` (a cada 30 s), `scripts\dbct-collector.ps1`, job `integrations/dbconnectiontester` | encontra a execução ativa, processa só os ciclos novos e grava `textfile\dbct\dbct.prom` |

Métricas (sem labels de host além dos que o Alloy adiciona; uma execução por banco):

| Métrica | Uso |
|---|---|
| `dbct_stage_failures_total{stage,code}` | falhas por etapa (`dns`, `ping`, `tcp`, `database_connect`, `database_query`) e código de diagnóstico do DBCT |
| `dbct_stage_duration_seconds` (histograma) e `dbct_stage_duration_max_seconds{stage}` | lentidão: quantis por janela e pior duração entre duas coletas |
| `dbct_stage_checks_total{stage}`, `dbct_cycles_total` | volume de testes |
| `dbct_stage_last_success{stage}`, `dbct_stage_last_duration_seconds{stage}` | estado do último ciclo |
| `dbct_run_active`, `dbct_run_info{run_id,profile,target,database_type}` | execução monitorada |
| `dbct_autostart_configured`, `dbct_autostart_running` | execução automática do DBCT no banco |
| `dbct_collection_success`, `_duration_seconds`, `_timestamp_seconds` | saúde da coleta |

Consultas para investigar um horário (Explore, intervalo em volta do horário
informado):

```promql
sum by (stage, code) (increase(dbct_stage_failures_total{host="<host>"}[5m]))
histogram_quantile(0.95, sum by (stage, le) (rate(dbct_stage_duration_seconds_bucket{host="<host>"}[5m])))
max by (stage) (dbct_stage_duration_max_seconds{host="<host>"})
```

Os contadores pertencem à execução atual e voltam a zero numa execução nova
(`increase` e `rate` tratam isso). Ao encontrar pela primeira vez uma execução
iniciada há mais de 2 minutos, o coletor começa a partir do ciclo atual, sem
lançar o passado no horário presente; o detalhe ciclo a ciclo continua no
histórico do DBCT.

| Pasta | Arquivos | Ciclo de vida |
|---|---|---|
| `scripts\` | `dbct-collector.ps1` | substituído a cada reaplicação |
| `textfile\dbct\` | `dbct.prom` | sobrescrito a cada execução |
| `data\dbct\` | `config.json` (`dbct.exe` e pasta do banco) | mantido ao desativar o módulo ou desinstalar; removido na limpeza completa |
| `data\dbct\` | `state.json` (posição e contadores da coleta) | removido ao desativar o módulo |
| `logs\` | `dbct-collector-AAAAMMDD.log` | 14 dias |

Desativar o módulo ou desinstalar o Alloy não altera o DBCT: a execução
automática, se configurada, continua.

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
