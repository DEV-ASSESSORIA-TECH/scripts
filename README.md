# scripts

Scripts operacionais da Assessoria Tech: instalação, configuração e
manutenção de serviços nos servidores atendidos.

Cada área fica em sua própria pasta, com um README próprio explicando uso e
requisitos. A documentação dos processos fica na base de conhecimento interna.

## Sumário

| Área | Pasta | Descrição |
|------|-------|-----------|
| Monitoramento | [DEV-ASSESSORIA-TECH/alloy](https://github.com/DEV-ASSESSORIA-TECH/alloy) | Agente Grafana Alloy (Linux e Windows). Saiu deste repositório; [`monitoring/alloy`](monitoring/alloy) guarda só uma ponte temporária |

Ferramentas que crescem a ponto de precisar de versões próprias (releases,
CI, documentação extensa) ganham um repositório separado; aqui ficam os
scripts menores.

## Organização

```
scripts/
├── <area>/            # ex.: monitoring, backup, network
│   └── <ferramenta>/  # um conjunto de scripts por ferramenta
│       ├── linux/
│       └── windows/
├── LICENSE
└── README.md
```

## Convenções

- Um ponto de entrada por ferramenta e sistema operacional; os demais
  arquivos são carregados ou baixados por ele.
- Scripts idempotentes: executar de novo não deve causar alterações sem
  necessidade.
- Nenhuma credencial no repositório. Segredos são informados na execução e
  gravados apenas no servidor de destino.
- Arquivos `.ps1` em ASCII, para compatibilidade com o Windows PowerShell 5.1.

## Licença

Uso permitido para estudo e desenvolvimento próprio. Links, IDs e
credenciais da infraestrutura da Assessoria Tech **não** podem ser usados por
terceiros sem autorização. Veja [LICENSE](LICENSE).
