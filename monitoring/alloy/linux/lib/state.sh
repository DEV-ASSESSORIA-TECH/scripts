# shellcheck shell=bash
# Leitura do estado local do Alloy (sem alterar nada), cabecalho e diagnostico.
# Requer lib/common.sh e lib/ui.sh.

host_name() {
  local name
  name=$(cat /proc/sys/kernel/hostname 2>/dev/null || hostname)
  printf '%s' "${name%%.*}"
}

alloy_installed() {
  [[ $(dpkg-query -W -f='${Status}' alloy 2>/dev/null || true) == 'install ok installed' ]]
}
alloy_version() { dpkg-query -W -f='${Version}' alloy 2>/dev/null || true; }
service_active() { systemctl is-active --quiet alloy 2>/dev/null; }
service_ready() { curl -fsS --max-time 2 "$READY_URL" >/dev/null 2>&1; }
service_user() { systemctl show alloy --property=User --value 2>/dev/null || true; }
credential_present() { [[ -s $SECRET && ! -L $SECRET ]]; }
docker_module() { [[ -f $ETC_DIR/docker.alloy ]]; }
docker_available() { command -v docker >/dev/null 2>&1 && [[ -S /var/run/docker.sock ]]; }
first_run() { ! credential_present && ! alloy_installed; }
heartbeat_configured() { [[ -s $HEARTBEAT_URL_FILE || -f $HEARTBEAT_TIMER_FILE ]]; }
heartbeat_timer_enabled() { systemctl is-enabled --quiet "$HEARTBEAT_UNIT.timer" 2>/dev/null; }

# last_field ARQUIVO CAMPO: valor de "campo=valor" no arquivo last do heartbeat.
last_field() {
  local value
  value=$(sed -n "s/^$2=//p" "$1" 2>/dev/null | head -n 1)
  [[ -n $value ]] || return 1
  printf '%s' "$value"
}

# Estado do heartbeat em "marcador|texto"; vazio quando nao configurado.
heartbeat_status() {
  local last=$HEARTBEAT_STATE/last ts age kuma loki text
  heartbeat_configured || return 0
  if ! heartbeat_timer_enabled; then printf 'warn|timer desativado: reconfigure em [9]'; return 0; fi
  if ! ts=$(last_field "$last" time); then printf 'warn|sem execucao registrada'; return 0; fi
  age=$(($(date +%s) - ts))
  ((age < 0)) && age=0
  kuma=$(last_field "$last" kuma || printf '?')
  loki=$(last_field "$last" loki || printf '?')
  text="ha ${age}s: Kuma $kuma, Loki $loki, alloy=$(last_field "$last" alloy || printf '?')"
  if ((age > 180)) || [[ $kuma != 200 ]]; then
    printf 'err|%s' "$text"
  elif [[ $loki != 204 ]]; then
    printf 'warn|%s' "$text"
  else
    printf 'ok|%s' "$text"
  fi
}

# Conta de servico gravada na credencial. Nunca imprime a senha.
credential_user() {
  local decoded user
  credential_present || return 1
  decoded=$(base64 -d <"$SECRET" 2>/dev/null) || return 1
  user=${decoded%%:*}
  decoded=''
  [[ $user =~ ^alloy-[a-z0-9][a-z0-9-]*$ ]] || return 1
  printf '%s' "$user"
}

wait_ready() {
  local _
  for _ in {1..15}; do
    service_active && service_ready && return 0
    sleep 1
  done
  return 1
}

# Estado do servico em "marcador|texto" para o cabecalho e o diagnostico.
service_status() {
  if ! alloy_installed; then
    printf 'off|nao instalado'
  elif service_active; then
    if service_ready; then printf 'ok|ativo e pronto'; else printf 'warn|ativo, nao pronto'; fi
  else
    printf 'err|parado'
  fi
}

# LAST_STATUS/LAST_ACTION sao definidos pelo menu do alloy.sh.
print_header() {
  local status badge text cred_badge cred_text mods heartbeat
  status=$(service_status)
  badge=${status%%|*}
  text=${status#*|}
  alloy_installed && text=$(printf '%-22s v%s' "$text" "$(alloy_version)")
  if credential_present; then
    cred_badge=ok
    cred_text=$(credential_user || printf 'presente (conta ilegivel)')
  else
    cred_badge=warn
    cred_text=ausente
  fi
  mods=Linux
  if docker_module; then mods+=' + Docker'; fi

  ui_banner "$(host_name)"
  ui_row Servico "$badge" "$text"
  ui_row Credencial "$cred_badge" "$cred_text"
  ui_row Modulos none "$mods"
  heartbeat=$(heartbeat_status)
  [[ -n $heartbeat ]] && ui_row Heartbeat "${heartbeat%%|*}" "${heartbeat#*|}"
  if [[ $ALLOY_LOCAL == 1 ]]; then
    ui_row Origem none 'arquivos locais'
  elif [[ $ALLOY_REF != main ]]; then
    ui_row Origem none "ref $ALLOY_REF"
  fi
  if [[ -n ${LAST_ACTION:-} ]]; then
    ui_row 'Ultima acao' "${LAST_STATUS:-none}" "$LAST_ACTION"
  fi
  ui_rule -
}

# Resumo de uma linha (saida do menu e comandos diretos).
print_summary() {
  local status
  status=$(service_status)
  printf '  Alloy %s %s' "$(ui_badge "${status%%|*}")" "${status#*|}"
  if credential_present; then printf '  |  credencial %s' "$(credential_user || printf 'presente')"; fi
  printf '\n'
}

# Teste de alcance: qualquer resposta HTTP comprova DNS, rota e TLS.
check_endpoint() {
  local code
  code=$(curl -sS -A "$USER_AGENT" -o /dev/null -w '%{http_code}' --connect-timeout 5 --max-time 10 "https://$2/" 2>/dev/null) || code=000
  if [[ $code == 000 ]]; then
    ui_row "$1" err "$2 - sem resposta (DNS, rota ou TLS)"
  else
    ui_row "$1" ok "$2 - HTTP $code"
  fi
}

# Link do Explore ja filtrado (ultima 1h). Uso: explore_url DATASOURCE CONSULTA
explore_url() {
  python3 -c '
import json, sys, urllib.parse
base, ds, expr = sys.argv[1:4]
panes = {"a": {"datasource": ds, "queries": [{"refId": "A", "expr": expr}],
               "range": {"from": "now-1h", "to": "now"}}}
print(base + "/explore?schemaVersion=1&orgId=1&panes="
      + urllib.parse.quote(json.dumps(panes, separators=(",", ":")), safe=""))
' "$GRAFANA_URL" "$1" "$2"
}

print_query() { # print_query ROTULO DATASOURCE CONSULTA
  ui_row "$1" none "$3"
  printf '                       %s%s%s\n' "$C_DIM" "$(explore_url "$2" "$3")" "$C_RESET"
}

# Timer, ultima execucao e linha enviada ao Loki pelo heartbeat.
diagnose_heartbeat() {
  local status line
  ui_section 'HEARTBEAT (UPTIME KUMA + LOKI)'
  if heartbeat_timer_enabled; then
    ui_row Timer ok "ativo, proxima $(systemctl show "$HEARTBEAT_UNIT.timer" --property=NextElapseUSecRealtime --value 2>/dev/null || printf '?')"
  else
    ui_row Timer err 'desativado: reconfigure em [9]'
  fi
  status=$(heartbeat_status)
  ui_row Ultima "${status%%|*}" "${status#*|}"
  if line=$(last_field "$HEARTBEAT_STATE/last" line); then ui_row Linha none "$line"; fi
  ui_row URL none "$HEARTBEAT_URL_FILE (root, 0600)"
  ui_row Logs none "journalctl -u $HEARTBEAT_UNIT"
}

diagnose() {
  local host status since files issues count
  host=$(host_name)

  ui_section SERVICO
  status=$(service_status)
  if alloy_installed; then
    ui_row Estado "${status%%|*}" "${status#*|} ($(systemctl is-enabled alloy 2>/dev/null || printf '?'))"
    ui_row Versao none "v$(alloy_version)"
    since=$(systemctl show alloy --property=ActiveEnterTimestamp --value 2>/dev/null || true)
    if service_active && [[ -n $since ]]; then ui_row Desde none "$since"; fi
    ui_row Usuario none "$(service_user)"
  else
    ui_row Estado off 'nao instalado'
  fi
  case "${ALLOYCTL_MODE:-}" in
    installed) ui_row alloyctl none "${ALLOYCTL_REF:-?} @ ${ALLOY_REF:0:7} ($ALLOYCTL_BIN)" ;;
    local) ui_row alloyctl none "clone local (ref $ALLOY_REF)" ;;
    *) ui_row alloyctl warn "nao instalado (arquivos temporarios, ref $ALLOY_REF)" ;;
  esac
  files=$(find "$ETC_DIR" -maxdepth 1 -name '*.alloy' 2>/dev/null | wc -l)
  ui_row Config none "$ETC_DIR ($files arquivo(s) .alloy)"
  if credential_present; then
    ui_row Credencial ok "$SECRET ($(stat -c '%U:%G %a' "$SECRET"))"
  else
    ui_row Credencial warn 'ausente'
  fi

  if alloy_installed; then
    ui_section 'AVISOS E ERROS (24H)'
    issues=$(journalctl -u alloy --since=-24h --no-pager -o cat 2>/dev/null | grep -E 'level=(warn|error)' || true)
    if [[ -z $issues ]]; then
      ui_row Journal ok 'nenhum aviso ou erro'
    else
      count=$(grep -c . <<<"$issues")
      ui_row Journal warn "$count linha(s); as mais recentes:"
      tail -n 6 <<<"$issues" | cut -c1-$((UI_WIDTH + 10)) | sed 's/^/    /'
    fi
  fi

  if heartbeat_configured; then diagnose_heartbeat; fi

  ui_section CONECTIVIDADE
  check_endpoint Auth auth.assessoriatech.com
  check_endpoint Mon mon.assessoriatech.com

  ui_section 'GRAFANA - EXPLORE (ULTIMA 1H)'
  print_query Metricas "$GRAFANA_DS_METRICS" "up{job=\"integrations/unix\",host=\"$host\"}"
  print_query Logs "$GRAFANA_DS_LOGS" "{job=\"systemd-journal\",host=\"$host\"}"
  if docker_module; then
    print_query Docker "$GRAFANA_DS_METRICS" "up{job=\"integrations/docker\",host=\"$host\"}"
    print_query 'Logs Docker' "$GRAFANA_DS_LOGS" "{job=\"docker\",host=\"$host\"}"
  fi
  if heartbeat_configured; then
    print_query Heartbeat "$GRAFANA_DS_LOGS" "{job=\"alloy-heartbeat\",host=\"$(cat /proc/sys/kernel/hostname 2>/dev/null || hostname)\"} | logfmt"
  fi
  printf '\n  %sValidar a credencial de ponta a ponta: opcao [4].%s\n' "$C_DIM" "$C_RESET"
}
