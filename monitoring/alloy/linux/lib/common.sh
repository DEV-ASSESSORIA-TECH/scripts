# shellcheck shell=bash
# shellcheck disable=SC2034  # constantes usadas pelos scripts que carregam esta lib
# Funcoes compartilhadas por alloy.sh e uninstall.sh: constantes, saida,
# confirmacoes e download dos arquivos do repositorio.

ALLOY_REPO_RAW=${ALLOY_REPO_RAW:-https://raw.githubusercontent.com/DEV-ASSESSORIA-TECH/scripts}
ALLOY_REMOTE_DIR=monitoring/alloy/linux
ALLOY_REF=${ALLOY_REF:-main}
# 1 quando executado a partir de um clone: nada e baixado.
ALLOY_LOCAL=${ALLOY_LOCAL:-0}

ETC_DIR=/etc/alloy
SECRET=$ETC_DIR/oauth-client-secret
ENV_FILE=/etc/default/alloy
DROPIN_DIR=/etc/systemd/system/alloy.service.d
DROPIN_FILE=$DROPIN_DIR/zz-assessoriatech-execution.conf
DATA_DIR=/var/lib/alloy
APT_SOURCE=/etc/apt/sources.list.d/grafana.list
APT_KEY=/etc/apt/keyrings/grafana.asc
READY_URL=http://127.0.0.1:12345/-/ready
# Links do diagnostico. Datasource por nome ou UID, como cadastrado no Grafana.
GRAFANA_URL=https://mon.assessoriatech.com/grafana
GRAFANA_DS_METRICS=Prometheus
GRAFANA_DS_LOGS=Loki

if [[ -t 1 ]]; then
  C_BOLD=$'\e[1m' C_OK=$'\e[32m' C_WARN=$'\e[33m' C_ERR=$'\e[31m' C_DIM=$'\e[2m' C_RESET=$'\e[0m'
else
  C_BOLD='' C_OK='' C_WARN='' C_ERR='' C_DIM='' C_RESET=''
fi

log() { printf '[Alloy] %s\n' "$*"; }
ok() { printf '[Alloy] %s%s%s\n' "$C_OK" "$*" "$C_RESET"; }
warn() { printf '[Alloy] %sAVISO:%s %s\n' "$C_WARN" "$C_RESET" "$*" >&2; }
fail() { printf '[Alloy] %sERRO:%s %s\n' "$C_ERR" "$C_RESET" "$*" >&2; exit 1; }

# confirm "Pergunta" [S|N]: retorna 0 para sim. O segundo argumento e o padrao.
confirm() {
  local default=${2:-S} hint='[S/n]' answer
  [[ $default == N ]] && hint='[s/N]'
  read -r -p "$1 $hint: " answer || return 1
  answer=${answer:-$default}
  [[ $answer =~ ^([sS]|[sS][iI][mM]|[yY]|[yY][eE][sS])$ ]]
}

validate_ref() {
  [[ $ALLOY_REF =~ ^[A-Za-z0-9][A-Za-z0-9._/-]*$ && $ALLOY_REF != *..* ]] ||
    fail "Referencia invalida: $ALLOY_REF"
}

# fetch DESTINO ARQUIVO...: baixa apenas os arquivos ausentes, todos na mesma
# chamada do curl (uma conexao). Em modo local, um arquivo ausente e erro.
fetch() {
  local dest=$1 name args=()
  shift
  for name in "$@"; do
    [[ -s $dest/$name ]] && continue
    if [[ $ALLOY_LOCAL == 1 ]]; then
      warn "Arquivo ausente no repositorio local: $name"
      return 1
    fi
    mkdir -p -- "$(dirname -- "$dest/$name")"
    args+=(-o "$dest/$name" "$ALLOY_REPO_RAW/$ALLOY_REF/$ALLOY_REMOTE_DIR/$name")
  done
  ((${#args[@]})) || return 0
  if ! curl -fsSL --proto '=https' --fail-early --connect-timeout 10 --retry 2 "${args[@]}"; then
    warn "Falha ao baixar arquivos do repositorio (ref $ALLOY_REF)."
    return 1
  fi
  for name in "$@"; do
    [[ -s $dest/$name ]] || { warn "Download vazio: $name"; return 1; }
  done
}
