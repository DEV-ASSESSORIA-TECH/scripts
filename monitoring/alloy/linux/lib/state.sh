# shellcheck shell=bash
# Leitura do estado local do Alloy (sem alterar nada) e diagnostico.
# Requer lib/common.sh.

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

print_header() {
  local svc cred mods user origin
  if ! alloy_installed; then
    svc="${C_DIM}nao instalado${C_RESET}"
  elif service_active; then
    user=$(service_user)
    if service_ready; then
      svc="${C_OK}ativo, pronto${C_RESET} (v$(alloy_version), usuario ${user:-alloy})"
    else
      svc="${C_WARN}ativo, nao pronto${C_RESET} (v$(alloy_version))"
    fi
  else
    svc="${C_ERR}parado${C_RESET} (v$(alloy_version))"
  fi
  if credential_present; then
    cred="${C_OK}presente${C_RESET} ($(credential_user || printf 'conta ilegivel'))"
  else
    cred="${C_WARN}ausente${C_RESET}"
  fi
  mods=Linux
  docker_module && mods+=' + Docker'
  origin="ref $ALLOY_REF"
  [[ $ALLOY_LOCAL == 1 ]] && origin='arquivos locais'
  printf '\n %sAlloy - %s%s  %s(%s)%s\n' "$C_BOLD" "$(host_name)" "$C_RESET" "$C_DIM" "$origin" "$C_RESET"
  printf ' Servico ..... %s\n' "$svc"
  printf ' Credencial .. %s\n' "$cred"
  printf ' Modulos ..... %s\n\n' "$mods"
}

# Teste de alcance: qualquer resposta HTTP comprova DNS, rota e TLS.
check_endpoint() {
  local code
  code=$(curl -sS -o /dev/null -w '%{http_code}' --connect-timeout 5 --max-time 10 "$1" 2>/dev/null) || code=000
  if [[ $code == 000 ]]; then
    printf '   %-36s %sSEM RESPOSTA%s (DNS, rota ou TLS)\n' "$1" "$C_ERR" "$C_RESET"
  else
    printf '   %-36s %sOK%s (HTTP %s)\n' "$1" "$C_OK" "$C_RESET" "$code"
  fi
}

diagnose() {
  local host
  host=$(host_name)
  print_header
  if alloy_installed; then
    printf '%s-- Servico%s\n' "$C_BOLD" "$C_RESET"
    systemctl --no-pager --full status alloy 2>&1 | head -n 12 || true
    printf '\n%s-- Ultimos logs (40 linhas)%s\n' "$C_BOLD" "$C_RESET"
    journalctl -u alloy -n 40 --no-pager 2>&1 || true
  fi
  printf '\n%s-- Conectividade%s\n' "$C_BOLD" "$C_RESET"
  check_endpoint https://auth.assessoriatech.com/
  check_endpoint https://mon.assessoriatech.com/
  printf '\n%s-- Consultas no Grafana (Explore)%s\n' "$C_BOLD" "$C_RESET"
  printf '   Prometheus: up{job="integrations/unix",host="%s"}\n' "$host"
  printf '   Loki:       {job="systemd-journal",host="%s"}\n' "$host"
  if docker_module; then
    printf '   Prometheus: up{job="integrations/docker",host="%s"}\n' "$host"
    printf '   Loki:       {job="docker",host="%s"}\n' "$host"
  fi
  printf '\n   Para validar a credencial de ponta a ponta, use "Testar credencial".\n'
}
