#!/usr/bin/env bash
# Configura, testa ou remove o heartbeat do host (Uptime Kuma Push + Loki).
#
# Opcional e independente da instalacao do Alloy (menu [9] do alloy.sh).
# Sem parametros: configura. Pede a URL de push copiada do Uptime Kuma, faz
# uma batida de teste e so entao grava a URL (root, 0600), instala o
# heartbeat.py e o timer systemd, conferindo a primeira execucao. A URL
# completa e informada na configuracao: o endereco do Kuma nao fica no
# repositorio.
#
#   --url URL   URL de push (automacao); sem ela, a URL e pedida no terminal
#   --test      executa o heartbeat agora (pelo systemd) e mostra o resultado
#   --remove    remove timer, URL, script e estado [--yes: sem confirmacao]
set -euo pipefail

dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib/common.sh
source "$dir/lib/common.sh"
# shellcheck source=lib/ui.sh
source "$dir/lib/ui.sh"
# shellcheck source=lib/state.sh
source "$dir/lib/state.sh"

action=setup
url_arg=''
assume_yes=false
while (($#)); do
  case "$1" in
    --url) (($# >= 2)) || fail 'Falta valor para --url.'; url_arg=$2; shift ;;
    --url=*) url_arg=${1#*=} ;;
    --test) action='test' ;;
    --remove) action=remove ;;
    --yes|-y) assume_yes=true ;;
    *) fail "Parametro desconhecido: $1" ;;
  esac
  shift
done
[[ $EUID -eq 0 ]] || fail 'Execute com sudo.'

host=$(host_name)

# URL colada do Kuma (com ou sem ?status=up&msg=OK&ping=) -> URL base de push.
push_url() {
  local value=$1
  value=${value//[[:space:]\"\']/}
  value=${value%%[?#]*}
  [[ $value =~ ^https://[A-Za-z0-9.-]+(:[0-9]+)?(/[A-Za-z0-9._~-]+)*/api/push/[A-Za-z0-9_-]{8,128}$ ]] ||
    fail 'URL invalida. Formato esperado: https://<servidor>/api/push/<token> (copie do monitor Push do Uptime Kuma).'
  printf '%s' "$value"
}

kuma_hint() {
  case "$1" in
    200) printf 'batida confirmada' ;;
    404) printf 'token desconhecido ou monitor pausado/inexistente no Kuma' ;;
    401|403|resposta_invalida) printf 'resposta bloqueada no caminho (Cloudflare ou Nginx); verifique as regras para /api/push' ;;
    sem_resposta) printf 'sem resposta do Kuma (DNS, rota, TLS ou firewall)' ;;
    erro*) printf '%s' "$1" ;;
    *) printf 'HTTP %s' "$1" ;;
  esac
}

# show_result ARQUIVO_LAST: linhas Alloy, Loki e Kuma; retorna 0 se o Kuma confirmou.
show_result() {
  local kuma loki line kind text
  kuma=$(last_field "$1" kuma)
  loki=$(last_field "$1" loki)
  line=$(last_field "$1" line)
  ui_row Alloy none "$line"
  case "$loki" in
    204) kind=ok text='linha gravada (job alloy-heartbeat)' ;;
    sem_credencial) kind=warn text='credencial do Alloy ausente ou ilegivel: so o Kuma recebe a batida' ;;
    *) kind=err text="falhou: $loki" ;;
  esac
  ui_row Loki "$kind" "$text"
  if [[ $kuma == 200 ]]; then kind=ok; else kind=err; fi
  ui_row 'Uptime Kuma' "$kind" "$(kuma_hint "$kuma")"
  [[ $kuma == 200 ]]
}

# Executa o servico agora (oneshot: o start espera o fim) e mostra o resultado.
run_service() {
  local before
  before=$(date +%s)
  systemctl start "$HEARTBEAT_UNIT.service" || true
  if [[ ! -s $HEARTBEAT_STATE/last ]] || (($(last_field "$HEARTBEAT_STATE/last" time || printf 0) < before)); then
    fail "Sem resultado desta execucao. Veja: journalctl -u $HEARTBEAT_UNIT -n 20"
  fi
  show_result "$HEARTBEAT_STATE/last"
}

# Credencial do Alloy lida direto (root:alloy 0640) pelo grupo alloy; a URL do
# Kuma, que so o heartbeat usa, chega por LoadCredential (o arquivo sempre existe).
write_units() {
  cat >"$HEARTBEAT_SERVICE_FILE" <<EOF
# Gerenciado pelo heartbeat-setup.sh (scripts/monitoring/alloy). Nao editar.
[Unit]
Description=Heartbeat do host: estado do Alloy no Loki e batida no Uptime Kuma
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/bin/python3 -I $HEARTBEAT_SCRIPT
DynamicUser=yes
SupplementaryGroups=alloy
StateDirectory=$HEARTBEAT_UNIT
StateDirectoryMode=0700
LoadCredential=kuma-url:$HEARTBEAT_URL_FILE
TimeoutStartSec=50
ProtectHome=yes
PrivateDevices=yes
NoNewPrivileges=yes
RestrictAddressFamilies=AF_UNIX AF_INET AF_INET6
EOF
  cat >"$HEARTBEAT_TIMER_FILE" <<EOF
# Gerenciado pelo heartbeat-setup.sh (scripts/monitoring/alloy). Nao editar.
[Unit]
Description=Heartbeat do host a cada minuto

[Timer]
OnBootSec=30s
OnUnitActiveSec=60s
AccuracySec=5s

[Install]
WantedBy=timers.target
EOF
  chmod 0644 "$HEARTBEAT_SERVICE_FILE" "$HEARTBEAT_TIMER_FILE"
  systemctl daemon-reload
}

# ------------------------------------------------------------------- remover
if [[ $action == remove ]]; then
  if [[ ! -e $HEARTBEAT_TIMER_FILE && ! -e $HEARTBEAT_DIR && ! -e $HEARTBEAT_LIB ]]; then
    log 'Heartbeat nao configurado; nada a remover.'
    exit 0
  fi
  if [[ $assume_yes != true ]]; then
    confirm "Remover o heartbeat de $host?" N || { log 'Cancelado; nada foi alterado.'; exit 0; }
  fi
  systemctl disable --now "$HEARTBEAT_UNIT.timer" >/dev/null 2>&1 || true
  # Estado do usuario dinamico (/var/lib/private/...) antes de remover a unidade.
  systemctl clean --what=state "$HEARTBEAT_UNIT.service" >/dev/null 2>&1 || true
  rm -f -- "$HEARTBEAT_SERVICE_FILE" "$HEARTBEAT_TIMER_FILE"
  systemctl daemon-reload
  systemctl reset-failed "$HEARTBEAT_UNIT.service" >/dev/null 2>&1 || true
  rm -rf -- "$HEARTBEAT_DIR" "$HEARTBEAT_LIB" "$HEARTBEAT_STATE" "/var/lib/private/$HEARTBEAT_UNIT"
  ok 'Heartbeat removido (timer, URL, script e estado).'
  warn 'Pause ou exclua o monitor Push deste host no Uptime Kuma: sem batidas, ele vai para DOWN.'
  exit 0
fi

# -------------------------------------------------------------------- testar
if [[ $action == test ]]; then
  heartbeat_configured || fail 'Heartbeat nao configurado.'
  heartbeat_timer_enabled || fail 'Timer desativado (Alloy desinstalado?). Reconfigure o heartbeat.'
  log 'Executando o heartbeat agora (alloy-heartbeat.service)...'
  printf '\n'
  run_service || fail 'O Uptime Kuma nao confirmou a batida.'
  exit 0
fi

# ---------------------------------------------------------------- configurar
staged=$dir/heartbeat.py
[[ -s $staged ]] || fail 'heartbeat.py ausente ao lado de heartbeat-setup.sh.'
[[ -x /usr/bin/python3 ]] || fail 'python3 ausente em /usr/bin; instale antes de executar.'
/usr/bin/python3 -I -c 'import ast, sys; ast.parse(open(sys.argv[1]).read())' "$staged" ||
  fail 'heartbeat.py com erro de sintaxe.'
# O servico le a credencial pelo grupo alloy, criado pelo pacote: sem o Alloy
# instalado, a unidade nao inicia.
getent group alloy >/dev/null || fail 'Grupo alloy ausente: instale o Alloy antes de configurar o heartbeat.'
# LoadCredential= e StateDirectory com DynamicUser: systemd 247+ (Debian 11+, Ubuntu 22.04+).
systemd_version=$(systemctl --version 2>/dev/null | awk 'NR == 1 { print $2 + 0 }')
((${systemd_version:-0} >= 247)) || fail "systemd ${systemd_version:-?} sem suporte (minimo 247: Debian 11+, Ubuntu 22.04+)."

if [[ -n $url_arg ]]; then
  candidate=$(push_url "$url_arg")
else
  [[ -t 0 ]] || fail 'Sem terminal interativo: informe --url.'
  if [[ -s $HEARTBEAT_URL_FILE ]] && confirm '  Usar a URL de push ja gravada?'; then
    candidate=$(push_url "$(<"$HEARTBEAT_URL_FILE")")
  else
    printf '  No Uptime Kuma, crie um monitor do tipo Push para este host:\n\n'
    ui_row Nome none "heartbeat-$host"
    ui_row Intervalo none '120 s (Heartbeat Interval)'
    ui_row Tentativas none '1, com intervalo de 60 s (DOWN em ~3 min)'
    printf '\n  Copie a URL de push mostrada no monitor e cole abaixo.\n\n'
    read -r -p '  URL de push: ' typed || typed=''
    candidate=$(push_url "$typed")
  fi
fi
if ! credential_present; then
  warn 'Sem credencial do Alloy: o estado nao vai para o Loki, so a batida no Kuma.'
elif [[ $(stat -c '%G' "$SECRET") != alloy || $(( 0$(stat -c '%a' "$SECRET") & 040 )) -eq 0 ]]; then
  warn "Credencial sem leitura para o grupo alloy ($(stat -c '%U:%G %a' "$SECRET")): use [1] Reaplicar configuracao."
fi

# Batida de teste antes de gravar qualquer coisa (estado em pasta temporaria).
printf '\n'
log 'Teste: estado local, Loki e batida no Uptime Kuma...'
probe=$(mktemp -d)
trap 'rm -rf -- "$probe"' EXIT
HEARTBEAT_KUMA_URL=$candidate STATE_DIRECTORY=$probe \
  /usr/bin/python3 -I "$staged" >/dev/null 2>&1 || true
[[ -s $probe/last ]] || fail 'O teste nao produziu resultado. Nada foi gravado.'
if ! show_result "$probe/last"; then
  fail "Teste reprovado: $(kuma_hint "$(last_field "$probe/last" kuma)"). Nada foi gravado."
fi

[[ ! -L $ETC_DIR ]] || fail "$ETC_DIR nao pode ser link simbolico."
[[ -d $ETC_DIR ]] || install -d -o root -g root -m 0750 "$ETC_DIR"
install -d -o root -g root -m 0700 "$HEARTBEAT_DIR"
tmp_url=$(mktemp "$HEARTBEAT_DIR/.kuma-url.XXXXXX")
printf '%s\n' "$candidate" >"$tmp_url"
chmod 0600 "$tmp_url"
mv -f -- "$tmp_url" "$HEARTBEAT_URL_FILE"
install -d -o root -g root -m 0755 "$HEARTBEAT_LIB"
install -o root -g root -m 0644 "$staged" "$HEARTBEAT_SCRIPT"
write_units
systemctl enable "$HEARTBEAT_UNIT.timer" >/dev/null 2>&1
printf '\n'
log 'URL gravada e timer ativado. Conferindo a primeira execucao pelo systemd...'
run_service || fail "O servico executou, mas o Kuma nao confirmou. Veja: journalctl -u $HEARTBEAT_UNIT"
systemctl start "$HEARTBEAT_UNIT.timer"
ok "Heartbeat ativo: a cada minuto ($HEARTBEAT_UNIT.timer)."
