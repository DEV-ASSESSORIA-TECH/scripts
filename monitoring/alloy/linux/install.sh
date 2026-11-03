#!/usr/bin/env bash
set -euo pipefail

log() { printf '[Alloy] %s\n' "$*"; }
fail() { printf '[Alloy] ERRO: %s\n' "$*" >&2; exit 1; }

[[ $EUID -eq 0 ]] || fail 'Execute com sudo.'
[[ -s /etc/alloy/oauth-client-secret ]] || fail 'Credencial ausente: execute setup-credentials.py antes.'
[[ ! -L /etc/alloy ]] || fail 'Diretorio /etc/alloy invalido (link simbolico).'
command -v apt-get >/dev/null 2>&1 || fail 'Este instalador requer APT (Debian/Ubuntu).'

script_dir=$(cd -- "$(dirname -- "$0")" && pwd)
source_config="$script_dir/config.alloy"
[[ -s $source_config ]] || fail 'config.alloy nao encontrado ao lado de install.sh.'

# Evita reinicios automaticos de outros servicos pelo needrestart durante o APT.
# Isso nao impede reinicios que os proprios pacotes executem nos seus scripts.
export NEEDRESTART_MODE=l
export DEBIAN_FRONTEND=noninteractive

log 'Preparando repositorio e instalando Grafana Alloy...'
apt-get update
apt-get install -y ca-certificates curl
install -d -m 0755 /etc/apt/keyrings
curl -fsSL https://apt.grafana.com/gpg-full.key -o /etc/apt/keyrings/grafana.asc
chmod 0644 /etc/apt/keyrings/grafana.asc
printf '%s\n' 'deb [signed-by=/etc/apt/keyrings/grafana.asc] https://apt.grafana.com stable main' > /etc/apt/sources.list.d/grafana.list
apt-get update
apt-get install -y alloy

log 'Validando config.alloy antes de instalar...'
alloy validate "$source_config"

install -d -o root -g alloy -m 0750 /etc/alloy
chown root:alloy /etc/alloy/oauth-client-secret
chmod 0640 /etc/alloy/oauth-client-secret
usermod -aG systemd-journal alloy

temp_config=$(mktemp /etc/alloy/.config.alloy.XXXXXX)
trap 'rm -f -- "$temp_config"' EXIT
install -o root -g alloy -m 0640 "$source_config" "$temp_config"

if [[ -f /etc/alloy/config.alloy ]]; then
  backup="/etc/alloy/config.alloy.bak-$(date -u +%Y%m%dT%H%M%SZ)-$$"
  cp -a /etc/alloy/config.alloy "$backup"
  log "Backup da configuracao anterior: $backup"
fi
mv -f -- "$temp_config" /etc/alloy/config.alloy

log 'Habilitando e iniciando Alloy...'
systemctl enable alloy
if ! systemctl restart alloy; then
  journalctl -u alloy -n 30 --no-pager >&2 || true
  fail 'Nao foi possivel iniciar Alloy. Verifique os logs e o backup da configuracao.'
fi

ready=false
for attempt in {1..12}; do
  if systemctl is-active --quiet alloy && curl -fsS --max-time 2 http://127.0.0.1:12345/-/ready >/dev/null 2>&1; then
    ready=true
    break
  fi
  sleep 1
done

if [[ $ready != true ]]; then
  journalctl -u alloy -n 30 --no-pager >&2 || true
  fail 'Alloy nao ficou pronto em 12 verificacoes. Consulte os logs.'
fi

log 'Instalacao concluida: Alloy ativo e pronto.'
systemctl --no-pager --full status alloy
log 'Confirme a chegada das metricas no Prometheus e dos logs no Loki.'
