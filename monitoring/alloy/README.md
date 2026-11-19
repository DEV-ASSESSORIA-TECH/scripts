# Grafana Alloy: mudou de repositório

O instalador e o `alloyctl` agora ficam em
**[DEV-ASSESSORIA-TECH/alloy](https://github.com/DEV-ASSESSORIA-TECH/alloy)**,
com versões publicadas como releases. O histórico foi levado junto.

Esta pasta guarda só uma **ponte temporária** (`linux/alloy.sh`,
`windows/alloy.ps1`), para não quebrar quem ainda usa o endereço antigo:

- o comando de instalação antigo e o script do Tactical RMM ainda não
  recolado: baixam o ponto de entrada do repositório novo e seguem por ele;
- o `alloyctl` já instalado: na próxima execução se atualiza por aqui, recebe
  a ponte e se reinstala a partir da última release do repositório novo. Os
  arquivos em `lib/` estão vazios de propósito: o `alloyctl` antigo exige que
  eles existam.

A ponte será removida quando os logs (`/var/log/alloyctl.log`,
`C:\ProgramData\GrafanaLabs\Alloy\logs\alloyctl-*.log`) mostrarem que as
máquinas migraram. Veja `docs/migracao.md` no repositório novo.
