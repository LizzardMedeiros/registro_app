# 0001. Registrar decisões em ADRs

- Status: Aceito
- Data: 2026-09-24

## Contexto

O workshop "Subindo Infra com IA" conduz o deploy por conversa com um agente. As
decisões (arquitetura, custo, segurança) surgem na conversa e se perdem se não
forem registradas. O responsável pediu para "documentar tudo".

## Decisão

Registrar cada decisão relevante como ADR em `docs/adr/`, numerado e imutável
depois de aceito. Fatos do código, respostas da entrevista e hipóteses ficam em
`docs/deploy-decisions.md`, que o `DEPLOY.md` exige para retomar o trabalho sem
repetir a entrevista.

## Consequências

- Quem retomar o laboratório (pessoa ou agente) entende o porquê de cada escolha.
- Mudanças de rumo exigem um novo ADR, o que deixa o histórico explícito.
- Custo pequeno de manutenção a cada decisão nova.
