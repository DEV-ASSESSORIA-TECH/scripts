#!/usr/bin/env bash
# Ponto de entrada unico do Grafana Alloy no Linux (Debian/Ubuntu).
# Sem comando: primeira instalacao guiada ou menu interativo.
# Baixa sob demanda, do mesmo ref, apenas os arquivos de cada operacao.
set -euo pipefail

usage() {
  cat <<'EOF'
Uso: sudo bash alloy.sh [comando] [opcoes] [--ref REF]

Sem comando, abre o menu (ou a primeira instalacao guiada).

Comandos:
  install [--modules docker|none] [--upgrade]
               credencial (se ausente) + instalacao/reaplicacao
  credentials  apenas o setup da credencial
  check        testa a credencial gravada (OAuth2 + Loki), sem alterar nada
  rotate       substitui a credencial e reinicia o Alloy
  modules docker|none
               ativa ou desativa o modulo Docker
  upgrade      atualiza o pacote Alloy
  status       diagnostico (servico, logs, conectividade, consultas)
  uninstall [--yes]
               remove o Alloy, mantendo credencial e configuracao
  purge [--yes]
               limpeza completa (inclui a credencial)
  menu         abre o menu mesmo na primeira execucao

Opcoes globais:
  --ref REF    branch, tag ou commit do repositorio (padrao: main)
  -h, --help   esta ajuda
EOF
}

# ---------------------------------------------------------------- argumentos
command=''
cmd_args=()
ref_arg=''
while (($#)); do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    --ref) (($# >= 2)) || { printf 'Falta valor para --ref.\n' >&2; exit 1; }; ref_arg=$2; shift 2; continue ;;
    --ref=*) ref_arg=${1#*=} ;;
    -*) cmd_args+=("$1") ;;
    *) if [[ -z $command ]]; then command=$1; else cmd_args+=("$1"); fi ;;
  esac
  shift
done
[[ -n $ref_arg ]] && export ALLOY_REF=$ref_arg
export ALLOY_REF=${ALLOY_REF:-main}

if [[ $EUID -ne 0 ]]; then
  printf '[Alloy] ERRO: execute com sudo.\n' >&2
  exit 1
fi

# ---------------------------------------------------------------- bootstrap
# Clone do repositorio: usa os arquivos locais. Caso contrario (arquivo
# baixado sozinho), trabalha numa pasta temporaria propria.
self_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
if [[ -f $self_dir/install.sh && -f $self_dir/lib/common.sh ]]; then
  export ALLOY_LOCAL=1
  src=$self_dir
else
  export ALLOY_LOCAL=0
  src=$(mktemp -d)
  trap 'rm -rf -- "$src"' EXIT
  [[ $ALLOY_REF =~ ^[A-Za-z0-9][A-Za-z0-9._/-]*$ && $ALLOY_REF != *..* ]] ||
    { printf '[Alloy] ERRO: referencia invalida: %s\n' "$ALLOY_REF" >&2; exit 1; }
  raw="https://raw.githubusercontent.com/DEV-ASSESSORIA-TECH/scripts/$ALLOY_REF/monitoring/alloy/linux"
  mkdir -p -- "$src/lib"
  curl -fsSL --proto '=https' --fail-early --connect-timeout 10 --retry 2 \
    -o "$src/lib/common.sh" "$raw/lib/common.sh" \
    -o "$src/lib/state.sh" "$raw/lib/state.sh" ||
    { printf '[Alloy] ERRO: falha ao baixar as bibliotecas (ref %s).\n' "$ALLOY_REF" >&2; exit 1; }
fi
# shellcheck source=lib/common.sh
source "$src/lib/common.sh"
# shellcheck source=lib/state.sh
source "$src/lib/state.sh"

command -v apt-get >/dev/null || fail 'APT obrigatorio (Debian/Ubuntu).'
command -v python3 >/dev/null || fail 'python3 ausente; instale antes de executar.'

# ---------------------------------------------------------------- operacoes
# Cada operacao retorna 0/1 sem encerrar o menu. Os scripts filhos rodam em
# processos proprios, com seus proprios controles de erro e rollback.

run_credentials() {
  fetch "$src" setup-credentials.py || return 1
  python3 "$src/setup-credentials.py" "$@"
}

run_installer() {
  fetch "$src" install.sh config.alloy || return 1
  bash "$src/install.sh" "$@"
}

do_install() {
  if ! credential_present; then
    # Uma unica chamada de download para as duas etapas.
    fetch "$src" setup-credentials.py install.sh config.alloy || return 1
    log "${C_BOLD}Etapa 1/2 - Credencial${C_RESET}"
    run_credentials || return 1
    log "${C_BOLD}Etapa 2/2 - Instalacao${C_RESET}"
  fi
  run_installer "$@"
}

do_setup_credentials() {
  if credential_present; then
    warn 'Credencial ja existe. Use "rotate" para substituir.'
    return 1
  fi
  run_credentials
}

do_check() {
  credential_present || { warn 'Nenhuma credencial gravada.'; return 1; }
  run_credentials --check
}

do_rotate() {
  credential_present || { warn 'Nenhuma credencial gravada; use o setup de credencial.'; return 1; }
  run_credentials --rotate || return 1
  if alloy_installed && service_active; then
    log 'Reiniciando o Alloy para carregar a nova credencial...'
    systemctl restart alloy || return 1
    if ! wait_ready; then
      warn 'Alloy nao ficou pronto apos a rotacao. Consulte o diagnostico.'
      return 1
    fi
    ok 'Alloy pronto com a nova credencial.'
  fi
}

do_modules() {
  case "${1:-}" in
    docker|none) ;;
    *) warn 'Use: modules docker|none'; return 1 ;;
  esac
  credential_present || { warn 'Credencial ausente; execute a instalacao primeiro.'; return 1; }
  run_installer --modules "$1"
}

do_upgrade() {
  credential_present || { warn 'Credencial ausente; execute a instalacao primeiro.'; return 1; }
  run_installer --upgrade
}

do_uninstall() {
  fetch "$src" uninstall.sh || return 1
  bash "$src/uninstall.sh" "$@"
}

# ---------------------------------------------------------------- interativo
need_tty() { [[ -t 0 ]] || fail 'Sem terminal interativo: informe um comando (veja --help).'; }

first_install() {
  printf '\n %sAlloy - primeira instalacao em %s%s\n' "$C_BOLD" "$(host_name)" "$C_RESET"
  printf ' 1) Setup da credencial: conta alloy-<hostname> + senha de aplicativo,\n'
  printf '    validadas com OAuth2 e Loki antes de gravar.\n'
  printf ' 2) Instalacao do Alloy e aplicacao da configuracao.\n\n'
  confirm 'Continuar?' || { log 'Cancelado; nada foi alterado.'; return 0; }
  do_install || return 1
  log 'Para gerenciar este servidor depois, execute o mesmo comando: o menu sera exibido.'
}

run_action() {
  printf '\n'
  if "$@"; then
    ok 'Concluido.'
  else
    warn 'A operacao nao foi concluida.'
  fi
}

pause() { read -r -p $'\nEnter para voltar ao menu...' _ || true; }

menu() {
  local choice default docker_label docker_target cred_label
  while :; do
    print_header
    default=''
    if ! alloy_installed || ! service_active; then default=1; fi
    if docker_module; then
      docker_label='Desativar modulo Docker'; docker_target=none
    else
      docker_label='Ativar modulo Docker'; docker_target=docker
      docker_available || docker_label+=" ${C_DIM}(Docker nao detectado)${C_RESET}"
    fi
    if credential_present; then cred_label='Rotacionar credencial'; else cred_label='Configurar credencial'; fi

    printf ' 1) Instalar / reaplicar configuracao%s\n' "${default:+ ${C_OK}(recomendado)${C_RESET}}"
    printf ' 2) %s\n' "$docker_label"
    printf ' 3) Atualizar o Alloy\n'
    printf ' 4) Testar credencial (sem gravar)\n'
    printf ' 5) %s\n' "$cred_label"
    printf ' 6) Diagnostico\n'
    printf ' 7) Desinstalar (mantem credencial e configuracao)\n'
    printf ' 8) Limpeza completa\n'
    printf ' 0) Sair\n\n'
    read -r -p "Opcao${default:+ [$default]}: " choice || { printf '\n'; return 0; }
    choice=${choice:-$default}
    case "$choice" in
      1) run_action do_install ;;
      2) run_action do_modules "$docker_target" ;;
      3) run_action do_upgrade ;;
      4) run_action do_check ;;
      5) if credential_present; then run_action do_rotate; else run_action do_setup_credentials; fi ;;
      6) printf '\n'; diagnose ;;
      7) run_action do_uninstall ;;
      8) run_action do_uninstall --purge ;;
      0|q|Q|sair) return 0 ;;
      '') continue ;;
      *) warn "Opcao invalida: $choice"; continue ;;
    esac
    pause
  done
}

# ---------------------------------------------------------------- despacho
case "$command" in
  '')
    need_tty
    if first_run; then first_install; else menu; fi ;;
  menu) need_tty; menu ;;
  install) do_install "${cmd_args[@]}" ;;
  credentials) do_setup_credentials ;;
  check) do_check ;;
  rotate) do_rotate ;;
  modules) do_modules "${cmd_args[@]}" ;;
  upgrade) do_upgrade ;;
  status) diagnose ;;
  uninstall) do_uninstall "${cmd_args[@]}" ;;
  purge) do_uninstall --purge "${cmd_args[@]}" ;;
  *) usage >&2; fail "Comando desconhecido: $command" ;;
esac
