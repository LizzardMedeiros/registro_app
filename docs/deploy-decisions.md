# Registro de decisões do deploy

Retomada do trabalho sem repetir a entrevista. Decisões detalhadas em
[`docs/adr/`](adr/README.md). Sem segredos neste arquivo.

## Estado atual (2026-09-24)

| Item | Situação |
|---|---|
| Conta AWS 270244457878 | Ativa (plano Free, US$ 100 de crédito até 2027-03-24). Bloqueio inicial: cartão vencido |
| Provedor OIDC + role `github-actions-workshop` | Criados e restritos ao environment `lab` |
| Environment `lab` no GitHub | Criado (somente `main`), variáveis configuradas |
| Implementação (API, testes, scripts, workflow) | Concluída na branch `feat/deploy-pipeline` |
| `deploy.sh --dry-run` / `destroy.sh --dry-run` | Executados com sucesso contra a conta |
| Ensaio real (provisionar → verificar → destruir) | Concluído em 2026-09-24, sem remanescentes |
| Ambiente `lab-lizzard` | **Destruído** após o ensaio; aguardando provisionamento para o workshop |

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

## Ensaio de 2026-09-24

Executado localmente com `deploy.sh --provision` e `destroy.sh --yes`, com a mesma
lógica do pipeline. O caminho OIDC do GitHub ainda não foi exercitado, porque
depende do merge na `main`.

| Etapa | Resultado |
|---|---|
| Provisionamento completo | ~12 min (RDS ~6 min), exit 0 |
| Verificação funcional do script | health, site, CORS, cadastro e consulta OK |
| Conferência manual | site 200 com `Cache-Control: no-cache`; `config.js` com IP e versão; login e `/me` persistidos; RDS `PubliclyAccessible=False`, backup 0, porta 5432 inacessível de fora |
| Destruição | exit 0, "nenhum remanescente" |
| Conferência independente | 0 ENIs, 0 IPs, 0 RDS/snapshots/backups, 0 clusters, 0 ECR, 0 S3, 0 logs, 0 SSM, 0 roles `registro-*`; só a VPC padrão da conta |
| Índice de tags | ainda lista tasks `STOPPED`, cluster `INACTIVE` e task definition `DELETE_IN_PROGRESS` do ECS: registros históricos, sem custo |

## Hipóteses pendentes

- **Plano Free:** confirmado no ensaio que Fargate, RDS, S3, ECR, SSM e Logs são
  permitidos.
- **Cotas:** Fargate com 6 vCPU on-demand (o lab usa 0,25); PostgreSQL 16.15
  disponível para `db.t4g.micro`.
- **Créditos:** não abatidos no cálculo abaixo, nem no alerta de orçamento.

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
