#!/usr/bin/env bash
# Remove o Grafana Alloy do Linux.
# Padrao: remove pacote e servico; mantem credencial, configuracao e backups
# em /etc/alloy para uma reinstalacao sem novo setup.
# --purge: remove tudo o que a instalacao criou (inclui a credencial).
set -euo pipefail

dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib/common.sh
source "$dir/lib/common.sh"
# shellcheck source=lib/state.sh
source "$dir/lib/state.sh"

usage() {
  printf 'Uso: sudo bash uninstall.sh [--purge] [--yes]\n'
  printf '  --purge  remove tambem credencial, configuracao, dados, usuario e repositorio APT\n'
  printf '  --yes    nao pede confirmacao (automacao)\n'
}

purge=false
assume_yes=false
while (($#)); do
  case "$1" in
    --purge) purge=true ;;
    --yes|-y) assume_yes=true ;;
    --help|-h) usage; exit 0 ;;
    *) fail "Parametro desconhecido: $1" ;;
  esac
  shift
done

[[ $EUID -eq 0 ]] || fail 'Execute com sudo.'
if ! command -v dpkg-query >/dev/null || ! command -v apt-get >/dev/null; then
  fail 'APT obrigatorio (Debian/Ubuntu).'
fi

host=$(host_name)
account=$(credential_user || true)
package_known=false
dpkg-query -W alloy >/dev/null 2>&1 && package_known=true

# Outro pacote instalado do repositorio Grafana (ex.: grafana, loki)?
grafana_repo_user() {
  local names installed
  names=$(sed -n 's/^Package: //p' /var/lib/apt/lists/apt.grafana.com_*_Packages 2>/dev/null | sort -u || true)
  [[ -n $names ]] || names=$'grafana\ngrafana-enterprise\ngrafana-agent\ngrafana-agent-flow\nloki\npromtail\nmimir\ntempo\npyroscope\nk6'
  installed=$(dpkg-query -W -f='${Package}\t${db:Status-Abbrev}\n' 2>/dev/null | awk '$2 ~ /^ii/ {print $1}' | sort -u)
  comm -12 <(grep -vx alloy <<<"$names" | sort -u) <(printf '%s\n' "$installed") | head -n 1
}

if [[ $purge == true ]]; then
  targets=()
  [[ $package_known == true ]] && targets+=("pacote alloy (purge)")
  for path in "$ETC_DIR" "$DATA_DIR" "$ENV_FILE" "$DROPIN_FILE" "$HEARTBEAT_TIMER_FILE" "$HEARTBEAT_LIB"; do
    [[ -e $path || -L $path ]] && targets+=("$path")
  done
  id alloy >/dev/null 2>&1 && targets+=("usuario/grupo alloy")
  repo_user=$(grafana_repo_user)
  if [[ -z $repo_user ]]; then
    [[ -e $APT_SOURCE ]] && targets+=("$APT_SOURCE")
    [[ -e $APT_KEY ]] && targets+=("$APT_KEY")
  fi
  if ((${#targets[@]} == 0)); then
    log 'Nada a remover: o Alloy nao esta instalado e nao ha residuos.'
    exit 0
  fi
  printf '\n%sLimpeza completa em %s. Sera removido:%s\n' "$C_BOLD" "$host" "$C_RESET"
  printf '  - %s\n' "${targets[@]}"
  [[ -n $repo_user ]] && printf '  (repositorio APT Grafana mantido: em uso por %s)\n' "$repo_user"
  printf '\n'
  if [[ $assume_yes != true ]]; then
    [[ -t 0 ]] || fail 'Confirmacao necessaria: use --yes sem terminal.'
    read -r -p "Digite o hostname ($host) para confirmar: " typed || typed=''
    [[ $typed == "$host" ]] || fail 'Confirmacao incorreta; nada foi removido.'
  fi
else
  if [[ $package_known != true ]]; then
    log 'O Alloy nao esta instalado. Para remover residuos, use a limpeza completa (--purge).'
    exit 0
  fi
  if [[ $assume_yes != true ]]; then
    [[ -t 0 ]] || fail 'Confirmacao necessaria: use --yes sem terminal.'
    confirm "Desinstalar o Alloy de $host? Credencial e configuracao serao mantidas." N ||
      { log 'Cancelado; nada foi alterado.'; exit 0; }
  fi
fi

export DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=l

log 'Parando o servico...'
systemctl disable --now alloy.service >/dev/null 2>&1 || true

if [[ $package_known == true ]]; then
  if [[ $purge == true ]]; then
    log 'Removendo o pacote alloy (purge)...'
    apt-get purge -y alloy
  else
    log 'Removendo o pacote alloy (arquivos de configuracao mantidos)...'
    apt-get remove -y alloy
  fi
fi

# Heartbeat: o timer para junto com o Alloy (desinstalacao intencional); a URL
# fica para reativar em [9] sem colar de novo. --purge remove tudo.
heartbeat_was_on=false
if heartbeat_timer_enabled; then
  heartbeat_was_on=true
  log 'Desativando o timer do heartbeat...'
  systemctl disable --now "$HEARTBEAT_UNIT.timer" >/dev/null 2>&1 || true
fi
if [[ $purge == true && -e $HEARTBEAT_SERVICE_FILE ]]; then
  systemctl clean --what=state "$HEARTBEAT_UNIT.service" >/dev/null 2>&1 || true
  rm -f -- "$HEARTBEAT_SERVICE_FILE" "$HEARTBEAT_TIMER_FILE"
  rm -rf -- "$HEARTBEAT_LIB" "$HEARTBEAT_STATE" "/var/lib/private/$HEARTBEAT_UNIT"
fi

# Drop-in criado pelo install.sh; sem a unidade, ele nao tem efeito.
rm -f -- "$DROPIN_FILE"
rmdir -- "$DROPIN_DIR" 2>/dev/null || true
systemctl daemon-reload || true
systemctl reset-failed alloy.service >/dev/null 2>&1 || true

if [[ $purge == true ]]; then
  log 'Removendo credencial, configuracao, backups e dados...'
  rm -rf -- "$ETC_DIR" "$DATA_DIR"
  rm -f -- "$ENV_FILE"
  if id alloy >/dev/null 2>&1; then
    userdel alloy 2>/dev/null || warn 'Nao foi possivel remover o usuario alloy.'
  fi
  if getent group alloy >/dev/null 2>&1; then
    groupdel alloy 2>/dev/null || warn 'Nao foi possivel remover o grupo alloy.'
  fi
  if [[ -z $repo_user ]]; then
    rm -f -- "$APT_SOURCE" "$APT_KEY"
    log 'Repositorio APT Grafana removido (as listas antigas somem no proximo apt-get update).'
  fi
  ok "Limpeza completa concluida em $host."
  printf '\n'
  warn "A conta ${account:-alloy-$host} continua ativa no Authentik."
  warn 'Desative-a ou remova-a do grupo alloy-agents para revogar o acesso deste servidor.'
  if [[ $heartbeat_was_on == true ]]; then warn 'Exclua tambem o monitor Push deste host no Uptime Kuma.'; fi
else
  ok "Alloy desinstalado de $host."
  log "Mantidos: $SECRET, $ETC_DIR/*.alloy e $ETC_DIR/backups."
  log 'Para reinstalar sem novo setup, execute a instalacao novamente.'
  if [[ $heartbeat_was_on == true ]]; then
    warn 'Heartbeat parado: pause o monitor Push deste host no Uptime Kuma. A URL ficou gravada para reativar em [9].'
  fi
fi
