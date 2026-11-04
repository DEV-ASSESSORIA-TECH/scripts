"""Credencial OAuth2 do Alloy (conta de servico do Authentik).

Sem opcoes: pede a conta e a senha de aplicativo, testa OAuth2 + Loki e,
somente se ambos passarem, grava /etc/alloy/oauth-client-secret.
--check:  testa a credencial ja gravada, sem alterar nada.
--rotate: substitui a credencial existente (apos os mesmos testes),
          preservando dono e permissoes do arquivo atual.
"""

import argparse
import base64
import binascii
import json
import os
import re
import socket
import stat
import sys
import termios
import time
import tty
import readline  # noqa: F401  (edicao de linha no input())
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path

CLIENT_ID = "1T4SNZ8iDuvM18ZIB9fSc109ZZVglsXBtLxeU4ng"
TOKEN_URL = "https://auth.assessoriatech.com/application/o/token/"
LOKI_URL = "https://mon.assessoriatech.com/loki/api/v1/push"
BASE = Path("/etc/alloy")
SECRET = BASE / "oauth-client-secret"
USERNAME_RE = r"alloy-[a-z0-9][a-z0-9-]*"
UNCHANGED = "Nenhum arquivo local foi alterado."


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return None


opener = urllib.request.build_opener(NoRedirect)


def post(url, body, headers, label):
    request = urllib.request.Request(
        url,
        data=body,
        headers={
            "User-Agent": "AssessoriaTech-Alloy-Setup/1.0",
            "Accept": "application/json",
            **headers,
        },
        method="POST",
    )
    try:
        with opener.open(request, timeout=12) as response:
            return response.status, response.read(8192)
    except urllib.error.HTTPError as exc:
        return exc.code, exc.read(8192)
    except (urllib.error.URLError, OSError) as exc:
        print(f"{label}: HTTP sem resposta | ERRO de rede/TLS ({type(exc).__name__})")
        raise SystemExit(UNCHANGED) from None


def oauth_error_details(body, credential):
    """Exibe somente os campos de erro OAuth2, sanitizados; nunca o corpo inteiro."""
    try:
        data = json.loads(body)
    except ValueError:
        print("OAuth2 - detalhes indisponiveis (resposta nao e JSON valido).")
        return
    if not isinstance(data, dict):
        return
    code = data.get("error")
    if isinstance(code, str) and re.fullmatch(r"[a-zA-Z][a-zA-Z0-9_-]{0,63}", code):
        print(f"OAuth2 - codigo: {code}")
    description = data.get("error_description") or data.get("detail")
    if not isinstance(description, str) or not description.strip():
        return
    description = re.sub(r"[\x00-\x1f\x7f]+", " ", description).strip()
    description = description.replace(credential, "[credencial omitida]")
    description = re.sub(r"(?i)\b(Bearer|Basic)\s+[a-zA-Z0-9+/_=-]{8,}", r"\1 [omitido]", description)
    description = re.sub(
        r"(?i)\b(client_secret|access_token|refresh_token|id_token|password|senha)\s*[:=]\s*[^\s,;]+",
        r"\1=[omitido]",
        description,
    )
    if len(description) > 200:
        description = description[:200] + "..."
    print(f"OAuth2 - descricao: {description}")


def validate(credential, username):
    """Teste 1: token OAuth2. Teste 2: uma linha de log no Loki. Sai em falha."""
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
        oauth_error_details(response_body, credential)
        raise SystemExit(UNCHANGED)
    try:
        access_token = json.loads(response_body)["access_token"]
        if not isinstance(access_token, str) or not access_token:
            raise ValueError("Token vazio")
    except (ValueError, KeyError, TypeError):
        print("Teste 1 - OAuth2: HTTP 200 | REPROVADO - token ausente")
        raise SystemExit(UNCHANGED) from None
    print("Teste 1 - OAuth2: HTTP 200 | APROVADO - token emitido")

    probe = {
        "streams": [{
            "stream": {"job": "alloy-auth-probe", "host": username[len("alloy-"):]},
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
        raise SystemExit(UNCHANGED)
    print("Teste 2 - Loki: HTTP 204 | APROVADO - ingestao autorizada")


def getpass_masked(prompt="Senha do aplicativo: "):
    fd = os.open("/dev/tty", os.O_RDWR)
    old_settings = termios.tcgetattr(fd)
    password = bytearray()

    try:
        os.write(fd, prompt.encode())
        tty.setcbreak(fd)

        while True:
            char = os.read(fd, 1)

            if not char:
                raise EOFError

            if char in (b"\r", b"\n"):
                break

            if char in (b"\x08", b"\x7f"):
                if password:
                    password.pop()
                    os.write(fd, b"\b \b")
                continue

            if char == b"\x03":
                raise KeyboardInterrupt

            if char[0] >= 32 and char != b"\x7f":
                password.extend(char)
                os.write(fd, b"*")

        return password.decode("utf-8")

    finally:
        termios.tcsetattr(fd, termios.TCSADRAIN, old_settings)
        os.write(fd, b"\n")
        os.close(fd)


def suggested_username():
    host = socket.gethostname().split(".")[0].strip().lower()
    return f"alloy-{host}" if host else ""


def prompt_credential():
    if not sys.stdin.isatty():
        raise SystemExit("Execute em um terminal interativo (TTY).")
    suggestion = suggested_username()
    label = f"Conta de servico [{suggestion}]: " if suggestion else "Conta de servico (alloy-<hostname>): "
    try:
        username = input(label).strip().lower() or suggestion
        password = getpass_masked()
    except (EOFError, KeyboardInterrupt):
        raise SystemExit("\nOperacao cancelada; nenhum arquivo alterado.") from None
    except OSError as exc:
        raise SystemExit(f"Erro ao acessar o terminal: {exc}") from None

    if not re.fullmatch(USERNAME_RE, username) or not password:
        raise SystemExit("Usuario ou senha invalidos; nenhum arquivo alterado.")
    credential = base64.b64encode(f"{username}:{password}".encode("utf-8")).decode("ascii")
    return username, credential


def check_base():
    if BASE.is_symlink() or (BASE.exists() and not BASE.is_dir()):
        raise SystemExit("Diretorio /etc/alloy invalido.")


def secret_stat():
    """lstat da credencial: None se ausente; erro se nao for arquivo regular."""
    try:
        info = os.lstat(SECRET)
    except FileNotFoundError:
        return None
    if not stat.S_ISREG(info.st_mode):
        raise SystemExit("Caminho da credencial nao e arquivo regular.")
    return info


def read_stored():
    fd = os.open(SECRET, os.O_RDONLY | os.O_NOFOLLOW)
    with os.fdopen(fd, "r", encoding="ascii") as file:
        credential = file.read().strip()
    try:
        decoded = base64.b64decode(credential, validate=True).decode("utf-8")
    except (binascii.Error, UnicodeDecodeError):
        raise SystemExit("Credencial gravada nao e Base64 valido.") from None
    username, sep, password = decoded.partition(":")
    if not sep or not password or not re.fullmatch(USERNAME_RE, username):
        raise SystemExit("Credencial gravada em formato inesperado (usuario:senha).")
    return username, credential


def fsync_dir(path):
    fd = os.open(path, os.O_RDONLY | os.O_DIRECTORY)
    try:
        os.fsync(fd)
    finally:
        os.close(fd)


def write_new(credential):
    # Apenas a partir daqui persistimos no disco. Nao exige Alloy instalado.
    os.umask(0o077)
    if not BASE.exists():
        BASE.mkdir(mode=0o700)
        BASE.chmod(0o700)
    if BASE.is_symlink() or not BASE.is_dir():
        raise SystemExit("Diretorio /etc/alloy invalido; credencial nao gravada.")

    fd = os.open(SECRET, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
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


def write_rotate(credential, current):
    # Arquivo temporario no mesmo diretorio + rename: troca atomica, sem
    # janela com credencial vazia. Mantem dono/grupo/modo (ex.: root:alloy 640).
    os.umask(0o077)
    temp = BASE / f".oauth-client-secret.{os.getpid()}.tmp"
    fd = os.open(temp, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
    try:
        with os.fdopen(fd, "w", encoding="ascii") as file:
            os.fchown(file.fileno(), current.st_uid, current.st_gid)
            os.fchmod(file.fileno(), stat.S_IMODE(current.st_mode))
            file.write(credential)
            file.flush()
            os.fsync(file.fileno())
        os.replace(temp, SECRET)
        fsync_dir(BASE)
    except Exception:
        temp.unlink(missing_ok=True)
        raise
    if read_stored()[1] != credential:
        raise SystemExit("Credencial gravada nao corresponde ao valor validado.")
    mode = stat.S_IMODE(current.st_mode)
    print(f"Credencial rotacionada: {SECRET} (uid {current.st_uid}, gid {current.st_gid}, {mode:o}).")


def main():
    parser = argparse.ArgumentParser(description="Credencial OAuth2 do Alloy.")
    mode = parser.add_mutually_exclusive_group()
    mode.add_argument("--check", action="store_true", help="testa a credencial gravada, sem alterar nada")
    mode.add_argument("--rotate", action="store_true", help="substitui a credencial existente")
    args = parser.parse_args()

    if os.geteuid() != 0:
        raise SystemExit("Execute como root (sudo).")
    check_base()
    current = secret_stat()

    if args.check:
        if current is None:
            raise SystemExit("Credencial inexistente; nada a testar.")
        username, credential = read_stored()
        print(f"Testando a credencial gravada ({username})...")
        validate(credential, username)
        print("Credencial valida. Nenhum arquivo foi alterado.")
        return

    if current is not None and not args.rotate:
        raise SystemExit("Credencial ja existe; nada foi sobrescrito. Use --rotate para substituir.")
    if current is None and args.rotate:
        raise SystemExit("Credencial inexistente. Execute sem --rotate.")

    username, credential = prompt_credential()
    validate(credential, username)
    if args.rotate:
        write_rotate(credential, current)
        print("Se o Alloy estiver em execucao, reinicie o servico para carregar a nova credencial.")
    else:
        write_new(credential)
        print("Proxima etapa: instalar e configurar o Alloy.")


if __name__ == "__main__":
    main()
