import base64
import getpass
import json
import os
import re
import time
import sys
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path

CLIENT_ID = "1T4SNZ8iDuvM18ZIB9fSc109ZZVglsXBtLxeU4ng"
TOKEN_URL = "https://auth.assessoriatech.com/application/o/token/"
LOKI_URL = "https://mon.assessoriatech.com/loki/api/v1/push"
BASE = Path("/etc/alloy")
SECRET = BASE / "oauth-client-secret"


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return None


opener = urllib.request.build_opener(NoRedirect)


def post(url, body, headers, label):
    request = urllib.request.Request(url, data=body, headers=headers, method="POST")
    try:
        with opener.open(request, timeout=12) as response:
            return response.status, response.read(8192)
    except urllib.error.HTTPError as exc:
        return exc.code, exc.read(8192)
    except (urllib.error.URLError, OSError) as exc:
        print(f"{label}: HTTP sem resposta | ERRO de rede/TLS ({type(exc).__name__})")
        raise SystemExit("Nenhum arquivo local foi alterado.") from None


def main():
    if os.geteuid() != 0:
        raise SystemExit("Execute como root (sudo).")
    if BASE.is_symlink() or (BASE.exists() and not BASE.is_dir()):
        raise SystemExit("Diretorio /etc/alloy invalido.")
    if os.path.lexists(SECRET):
        raise SystemExit("Credencial ja existe; nada foi sobrescrito.")

    if not sys.stdin.isatty():
        raise SystemExit("Execute em um terminal interativo (TTY).")

    try:
        username = input("Conta de servico (alloy-<hostname>): ").strip()
        password = getpass.getpass("Senha do aplicativo: ")
    except (EOFError, KeyboardInterrupt):
        raise SystemExit("\nOperacao cancelada; nenhum arquivo alterado.") from None
    except OSError as exc:
        raise SystemExit(f"Erro ao acessar o terminal: {exc}") from None

    if not re.fullmatch(r"alloy-[a-z0-9][a-z0-9-]*", username) or not password:
        raise SystemExit("Usuario ou senha invalidos; nenhum arquivo alterado.")
    credential = base64.b64encode(
        f"{username}:{password}".encode("utf-8")
    ).decode("ascii")

    token_body = urllib.parse.urlencode({
        "grant_type": "client_credentials",
        "client_id": CLIENT_ID,
        "client_secret": credential,
        "scope": "profile",
    }).encode("ascii")
    status, response_body = post(
        TOKEN_URL, token_body,
        {"Content-Type": "application/x-www-form-urlencoded"},
        "Teste 1 - OAuth2",
    )
    if status != 200:
        print(f"Teste 1 - OAuth2: HTTP {status} | REPROVADO - autenticacao negada")
        raise SystemExit("Nenhum arquivo local foi alterado.")
    try:
        access_token = json.loads(response_body)["access_token"]
        if not isinstance(access_token, str) or not access_token:
            raise ValueError("Token vazio")
    except (ValueError, KeyError, TypeError):
        print("Teste 1 - OAuth2: HTTP 200 | REPROVADO - token ausente")
        raise SystemExit("Nenhum arquivo local foi alterado.") from None
    print("Teste 1 - OAuth2: HTTP 200 | APROVADO - token emitido")

    probe = {
        "streams": [{
            "stream": {"job": "alloy-auth-probe", "host": username[6:]},
            "values": [[str(time.time_ns()), "Teste de autorizacao Alloy"]],
        }]
    }
    status, _ = post(
        LOKI_URL, json.dumps(probe, separators=(",", ":")).encode("utf-8"),
        {"Content-Type": "application/json", "Authorization": f"Bearer {access_token}"},
        "Teste 2 - Loki",
    )
    if status != 204:
        print(f"Teste 2 - Loki: HTTP {status} | REPROVADO - ingestao nao confirmada")
        raise SystemExit("Nenhum arquivo local foi alterado.")
    print("Teste 2 - Loki: HTTP 204 | APROVADO - ingestao autorizada")

    # Apenas a partir daqui persistimos no disco. Nao exige Alloy instalado.
    os.umask(0o077)
    if not BASE.exists():
        BASE.mkdir(mode=0o700)
        BASE.chmod(0o700)
    if BASE.is_symlink() or not BASE.is_dir():
        raise SystemExit("Diretorio /etc/alloy invalido; credencial nao gravada.")

    fd = os.open(
        SECRET, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600
    )
    try:
        with os.fdopen(fd, "w", encoding="ascii") as file:
            file.write(credential)
            file.flush()
            os.fchown(file.fileno(), 0, 0)
            os.fchmod(file.fileno(), 0o600)
            os.fsync(file.fileno())
    except Exception:
        SECRET.unlink(missing_ok=True)
        raise
    print("Credencial instalada: /etc/alloy/oauth-client-secret (root:root, 600).")
    print("Proxima etapa: instalar e configurar o Alloy.")


if __name__ == "__main__":
    main()
