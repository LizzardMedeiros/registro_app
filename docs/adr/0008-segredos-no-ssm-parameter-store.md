# 0008. Segredos no SSM Parameter Store

- Status: Aceito
- Data: 2026-09-24

## Contexto

A API precisa da senha do banco e do segredo JWT. Antes, `JWT_SECRET` tinha um
valor padrão no código (`troque-este-segredo`), aceito inclusive em produção.

## Decisão

- `/registro/<env>/db-password` e `/registro/<env>/jwt-secret` como `SecureString`
  (chave gerenciada `aws/ssm`), gerados com `openssl rand` na primeira execução e
  nunca impressos (o dry-run mascara `--value` e `--master-user-password`).
- O ECS injeta os valores como `PGPASSWORD` e `JWT_SECRET` (`secrets` da task
  definition). A role de execução só lê `parameter/registro/<env>/*`.
- A API se recusa a iniciar com `NODE_ENV=production` e o segredo padrão.
- Secrets Manager não foi usado: custa por segredo por mês e o Parameter Store
  Standard é gratuito, sem necessidade de rotação no laboratório.

## Consequências

- Sem rotação automática de senha.
- A senha do RDS é passada à AWS CLI como argumento na criação do banco,
  visível na lista de processos do runner efêmero (risco aceito).
- Nenhum segredo no repositório, nos workflows ou no bundle do frontend.
