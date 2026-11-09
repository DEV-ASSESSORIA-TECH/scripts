#!/usr/bin/env bash
# Heartbeat do host: estado local do Alloy para o Loki e batida no Uptime Kuma.
#
# Executado a cada minuto pelo alloy-heartbeat.timer (alloy-heartbeat.service,
# usuario dinamico, sem root), criado pelo heartbeat-setup.sh (menu [9]).
# Nao depende do processo do Alloy:
#
#   1. Le o estado local: servico, /-/ready, /-/healthy e o /metrics do Alloy
#      (atraso do remote_write e contadores do loki.write).
#   2. Envia uma linha logfmt ao Loki (job alloy-heartbeat), com a credencial
#      OAuth2 do Alloy. Sem credencial, esta etapa e pulada.
#   3. Faz o push no Uptime Kuma (sempre status=up), com um resumo curto no msg.
#
# Contrato do stream: grafana-dashboards, contracts/loki/heartbeat.yml.
# Resultado da ultima execucao em $STATE_DIRECTORY/last; uma linha por
# execucao no journal. URL do Kuma, credencial e token nunca aparecem na linha
# de comando (curl le de stdin) nem no log.
# Codigo de saida: 0 quando o Kuma confirmou a batida, 1 caso contrario.
#
# Entradas (o systemd fornece as duas primeiras):
#   CREDENTIALS_DIRECTORY  kuma-url e oauth-client-secret (LoadCredential=)
#   STATE_DIRECTORY        estado (last, token)
#   HEARTBEAT_KUMA_URL     URL a testar no lugar da gravada (configuracao)
#   HEARTBEAT_SECRET_FILE  credencial fora do systemd (configuracao)
#   HEARTBEAT_SHOW=1       mostra o resultado no terminal
set -uo pipefail
umask 077

CLIENT_ID=1T4SNZ8iDuvM18ZIB9fSc109ZZVglsXBtLxeU4ng
TOKEN_URL=https://auth.assessoriatech.com/application/o/token/
LOKI_URL=https://mon.assessoriatech.com/loki/api/v1/push
ALLOY_HTTP=http://127.0.0.1:12345
USER_AGENT=AssessoriaTech-Alloy-Heartbeat/1.0
# Acima disso (segundos sem amostra enviada), o Alloy e considerado degradado.
LAG_LIMIT=300

creds=${CREDENTIALS_DIRECTORY:-}
state_dir=${STATE_DIRECTORY:-/var/lib/alloy-heartbeat}
secret_file=${HEARTBEAT_SECRET_FILE:-${creds:+$creds/oauth-client-secret}}
url_file=${creds:+$creds/kuma-url}
token_file=$state_dir/token
last_file=$state_dir/last
work=$(mktemp -d) || exit 1
trap 'rm -rf -- "$work"' EXIT

# local_get CAMINHO: corpo em $work/body, codigo HTTP na saida (000 = sem resposta).
local_get() {
  curl -s --noproxy '*' --max-time 3 -o "$work/body" -w '%{http_code}' "$ALLOY_HTTP$1" 2>/dev/null || true
}

# ------------------------------------------------------------- estado local
declare -a keys=() values=()
put() { keys+=("$1"); values+=("$2"); }
get() {
  local i
  for i in "${!keys[@]}"; do [[ ${keys[$i]} == "$1" ]] && { printf '%s' "${values[$i]}"; return 0; }; done
  return 1
}

collect_state() {
  local load active version code healthy=unknown lag='' list
  load=$(systemctl show alloy.service --property=LoadState --value 2>/dev/null || true)
  if [[ $load != loaded ]]; then
    put alloy ausente; put service absent
    return
  fi
  version=$(dpkg-query -W -f='${Version}' alloy 2>/dev/null || true)
  [[ -n $version ]] && version="v${version#v}"
  active=$(systemctl is-active alloy.service 2>/dev/null || true)
  if [[ $active != active ]]; then
    put alloy parado; put service stopped
    [[ -n $version ]] && put version "$version"
    return
  fi

  local -a fields=(service running)
  code=$(local_get /-/ready)
  local ready=0
  [[ $code == 200 ]] && ready=1
  fields+=(ready "$ready")

  code=$(local_get /-/healthy)
  if [[ $code == 200 ]]; then
    healthy=1; fields+=(healthy 1)
  elif [[ $code == 500 ]]; then
    healthy=0; fields+=(healthy 0)
    list=$(tr '\n' ' ' <"$work/body" | sed -e 's/^.*unhealthy components:[[:space:]]*//' \
      -e 's/[^A-Za-z0-9_.,\/ -]//g' -e 's/[[:space:]]*,[[:space:]]*/,/g' -e 's/^ *//; s/ *$//' | cut -c1-200)
    [[ -n $list ]] && fields+=(unhealthy "$list")
  fi

  code=$(local_get /metrics)
  if [[ $code == 200 ]]; then
    local name value
    while IFS='=' read -r name value; do
      [[ -n $name ]] || continue
      fields+=("$name" "$value")
      [[ $name == metrics_lag_s ]] && lag=$value
    done < <(awk -v now="$(date +%s)" '
      /^prometheus_remote_storage_queue_highest_sent_timestamp_seconds[{ ]/ { v = $NF + 0; if (v > hs) hs = v }
      /^prometheus_remote_storage_samples_failed_total[{ ]/ { sf += $NF; f1 = 1 }
      /^loki_write_sent_entries_total[{ ]/ { ls += $NF; f2 = 1 }
      /^loki_write_dropped_entries_total[{ ]/ { ld += $NF; f3 = 1 }
      END {
        if (hs > 0) { lag = now - hs; if (lag < 0) lag = 0; printf "metrics_lag_s=%.0f\n", lag }
        if (f1) printf "samples_failed=%.0f\n", sf
        if (f2) printf "logs_sent=%.0f\n", ls
        if (f3) printf "logs_dropped=%.0f\n", ld
      }' "$work/body")
  fi
  [[ -n $version ]] && fields+=(version "$version")

  local state=ok
  if [[ $ready != 1 ]]; then
    state=nao_pronto
  elif [[ $healthy == 0 ]] || { [[ -n $lag ]] && ((lag > LAG_LIMIT)); }; then
    state=degradado
  fi
  put alloy "$state"
  local i
  for ((i = 0; i < ${#fields[@]}; i += 2)); do put "${fields[$i]}" "${fields[$((i + 1))]}"; done
}

logfmt() {
  local i out='' value
  for i in "${!keys[@]}"; do
    value=${values[$i]}
    if [[ $value =~ ^[A-Za-z0-9_.:/-]+$ ]]; then
      out+="${keys[$i]}=$value "
    else
      out+="${keys[$i]}=\"${value//[\"\\]/}\" "
    fi
  done
  printf '%s' "${out% }"
}

# ------------------------------------------------------------------- Loki

# Token OAuth2 reaproveitado ate 60s antes de expirar ($state_dir/token, 0600).
# Saida: token em $work/token; retorno 0, ou codigo/motivo em stdout.
get_token() {
  local fresh=$1 now expires token code body
  now=$(date +%s)
  if [[ $fresh != 1 && -s $token_file ]]; then
    { read -r expires; read -r token; } <"$token_file" || true
    if [[ ${expires:-0} =~ ^[0-9]+$ && -n ${token:-} ]] && ((expires > now + 60)); then
      printf '%s' "$token" >"$work/token"
      return 0
    fi
  fi
  # client_secret em Base64: so + / = precisam de escape. Corpo via arquivo,
  # nunca na linha de comando.
  local secret
  secret=$(tr -d '\r\n' <"$secret_file")
  secret=${secret//+/%2B}; secret=${secret//\//%2F}; secret=${secret//=/%3D}
  printf 'grant_type=client_credentials&client_id=%s&scope=profile&client_secret=%s' "$CLIENT_ID" "$secret" >"$work/form"
  secret=''
  code=$(curl -s --max-time 10 -A "$USER_AGENT" -o "$work/token.json" -w '%{http_code}' \
    -H 'Content-Type: application/x-www-form-urlencoded' --data-binary @"$work/form" "$TOKEN_URL" 2>/dev/null) || code=000
  rm -f -- "$work/form"
  [[ $code == 000 ]] && { printf 'token_sem_resposta'; return 1; }
  [[ $code == 200 ]] || { printf 'token_%s' "$code"; return 1; }
  body=$(tr -d '\n' <"$work/token.json")
  token=$(sed -n 's/.*"access_token"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' <<<"$body")
  expires=$(sed -n 's/.*"expires_in"[[:space:]]*:[[:space:]]*\([0-9][0-9]*\).*/\1/p' <<<"$body")
  rm -f -- "$work/token.json"
  [[ -n $token ]] || { printf 'token_invalido'; return 1; }
  printf '%s' "$token" >"$work/token"
  if [[ -d $state_dir ]]; then
    printf '%s\n%s\n' "$((now + ${expires:-300}))" "$token" >"$token_file.tmp" && mv -f -- "$token_file.tmp" "$token_file"
  fi
  return 0
}

send_loki() {
  local host=$1 line=$2 escaped fresh reason code
  [[ -n $secret_file && -r $secret_file && -s $secret_file ]] || { printf 'sem_credencial'; return; }
  escaped=${line//\\/\\\\}
  escaped=${escaped//\"/\\\"}
  printf '{"streams":[{"stream":{"job":"alloy-heartbeat","host":"%s","os":"linux"},"values":[["%s","%s"]]}]}' \
    "$host" "$(date +%s%N)" "$escaped" >"$work/payload"
  for fresh in 0 1; do
    reason=$(get_token "$fresh") || { printf '%s' "$reason"; return; }
    code=$(curl -s --max-time 10 -A "$USER_AGENT" -o /dev/null -w '%{http_code}' -K - \
      --data-binary @"$work/payload" 2>/dev/null <<EOF
url = "$LOKI_URL"
header = "Content-Type: application/json"
header = "Authorization: Bearer $(<"$work/token")"
EOF
    ) || code=000
    rm -f -- "$work/token"
    # 401 com token do cache: pede um novo e tenta uma vez mais.
    [[ $code == 401 && $fresh == 0 ]] && continue
    [[ $code == 000 ]] && code=sem_resposta
    printf '%s' "$code"
    return
  done
}

# ------------------------------------------------------------------- Kuma

urlencode() {
  local text=$1 out='' c i
  for ((i = 0; i < ${#text}; i++)); do
    c=${text:i:1}
    case "$c" in
      [A-Za-z0-9._~-]) out+=$c ;;
      *) out+=$(printf '%%%02X' "'$c") ;;
    esac
  done
  printf '%s' "$out"
}

# Saida: codigo HTTP ('200', '404'...), 'sem_resposta', 'resposta_invalida'
# (200 sem {"ok":true}, ex. pagina da Cloudflare) ou 'erro: ...'.
send_kuma() {
  local msg=$1 url code
  if [[ -n ${HEARTBEAT_KUMA_URL:-} ]]; then
    url=$HEARTBEAT_KUMA_URL
  elif [[ -n $url_file && -r $url_file ]]; then
    url=$(<"$url_file")
  else
    printf 'erro: URL de push ausente'
    return
  fi
  url=${url%%[?#]*}
  url=${url//[[:space:]]/}
  if [[ ! $url =~ ^https://[A-Za-z0-9.-]+(:[0-9]+)?(/[A-Za-z0-9._~-]+)*/api/push/[A-Za-z0-9_-]{8,128}$ ]]; then
    printf 'erro: URL de push invalida'
    return
  fi
  code=$(curl -s --max-time 10 -A "$USER_AGENT" -o "$work/kuma" -w '%{http_code}' -K - 2>/dev/null <<EOF
url = "$url?status=up&msg=$(urlencode "$msg")&ping="
EOF
  ) || code=000
  if [[ $code == 000 ]]; then
    printf 'sem_resposta'
  elif [[ $code == 200 ]] && ! grep -Eq '"ok"[[:space:]]*:[[:space:]]*true' "$work/kuma"; then
    printf 'resposta_invalida'
  else
    printf '%s' "$code"
  fi
}

# ------------------------------------------------------------------ execucao
collect_state
line=$(logfmt)
host=$(cat /proc/sys/kernel/hostname 2>/dev/null || hostname)
loki=$(send_loki "$host" "$line")

summary="alloy=$(get alloy)"
lag=$(get metrics_lag_s) && summary+=" lag=${lag}s"
unhealthy=$(get unhealthy) && summary+=" unhealthy=$unhealthy"
summary+=" loki=$loki"
version=$(get version) && summary+=" $version"
kuma=$(send_kuma "$summary")

if [[ -d $state_dir ]]; then
  {
    printf 'time=%s\n' "$(date +%s)"
    printf 'kuma=%s\n' "$kuma"
    printf 'loki=%s\n' "$loki"
    printf 'alloy=%s\n' "$(get alloy)"
    printf 'line=%s\n' "$line"
  } >"$last_file.tmp" && mv -f -- "$last_file.tmp" "$last_file"
fi
printf 'kuma=%s loki=%s  %s\n' "$kuma" "$loki" "$line"

if [[ ${HEARTBEAT_SHOW:-0} == 1 ]]; then
  printf '  Alloy        %s\n  Loki         %s\n  Uptime Kuma  %s\n' "$line" "$loki" "$kuma"
fi
[[ $kuma == 200 ]]
