#!/usr/bin/env bash
# PONTE TEMPORARIA: o alloyctl mudou para DEV-ASSESSORIA-TECH/alloy.
#
# Este arquivo atende quem ainda chega pelo endereco antigo:
#   - o comando antigo do README (raw .../scripts/main/monitoring/alloy/...);
#   - o alloyctl ja instalado, que se atualiza por este caminho e baixa
#     alloy.sh + lib/*.sh (os lib/ daqui sao vazios de proposito).
# Nos dois casos, baixa o ponto de entrada do repositorio novo e o executa: ele
# instala o alloyctl da ultima release (canal stable) por cima de /opt/alloyctl
# e segue com o mesmo comando. --ref e --no-update sao descartados (as refs
# deste repositorio nao existem no novo).
set -euo pipefail

NEW_ENTRY=https://raw.githubusercontent.com/DEV-ASSESSORIA-TECH/alloy/main/linux/alloy.sh

args=()
while (($#)); do
  case "$1" in
    --ref) shift; (($#)) && shift ;;
    --ref=*|--no-update) shift ;;
    *) args+=("$1"); shift ;;
  esac
done
unset ALLOY_REF

printf '[alloyctl] O alloyctl mudou para github.com/DEV-ASSESSORIA-TECH/alloy; migrando...\n'
dir=$(mktemp -d)
trap 'rm -rf -- "$dir"' EXIT
if ! curl -fsSL --proto '=https' --connect-timeout 10 --retry 2 -A 'AssessoriaTech-Alloy-Installer/1.0' \
    -o "$dir/alloy.sh" "$NEW_ENTRY"; then
  printf '[alloyctl] ERRO: falha ao baixar %s\n' "$NEW_ENTRY" >&2
  exit 1
fi
bash "$dir/alloy.sh" "${args[@]}"
