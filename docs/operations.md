# Operação do ambiente do laboratório

Comandos para o ambiente `lab-lizzard` (conta 270244457878, `us-east-1`). Use
`--profile personal` localmente; no CI as credenciais vêm do OIDC.

```bash
export AWS_PROFILE=personal AWS_REGION=us-east-1
ENV=lab-lizzard ACCOUNT=270244457878
```

## Primeiro provisionamento

Pelo GitHub (recomendado): **Actions → CI/CD → Run workflow → action = provision**
na branch `main`. Ou localmente:

```bash
docker build -t registro-api:local api
scripts/deploy.sh --env $ENV --region $AWS_REGION --account $ACCOUNT \
  --profile personal --provision --image-tag local-$(date +%s) --local-image registro-api:local
```

Para ver o plano sem alterar nada, acrescente `--dry-run`.

## Atualizar

Faça merge ou push na `main`. O pipeline valida, publica a imagem do commit,
roda as migrations, atualiza o ECS, republica o site e verifica. A URL do site
aparece no resumo do workflow e no environment `lab`.

Se a task for substituída fora de um deploy (o IP muda), rode o workflow
manualmente com `action = deploy` para regenerar o `config.js` do site.

## Logs

```bash
# API (últimos 30 min, seguindo)
aws logs tail /ecs/registro-$ENV --since 30m --follow
# Somente migrations
aws logs tail /ecs/registro-$ENV --since 1h --filter-pattern '"Aplicando" OR "Migration" OR "Falha"'
# Eventos do serviço (falhas de health check, rollback)
aws ecs describe-services --cluster registro-$ENV --services registro-$ENV-api \
  --query 'services[0].events[:10].[createdAt,message]' --output table
# Motivo de parada de tasks recentes
aws ecs list-tasks --cluster registro-$ENV --desired-status STOPPED --query taskArns --output text |
  xargs -r aws ecs describe-tasks --cluster registro-$ENV --query 'tasks[].[taskArn,stoppedReason,containers[0].exitCode]' --output table --tasks
```

## Recuperar uma entrega falha

| Sintoma | O que aconteceu | Ação |
|---|---|---|
| Job de validação vermelho | Teste, lint ou build falhou | Nada foi publicado; a versão anterior continua no ar. Corrija e faça push. |
| "Migration falhou" | Task de migration saiu com código ≠ 0 | O serviço não foi atualizado. Veja os logs da migration, corrija o SQL e faça push. A migration roda em transação. |
| "Rollback do circuit breaker" | A task nova não passou no health check | O ECS voltou para a revisão anterior. Veja os eventos do serviço e os logs da task. |
| "config.js não aponta para ..." / site sem API | IP da task mudou | Rode o workflow com `action = deploy`. |
| Deploy "não está ativo" | Ambiente destruído ou nunca criado | Provisione explicitamente (`action = provision`). |

Reverter a aplicação (revert do commit + push) **não desfaz migrations nem
restaura dados**: escreva migrations compatíveis com a versão anterior.

Para voltar a uma versão já publicada sem novo build, rode o workflow com
`action = deploy` a partir do commit desejado, ou localmente
`scripts/deploy.sh ... --image-tag <tag-existente-no-ECR>`.

## Encerrar

Remove tudo do ambiente, **inclusive o banco e os dados de teste** (sem snapshot):

```bash
scripts/destroy.sh --env $ENV --region $AWS_REGION --account $ACCOUNT --profile personal
# pede para digitar o nome do ambiente; --yes pula a pergunta (uso pelo agente
# depois da confirmação na conversa); --dry-run mostra o que seria removido
```

O script confere remanescentes e sai com erro se algo sobrou. O provedor OIDC e
a role `github-actions-workshop` são preservados; para removê-los depois do
workshop:

```bash
aws iam detach-role-policy --role-name github-actions-workshop --policy-arn arn:aws:iam::aws:policy/AdministratorAccess
aws iam delete-role --role-name github-actions-workshop
aws iam delete-open-id-connect-provider --open-id-connect-provider-arn \
  arn:aws:iam::$ACCOUNT:oidc-provider/token.actions.githubusercontent.com
```

Cobranças podem aparecer na fatura até 24 h depois; confira em **Billing → Bills**.

## Alerta de custo

O budget `workshop-limite-2usd` avisa o responsável por e-mail se o custo do
mês (real ou previsto) passar de US$ 2, sem abater créditos (ADR 0012). Ele só
avisa: se o e-mail chegar, rode o `destroy.sh`. Para remover o alerta depois do
workshop:

```bash
aws budgets delete-budget --account-id $ACCOUNT --budget-name workshop-limite-2usd
```
