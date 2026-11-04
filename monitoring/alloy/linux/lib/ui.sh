# shellcheck shell=bash
# shellcheck disable=SC2034  # UI_KEY e lida pelo menu do alloy.sh
# Primitivas de interface do terminal: telas, secoes, marcadores e teclas.
# Requer lib/common.sh (cores). Largura fixa para caber em 80 colunas.

UI_WIDTH=62

ui_clear() {
  [[ -t 1 ]] && printf '\e[H\e[2J'
  return 0
}

ui_line() { printf '%*s' "$2" '' | tr ' ' "$1"; }
ui_rule() { printf ' %s\n' "$(ui_line "${1:--}" "$UI_WIDTH")"; }

# ui_title ESQUERDA DIREITA: titulo em negrito, texto alinhado a direita.
ui_title() {
  local gap=$((UI_WIDTH - 2 - ${#1} - ${#2}))
  ((gap < 1)) && gap=1
  printf '  %s%s%s%*s%s\n' "$C_BOLD" "$1" "$C_RESET" "$gap" '' "$2"
}

ui_banner() {
  ui_rule '='
  ui_title 'GRAFANA ALLOY' "$1"
  ui_rule '='
}

# == TITULO =========================================
ui_section() {
  local text=" $1 "
  printf '\n %s==%s%s%s\n' "$C_BOLD" "$text" "$(ui_line '=' $((UI_WIDTH - 2 - ${#text})))" "$C_RESET"
}

ui_badge() {
  case "$1" in
    ok) printf '%s[ OK ]%s' "$C_OK" "$C_RESET" ;;
    warn) printf '%s[ !! ]%s' "$C_WARN" "$C_RESET" ;;
    err) printf '%s[ !! ]%s' "$C_ERR" "$C_RESET" ;;
    off) printf '%s[ -- ]%s' "$C_DIM" "$C_RESET" ;;
    *) printf '      ' ;;
  esac
}

# ui_row ROTULO MARCADOR TEXTO: linha alinhada de estado.
ui_row() { printf '  %-12s %s  %s\n' "$1" "$(ui_badge "$2")" "$3"; }

# ui_cell TEXTO COR LARGURA: celula sem quebra; a cor nao conta na largura.
ui_cell() { printf '%s%-*s%s' "$2" "$3" "$1" "$C_RESET"; }

# ui_columns ESQ COR_ESQ DIR COR_DIR: linha do menu em duas colunas.
ui_columns() {
  printf '  '
  ui_cell "$1" "$2" 30
  printf '%s%s%s\n' "$4" "$3" "$C_RESET"
}

# Le uma tecla, sem Enter, em UI_KEY. Enter -> vazio; Esc e setas -> ESC.
ui_readkey() {
  local key='' next=''
  IFS= read -rsn1 key || return 1
  if [[ $key == $'\e' ]]; then
    # Setas chegam como ESC [ X ou ESC O X: descartar so esses dois bytes.
    IFS= read -rsn1 -t 0.05 next || true
    if [[ $next == '[' || $next == O ]]; then IFS= read -rsn1 -t 0.05 next || true; fi
    key=ESC
  fi
  UI_KEY=$key
}

ui_pause() {
  printf '\n  %sTecle algo para voltar ao menu...%s' "$C_DIM" "$C_RESET"
  ui_readkey || true
  printf '\n'
}
