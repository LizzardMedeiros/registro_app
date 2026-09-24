# Registro de decisões do deploy

Retomada do trabalho sem repetir a entrevista. Decisões detalhadas em
[`docs/adr/`](adr/README.md). Sem segredos neste arquivo.

## Estado atual (2026-09-24)

| Item | Situação |
|---|---|
| Conta AWS 270244457878 | **Em ativação** (`OptInRequired`/`NotSignedUp` em EC2, S3, RDS, ECS, SSM) |
| Provedor OIDC + role `github-actions-workshop` | Criados e restritos ao environment `lab` |
| Environment `lab` no GitHub | Criado (somente `main`), variáveis configuradas |
| Implementação (API, testes, scripts, workflow) | Concluída na branch `feat/deploy-pipeline` |
| `deploy.sh --dry-run` / `destroy.sh --dry-run` | Executados com sucesso contra a conta |
| Provisionamento real | Aguardando ativação da conta |

## Fatos encontrados no código

- API: Node + Express 4 (CommonJS), `bcryptjs`, `jsonwebtoken`, `pg`; lockfile
  `api/package-lock.json`; porta 3000; health `GET /api/health`.
- Migrations SQL em `api/migrations/`, aplicadas em ordem por `src/migrate.js`
  com tabela `schema_migrations` (feito para rodar como task única).
- Conexão com o banco por `DATABASE_URL` ou variáveis `PG*`; TLS verificado
  com `DB_SSL=true` e CA da AWS baixado no build da imagem.
- Imagem roda como usuário `node` (não-root).
- Frontend: HTML/CSS/JS puro, sem build; chamava `/api` na mesma origem.
- Não havia testes, linters, workflows nem scripts de infraestrutura.
- Lacunas corrigidas: sem CORS; `app.listen` no módulo (impedia testes);
  `JWT_SECRET` com valor padrão aceito em produção; e-mail validado antes do
  `trim` (bug); sem HEALTHCHECK; Node 20 na imagem.

## Respostas do responsável

| Pergunta | Resposta |
|---|---|
| Conta, perfil, região | 270244457878, perfil `personal`, `us-east-1` |
| Credencial root | Aceita explicitamente (conta descartável) |
| Identificador do grupo | `lab-lizzard` |
| Repositório | Fork `LizzardMedeiros/registro_app` |
| Permissões da role do CI | `AdministratorAccess` |
| Escopo da trust | Este repositório (restrito depois ao environment `lab`) |
| Uso | Só o responsável, testes manuais, acesso público, interrupção breve aceita |
| Hospedagem | Padrão do `DEPLOY.md` (ECS Fargate, RDS, S3 website) |
| Uploads, jobs, WebSockets | Não existem no código |
| Orçamento e duração | Perguntou sobre free tier; meta de US$ 0,50 mantida (estimativa bem abaixo) |
| Quem confirma o encerramento | O responsável, na conversa |
| Proteção contra esquecimento | Alerta do AWS Budgets de US$ 2/mês por e-mail (ADR 0012) |

## Hipóteses pendentes

- **Plano da conta (Free ou Paid):** não verificável antes da ativação. No plano
  Free, alguns serviços podem ser restritos; se Fargate ou RDS forem bloqueados,
  migrar para Paid (os créditos continuam valendo).
- **Créditos:** contas novas recebem US$ 100 (mais até US$ 100 em tarefas). Não
  presumidos no cálculo abaixo.
- **Cotas de conta nova** (vCPU do Fargate, instâncias RDS): conferir no primeiro
  provisionamento.

## Custo estimado

Calculado por `scripts/estimate-cost.sh` com a AWS Pricing API (preços
on-demand, sem créditos nem free tier). Inclui 0,5 h extra de task para
migrations e sobreposição.

Estimativa para 2 h (consulta à AWS Pricing API em 2026-09-24)

| Recurso | Configuração | Tarifa (USD) | Unidade | Subtotal (USD) |
|---|---|---|---|---|
| Fargate vCPU | 0.25 vCPU x 2.5 h | 0.04048 | vCPU-hora | 0.0253 |
| Fargate memória | 0.5 GB x 2.5 h | 0.004445 | GB-hora | 0.0056 |
| RDS PostgreSQL | db.t4g.micro Single-AZ x 2 h | 0.016 | hora | 0.0320 |
| RDS armazenamento | 20 GB gp3 | 0.115 | GB-mês | 0.0063 |
| IPv4 público (task) | 1 x 2.5 h | 0.005 | IP-hora | 0.0125 |
| ECR armazenamento | 0.1 GB | 0.1 | GB-mês | 0.0000 |
| S3 armazenamento | < 1 MB | 0.023 | GB-mês | 0.0000 |
| S3 PUT/LIST | 50 req | 5e-06 | req | 0.0003 |
| S3 GET | 2000 req | 4e-07 | req | 0.0008 |
| CloudWatch Logs | 0.01 GB ingeridos | 0.5 | GB | 0.0050 |
| SSM Parameter Store | parâmetros Standard | 0 | grátis | 0.0000 |
| Transferência de saída | < 1 GB (100 GB/mês grátis) | 0 | GB | 0.0000 |

**Total estimado: US$ 0.0877** para 2 h | custo por hora ~US$ 0.0439 | 24 h ~US$ 1.05

- Custo AWS apenas. GitHub Actions é gratuito em repositório público; o uso do
  agente de IA é cobrado à parte.
- Incertezas: logs e requisições dependem do uso; tráfego de saída < 1 GB fica
  na franquia gratuita de 100 GB/mês.
- Um alerta de orçamento não desliga recursos: o encerramento é o `destroy.sh`.

## Inventário de recursos por ambiente

| Recurso | Nome | Criado por |
|---|---|---|
| VPC, IGW, 1 sub-rede pública, 2 privadas, route table | `registro-lab-lizzard-*` | deploy.sh |
| Security groups | `registro-lab-lizzard-api-sg`, `-db-sg` | deploy.sh |
| ECR | `registro-lab-lizzard-api` | deploy.sh |
| SSM | `/registro/lab-lizzard/{db-password,jwt-secret,state}` | deploy.sh |
| CloudWatch Logs | `/ecs/registro-lab-lizzard` (retenção 1 dia) | deploy.sh |
| IAM role de execução | `registro-lab-lizzard-ecs-exec` | deploy.sh |
| S3 website | `registro-lab-lizzard-270244457878-site` | deploy.sh |
| RDS + subnet group | `registro-lab-lizzard-db`, `-db-subnets` | deploy.sh |
| ECS cluster, serviço, task definitions | `registro-lab-lizzard`, `-api` | deploy.sh |
| IPv4 público da task | (efêmero) | ECS |
| Provedor OIDC, role `github-actions-workshop` | compartilhados | bootstrap (preservados) |
| Budget `workshop-limite-2usd` | conta | AWS CLI, uma vez (preservado) |

## Escopo autorizado

- Criar e atualizar o ambiente `lab-lizzard` na conta 270244457878.
- Configurar o environment `lab` e variáveis no fork.
- Destruir: **somente após confirmação explícita** do responsável na conversa.
