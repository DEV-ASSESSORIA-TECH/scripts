# scripts

Repositório de scripts operacionais da Assessoria Tech: instalação,
configuração e manutenção de serviços nos servidores dos clientes.

## Sumário

| Área | Caminho | O que faz |
|------|---------|-----------|
| Monitoramento | [`monitoring/alloy/linux`](monitoring/alloy/linux) | Instala o Grafana Alloy em Linux (Debian/Ubuntu) |
| Monitoramento | [`monitoring/alloy/windows`](monitoring/alloy/windows) | Instala o Grafana Alloy em Windows |

## Estrutura

```
scripts/
│
├── monitoring/
│   └── alloy/
│       ├── linux/
│       │   ├── install.sh              # instala o Alloy (apt) e aplica o config.alloy
│       │   ├── setup-credentials.py    # valida e grava a credencial OAuth2
│       │   ├── config.alloy            # métricas do host + logs do journald
│       │   └── docker.alloy            # métricas e logs dos containers Docker
│       │
│       └── windows/
│           ├── install.ps1             # instala o Alloy e aplica o config.alloy
│           ├── setup-credentials.ps1   # valida e grava a credencial OAuth2
│           └── config.alloy            # métricas do host + Event Log
│
└── README.md
```

## Monitoramento (Grafana Alloy)

O [Grafana Alloy](https://grafana.com/docs/alloy/latest/) roda em cada
servidor, coleta métricas e logs e envia para a central:

- **Métricas** → Prometheus (`https://mon.assessoriatech.com/api/v1/write`)
- **Logs** → Loki (`https://mon.assessoriatech.com/loki/api/v1/push`)
- **Autenticação** → OAuth2 (`https://auth.assessoriatech.com`) com uma conta
  de serviço por servidor, no formato `alloy-<hostname>`.

O fluxo é sempre em duas etapas:

1. **`setup-credentials`** – pede usuário e senha da conta de serviço, testa
   o login OAuth2 e o envio de um log de teste ao Loki. Só grava a credencial
   em disco se os dois testes passarem. Nunca sobrescreve uma credencial
   existente.
2. **`install`** – instala o Alloy, copia o `config.alloy` e inicia o serviço.
   Faz backup da configuração anterior (`config.alloy.bak-<data>`).

### Linux

```bash
sudo python3 monitoring/alloy/linux/setup-credentials.py
```

```bash
sudo bash monitoring/alloy/linux/install.sh
```

Credencial: `/etc/alloy/oauth-client-secret` · Config: `/etc/alloy/config.alloy`

#### Docker (opcional)

O `docker.alloy` contém apenas a coleta de Docker (métricas via cAdvisor e
logs dos containers) e reutiliza os destinos definidos no `config.alloy`.
Para ativar num host que já tem o Alloy instalado:

```bash
sudo install -o root -g alloy -m 0640 monitoring/alloy/linux/docker.alloy /etc/alloy/docker.alloy
```

```bash
sudo usermod -aG docker alloy
```

```bash
sudo sed -i 's#^CONFIG_FILE=.*#CONFIG_FILE="/etc/alloy"#' /etc/default/alloy
```

```bash
sudo alloy validate /etc/alloy && sudo systemctl restart alloy
```

Com `CONFIG_FILE` apontando para o diretório, o Alloy carrega todos os
arquivos `*.alloy` de `/etc/alloy`.

### Windows

Em um PowerShell **como Administrador**:

```powershell
.\monitoring\alloy\windows\setup-credentials.ps1
.\monitoring\alloy\windows\install.ps1
```

Credencial: `C:\ProgramData\GrafanaLabs\Alloy\oauth-client-secret` (acesso só
para SYSTEM e Administradores) · Config:
`C:\Program Files\GrafanaLabs\Alloy\config.alloy`

Coleta métricas do host (`windows_exporter`) e os logs dos canais
**Application** e **System** do Event Viewer.
