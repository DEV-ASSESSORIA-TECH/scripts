#!/usr/bin/env bash
set -euo pipefail

log() { printf '[Alloy] %s\n' "$*"; }
fail() { printf '[Alloy] ERRO: %s\n' "$*" >&2; exit 1; }
usage() {
  printf 'Uso: sudo bash install.sh [--modules docker|none]\n'
  printf 'Sem parametro: detecta Docker e pergunta no terminal; preserva modulo existente.\n'
}

selection=auto
while (($#)); do
  case "$1" in
    --help|-h) usage; exit 0 ;;
    --modules) (($# >= 2)) || fail 'Falta valor para --modules.'; selection="$2"; shift 2 ;;
    --modules=*) selection="${1#*=}"; shift ;;
    *) fail "Parametro desconhecido: $1" ;;
  esac
done
case "$selection" in auto|docker|none) ;; *) fail 'Use --modules docker ou --modules none.' ;; esac

[[ $EUID -eq 0 ]] || fail 'Execute com sudo.'
[[ -s /etc/alloy/oauth-client-secret ]] || fail 'Execute setup-credentials.py primeiro.'
[[ ! -L /etc/alloy ]] || fail '/etc/alloy nao pode ser link simbolico.'
command -v apt-get >/dev/null || fail 'APT obrigatorio (Debian/Ubuntu).'

script_dir=$(cd -- "$(dirname -- "$0")" && pwd)
[[ -s "$script_dir/config.alloy" ]] || fail 'config.alloy ausente ao lado de install.sh.'

docker_ready() {
  command -v docker >/dev/null 2>&1 &&
    [[ -S /var/run/docker.sock ]] &&
    timeout 5 docker info --format '{{.ServerVersion}}' >/dev/null 2>&1
}

use_docker=false
case "$selection" in
  docker) docker_ready || fail 'Docker indisponivel; modulo solicitado explicitamente.'
          use_docker=true ;;
  none) log 'Instalando apenas a base Linux.' ;;
  auto)
    if [[ -f /etc/alloy/docker.alloy ]]; then
      docker_ready || fail 'Modulo Docker existente, mas Docker indisponivel. Use --modules none para remover.'
      use_docker=true
      log 'Modulo Docker existente sera preservado.'
    elif docker_ready; then
      if [[ -t 0 ]]; then
        log 'Docker detectado. O acesso ao socket Docker equivale a privilegios root.'
        read -r -p 'Ativar monitoramento Docker (metricas + stdout/stderr)? [S/n]: ' answer || answer=n
        case "$answer" in ''|s|S|sim|Sim|SIM|y|Y|yes|YES) use_docker=true ;; esac
      else
        log 'Docker detectado sem terminal; use --modules docker para habilitar.'
      fi
    fi ;;
esac

stage=$(mktemp -d)
trap 'rm -rf -- "$stage"' EXIT
cp -- "$script_dir/config.alloy" "$stage/config.alloy"
if [[ $use_docker == true ]]; then
  if [[ -s "$script_dir/docker.alloy" ]]; then
    cp -- "$script_dir/docker.alloy" "$stage/docker.alloy"
  else
    log 'Baixando docker.alloy da API GitHub...'
    curl -fsSL -H 'Accept: application/vnd.github+json' \
      'https://api.github.com/repos/DEV-ASSESSORIA-TECH/scripts/contents/monitoring/alloy/linux/docker.alloy?ref=main' |
      python3 -c 'import base64,json,sys; sys.stdout.buffer.write(base64.b64decode(json.load(sys.stdin)["content"]))' > "$stage/docker.alloy"
    [[ -s "$stage/docker.alloy" ]] || fail 'Download docker.alloy vazio.'
  fi
fi

# Preservar modulos locais adicionais durante a validacao.
shopt -s nullglob
for existing in /etc/alloy/*.alloy; do
  name=$(basename -- "$existing")
  [[ $name == config.alloy || $name == docker.alloy ]] || cp -- "$existing" "$stage/$name"
done
shopt -u nullglob

# needrestart nao deve reiniciar os servicos existentes (ex.: Bitdefender).
export NEEDRESTART_MODE=l DEBIAN_FRONTEND=noninteractive
log 'Instalando Grafana Alloy...'
apt-get update
apt-get install -y ca-certificates curl python3
install -d -m 0755 /etc/apt/keyrings
curl -fsSL https://apt.grafana.com/gpg-full.key -o /etc/apt/keyrings/grafana.asc
chmod 0644 /etc/apt/keyrings/grafana.asc
printf '%s\n' 'deb [signed-by=/etc/apt/keyrings/grafana.asc] https://apt.grafana.com stable main' > /etc/apt/sources.list.d/grafana.list
apt-get update
apt-get install -y alloy

log 'Validando conjunto completo de arquivos .alloy...'
alloy validate "$stage" || fail 'Configuracao invalida. Configuracao existente mantida.'

install -d -o root -g alloy -m 0750 /etc/alloy
chown root:alloy /etc/alloy/oauth-client-secret
chmod 0640 /etc/alloy/oauth-client-secret
usermod -aG adm,systemd-journal alloy
# Docker requer acesso aos cgroups protegidos por agentes de seguranca.
# O servico executa como root SOMENTE quando o modulo Docker estiver ativo.
# Nao adicionamos alloy ao grupo docker: o servico root nao precisa disso.
if [[ $use_docker == true ]]; then
  log 'Modulo Docker: Alloy executara como root (acesso a cgroups e docker.sock).'
else
  log 'Base Linux: Alloy executara como usuario alloy.'
fi

stamp="$(date -u +%Y%m%dT%H%M%SZ)-$$"
backup=$(mktemp -d)
old_active=$(systemctl is-active alloy 2>/dev/null || true)
old_enabled=$(systemctl is-enabled alloy 2>/dev/null || true)
env_file=/etc/default/alloy
# Nome ordenado depois de override.conf: prevalece sobre overrides anteriores,
# inclusive o override.conf usado no teste manual do SRV-VPN.
dropin_dir=/etc/systemd/system/alloy.service.d
dropin_file="$dropin_dir/zz-assessoriatech-execution.conf"
for name in config.alloy docker.alloy; do
  [[ ! -f /etc/alloy/$name ]] || cp -a -- "/etc/alloy/$name" "$backup/$name"
done
[[ ! -f "$env_file" ]] || cp -a -- "$env_file" "$backup/default.alloy"
[[ ! -f "$dropin_file" ]] || cp -a -- "$dropin_file" "$backup/execution.conf"

rollback() {
  log 'Restaurando arquivos anteriores...'
  for name in config.alloy docker.alloy; do
    if [[ -f "$backup/$name" ]]; then
      cp -a -- "$backup/$name" "/etc/alloy/$name"
    else
      rm -f -- "/etc/alloy/$name"
    fi
  done
  if [[ -f "$backup/default.alloy" ]]; then
    cp -a -- "$backup/default.alloy" "$env_file"
  else
    rm -f -- "$env_file"
  fi
  if [[ -f "$backup/execution.conf" ]]; then
    install -D -o root -g root -m 0644 "$backup/execution.conf" "$dropin_file"
  else
    rm -f -- "$dropin_file"
  fi
  systemctl daemon-reload
  # Muitas reinicializacoes em sequencia podem disparar start-limit-hit.
  systemctl reset-failed alloy || true
  if [[ $old_active == active ]]; then
    systemctl restart alloy || log 'CRITICO: erro ao reiniciar a configuracao restaurada.'
    restored=false
    for attempt in {1..12}; do
      if systemctl is-active --quiet alloy &&
         curl -fsS --max-time 2 http://127.0.0.1:12345/-/ready >/dev/null 2>&1; then
        restored=true
        break
      fi
      sleep 1
    done
    if [[ $restored == true ]]; then
      log 'Configuracao anterior restaurada e Alloy pronto.'
    else
      log 'CRITICO: arquivos restaurados, mas Alloy nao ficou pronto.'
      journalctl -u alloy -n 30 --no-pager >&2 || true
    fi
  else
    systemctl stop alloy || true
  fi
  [[ $old_enabled == enabled ]] || systemctl disable alloy || true
}

for name in config.alloy docker.alloy; do
  if [[ -f "$stage/$name" ]]; then
    install -o root -g alloy -m 0640 "$stage/$name" "/etc/alloy/.$name.tmp"
    mv -f -- "/etc/alloy/.$name.tmp" "/etc/alloy/$name"
  else
    rm -f -- "/etc/alloy/$name"
  fi
done

# O servico Debian/Ubuntu le CONFIG_FILE deste arquivo. Diretorio carrega
# os arquivos *.alloy em conjunto, sem incluir subdiretorios ou backups.
if [[ ! -f $env_file ]]; then
  printf 'CONFIG_FILE="/etc/alloy"\nCUSTOM_ARGS=""\n' > "$env_file"
elif grep -q '^CONFIG_FILE=' "$env_file"; then
  sed -i 's|^CONFIG_FILE=.*|CONFIG_FILE="/etc/alloy"|' "$env_file"
else
  printf '\nCONFIG_FILE="/etc/alloy"\n' >> "$env_file"
fi

# Drop-in gerenciado pelo instalador. Base Linux volta a ser nao privilegiada
# mesmo se um override.conf manual anterior ainda especificar User=root.
install -d -o root -g root -m 0755 "$dropin_dir"
managed_dropin=$(mktemp "$dropin_dir/.zz-assessoriatech-execution.XXXXXX")
if [[ $use_docker == true ]]; then
  printf '[Service]\nUser=root\nGroup=root\n' > "$managed_dropin"
  desired_user=root
  desired_group=root
else
  printf '[Service]\nUser=alloy\nGroup=alloy\n' > "$managed_dropin"
  desired_user=alloy
  desired_group=alloy
fi
chown root:root "$managed_dropin"
chmod 0644 "$managed_dropin"
mv -f -- "$managed_dropin" "$dropin_file"
systemctl daemon-reload
systemctl reset-failed alloy || true

actual_user=$(systemctl show alloy --property=User --value)
actual_group=$(systemctl show alloy --property=Group --value)
if [[ $actual_user != "$desired_user" || $actual_group != "$desired_group" ]]; then
  rollback
  fail "Usuario efetivo incorreto: $actual_user:$actual_group (esperado $desired_user:$desired_group)."
fi

log "Habilitando e iniciando Alloy como $desired_user:$desired_group..."
systemctl enable alloy
if ! systemctl restart alloy; then
  journalctl -u alloy -n 30 --no-pager >&2 || true
  rollback
  fail 'Falha na inicializacao; arquivos restaurados.'
fi

ready=false
for i in {1..12}; do
  if systemctl is-active --quiet alloy &&
     curl -fsS --max-time 2 http://127.0.0.1:12345/-/ready >/dev/null 2>&1; then
    ready=true
    break
  fi
  sleep 1
done
if [[ $ready != true ]]; then
  journalctl -u alloy -n 30 --no-pager >&2 || true
  rollback
  fail 'Alloy nao ficou pronto; arquivos restaurados.'
fi

# Backups persistentes para auditoria e reversao manual.
install -d -m 0700 /etc/alloy/backups
for name in config.alloy docker.alloy; do
  [[ ! -f "$backup/$name" ]] || cp -a -- "$backup/$name" "/etc/alloy/backups/$name.$stamp"
done
[[ ! -f "$backup/default.alloy" ]] || cp -a -- "$backup/default.alloy" "/etc/alloy/backups/default.alloy.$stamp"
[[ ! -f "$backup/execution.conf" ]] || cp -a -- "$backup/execution.conf" "/etc/alloy/backups/execution.conf.$stamp"
rm -rf -- "$backup"

log "Alloy ativo e pronto como $desired_user:$desired_group."
log "Modulos: Linux$( [[ $use_docker == true ]] && printf ' + Docker' || true )"
systemctl --no-pager --full status alloy
