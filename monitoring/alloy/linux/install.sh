#!/usr/bin/env bash
set -euo pipefail

if [[ ${EUID} -ne 0 ]]; then
  echo 'Execute com sudo.' >&2
  exit 1
fi

if [[ ! -s /etc/alloy/oauth-client-secret ]]; then
  echo 'Credencial ausente: execute setup-credentials.py antes.' >&2
  exit 1
fi

apt-get update
apt-get install -y ca-certificates curl
install -d -m 0755 /etc/apt/keyrings
curl -fsSL https://apt.grafana.com/gpg-full.key -o /etc/apt/keyrings/grafana.asc
chmod 0644 /etc/apt/keyrings/grafana.asc
printf '%s\n' 'deb [signed-by=/etc/apt/keyrings/grafana.asc] https://apt.grafana.com stable main' > /etc/apt/sources.list.d/grafana.list
apt-get update
apt-get install -y alloy
systemctl stop alloy || true

install -d -o root -g alloy -m 0750 /etc/alloy
chown root:alloy /etc/alloy/oauth-client-secret
chmod 0640 /etc/alloy/oauth-client-secret
usermod -aG systemd-journal alloy

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
if [[ -f /etc/alloy/config.alloy ]]; then
  cp -a /etc/alloy/config.alloy "/etc/alloy/config.alloy.bak-$(date +%Y%m%d-%H%M%S)"
fi
install -o root -g alloy -m 0640 "${script_dir}/config.alloy" /etc/alloy/config.alloy

alloy validate /etc/alloy/config.alloy
systemctl enable --now alloy
systemctl restart alloy
systemctl --no-pager status alloy
