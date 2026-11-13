#!/usr/bin/env bash
set -euo pipefail

log() { printf '[Alloy] %s\n' "$*"; }
fail() { printf '[Alloy] ERRO: %s\n' "$*" >&2; exit 1; }

# O servico pode ainda nao estar carregado durante a primeira instalacao.
# So tentar limpar falhas quando a unidade realmente estiver em estado failed.
reset_failed_alloy() {
  if systemctl is-failed --quiet alloy.service 2>/dev/null; then
    systemctl reset-failed alloy.service || true
  fi
}
usage() {
  printf 'Uso: sudo bash install.sh [--modules docker|none] [--upgrade]\n'
  printf 'Sem parametro: detecta Docker, preserva modulo existente e nao altera a versao do Alloy.\n'
  printf '  --modules docker  habilita Docker explicitamente\n'
  printf '  --modules none    desabilita o modulo Docker\n'
  printf '  --upgrade         atualiza o pacote Alloy via APT (opt-in)\n'
}

upgrade=false
selection=auto
while (($#)); do
  case "$1" in
    --help|-h) usage; exit 0 ;;
    --upgrade) upgrade=true; shift ;;
    --modules) (($# >= 2)) || fail 'Falta valor para --modules.'; selection="$2"; shift 2 ;;
    --modules=*) selection="${1#*=}"; shift ;;
    *) fail "Parametro desconhecido: $1" ;;
  esac
done
case "$selection" in auto|docker|none) ;; *) fail 'Use --modules docker ou --modules none.' ;; esac

[[ $EUID -eq 0 ]] || fail 'Execute com sudo.'
[[ -s /etc/alloy/oauth-client-secret ]] || fail 'Credencial ausente: execute alloy.sh (ou setup-credentials.py) primeiro.'
[[ ! -L /etc/alloy ]] || fail '/etc/alloy nao pode ser link simbolico.'
command -v apt-get >/dev/null || fail 'APT obrigatorio (Debian/Ubuntu).'
command -v curl >/dev/null || fail 'curl ausente; instale antes de executar.'
command -v python3 >/dev/null || fail 'python3 ausente; instale antes de executar.'
command -v cmp >/dev/null || fail 'cmp ausente; instale coreutils/diffutils.'

script_dir=$(cd -- "$(dirname -- "$0")" && pwd)
# Mesmos valores de lib/common.sh (install.sh roda sem a lib).
TEXTFILE_DIR=/var/lib/alloy-textfile
BACKUP_TEXTFILE_DIR=$TEXTFILE_DIR/backup
BACKUP_GROUP=alloy-backup
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
# Leitura dos backups: sempre instalada (pasta vazia nao publica nada).
if [[ -s "$script_dir/backup.alloy" ]]; then
  cp -- "$script_dir/backup.alloy" "$stage/backup.alloy"
else
  ref=${ALLOY_REF:-main}
  [[ $ref =~ ^[A-Za-z0-9][A-Za-z0-9._/-]*$ && $ref != *..* ]] || fail "ALLOY_REF invalido: $ref"
  log "Baixando backup.alloy (ref $ref)..."
  curl -fsSL --proto '=https' -o "$stage/backup.alloy" \
    "https://raw.githubusercontent.com/DEV-ASSESSORIA-TECH/scripts/$ref/monitoring/alloy/linux/backup.alloy"
  [[ -s "$stage/backup.alloy" ]] || fail 'Download backup.alloy vazio.'
fi
if [[ $use_docker == true ]]; then
  if [[ -s "$script_dir/docker.alloy" ]]; then
    cp -- "$script_dir/docker.alloy" "$stage/docker.alloy"
  else
    # Mesma origem e referencia do alloy.sh (ALLOY_REF; padrao: main).
    ref=${ALLOY_REF:-main}
    [[ $ref =~ ^[A-Za-z0-9][A-Za-z0-9._/-]*$ && $ref != *..* ]] || fail "ALLOY_REF invalido: $ref"
    log "Baixando docker.alloy (ref $ref)..."
    curl -fsSL --proto '=https' -o "$stage/docker.alloy" \
      "https://raw.githubusercontent.com/DEV-ASSESSORIA-TECH/scripts/$ref/monitoring/alloy/linux/docker.alloy"
    [[ -s "$stage/docker.alloy" ]] || fail 'Download docker.alloy vazio.'
  fi
fi

# Preservar modulos locais adicionais durante a validacao.
shopt -s nullglob
for existing in /etc/alloy/*.alloy; do
  name=$(basename -- "$existing")
  [[ $name == config.alloy || $name == docker.alloy || $name == backup.alloy ]] || cp -- "$existing" "$stage/$name"
done
shopt -u nullglob

# Nunca atualizar o agente implicitamente ao alterar configuracoes/modulos.
# --upgrade e a unica opcao que atualiza um Alloy ja instalado.
alloy_installed=false
if [[ $(dpkg-query -W -f='${Status}' alloy 2>/dev/null || true) == 'install ok installed' ]]; then
  alloy_installed=true
fi
alloy_changed=false
if [[ $alloy_installed == true && $upgrade == false ]]; then
  log "Alloy ja instalado (versao $(dpkg-query -W -f='${Version}' alloy)). Ignorando APT."
else
  # needrestart nao deve reiniciar servicos existentes (ex.: Bitdefender).
  export NEEDRESTART_MODE=l DEBIAN_FRONTEND=noninteractive
  log 'Preparando repositorio Grafana (instalacao ou upgrade explicito)...'
  apt-get update

  # Evitar atualizar dependencias ja instaladas durante o bootstrap.
  # Instalar somente pacotes ausentes; --upgrade atualiza apenas o Alloy.
  missing_packages=()
  for pkg in ca-certificates curl python3; do
    if [[ $(dpkg-query -W -f='${Status}' "$pkg" 2>/dev/null || true) != 'install ok installed' ]]; then
      missing_packages+=("$pkg")
    fi
  done
  if (( ${#missing_packages[@]} )); then
    log "Instalando dependencias ausentes: ${missing_packages[*]}"
    apt-get install -y --no-upgrade "${missing_packages[@]}"
  else
    log 'Dependencias do instalador ja presentes. Nenhuma atualizacao necessaria.'
  fi

  install -d -m 0755 /etc/apt/keyrings
  curl -fsSL https://apt.grafana.com/gpg-full.key -o /etc/apt/keyrings/grafana.asc
  chmod 0644 /etc/apt/keyrings/grafana.asc
  printf '%s\n' 'deb [signed-by=/etc/apt/keyrings/grafana.asc] https://apt.grafana.com stable main' > /etc/apt/sources.list.d/grafana.list
  apt-get update

  if [[ $alloy_installed == true ]]; then
    before_version=$(dpkg-query -W -f='${Version}' alloy)
    apt-get install -y --only-upgrade alloy
    after_version=$(dpkg-query -W -f='${Version}' alloy)
    if [[ $before_version != "$after_version" ]]; then
      alloy_changed=true
      log "Alloy atualizado: $before_version -> $after_version."
    else
      log "Alloy ja estava na versao mais recente: $after_version."
    fi
  else
    apt-get install -y alloy
    alloy_changed=true
    log "Alloy instalado: $(dpkg-query -W -f='${Version}' alloy)."
  fi
fi
command -v alloy >/dev/null || fail 'Pacote presente, mas binario alloy indisponivel.'

log 'Validando conjunto completo de arquivos .alloy...'
alloy validate "$stage" || fail 'Configuracao invalida. Configuracao existente mantida.'

install -d -o root -g alloy -m 0750 /etc/alloy
chown root:alloy /etc/alloy/oauth-client-secret
chmod 0640 /etc/alloy/oauth-client-secret
usermod -aG adm,systemd-journal alloy
# Pasta dos backups (contrato backup.yml do repositorio grafana): produtores
# externos gravam <service>__<backup_id>.prom. Escrita para root e para o grupo
# alloy-backup (a conta do produtor entra nele); setgid mantem o grupo nos
# arquivos novos. Leitura para todos: o Alloy roda como alloy ou root.
getent group "$BACKUP_GROUP" >/dev/null || groupadd --system "$BACKUP_GROUP"
install -d -o root -g root -m 0755 "$TEXTFILE_DIR"
install -d -o root -g "$BACKUP_GROUP" -m 2775 "$BACKUP_TEXTFILE_DIR"
# Docker requer acesso aos cgroups protegidos por agentes de seguranca.
# O servico executa como root SOMENTE quando o modulo Docker estiver ativo.
# Nao adicionamos alloy ao grupo docker: o servico root nao precisa disso.
if [[ $use_docker == true ]]; then
  log 'Modulo Docker: Alloy executara como root (acesso a cgroups e docker.sock).'
else
  log 'Base Linux: Alloy executara como usuario alloy.'
fi

# Montar o estado desejado ANTES de alterar a configuracao instalada.
env_file=/etc/default/alloy
dropin_dir=/etc/systemd/system/alloy.service.d
dropin_file="$dropin_dir/zz-assessoriatech-execution.conf"
if [[ $use_docker == true ]]; then
  desired_user=root
  desired_group=root
else
  desired_user=alloy
  desired_group=alloy
fi

if [[ -f $env_file ]]; then
  cp -a -- "$env_file" "$stage/default.alloy"
else
  printf 'CONFIG_FILE="/etc/alloy"\nCUSTOM_ARGS=""\n' > "$stage/default.alloy"
fi
if grep -q '^CONFIG_FILE=' "$stage/default.alloy"; then
  sed -i 's|^CONFIG_FILE=.*|CONFIG_FILE="/etc/alloy"|' "$stage/default.alloy"
else
  printf '\nCONFIG_FILE="/etc/alloy"\n' >> "$stage/default.alloy"
fi
printf '[Service]\nUser=%s\nGroup=%s\n' "$desired_user" "$desired_group" > "$stage/execution.conf"

same_file() {
  [[ -f "$2" ]] && cmp -s -- "$1" "$2"
}
files_changed=false
for name in config.alloy docker.alloy backup.alloy; do
  if [[ -f "$stage/$name" ]]; then
    same_file "$stage/$name" "/etc/alloy/$name" || files_changed=true
  elif [[ -e "/etc/alloy/$name" || -L "/etc/alloy/$name" ]]; then
    files_changed=true
  fi
done
env_changed=false
same_file "$stage/default.alloy" "$env_file" || env_changed=true
dropin_changed=false
same_file "$stage/execution.conf" "$dropin_file" || dropin_changed=true
old_active=$(systemctl is-active alloy 2>/dev/null || true)
old_enabled=$(systemctl is-enabled alloy 2>/dev/null || true)
actual_user=$(systemctl show alloy --property=User --value)
actual_group=$(systemctl show alloy --property=Group --value)
identity_changed=false
if [[ $actual_user != "$desired_user" || $actual_group != "$desired_group" ]]; then
  identity_changed=true
fi

if [[ $files_changed == false && $env_changed == false &&
      $dropin_changed == false && $identity_changed == false &&
      $alloy_changed == false && $old_active == active && $old_enabled == enabled ]]; then
  log 'Nenhuma alteracao encontrada. Alloy ja esta ativo; nenhuma reinicializacao necessaria.'
  log "Versao: $(dpkg-query -W -f='${Version}' alloy). Modulos: Linux$( [[ $use_docker == true ]] && printf ' + Docker' || true ) + leitura de backups."
  exit 0
fi

log 'Aplicando apenas as alteracoes necessarias...'
stamp="$(date -u +%Y%m%dT%H%M%SZ)-$$"
backup=$(mktemp -d)
trap 'rm -rf -- "$stage" "$backup"' EXIT
for name in config.alloy docker.alloy backup.alloy; do
  [[ ! -f "/etc/alloy/$name" ]] || cp -a -- "/etc/alloy/$name" "$backup/$name"
done
[[ ! -f "$env_file" ]] || cp -a -- "$env_file" "$backup/default.alloy"
[[ ! -f "$dropin_file" ]] || cp -a -- "$dropin_file" "$backup/execution.conf"

rollback() {
  log 'Restaurando configuracao anterior...'
  for name in config.alloy docker.alloy backup.alloy; do
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
  reset_failed_alloy
  if [[ $old_active == active ]]; then
    systemctl restart alloy || log 'CRITICO: falha ao reiniciar configuracao restaurada.'
    restored=false
    for _ in {1..12}; do
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

if [[ $files_changed == true ]]; then
  for name in config.alloy docker.alloy backup.alloy; do
    if [[ -f "$stage/$name" ]]; then
      if ! same_file "$stage/$name" "/etc/alloy/$name"; then
        install -o root -g alloy -m 0640 "$stage/$name" "/etc/alloy/.$name.tmp"
        mv -f -- "/etc/alloy/.$name.tmp" "/etc/alloy/$name"
      fi
    else
      rm -f -- "/etc/alloy/$name"
    fi
  done
fi
if [[ $env_changed == true ]]; then
  install -o root -g root -m 0644 "$stage/default.alloy" "$env_file"
fi
if [[ $dropin_changed == true ]]; then
  install -d -o root -g root -m 0755 "$dropin_dir"
  install -o root -g root -m 0644 "$stage/execution.conf" "$dropin_file"
fi
if [[ $dropin_changed == true || $alloy_changed == true ]]; then
  systemctl daemon-reload
fi

# Apenas reiniciar ao mudar configuracao, usuario ou versao, ou se parado.
log "Habilitando e iniciando Alloy como $desired_user:$desired_group..."
reset_failed_alloy
if ! systemctl enable alloy || ! systemctl restart alloy; then
  journalctl -u alloy -n 30 --no-pager >&2 || true
  rollback
  fail 'Falha na inicializacao; configuracao anterior restaurada.'
fi
ready=false
for _ in {1..12}; do
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
  fail 'Alloy nao ficou pronto; configuracao anterior restaurada.'
fi

# Backups persistentes apenas quando houve alteracoes; nenhum backup vazio.
install -d -m 0700 /etc/alloy/backups
for name in config.alloy docker.alloy backup.alloy; do
  [[ ! -f "$backup/$name" ]] || cp -a -- "$backup/$name" "/etc/alloy/backups/$name.$stamp"
done
[[ ! -f "$backup/default.alloy" ]] || cp -a -- "$backup/default.alloy" "/etc/alloy/backups/default.alloy.$stamp"
[[ ! -f "$backup/execution.conf" ]] || cp -a -- "$backup/execution.conf" "/etc/alloy/backups/execution.conf.$stamp"

log "Alloy ativo e pronto como $desired_user:$desired_group."
log "Modulos: Linux$( [[ $use_docker == true ]] && printf ' + Docker' || true ) + leitura de backups ($BACKUP_TEXTFILE_DIR)"
systemctl --no-pager --full status alloy
