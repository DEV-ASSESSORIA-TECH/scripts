#!/usr/bin/env python3
"""Heartbeat do host: estado local do Alloy para o Loki e batida no Uptime Kuma.

Executado a cada minuto pelo alloy-heartbeat.timer (alloy-heartbeat.service,
usuario dinamico sem root, no grupo alloy para ler a credencial), criado pelo
heartbeat-setup.sh (menu [9]). Nao depende do processo do Alloy:

  1. Le o estado local: servico, /-/ready, /-/healthy e o /metrics do Alloy
     (atraso do remote_write e contadores do loki.write).
  2. Envia uma linha logfmt ao Loki (job alloy-heartbeat), com a credencial
     OAuth2 do Alloy. Sem credencial legivel, esta etapa e pulada.
  3. Faz o push no Uptime Kuma (sempre status=up), com um resumo curto no msg.

Contrato do stream: grafana-dashboards, contracts/loki/heartbeat.yml.
Resultado da ultima execucao em $STATE_DIRECTORY/last (campo=valor); uma
linha por execucao no journal. URL do Kuma, credencial e token ficam dentro
do processo: nunca vao para a linha de comando nem para o log.
Codigo de saida: 0 quando o Kuma confirmou a batida, 1 caso contrario.

Entradas:
  CREDENTIALS_DIRECTORY  kuma-url (LoadCredential= do systemd)
  STATE_DIRECTORY        estado (last, token); o systemd fornece
  HEARTBEAT_KUMA_URL     URL a testar no lugar da gravada (configuracao)
  HEARTBEAT_SECRET_FILE  credencial em outro caminho (testes)
  HEARTBEAT_SHOW=1       mostra o resultado no terminal
"""

import json
import os
import re
import socket
import subprocess
import sys
import time
import urllib.error
import urllib.parse
import urllib.request

CLIENT_ID = "1T4SNZ8iDuvM18ZIB9fSc109ZZVglsXBtLxeU4ng"
TOKEN_URL = "https://auth.assessoriatech.com/application/o/token/"
LOKI_URL = "https://mon.assessoriatech.com/loki/api/v1/push"
ALLOY_HTTP = "http://127.0.0.1:12345"
USER_AGENT = "AssessoriaTech-Alloy-Heartbeat/1.0"
# Acima disso (segundos sem amostra enviada), o Alloy e considerado degradado.
LAG_LIMIT = 300
PUSH_URL_RE = re.compile(
    r"^https://[A-Za-z0-9.-]+(:[0-9]+)?(/[A-Za-z0-9._~-]+)*/api/push/[A-Za-z0-9_-]{8,128}$"
)
LOGFMT_SAFE = re.compile(r"^[A-Za-z0-9_.:/-]+$")

CREDS_DIR = os.environ.get("CREDENTIALS_DIRECTORY", "")
STATE_DIR = os.environ.get("STATE_DIRECTORY", "/var/lib/alloy-heartbeat")
SECRET_FILE = os.environ.get("HEARTBEAT_SECRET_FILE", "/etc/alloy/oauth-client-secret")
TOKEN_FILE = os.path.join(STATE_DIR, "token")
LAST_FILE = os.path.join(STATE_DIR, "last")


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return None


# Local: sem proxy. Remoto: proxy do ambiente, se houver. Nenhum segue redirecionamento.
LOCAL = urllib.request.build_opener(urllib.request.ProxyHandler({}), NoRedirect)
REMOTE = urllib.request.build_opener(NoRedirect)


def http(opener, url, data=None, headers=None, timeout=10):
    """(codigo HTTP, corpo). Codigo 0 = sem resposta (DNS, rota, TLS, timeout)."""
    request = urllib.request.Request(url, data=data, headers={"User-Agent": USER_AGENT, **(headers or {})})
    try:
        with opener.open(request, timeout=timeout) as response:
            return response.status, response.read().decode("utf-8", "replace")
    except urllib.error.HTTPError as exc:
        try:
            body = exc.read().decode("utf-8", "replace")
        except OSError:
            body = ""
        return exc.code, body
    except (urllib.error.URLError, OSError, ValueError):
        return 0, ""


def local_get(path):
    return http(LOCAL, ALLOY_HTTP + path, timeout=3)


def run(*args):
    try:
        return subprocess.run(args, capture_output=True, text=True, timeout=10).stdout.strip()
    except (OSError, subprocess.SubprocessError):
        return ""


def write_state(path, text):
    """Escrita atomica de um arquivo pequeno de estado (0600)."""
    temp = path + ".tmp"
    fd = os.open(temp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC | os.O_NOFOLLOW, 0o600)
    with os.fdopen(fd, "w", encoding="utf-8") as file:
        file.write(text)
    os.replace(temp, path)


# ------------------------------------------------------------- estado local

def metric_value(lines, name, use_max=False):
    """Soma (ou maximo) das amostras de uma metrica no texto do /metrics."""
    pattern = re.compile(r"^" + re.escape(name) + r"(\{[^}]*\})?\s+(\S+)")
    found, total = False, 0.0
    for line in lines:
        if not line.startswith(name):
            continue
        match = pattern.match(line)
        if not match:
            continue
        try:
            value = float(match.group(2))
        except ValueError:
            continue
        if value != value:  # NaN
            continue
        if use_max:
            total = value if not found or value > total else total
        else:
            total += value
        found = True
    return total if found else None


def collect_state():
    """Campos em ordem: viram a linha logfmt do Loki."""
    if run("systemctl", "show", "alloy.service", "--property=LoadState", "--value") != "loaded":
        return {"alloy": "ausente", "service": "absent"}
    version = run("dpkg-query", "-W", "-f=${Version}", "alloy")
    version = "v" + version.lstrip("v") if version else ""
    if run("systemctl", "is-active", "alloy.service") != "active":
        state = {"alloy": "parado", "service": "stopped"}
        if version:
            state["version"] = version
        return state

    state = {"alloy": "", "service": "running"}
    ready = local_get("/-/ready")[0] == 200
    state["ready"] = "1" if ready else "0"

    healthy = None
    code, body = local_get("/-/healthy")
    if code == 200:
        healthy = True
        state["healthy"] = "1"
    elif code == 500:
        healthy = False
        state["healthy"] = "0"
        names = re.sub(r"(?s)^.*unhealthy components:\s*", "", body)
        names = re.sub(r"[^A-Za-z0-9_.,/ -]", "", names.replace("\n", " "))
        names = re.sub(r"\s*,\s*", ",", names).strip()[:200]
        if names:
            state["unhealthy"] = names

    lag = None
    code, body = local_get("/metrics")
    if code == 200:
        lines = body.splitlines()
        sent = metric_value(lines, "prometheus_remote_storage_queue_highest_sent_timestamp_seconds", True)
        if sent is not None and sent > 0:
            lag = max(0, round(time.time() - sent))
            state["metrics_lag_s"] = str(lag)
        for field, name in (
            ("samples_failed", "prometheus_remote_storage_samples_failed_total"),
            ("logs_sent", "loki_write_sent_entries_total"),
            ("logs_dropped", "loki_write_dropped_entries_total"),
        ):
            value = metric_value(lines, name)
            if value is not None:
                state[field] = str(round(value))
    if version:
        state["version"] = version

    if not ready:
        state["alloy"] = "nao_pronto"
    elif healthy is False or (lag is not None and lag > LAG_LIMIT):
        state["alloy"] = "degradado"
    else:
        state["alloy"] = "ok"
    return state


def logfmt(state):
    parts = []
    for key, value in state.items():
        if LOGFMT_SAFE.match(value):
            parts.append(f"{key}={value}")
        else:
            parts.append(f'{key}="' + re.sub(r'["\\]', "", value) + '"')
    return " ".join(parts)


# ------------------------------------------------------------------- Loki

def access_token(fresh):
    """(token, 'ok') ou (None, motivo). Token reaproveitado ate 60s antes de expirar."""
    now = int(time.time())
    if not fresh:
        try:
            with open(TOKEN_FILE, encoding="utf-8") as file:
                cached = json.load(file)
            if cached.get("token") and int(cached.get("expires", 0)) > now + 60:
                return cached["token"], "ok"
        except (OSError, ValueError, TypeError, AttributeError):
            pass
    with open(SECRET_FILE, encoding="ascii") as file:
        secret = file.read().strip()
    form = urllib.parse.urlencode({
        "grant_type": "client_credentials",
        "client_id": CLIENT_ID,
        "client_secret": secret,
        "scope": "profile",
    }).encode()
    secret = None
    code, body = http(REMOTE, TOKEN_URL, form, {"Content-Type": "application/x-www-form-urlencoded",
                                                "Accept": "application/json"})
    if code == 0:
        return None, "token_sem_resposta"
    if code != 200:
        return None, f"token_{code}"
    try:
        data = json.loads(body)
        token = data["access_token"]
        expires = int(data.get("expires_in") or 300)
    except (ValueError, KeyError, TypeError):
        return None, "token_invalido"
    if not isinstance(token, str) or not token:
        return None, "token_invalido"
    try:
        write_state(TOKEN_FILE, json.dumps({"token": token, "expires": now + expires}))
    except OSError:
        pass
    return token, "ok"


def send_loki(host, line):
    if not os.access(SECRET_FILE, os.R_OK) or os.path.getsize(SECRET_FILE) == 0:
        return "sem_credencial"
    payload = json.dumps({"streams": [{
        "stream": {"job": "alloy-heartbeat", "host": host, "os": "linux"},
        "values": [[str(time.time_ns()), line]],
    }]}).encode()
    for fresh in (False, True):
        token, reason = access_token(fresh)
        if not token:
            return reason
        code, _ = http(REMOTE, LOKI_URL, payload, {"Content-Type": "application/json",
                                                   "Authorization": f"Bearer {token}"})
        # 401 com token do cache: pede um novo e tenta uma vez mais.
        if code == 401 and not fresh:
            continue
        return "sem_resposta" if code == 0 else str(code)
    return "401"


# ------------------------------------------------------------------- Kuma

def push_url():
    url = os.environ.get("HEARTBEAT_KUMA_URL", "")
    if not url and CREDS_DIR:
        with open(os.path.join(CREDS_DIR, "kuma-url"), encoding="utf-8") as file:
            url = file.read()
    url = re.split(r"[?#]", "".join(url.split()))[0]
    if not url:
        raise ValueError("URL de push ausente")
    if not PUSH_URL_RE.match(url):
        raise ValueError("URL de push invalida")
    return url


def send_kuma(message):
    """Codigo HTTP ('200', '404'...), 'sem_resposta' ou 'resposta_invalida'
    (200 sem {"ok": true}, ex. pagina da Cloudflare)."""
    query = urllib.parse.urlencode({"status": "up", "msg": message, "ping": ""}, quote_via=urllib.parse.quote)
    code, body = http(REMOTE, push_url() + "?" + query)
    if code == 0:
        return "sem_resposta"
    if code == 200:
        try:
            if json.loads(body).get("ok") is not True:
                return "resposta_invalida"
        except (ValueError, AttributeError):
            return "resposta_invalida"
    return str(code)


# ------------------------------------------------------------------ execucao

def main():
    os.umask(0o077)
    state = collect_state()
    line = logfmt(state)
    try:
        loki = send_loki(socket.gethostname(), line)
    except OSError as exc:
        loki = f"erro_{type(exc).__name__}"

    summary = f"alloy={state['alloy']}"
    if "metrics_lag_s" in state:
        summary += f" lag={state['metrics_lag_s']}s"
    if "unhealthy" in state:
        summary += f" unhealthy={state['unhealthy']}"
    summary += f" loki={loki}"
    if "version" in state:
        summary += f" {state['version']}"
    try:
        kuma = send_kuma(summary)
    except (OSError, ValueError) as exc:
        kuma = f"erro: {exc}" if isinstance(exc, ValueError) else f"erro: {type(exc).__name__}"

    if os.path.isdir(STATE_DIR):
        try:
            write_state(LAST_FILE, f"time={int(time.time())}\nkuma={kuma}\nloki={loki}\n"
                                   f"alloy={state['alloy']}\nline={line}\n")
        except OSError:
            pass
    print(f"kuma={kuma} loki={loki}  {line}", flush=True)
    if os.environ.get("HEARTBEAT_SHOW") == "1":
        print(f"  Alloy        {line}\n  Loki         {loki}\n  Uptime Kuma  {kuma}")
    return 0 if kuma == "200" else 1


if __name__ == "__main__":
    sys.exit(main())
