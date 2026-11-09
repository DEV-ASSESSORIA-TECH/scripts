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
  heartbeat [--url URL]
               configura o heartbeat (Uptime Kuma Push + Loki)
  heartbeat-test
               executa o heartbeat agora e mostra o resultado
  heartbeat-remove [--yes]
               remove o heartbeat
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
    --url) (($# >= 2)) || { printf 'Falta valor para --url.\n' >&2; exit 1; }; cmd_args+=(--url "$2"); shift 2; continue ;;
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
    -o "$src/lib/state.sh" "$raw/lib/state.sh" \
    -o "$src/lib/ui.sh" "$raw/lib/ui.sh" ||
    { printf '[Alloy] ERRO: falha ao baixar as bibliotecas (ref %s).\n' "$ALLOY_REF" >&2; exit 1; }
fi
# shellcheck source=lib/common.sh
source "$src/lib/common.sh"
# shellcheck source=lib/ui.sh
source "$src/lib/ui.sh"
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
    ui_section 'ETAPA 1/2 - CREDENCIAL'
    run_credentials || return 1
    ui_section 'ETAPA 2/2 - INSTALACAO'
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

# Heartbeat opcional: nunca sugerido na instalacao, so pelo menu [9] ou comando.
do_heartbeat() {
  fetch "$src" heartbeat-setup.sh heartbeat.py || return 1
  bash "$src/heartbeat-setup.sh" "$@"
}

# ---------------------------------------------------------------- interativo
need_tty() { [[ -t 0 ]] || fail 'Sem terminal interativo: informe um comando (veja --help).'; }

first_install() {
  ui_clear
  ui_banner "$(host_name)"
  printf '  Primeira instalacao neste servidor.\n\n'
  printf '  %s[1/2] Credencial%s   conta alloy-<hostname> + senha de aplicativo,\n' "$C_BOLD" "$C_RESET"
  printf '                     validada (OAuth2 + Loki) antes de gravar\n'
  printf '  %s[2/2] Instalacao%s   Alloy + configuracao, com validacao e rollback\n\n' "$C_BOLD" "$C_RESET"
  confirm '  Continuar?' || { log 'Cancelado; nada foi alterado.'; return 0; }
  do_install || return 1
  printf '\n'
  LAST_STATUS=ok LAST_ACTION="Primeira instalacao - concluida ($(date +%H:%M))"
  print_header
  printf '  Para gerenciar este servidor depois, execute o mesmo comando.\n'
}

# run_screen TITULO FUNCAO [ARGS...]: tela propria, resultado e "ultima acao".
run_screen() {
  local title=$1
  shift
  ui_clear
  ui_section "$(tr '[:lower:]' '[:upper:]' <<<"$title")"
  printf '\n'
  if "$@"; then
    LAST_STATUS=ok LAST_ACTION="$title - concluido ($(date +%H:%M))"
    printf '\n  %s Concluido.\n' "$(ui_badge ok)"
  else
    LAST_STATUS=err LAST_ACTION="$title - falhou ($(date +%H:%M))"
    printf '\n  %s A operacao nao foi concluida.\n' "$(ui_badge err)"
  fi
  ui_pause
}

view_screen() {
  ui_clear
  ui_banner "$(host_name)"
  "$@"
  ui_pause
}

heartbeat_menu() {
  while heartbeat_configured; do
    ui_clear
    print_header
    ui_columns 'HEARTBEAT' "$C_BOLD" '' ''
    ui_columns ' [1] Testar agora' '' ' [3] Remover' "$C_ERR"
    ui_columns ' [2] Reconfigurar' '' '' ''
    ui_rule -
    printf '  Tecle a opcao (0 volta): '
    ui_readkey || { printf '\n'; return 0; }
    [[ $UI_KEY == ESC ]] || printf '%s' "$UI_KEY"
    printf '\n'
    case "$UI_KEY" in
      1) run_screen 'Testar heartbeat' do_heartbeat --test ;;
      2) run_screen 'Reconfigurar heartbeat' do_heartbeat ;;
      3) run_screen 'Remover heartbeat' do_heartbeat --remove ;;
      0|q|Q|ESC) return 0 ;;
      *) ;;
    esac
  done
}

menu() {
  local default label1 label2 color2 docker_target label5 label9 prompt
  while :; do
    default=''
    if ! alloy_installed || ! service_active; then default=1; fi
    if alloy_installed; then label1='Reaplicar configuracao'; else label1='Instalar Alloy'; fi
    color2=''
    if docker_module; then
      label2='Desativar Docker'; docker_target=none
    else
      label2='Ativar Docker'; docker_target=docker
      if ! docker_available; then label2+=' (ausente)'; color2=$C_DIM; fi
    fi
    if credential_present; then label5='Rotacionar'; else label5='Configurar'; fi

    ui_clear
    print_header
    ui_columns 'INSTALACAO' "$C_BOLD" 'CREDENCIAL' "$C_BOLD"
    ui_columns " [1] $label1" "${default:+$C_OK}" ' [4] Testar' ''
    ui_columns " [2] $label2" "$color2" " [5] $label5" ''
    ui_columns ' [3] Atualizar Alloy' '' '' ''
    printf '\n'
    ui_columns 'DIAGNOSTICO' "$C_BOLD" 'REMOCAO' "$C_BOLD"
    if heartbeat_configured; then label9='Heartbeat'; else label9='Configurar heartbeat'; fi
    ui_columns ' [6] Ver diagnostico' '' ' [7] Desinstalar' "$C_ERR"
    ui_columns " [9] $label9" '' ' [8] Limpeza completa' "$C_ERR"
    ui_rule -
    prompt='Tecle a opcao (0 sai)'
    [[ -n $default ]] && prompt="Tecle a opcao (Enter = $default, 0 sai)"
    printf '  %s: ' "$prompt"
    ui_readkey || { printf '\n'; return 0; }
    [[ -z $UI_KEY ]] && UI_KEY=$default
    [[ $UI_KEY == ESC ]] || printf '%s' "$UI_KEY"
    printf '\n'
    case "$UI_KEY" in
      1) run_screen "$label1" do_install ;;
      2) run_screen "$label2" do_modules "$docker_target" ;;
      3) run_screen 'Atualizar Alloy' do_upgrade ;;
      4) run_screen 'Testar credencial' do_check ;;
      5) if credential_present; then
           run_screen 'Rotacionar credencial' do_rotate
         else
           run_screen 'Configurar credencial' do_setup_credentials
         fi ;;
      6) view_screen diagnose ;;
      7) run_screen 'Desinstalar' do_uninstall ;;
      8) run_screen 'Limpeza completa' do_uninstall --purge ;;
      9) if heartbeat_configured; then
           heartbeat_menu
         else
           run_screen 'Configurar heartbeat' do_heartbeat
         fi ;;
      0|q|Q)
        ui_clear
        print_summary
        printf '  Para abrir o menu de novo, execute o mesmo comando.\n'
        return 0 ;;
      *) ;;
    esac
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
  status) ui_banner "$(host_name)"; print_summary; diagnose ;;
  uninstall) do_uninstall "${cmd_args[@]}" ;;
  purge) do_uninstall --purge "${cmd_args[@]}" ;;
  heartbeat) do_heartbeat "${cmd_args[@]}" ;;
  heartbeat-test) do_heartbeat --test ;;
  heartbeat-remove) do_heartbeat --remove "${cmd_args[@]}" ;;
  *) usage >&2; fail "Comando desconhecido: $command" ;;
esac
